import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync } from 'node:fs';
import { createConnection, createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const notReachable = new Set(['not_attached', 'vm_service_connection_failed', 'vm_service_uri_unavailable']);
const lossCodes = {
  exit: ['scout_agent_exited', 'Scout agent process exited'],
  spawn: ['scout_agent_spawn_failed', 'Scout agent process could not run; check flutter-scout is on PATH'],
  stdin: ['scout_agent_transport_error', 'Scout agent input pipe failed'],
  protocol: ['scout_agent_protocol_error', 'Scout agent sent malformed or uncorrelated output'],
  timeout: ['scout_agent_request_timeout', 'Scout agent did not answer within the request budget'],
  abort: ['scout_agent_aborted', 'Scout connection was aborted by the client'],
};

function agentError(code, message, extra = {}) {
  return Object.assign(new Error(message), { code, dispatch: 'not_dispatched', ...extra });
}

// Bounds for taps() and steps() and for the settled scene after an input.
const maxTaps = 32;
const maxSteps = 16;
const settleBudgetMs = 3000;

// Options that keep a step on its exact observed handles.
const tapStepParams = new Set(['button', 'taps', 'intervalMs', 'lateWaitMs']);
const gestureStepParams = new Set(['target', 'distance']);

/** The exact handles one steps() action presses, or why it is not an
 * exact-handle action (tap, long-press, input, fill, scroll or swipe on
 * observed handles; the same forms the agent's staleness guard scopes). */
export function stepHandles(action) {
  if (!action || typeof action !== 'object' || Array.isArray(action)) return 'an action object is required';
  const extra = Object.keys(action).filter(key => !['method', 'args', 'params', 'allowUnrelatedChanges'].includes(key));
  if (extra.length) return `unexpected ${extra.join(', ')}`;
  if (action.allowUnrelatedChanges !== undefined && typeof action.allowUnrelatedChanges !== 'boolean') {
    return 'allowUnrelatedChanges must be true or false';
  }
  const args = action.args ?? [];
  const params = action.params ?? {};
  if (!Array.isArray(args) || !params || typeof params !== 'object' || Array.isArray(params)) return 'args must be a list and params an object';
  const keys = Object.keys(params);
  const named = values => (values.length && values.every(value => typeof value === 'string' && value && value.trim() === value)
    ? values : null);
  let targets = null;
  switch (action.method) {
    case 'tap': if (args.length === 1 && keys.every(key => tapStepParams.has(key))) targets = named(args); break;
    case 'long-press': if (args.length === 1 && !keys.length) targets = named(args); break;
    case 'input': if (args.length === 1 && keys.length === 1 && keys[0] === 'target') targets = named([params.target]); break;
    case 'fill':
      if (!args.length && keys.length === 1 && params.json && typeof params.json === 'object' && !Array.isArray(params.json)) {
        targets = named(Object.keys(params.json));
      }
      break;
    case 'scroll': case 'swipe':
      if (args.length <= 1 && typeof params.target === 'string' && keys.every(key => gestureStepParams.has(key))) {
        targets = named([params.target]);
      }
      break;
  }
  return targets ?? 'steps take only exact-handle tap, long-press, input (params.target), fill, scroll or swipe (params.target); use act for text, coordinate and navigation input';
}

const controlOf = (view, id) => (Array.isArray(view?.interactables) ? view.interactables : []).find(control => control?.id === id);
const viewHas = (view, id) => Boolean(controlOf(view, id)) ||
  Boolean(view?.fieldValues && typeof view.fieldValues === 'object' && Object.hasOwn(view.fieldValues, id));
const surfaceOf = view => JSON.stringify([view?.activeSurface?.kind ?? null, view?.activeSurface?.instance ?? null]);

/** Why the next step must not be sent on [current] (the settled scene after
 * the step before), or null: a different screen or surface, a scene that had
 * not settled, or a step handle that now names another control. */
export function stepDrift(decision, current, targets, settle) {
  if (settle && !['settled', 'unchanged'].includes(settle.status)) {
    return { code: 'steps_view_unsettled', message: `the view was ${settle.status} after the previous step; observe and decide again.` };
  }
  if (current?.screen !== decision?.screen || surfaceOf(current) !== surfaceOf(decision)) {
    return { code: 'steps_screen_changed', message: `the previous step moved to ${current?.screen ?? 'another screen'}; observe and decide again.`,
      staleChanges: [{ field: 'screen', before: decision?.screen ?? null, after: current?.screen ?? null }] };
  }
  const changes = [];
  for (const target of targets) {
    if (!viewHas(current, target)) { changes.push({ target, disappeared: true }); continue; }
    const was = controlOf(decision, target);
    const now = controlOf(current, target);
    if (!was && !now) continue;
    for (const key of ['instance', 'kind', 'label']) {
      if (was?.[key] !== now?.[key]) changes.push({ target, field: key, before: was?.[key] ?? null, after: now?.[key] ?? null });
    }
  }
  return changes.length
    ? { code: 'steps_target_changed', message: `${changes[0].target} is no longer the control you decided on; observe and decide again.`, staleChanges: changes }
    : null;
}

/** Every input outcome carries the next decision's revision at the top
 * level, as observe does; the screen itself stays in `scene.view`. */
function withRevision(outcome) {
  const revision = outcome.scene?.viewRevision;
  return Number.isInteger(revision) && outcome.viewRevision === undefined ? { ...outcome, viewRevision: revision } : outcome;
}

/** Why an input or its follow-up observation failed, from the canonical
 * receipt first, then the scene. */
function inputFailure(result, scene) {
  const receipt = result && typeof result === 'object' ? result : {};
  const error = receipt.error ?? receipt.structuredError ??
    (receipt.ok === true ? scene?.error ?? scene?.blockedBy : null) ??
    { code: 'input_failed_without_reason', message: 'The input receipt reported ok:false without a reason; read result and scene.' };
  return { error, dispatch: receipt.dispatch ?? null };
}

/** Whether a canonical receipt's delta saw any change on the screen. */
function deltaShowsChange(delta) {
  if (!delta || typeof delta !== 'object') return false;
  const nonEmpty = value => Array.isArray(value) && value.length > 0;
  return delta.viewChanged === true || delta.viewport?.changed === true || delta.keyboard?.changed === true ||
    ['newText', 'removedText', 'changedText', 'newFields', 'removedFields', 'changedFields',
      'controlStateChanges', 'changedGeometry', 'newInteractables', 'removedInteractables']
      .some(key => nonEmpty(delta[key])) ||
    nonEmpty(delta.scroll?.changedRegions) || nonEmpty(delta.scroll?.newRegions) ||
    nonEmpty(delta.scroll?.removedRegions);
}

const sinceInputLimit = 8;
const controlStateKeys = ['enabled', 'selected', 'checked', 'toggled', 'expanded', 'label'];

/** What the settled view shows that the view before the input did not
 * (bounded): texts and controls that appeared or went, controls whose state
 * changed, and changed field values. Null when nothing differs. */
function viewDifference(before, after) {
  if (!before || !after || typeof before !== 'object' || typeof after !== 'object') return null;
  const strings = view => new Set((Array.isArray(view.visibleText) ? view.visibleText : []).filter(t => typeof t === 'string'));
  const controls = view => new Map((Array.isArray(view.interactables) ? view.interactables : [])
    .filter(c => c && typeof c.id === 'string').map(c => [c.id, c]));
  const take = values => values.slice(0, sinceInputLimit);
  const [textBefore, textAfter] = [strings(before), strings(after)];
  const [controlsBefore, controlsAfter] = [controls(before), controls(after)];
  const changedControls = [];
  for (const [id, now] of controlsAfter) {
    const was = controlsBefore.get(id);
    if (!was) continue;
    const changed = {};
    for (const key of controlStateKeys) {
      if (was[key] !== now[key]) changed[key] = { before: was[key] ?? null, after: now[key] ?? null };
    }
    if (Object.keys(changed).length) changedControls.push({ id, ...changed });
  }
  const fieldsBefore = before.fieldValues && typeof before.fieldValues === 'object' ? before.fieldValues : {};
  const fieldsAfter = after.fieldValues && typeof after.fieldValues === 'object' ? after.fieldValues : {};
  const changedFields = Object.keys(fieldsAfter)
    .filter(id => JSON.stringify(fieldsBefore[id]) !== JSON.stringify(fieldsAfter[id]));
  const difference = {
    appearedText: take([...textAfter].filter(t => !textBefore.has(t))),
    goneText: take([...textBefore].filter(t => !textAfter.has(t))),
    appearedControls: take([...controlsAfter.keys()].filter(id => !controlsBefore.has(id))),
    goneControls: take([...controlsBefore.keys()].filter(id => !controlsAfter.has(id))),
    changedControls: take(changedControls),
    changedFields: take(changedFields),
  };
  for (const key of Object.keys(difference)) if (!difference[key].length) delete difference[key];
  return Object.keys(difference).length ? difference : null;
}

/** Persistent JSONL client. No ports, screenshots, implicit retries or app logic. */
export class ScoutAgent {
  static async connect({ app, binary = 'flutter-scout', cwd, intervalMs = 250, maxItems = 60, overlay = true } = {}) {
    if (typeof app !== 'string' || !app || !Number.isInteger(intervalMs) ||
        intervalMs < 100 || intervalMs > 10000 || !Number.isInteger(maxItems) ||
        maxItems < 1 || maxItems > 100) throw new TypeError('A named app and bounded polling options are required');
    const child = spawn(binary, ['--app', app, 'agent', '--interval-ms', String(intervalMs),
      '--max-items', String(maxItems), ...(overlay === false ? ['--no-overlay'] : [])],
    { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    const client = new ScoutAgent(child);
    client.intervalMs = intervalMs;
    let ready;
    try { ready = await client.ready; } catch (error) { throw await client.settle(error); }
    if (ready.agentProtocol !== 2) {
      client.abort();
      throw await client.settle(agentError('scout_agent_protocol_mismatch',
        `flutter-scout speaks agentProtocol ${ready.agentProtocol ?? 'none'}; this client needs 2. Update the CLI and this skill together.`));
    }
    if (!ready.ok) {
      const cause = ready.view?.error?.code ?? ready.hand?.halted ?? null;
      const detail = typeof ready.view?.error?.message === 'string' ? ` ${ready.view.error.message.slice(0, 300)}` : '';
      const [code, message] = cause === 'flutter_scout_helper_not_registered'
        ? ['scout_helper_missing', 'The app is reachable but flutter_scout_helper is not registered. Add FlutterScoutBinding.ensureInitialized() before runApp and relaunch.']
        : notReachable.has(cause)
          ? ['scout_app_unreachable', `The named session has no reachable app (${cause}). Check flutter-scout --app <name> status; ensure or relaunch if it stopped.`]
          : ['scout_agent_not_ready', `Scout opened but the app is not observable (${cause ?? 'unknown'}).`];
      client.abort();
      throw await client.settle(agentError(code, message + detail, { cause }));
    }
    return client;
  }

  constructor(child) {
    this.child = child;
    this.pending = new Map();
    this.serial = 0;
    this.latest = null;
    this.intervalMs = 250;
    this.closed = false;
    this.closing = false;
    this.failure = null;
    this.buffer = Buffer.alloc(0);
    // Hand state seen by this client. Any of it turns a lost transport into
    // an unknown dispatch instead of a clean read-only failure.
    this.unreceipted = null;
    this.armed = new Set();
    this.exit = null;
    this.stderrTail = '';
    this.exited = new Promise(resolve => { this.resolveExited = resolve; });
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.readyTimer = setTimeout(() => this.fail('timeout'), 45000);
    child.stdout.on('data', chunk => this.receive(chunk));
    // Keep only a bounded tail of CLI diagnostics for failure reports.
    child.stderr.on('data', chunk => { this.stderrTail = (this.stderrTail + chunk.toString('utf8')).slice(-4096); });
    child.on('error', () => this.fail('spawn'));
    child.stdin.on('error', () => this.fail('stdin'));
    child.on('exit', (code, signal) => {
      this.exit = { exitCode: code ?? null, signal: signal ?? null };
      this.resolveExited();
      // Let buffered stdout/stderr drain before classifying the loss.
      if (!this.closed) setTimeout(() => this.fail('exit'), 50);
    });
  }

  /** Last non-empty CLI stderr line, bounded. */
  get lastStderr() {
    const lines = this.stderrTail.split('\n').map(line => line.trim()).filter(Boolean);
    return lines.length ? lines[lines.length - 1].slice(0, 300) : null;
  }

  /** True when an input may be executing or its receipt is still unread. */
  get inFlight() {
    return Boolean(this.acting || this.unreceipted || this.armed.size ||
      [...this.pending.values()].some(request => request.method === 'start'));
  }

  /** Waits briefly for the child to exit, then attaches its exit facts. */
  async settle(error) {
    await Promise.race([this.exited, new Promise(resolve => setTimeout(resolve, 1500).unref?.())]);
    const own = this.exit && !this.terminated;
    if (!this.exit) this.terminate();
    return Object.assign(error, {
      exitCode: own ? this.exit.exitCode : null,
      signal: own ? this.exit.signal : null,
      stderr: this.lastStderr,
    });
  }

  terminate() {
    if (this.exit) return;
    this.terminated = true;
    this.child.kill();
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const end = this.buffer.indexOf(10);
      if (end < 0) break;
      if (end > 8 * 1024 * 1024) return this.fail('protocol');
      const line = this.buffer.subarray(0, end).toString('utf8');
      this.buffer = this.buffer.subarray(end + 1);
      let value;
      try {
        const envelope = JSON.parse(line);
        value = envelope.result && typeof envelope.result === 'object' && !Array.isArray(envelope.result)
          ? { ...envelope.result, ...(typeof envelope.ok === 'boolean' ? { ok: envelope.ok } : {}),
              ...(envelope.structuredError ? { error: envelope.structuredError } : {}) }
          : envelope;
        if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
        // Request-level failures can be flattened by the canonical CLI error
        // envelope. Keep their outcome/safety fields without retransmitting
        // the static capability table and unavailable timing schema.
        if (value === envelope && typeof value.id === 'string') {
          value = { ...value };
          for (const key of ['capabilities', 'protocolRange', 'identityAvailability', 'timings']) delete value[key];
        }
      } catch { return this.fail('protocol'); }
      if (value.type === 'ready' && this.resolveReady) {
        clearTimeout(this.readyTimer);
        this.latest = value;
        const resolve = this.resolveReady;
        this.resolveReady = this.rejectReady = null;
        resolve(value);
        continue;
      }
      if (this.rejectReady && value.ok === false && !value.id) {
        // A command-level CLI failure (unknown session, busy lease, ...) uses
        // the canonical envelope: result:null plus structuredError.
        const cause = value.error && typeof value.error === 'object' ? value.error : value.structuredError;
        const error = agentError(cause?.code ?? 'scout_agent_unavailable',
          cause?.message ?? 'Scout agent could not open');
        clearTimeout(this.readyTimer);
        this.rejectReady(error);
        this.resolveReady = this.rejectReady = null;
        // The CLI exits by itself after this envelope; settle() keeps its
        // exit code and only terminates a child that lingers.
        this.closed = true;
        return;
      }
      const request = this.pending.get(value.id);
      if (!request) return this.fail('protocol');
      this.pending.delete(value.id);
      clearTimeout(request.timer);
      if (value.view && (value.viewRevision ?? -1) >= (this.latest?.viewRevision ?? -1)) this.latest = value;
      // A rejected hand request carries the current scene for one new decision.
      if (value.scene?.view && (value.scene.viewRevision ?? -1) >= (this.latest?.viewRevision ?? -1)) this.latest = value.scene;
      if (value.event?.view) {
        // Historical events stay historical: never overwrite a newer view.
        if ((value.event.viewRevision ?? -1) >= (this.latest?.viewRevision ?? -1)) {
          this.latest = { view: value.event.view, viewRevision: value.event.viewRevision };
        }
      }
      this.track(request, value);
      if (request.method === 'close' && value.ok === true && value.type === 'closed') {
        this.closed = true;
        this.child.stdin.end();
      }
      request.resolve(value);
    }
    if (this.buffer.length > 8 * 1024 * 1024) this.fail('protocol');
  }

  track(request, value) {
    if (request.method === 'start' && value.ok === true && value.actionId) this.unreceipted = value.actionId;
    if (request.method === 'react' && value.ok === true && value.conditionId) this.armed.add(value.conditionId);
    if (request.method === 'cancel' && value.ok === true && request.params.scope === 'reaction') {
      this.armed.delete(request.params.conditionId);
    }
    const event = value.event;
    if (event?.type === 'action' && event.actionId === this.unreceipted) this.unreceipted = null;
    if (event?.type === 'reaction' && event.status !== 'hand_busy') {
      this.armed.delete(event.conditionId);
      if (event.status === 'triggered' && event.actionId) this.unreceipted = event.actionId;
    }
  }

  fail(reason = 'abort') {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.readyTimer);
    const [code, base] = lossCodes[reason] ?? lossCodes.abort;
    const exit = this.exit
      ? ` (${this.exit.signal ? `signal ${this.exit.signal}` : `exit code ${this.exit.exitCode}`})` : '';
    const inFlight = this.inFlight;
    const stderr = this.lastStderr;
    const message = `Scout connection lost: ${base}${exit}. ` + (inFlight
      ? 'An input was in flight and may have dispatched. Reconcile; never retry automatically.'
      : 'No input was in flight; reconnect and observe again.') + (stderr ? ` Last stderr: ${stderr}` : '');
    const error = agentError(code, message, {
      dispatch: inFlight ? 'dispatch_outcome_unknown' : 'not_dispatched',
      exitCode: this.exit?.exitCode ?? null,
      signal: this.exit?.signal ?? null,
      stderr,
    });
    this.failure = error;
    this.rejectReady?.(error);
    this.resolveReady = this.rejectReady = null;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
    this.terminate();
  }

  request(method, params = {}, timeoutMs = 45000) {
    if (this.closed || (this.closing && method !== 'close')) {
      return Promise.reject(agentError('scout_client_closed',
        `Scout client closed${this.failure ? ` after ${this.failure.code}` : ''}; open a new connection.`,
        { cause: this.failure?.code ?? null }));
    }
    if (this.pending.size >= 16) return Promise.reject(new Error('At most 16 concurrent requests'));
    const id = `q${++this.serial}`;
    const line = JSON.stringify({ ...params, id, method }) + '\n';
    if (Buffer.byteLength(line) > 65536) return Promise.reject(new Error('Request exceeds 64 KiB'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail('timeout'), timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method, params });
      this.child.stdin.write(line, error => { if (error) this.fail('stdin'); });
    });
  }

  observe() { return this.request('observe'); }
  foreground() { return this.request('foreground'); }
  async query(method, params = {}, args = []) {
    const response = await this.request('query', { query: { method, params, args } });
    return response.queryResult ? { ...response.queryResult, ok: response.ok } : response;
  }
  status() { return this.request('status'); }
  start(viewRevision, action) { return this.request('start', { viewRevision, action }); }
  acknowledge(actionId) { return this.request('acknowledge', { actionId }); }
  reconcile(actionId, viewRevision) { return this.request('reconcile', { actionId, viewRevision }); }

  /** One input, with independent eyes throughout; never retries or waits for
   * business completion. Returns all intervening events, including failures;
   * plain view updates are only counted (`viewEvents`), as the returned
   * scene is newer.
   * After an input that dispatched, the returned scene is taken once the
   * eyes saw the view settle (see settledScene).
   * Do not run another next()/act() consumer concurrently. */
  async act(viewRevision, action, timeoutMs = 45000) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new TypeError('act timeout must be 1..120000 ms');
    if (this.acting || this.consuming) throw new Error('Only one act/event consumer at a time');
    this.acting = true;
    const log = { events: [], viewEvents: 0 };
    const deadline = Date.now() + timeoutMs;
    const before = this.latest?.view;
    const beforeRevision = this.latest?.viewRevision;
    try {
      const step = await this.inputOnce(viewRevision, action, deadline, log);
      if (step.stopped) return withRevision(step.stopped);
      const { scene, settle } = await this.settledScene(step.result, before, beforeRevision, deadline, log);
      const ok = step.result?.ok === true && scene.ok === true;
      // A failed input keeps its reason in the receipt; lift it so a caller
      // reading only the top level never sees ok:false with no error.
      const failure = ok ? null : inputFailure(step.result, scene);
      return withRevision({ ok, actionId: step.actionId,
        ...(failure ? { error: failure.error, dispatch: failure.dispatch } : {}),
        result: step.result, ...(settle ? { settle } : {}), scene, ...log });
    } finally { this.acting = false; }
  }

  /** Taps observed exact handles in order (a keypad, PIN pad or stepper),
   * all decided from `viewRevision`, one canonical receipt each, then one
   * scene. Stops at the first tap that fails or is rejected; never retries
   * or skips. Each tap is an ordinary act: the staleness guard, hit test and
   * receipt rules are unchanged, so a tap that navigates makes the next one
   * fail as stale. A keypad display that updates between keys needs
   * `allowUnrelatedChanges`. */
  async taps(viewRevision, targets, { allowUnrelatedChanges = false, timeoutMs = 45000 } = {}) {
    if (!Array.isArray(targets) || targets.length < 1 || targets.length > maxTaps ||
        targets.some(target => typeof target !== 'string' || !target)) {
      throw new TypeError(`taps needs 1..${maxTaps} observed handles`);
    }
    if (typeof allowUnrelatedChanges !== 'boolean') throw new TypeError('allowUnrelatedChanges must be true or false');
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new TypeError('taps timeout must be 1..120000 ms');
    if (this.acting || this.consuming) throw new Error('Only one act/event consumer at a time');
    this.acting = true;
    const log = { events: [], viewEvents: 0 };
    const receipts = [];
    const deadline = Date.now() + timeoutMs;
    const before = this.latest?.view;
    const beforeRevision = this.latest?.viewRevision;
    try {
      let last = null;
      for (const target of targets) {
        const action = { method: 'tap', args: [target], ...(allowUnrelatedChanges ? { allowUnrelatedChanges } : {}) };
        const step = await this.inputOnce(viewRevision, action, deadline, log);
        if (step.stopped) {
          const { scene, events: _events, viewEvents: _views, ...rest } = step.stopped;
          receipts.push({ target, ...rest });
          return withRevision({ ok: false, completed: receipts.length - 1, requested: targets.length,
            error: rest.error ?? { code: 'tap_rejected', message: `Tap ${target} was not accepted; nothing more was sent.` },
            dispatch: rest.dispatch ?? 'not_dispatched', taps: receipts,
            ...(scene ? { scene } : {}), ...log });
        }
        const result = step.result;
        receipts.push({ target, ok: result?.ok === true, actionId: step.actionId, dispatch: result?.dispatch ?? null,
          ...(result?.warnings ? { warnings: result.warnings } : {}), ...(result?.error ? { error: result.error } : {}) });
        last = step.result;
        if (result?.ok !== true) break;
      }
      // The last attempted tap keeps its whole canonical receipt; every
      // receipt stays in the private journal.
      receipts[receipts.length - 1].result = last;
      const { scene, settle } = await this.settledScene(last, before, beforeRevision, deadline, log);
      const failed = receipts.find(receipt => !receipt.ok);
      const ok = !failed && scene.ok === true;
      const failure = ok ? null : inputFailure(last, scene);
      return withRevision({ ok, completed: receipts.filter(receipt => receipt.ok).length, requested: targets.length,
        ...(failure ? { error: failure.error, dispatch: failure.dispatch } : {}),
        taps: receipts, ...(settle ? { settle } : {}), scene, ...log });
    } finally { this.acting = false; }
  }

  /** Runs a short list of exact-handle inputs (1..maxSteps) the caller
   * decided from `viewRevision`, in order, each with its own canonical
   * receipt and settle, then returns one final scene. Every handle must be
   * in that decision view. Before each later step, the settled scene from
   * the step before must still show the same screen and surface and every
   * handle of the step as the same control (`instance`, `kind`, `label`);
   * the step is then sent against that scene's revision, so the normal
   * staleness guard, hit test and receipt rules apply unchanged. It stops at
   * the first step that fails, is rejected, leaves the view unsettled, or
   * finds a changed screen or target; never retries, skips or reorders. */
  async steps(viewRevision, actions, { timeoutMs = 45000 } = {}) {
    if (!Array.isArray(actions) || actions.length < 1 || actions.length > maxSteps) {
      throw new TypeError(`steps needs 1..${maxSteps} actions`);
    }
    const handles = actions.map(stepHandles);
    const bad = handles.findIndex(entry => typeof entry === 'string');
    if (bad >= 0) throw new TypeError(`steps[${bad}]: ${handles[bad]}`);
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new TypeError('steps timeout must be 1..120000 ms');
    if (this.acting || this.consuming) throw new Error('Only one act/event consumer at a time');
    const decision = this.latest;
    const refuse = (code, message, extra = {}) => withRevision({ ok: false, completed: 0, requested: actions.length,
      dispatch: 'not_dispatched', error: { code, message, ...extra }, steps: [], ...(decision?.view ? { scene: decision } : {}),
      events: [], viewEvents: 0 });
    if (!decision?.view || decision.viewRevision !== viewRevision) {
      return refuse('steps_decision_stale', `The latest scene is revision ${decision?.viewRevision ?? 'none'}, not ${viewRevision}; observe and decide again. Nothing was sent.`);
    }
    for (const [index, targets] of handles.entries()) {
      const missing = targets.filter(target => !viewHas(decision.view, target));
      if (missing.length) {
        return refuse('steps_target_not_observed', `steps[${index}] names ${missing.join(', ')}, which revision ${viewRevision} does not show; every step must use a handle from that scene. Nothing was sent.`);
      }
    }
    this.acting = true;
    const log = { events: [], viewEvents: 0 };
    const receipts = [];
    const deadline = Date.now() + timeoutMs;
    let scene = decision;
    let settle = null;
    let last = null;
    let stop = null;
    try {
      for (const [index, action] of actions.entries()) {
        const targets = handles[index];
        if (index > 0) {
          stop = stepDrift(decision.view, scene.view, targets, settle);
          if (stop) { stop = { ...stop, message: `steps[${index}] was not sent: ${stop.message}` }; break; }
        }
        const before = scene.view;
        const beforeRevision = scene.viewRevision;
        const step = await this.inputOnce(beforeRevision, action, deadline, log);
        if (step.stopped) {
          const { scene: rejectedScene, events: _events, viewEvents: _views, ...rest } = step.stopped;
          receipts.push({ method: action.method, targets, ...rest });
          if (rejectedScene?.view) scene = rejectedScene;
          stop = rest.error ?? { code: 'step_rejected', message: `steps[${index}] was not accepted; nothing more was sent.` };
          last = null;
          break;
        }
        last = step.result;
        const settled = await this.settledScene(step.result, before, beforeRevision, deadline, log);
        scene = settled.scene;
        settle = settled.settle ?? null;
        const ok = step.result?.ok === true && scene.ok === true;
        receipts.push({ method: action.method, targets, ok, actionId: step.actionId, dispatch: step.result?.dispatch ?? null,
          ...(settle ? { settle } : {}), ...(step.result?.warnings ? { warnings: step.result.warnings } : {}),
          ...(ok ? {} : { error: inputFailure(step.result, scene).error }) });
        if (!ok) { stop = inputFailure(step.result, scene).error; break; }
      }
      // The last attempted step keeps its whole canonical receipt; every
      // receipt stays in the private journal.
      if (last && receipts.length) receipts[receipts.length - 1].result = last;
      const completed = receipts.filter(receipt => receipt.ok).length;
      const ok = !stop && completed === actions.length;
      const failed = receipts.find(receipt => !receipt.ok);
      return withRevision({ ok, completed, requested: actions.length,
        ...(ok ? {} : { error: stop, dispatch: failed ? failed.dispatch ?? 'not_dispatched' : 'not_dispatched' }),
        steps: receipts, scene, ...log });
    } finally { this.acting = false; }
  }

  /** start() one input and consume its receipt; acknowledges success.
   * Returns {actionId, result}, or {stopped} with the response to return. */
  async inputOnce(viewRevision, action, deadline, log) {
    const ticket = await this.start(viewRevision, action);
    if (!ticket.ok) return { stopped: { ...ticket, ...log } };
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0 || log.events.length + log.viewEvents > 80) {
        this.abort();
        throw Object.assign(new Error('Input receipt unavailable within the bounded action budget; reconcile before further input'),
          { code: 'scout_agent_receipt_unavailable', dispatch: 'dispatch_outcome_unknown' });
      }
      const response = await this.next(Math.min(10000, remaining));
      if (!response.ok) return { stopped: { ...response, actionId: ticket.actionId, ...log } };
      const event = response.event;
      if (event?.type === 'timeout') continue;
      // Plain view updates are only counted: the returned scene is newer.
      if (event?.type === 'view') { log.viewEvents += 1; continue; }
      if (event?.type !== 'action' || event.actionId !== ticket.actionId) log.events.push(event);
      if (event?.type === 'closed') {
        throw agentError('scout_agent_closed_before_receipt',
          'Scout closed before delivering the input receipt; reconcile before further input',
          { dispatch: 'dispatch_outcome_unknown' });
      }
      if (event?.type !== 'action' || event.actionId !== ticket.actionId) continue;
      if (event.result?.ok === true) {
        const acknowledged = await this.acknowledge(ticket.actionId);
        if (!acknowledged.ok) return { stopped: { ...acknowledged, actionId: ticket.actionId, result: event.result, ...log } };
      }
      return { actionId: ticket.actionId, result: event.result };
    }
  }

  /** The scene after an input that dispatched successfully. The receipt is
   * taken right after dispatch, so an effect the app applies a moment later
   * (a cart total recomputed, a list loading on a new screen) may not be in
   * it yet. When the view changed, act therefore waits until the passive
   * eyes report no view change for two consecutive samples, at most
   * settleBudgetMs, then observes, so the returned revision is usable for
   * the next decision. When nothing changed (the receipt saw no change and
   * the scene after it has the revision from before the input; the eyes
   * advance the revision only when the view changes), it waits one eyes
   * interval for a change about to land and, if none
   * comes, returns that scene (`unchanged`); a slower effect is for watch.
   * No frames are pumped and nothing is retried. `settle` reports what
   * happened: `trigger` says what the receipt saw (`screen` for a new
   * screen, route or surface, `in_place` for a change on the same screen,
   * `none` when the receipt saw no change yet), and `sinceInput` names what
   * differs from the view before the input. A failed or not-dispatched input
   * returns the scene at once. */
  async settledScene(result, before, beforeRevision, deadline, log) {
    const settled = await this.settleAfterInput(result, before, beforeRevision, deadline, log);
    // A tap that changed only how its target is painted: its state likely
    // changed where Scout cannot read it. Say so where the outcome is read.
    const painted = result?.paintOnlyChange?.target;
    return painted && settled.settle ? { ...settled, settle: { ...settled.settle, paintOnlyChange: painted } } : settled;
  }

  async settleAfterInput(result, before, beforeRevision, deadline, log) {
    let scene = await this.observe();
    if (result?.ok !== true || scene.ok !== true) return { scene };
    const delta = result.delta;
    const moved = delta?.screenChanged === true || delta?.route?.changed === true ||
      delta?.activeSurface?.changed === true ||
      (typeof before?.screen === 'string' && typeof scene.view?.screen === 'string' && before.screen !== scene.view.screen);
    const trigger = moved ? 'screen' : deltaShowsChange(delta) ? 'in_place' : 'none';
    const unchanged = trigger === 'none' && Number.isInteger(beforeRevision) &&
      scene.viewRevision === beforeRevision;
    // The helper already waited out the late-change window and saw that the
    // input's own work had settled with Flutter idle: nothing is about to
    // land, so the eyes interval below would only repeat that check.
    if (unchanged && result.lateWindow?.ended === 'input_idle') {
      return { scene, settle: { status: 'unchanged', trigger, waitedMs: 0, viewChanges: 0, basis: 'input_idle' } };
    }
    const quietMs = Math.max(500, 2 * this.intervalMs);
    // Nothing changed yet: one eyes interval, widened to the full quiet
    // window as soon as the eyes report a change.
    let windowMs = unchanged ? this.intervalMs : quietMs;
    const started = Date.now();
    const budget = Math.min(settleBudgetMs, deadline - started);
    let viewChanges = 0;
    let status = 'still_changing';
    while (Date.now() - started < budget) {
      const wait = Math.min(windowMs, budget - (Date.now() - started));
      const response = await this.next(wait);
      if (!response.ok) { status = 'unavailable'; break; }
      const event = response.event;
      if (event?.type === 'timeout') {
        // A full window with no view event: the samples saw one state.
        if (wait === windowMs) status = viewChanges === 0 && unchanged ? 'unchanged' : 'settled';
        break;
      }
      if (event?.type === 'view') { viewChanges += 1; windowMs = quietMs; continue; }
      log.events.push(event);
      if (event?.type === 'closed') { status = 'unavailable'; break; }
    }
    // The scene taken after the receipt is still current.
    if (status === 'unchanged') {
      return { scene, settle: { status, trigger, waitedMs: Date.now() - started, viewChanges } };
    }
    scene = await this.observe();
    const sinceInput = viewDifference(before, scene.view);
    return { scene, settle: { status, trigger, waitedMs: Date.now() - started, viewChanges,
      ...(sinceInput ? { sinceInput } : {}) } };
  }
  watch(condition, timeoutMs = 5000) { return this.request('watch', { condition, timeoutMs }); }

  /** watch() that blocks until its condition ends (met, timeout, ...) and
   * returns that event: ok is true only when the condition was met. It is
   * the event consumer meanwhile; other events it reads come back in
   * `events`, except plain view updates, which are only counted. */
  async watchUntil(condition, timeoutMs = 5000) {
    if (this.acting || this.consuming) throw new Error('Only one act/event consumer at a time');
    this.consuming = true;
    const events = [];
    let viewEvents = 0;
    try {
      const ticket = await this.watch(condition, timeoutMs);
      if (!ticket.ok) return { ...ticket, events };
      // The session ends the condition at its own deadline; this only
      // bounds a lost event.
      const deadline = Date.now() + timeoutMs + 15000;
      for (;;) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) {
          return { ok: false, conditionId: ticket.conditionId, events, viewEvents,
            error: { code: 'watch_event_unavailable',
              message: 'The condition did not report an end within its timeout; observe, then cancel or watch again.' } };
        }
        const response = await this.next(Math.min(30000, remaining));
        if (!response.ok) return { ...response, conditionId: ticket.conditionId, events, viewEvents };
        const event = response.event;
        if (event?.type === 'timeout') continue;
        if (event?.type === 'view') { viewEvents += 1; continue; }
        if (event?.type === 'condition' && event.conditionId === ticket.conditionId) {
          const { type, ...ended } = event;
          const met = event.status === 'met';
          return { ok: met, ...ended,
            ...(met ? {} : { error: { code: 'watch_not_met',
              message: `The condition ended ${event.status} before it was met.` } }),
            events, viewEvents };
        }
        events.push(event);
        if (event?.type === 'closed') {
          return { ok: false, conditionId: ticket.conditionId, events, viewEvents,
            error: { code: 'scout_agent_closed', message: 'Scout closed before the condition ended.' } };
        }
      }
    } finally { this.consuming = false; }
  }
  react(viewRevision, condition, reaction, timeoutMs = 5000) {
    return this.request('react', { viewRevision, condition, reaction, timeoutMs });
  }
  next(timeoutMs = 10000) { return this.request('next', { timeoutMs }); }
  cancel(scope, conditionId) { return this.request('cancel', { scope, ...(conditionId ? { conditionId } : {}) }); }
  close() {
    if (this.closed) return Promise.resolve({ ok: true, type: 'closed' });
    if (!this.closePromise) {
      this.closing = true;
      this.closePromise = this.request('close');
    }
    return this.closePromise;
  }
  /** Emergency transport shutdown, NOT app-operation cancellation. */
  abort() { this.fail('abort'); }
}

// ---------------------------------------------------------------------------
// Shell bridge for agents without a persistent Node tool (e.g. Claude Code's
// Bash tool). `serve` keeps ONE ScoutAgent connection in a background process
// behind a private Unix socket; each `call` sends one request to it. It adds
// no retries, queues or app logic: one hand, receipts and acknowledgement are
// the ScoutAgent semantics above.
//
//   node agent_client.mjs serve --app <name>           # returns when connected
//   node agent_client.mjs call --app <name> observe
//   node agent_client.mjs call --app <name> act '{"viewRevision":3,"action":{...}}'
//   node agent_client.mjs call --app <name> act - <<'JSON'   # secret input/fill: stdin only
//   node agent_client.mjs call --app <name> disconnect   # before reload/restart
//   node agent_client.mjs stop --app <name>              # close Scout and the bridge
// ---------------------------------------------------------------------------

const bridgeParams = {
  observe: [], status: [], foreground: [], bridge: [], disconnect: [], close: [],
  act: ['viewRevision', 'action', 'timeoutMs', 'argv'],
  taps: ['viewRevision', 'targets', 'allowUnrelatedChanges', 'timeoutMs'],
  steps: ['viewRevision', 'actions', 'timeoutMs', 'argv'],
  start: ['viewRevision', 'action', 'argv'],
  acknowledge: ['actionId'],
  reconcile: ['actionId', 'viewRevision'],
  next: ['timeoutMs'],
  watch: ['condition', 'timeoutMs', 'wait'],
  react: ['viewRevision', 'condition', 'reaction', 'timeoutMs'],
  cancel: ['scope', 'conditionId'],
  query: ['method', 'params', 'args'],
};
// Allowed on a reconnected connection before the caller has observed it.
// Revisions, action ids and condition ids restart with every connection.
const freshSafe = new Set(['observe', 'status', 'query', 'bridge', 'disconnect', 'close']);
const idleShutdownMs = 30 * 60 * 1000;

// Mirrors the CLI's typedValueTargetLooksSensitive (cli_privacy.dart).
const sensitiveTargetPattern = new RegExp(
  '(^|[^a-z0-9])(password|passcode|passphrase|pwd|secret|pin|cvv|cvc|otp|' +
  'token|cookie|session[ _-]?id|api[ _-]?key|security[ _-]?code|' +
  'card[ _-]?number|account[ _-]?number|one[ _-]?time[ _-]?code|' +
  'verification[ _-]?code)($|[^a-z0-9])', 'i');

/** Whether a field handle or label names a credential (`field.staff_pin`). */
export function targetLooksSensitive(target) {
  return typeof target === 'string' && sensitiveTargetPattern.test(target.replace(/[._]/g, ' '));
}

/** Why `action`'s typed values must not come from process arguments, or
 * null when every target is one of the scene's `fieldValues` that Scout does
 * not treat as secret. Unknown or unnamed targets fail closed. Without
 * `fieldValues`, only the target names are checked. */
export function argvTypedValueRefusal(action, fieldValues) {
  const method = action?.method;
  if (method !== 'input' && method !== 'fill') return null;
  const json = action.params?.json;
  const targets = method === 'input' ? [action.params?.target]
    : json && typeof json === 'object' && !Array.isArray(json) ? Object.keys(json) : [null];
  for (const target of targets) {
    if (typeof target !== 'string' || !target) {
      return method === 'input'
        ? 'input without params.target types into whichever field has focus, which may be secret'
        : 'fill needs a field-to-value map';
    }
    if (targetLooksSensitive(target)) return `${target} names a credential`;
    if (fieldValues === undefined) continue;
    const fields = fieldValues && typeof fieldValues === 'object' ? fieldValues : {};
    if (!Object.hasOwn(fields, target)) {
      return `${target} is not a field in the latest scene, so Scout cannot confirm it is not secret`;
    }
    const value = fields[target];
    if (value && typeof value === 'object' && value.redacted === true) {
      return `${target} is a field Scout treats as secret (obscured, or labelled as a credential)`;
    }
  }
  return null;
}

function bridgePaths(app, socket) {
  if (socket) return { socket, log: `${socket}.log` };
  // Unix socket paths are limited to ~104 bytes; long names are hashed.
  const name = /^[A-Za-z0-9._-]{1,24}$/.test(app) ? app
    : `app-${createHash('sha256').update(app).digest('hex').slice(0, 16)}`;
  const uid = typeof process.getuid === 'function' ? process.getuid() : 'user';
  const dir = join(tmpdir(), `flutter-scout-${uid}`);
  return { socket: join(dir, `${name}.sock`), log: join(dir, `${name}.log`) };
}

function ensurePrivateDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (typeof process.getuid === 'function' && stat.uid !== process.getuid()) || (stat.mode & 0o077)) {
    throw agentError('bridge_insecure_directory', `${dir} must be a 0700 directory owned by the current user.`);
  }
}

function errorResponse(error) {
  const details = {};
  for (const key of ['cause', 'exitCode', 'signal', 'stderr']) {
    if (error?.[key] !== undefined && error[key] !== null) details[key] = error[key];
  }
  return {
    ok: false,
    dispatch: error?.dispatch ?? 'not_dispatched',
    error: { code: error?.code ?? 'bridge_request_rejected', message: String(error?.message ?? error), ...details },
    retry: 'never_automatic',
  };
}

function lossSummary(failure) {
  if (!failure) return null;
  const { code, dispatch, exitCode, signal, stderr } = failure;
  return { code, dispatch, exitCode, signal, stderr, message: failure.message };
}

export class ScoutBridge {
  constructor(options) {
    this.options = options;
    this.agent = null;
    this.opening = null;
    this.connection = 0;
    this.fresh = false;
    this.disconnected = false;
  }

  /** Opens the connection lazily; reports a reconnect, never resends input. */
  ensureAgent() {
    if (this.agent && !this.agent.closed) return Promise.resolve(null);
    if (!this.opening) {
      const previous = this.agent;
      this.opening = ScoutAgent.connect(this.options).then(agent => {
        this.agent = agent;
        this.connection += 1;
        if (this.connection === 1) return null;
        this.fresh = true;
        const info = { reconnected: true, connection: this.connection,
          reason: this.disconnected ? 'disconnected' : 'transport_lost',
          previousLoss: this.disconnected ? null : lossSummary(previous?.failure) };
        this.disconnected = false;
        return info;
      }).finally(() => { this.opening = null; });
    }
    return this.opening;
  }

  get busy() {
    const agent = this.agent;
    return Boolean(agent && !agent.closed && (agent.acting ||
      [...agent.pending.values()].some(request => request.method === 'start')));
  }

  async disconnect() {
    if (this.busy) {
      throw agentError('bridge_input_in_flight', 'An input is running; wait for its receipt before disconnecting.');
    }
    const agent = this.agent;
    if (!agent || agent.closed) return { ok: true, type: 'disconnected', connected: false };
    const closed = await agent.close();
    this.disconnected = true;
    return { ...closed, ok: closed.ok === true, type: 'disconnected', connected: false };
  }

  async handle(request) {
    const { method, params = {} } = request ?? {};
    if (!Object.hasOwn(bridgeParams, method) || !params || typeof params !== 'object' || Array.isArray(params) ||
        Object.keys(params).some(key => !bridgeParams[method].includes(key))) {
      throw agentError('bridge_invalid_request',
        `Unknown method or field. Methods: ${Object.keys(bridgeParams).join(', ')}.`);
    }
    if (method === 'bridge') {
      return { ok: true, app: this.options.app, pid: process.pid, connection: this.connection,
        connected: Boolean(this.agent && !this.agent.closed), fresh: this.fresh };
    }
    if (method === 'disconnect' || method === 'close') return this.disconnect();
    if (params.argv !== undefined && params.argv !== true) {
      throw agentError('bridge_invalid_request', 'argv is set only by the shell bridge.');
    }
    if (params.wait !== undefined && typeof params.wait !== 'boolean') {
      throw agentError('bridge_invalid_request', 'wait must be true or false.');
    }
    const bridge = await this.ensureAgent();
    const tag = value => (bridge ? { ...value, bridge } : value);
    if (this.fresh && !freshSafe.has(method)) {
      return tag(errorResponse(agentError('bridge_reconnected',
        'Scout reconnected; revisions and ids restarted. Observe and decide again. Nothing was sent.')));
    }
    const agent = this.agent;
    const p = params;
    // Typed values may come from the command line only for fields Scout
    // can see are not secret; secrets stay out of process arguments.
    const typedActions = method === 'steps' ? (Array.isArray(p.actions) ? p.actions : []) : [p.action];
    const refusal = p.argv
      ? typedActions.map(action => argvTypedValueRefusal(action, agent.latest?.view?.fieldValues ?? {})).find(Boolean) ?? null
      : null;
    if (refusal) {
      return tag(errorResponse(agentError('bridge_stdin_required',
        `${refusal}. Send this act JSON on stdin instead: act - <<'JSON' ... JSON. Nothing was sent.`)));
    }
    let result;
    switch (method) {
      case 'observe': result = await agent.observe(); break;
      case 'status': result = await agent.status(); break;
      case 'foreground': result = await agent.foreground(); break;
      case 'act': result = await agent.act(p.viewRevision, p.action, p.timeoutMs ?? 45000); break;
      case 'taps':
        result = await agent.taps(p.viewRevision, p.targets,
          { allowUnrelatedChanges: p.allowUnrelatedChanges ?? false, timeoutMs: p.timeoutMs ?? 45000 });
        break;
      case 'steps': result = await agent.steps(p.viewRevision, p.actions, { timeoutMs: p.timeoutMs ?? 45000 }); break;
      case 'start': result = await agent.start(p.viewRevision, p.action); break;
      case 'acknowledge': result = await agent.acknowledge(p.actionId); break;
      case 'reconcile': result = await agent.reconcile(p.actionId, p.viewRevision); break;
      case 'next': result = await agent.next(p.timeoutMs ?? 10000); break;
      case 'watch':
        result = p.wait ? await agent.watchUntil(p.condition, p.timeoutMs ?? 5000)
          : await agent.watch(p.condition, p.timeoutMs ?? 5000);
        break;
      case 'react': result = await agent.react(p.viewRevision, p.condition, p.reaction, p.timeoutMs ?? 5000); break;
      case 'cancel': result = await agent.cancel(p.scope, p.conditionId); break;
      case 'query': result = await agent.query(p.method, p.params ?? {}, p.args ?? []); break;
    }
    if (method === 'observe' || method === 'status') this.fresh = false;
    return tag(result);
  }
}

function sendBridge(socketPath, request, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let data = '';
    const timer = setTimeout(() => {
      socket.destroy();
      reject(agentError('bridge_call_timeout', 'The bridge did not answer in time.'));
    }, timeoutMs);
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'));
    socket.on('data', chunk => { data += chunk; });
    socket.on('error', error => { clearTimeout(timer); reject(error); });
    socket.on('end', () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(data)); } catch { reject(agentError('bridge_protocol_error', 'Malformed bridge reply.')); }
    });
  });
}

/** A socket request is `{method, params}`; `brief: true` beside them asks
 * for the brief reply (the shipped `scout-call` sends it, having no JSON
 * parser of its own). Typed values from process arguments are marked inside
 * params (`argv: true`), so a bridge that predates a field refuses it with
 * nothing sent. */
function bridgeRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) return request;
  const { brief: _brief, ...rest } = request;
  return rest;
}

/** One reply line with `ok` first, so a shell client can read the outcome
 * from its first bytes. */
function bridgeReply(response, brief) {
  const value = brief ? briefResponse(response) : response;
  if (!value || typeof value !== 'object' || !Object.hasOwn(value, 'ok')) return JSON.stringify(value);
  const { ok, ...rest } = value;
  return JSON.stringify({ ok, ...rest });
}

async function serveForeground(options, paths, report) {
  const bridge = new ScoutBridge(options);
  try {
    await bridge.ensureAgent();
  } catch (error) {
    return report(errorResponse(error));
  }
  let idle;
  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    clearTimeout(idle);
    server.close();
    try { unlinkSync(paths.socket); } catch {}
    const agent = bridge.agent;
    if (agent && !agent.closed) {
      await Promise.race([agent.close().catch(() => {}), new Promise(resolve => setTimeout(resolve, 10000))]);
      if (!agent.closed) agent.abort();
    }
    process.exit(0);
  };
  const armIdle = () => {
    clearTimeout(idle);
    idle = setTimeout(() => { if (bridge.busy) armIdle(); else shutdown(); }, idleShutdownMs);
  };
  const server = createServer(socket => {
    clearTimeout(idle);
    let data = '';
    socket.setEncoding('utf8');
    socket.on('error', () => {});
    socket.on('data', async chunk => {
      data += chunk;
      if (data.length > 1024 * 1024) return socket.destroy();
      const end = data.indexOf('\n');
      if (end < 0) return;
      socket.removeAllListeners('data');
      let request;
      let response;
      try {
        request = JSON.parse(data.slice(0, end));
        response = await bridge.handle(bridgeRequest(request));
      } catch (error) { response = errorResponse(error); }
      socket.end(bridgeReply(response, request?.brief === true) + '\n');
      if (request?.method === 'close' && response.ok) shutdown();
      else armIdle();
    });
  });
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, shutdown);
  const previousMask = process.umask(0o177);
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(paths.socket, resolve);
    });
  } catch (error) {
    await bridge.agent?.close().catch(() => {});
    return report(errorResponse(agentError('bridge_listen_failed', error.message)));
  } finally { process.umask(previousMask); }
  chmodSync(paths.socket, 0o600);
  armIdle();
  report({ ok: true, type: 'serving', app: options.app, pid: process.pid, socket: paths.socket,
    log: paths.log, scene: bridge.agent.latest });
}

/** Static protocol metadata repeated in every envelope: identity, version,
 * capability, timing and coordinate-frame boilerplate. Never an outcome,
 * failure, omission or safety field. */
const briefDropped = new Set([
  'capabilities', 'timings', 'protocolRange', 'identityAvailability', 'payloadBounds',
  'observationEffects', 'coordinateFrame', 'geometryCoordinateSpaces', 'physicalRect',
  'physicalSuggestedTapPoint', 'heuristicMeaning', 'scoreKind', 'schemaVersion',
  'protocolVersion', 'minSupportedProtocolVersion', 'maxSupportedProtocolVersion',
  'helperPackageVersion', 'helperProtocolVersion', 'responseBytes', 'maxResponseBytes',
  'commandId', 'cliCommandId', 'runId', 'runtimeInstanceId', 'stateDigest', 'snapshotId',
  'logCursor', 'eventCursor', 'capabilitySource', 'messageType', 'limitations', 'textTarget',
]);

/** `call --brief`: the same response without [briefDropped] metadata, at any
 * depth, so a shell agent reads decisions rather than kilobytes of tables. */
export function briefResponse(value) {
  if (Array.isArray(value)) return value.map(briefResponse);
  if (!value || typeof value !== 'object') return value;
  const out = {};
  for (const [key, entry] of Object.entries(value)) {
    if (!briefDropped.has(key)) out[key] = briefResponse(entry);
  }
  return out;
}

function parseArgs(argv) {
  const options = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--foreground') options.foreground = true;
    else if (arg === '--brief') options.brief = true;
    else if (arg === '--no-overlay') options.overlay = false;
    else if (['--app', '--socket', '--binary', '--interval-ms', '--max-items'].includes(arg)) {
      if (i + 1 >= argv.length) throw agentError('usage', `${arg} needs a value`);
      options[arg.slice(2)] = argv[++i];
    } else positional.push(arg);
  }
  return { options, positional };
}

async function readStdin() {
  let data = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) data += chunk;
  return data;
}

async function callBridge(command, options, paths, method, json) {
  const print = value => process.stdout.write(JSON.stringify(value) + '\n');
  let params = {};
  if (command === 'call' && json !== undefined) {
    try { params = JSON.parse(json === '-' ? await readStdin() : json); } catch {
      print(errorResponse(agentError('usage', 'Arguments must be one JSON object (or - to read it from stdin).')));
      return 2;
    }
    const typedActions = method === 'steps' ? (Array.isArray(params?.actions) ? params.actions : [])
      : ['act', 'start'].includes(method) ? [params?.action] : [];
    const typed = typedActions.some(action => ['input', 'fill'].includes(action?.method));
    if (json !== '-' && typed) {
      // A credential-named target never needs the bridge to say no.
      const refusal = typedActions.map(action => argvTypedValueRefusal(action)).find(Boolean) ?? null;
      if (refusal) {
        print(errorResponse(agentError('bridge_stdin_required',
          `${refusal}. Send this act JSON on stdin instead: act - <<'JSON' ... JSON. Nothing was sent.`)));
        return 2;
      }
      // The bridge checks the live scene; one that predates this check
      // rejects the unknown field, so nothing is sent.
      params = { ...params, argv: true };
    }
  }
  const request = { method: command === 'stop' ? 'close' : method, params };
  // A blocking watch answers when its condition ends.
  const waitMs = method === 'watch' && params?.wait === true && Number.isInteger(params.timeoutMs)
    ? params.timeoutMs + 30000 : 0;
  try {
    let response = await sendBridge(paths.socket, request, Math.max(150000, waitMs));
    if (response?.error?.code === 'bridge_invalid_request' && (params?.argv || params?.wait !== undefined)) {
      // A bridge started from an older client knows neither field.
      response = { ...response, error: { ...response.error, message: `${response.error.message} ` +
        'This bridge predates argv input and blocking watch: run stop, then serve again, or pass the JSON on stdin. Nothing was sent.' } };
    }
    print(options.brief ? briefResponse(response) : response);
    return response.ok === true ? 0 : 1;
  } catch (error) {
    if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) {
      if (command === 'stop') { print({ ok: true, type: 'closed', running: false }); return 0; }
      print(errorResponse(agentError('bridge_not_running',
        `No Scout bridge for ${options.app}. Start one: node agent_client.mjs serve --app ${options.app}`)));
      return 1;
    }
    const unknown = error.code === 'bridge_call_timeout' && ['act', 'taps', 'steps', 'start', 'react'].includes(request.method);
    print(errorResponse(Object.assign(error, unknown ? { dispatch: 'dispatch_outcome_unknown' } : {})));
    return 1;
  }
}

async function serveBridge(argv, options, paths) {
  const print = value => process.stdout.write(JSON.stringify(value) + '\n');
  // Reuse a live bridge for this app; clear only a stale socket file.
  try {
    const existing = await sendBridge(paths.socket, { method: 'bridge' }, 5000);
    if (existing?.app === options.app) {
      print({ ...existing, type: 'serving', reused: true, socket: paths.socket });
      return 0;
    }
    print(errorResponse(agentError('bridge_socket_in_use', `${paths.socket} serves another app.`)));
    return 1;
  } catch (error) {
    if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) { print(errorResponse(error)); return 1; }
  }
  try {
    if (!lstatSync(paths.socket).isSocket()) {
      print(errorResponse(agentError('bridge_socket_in_use', `${paths.socket} is not a socket.`)));
      return 1;
    }
    unlinkSync(paths.socket);
  } catch (error) { if (error.code !== 'ENOENT') { print(errorResponse(error)); return 1; } }
  const agentOptions = {
    app: options.app,
    ...(options.binary ? { binary: options.binary } : {}),
    ...(options['interval-ms'] ? { intervalMs: Number(options['interval-ms']) } : {}),
    ...(options['max-items'] ? { maxItems: Number(options['max-items']) } : {}),
    ...(options.overlay === false ? { overlay: false } : {}),
  };
  if (options.foreground) {
    // Runs until close/idle/signal; reports readiness over IPC or stdout.
    return new Promise(resolve => {
      serveForeground(agentOptions, paths, value => {
        const done = () => { if (!value.ok) resolve(1); };
        if (process.send) process.send(value, () => { process.disconnect(); done(); });
        else { print(value); done(); }
      });
    });
  }
  const log = openSync(paths.log, 'a', 0o600);
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), ...argv, '--foreground'],
    { detached: true, stdio: ['ignore', 'ignore', log, 'ipc'] });
  return new Promise(resolve => {
    child.once('message', value => {
      print(value);
      child.removeAllListeners('exit');
      child.disconnect();
      child.unref();
      resolve(value.ok ? 0 : 1);
    });
    child.once('exit', code => {
      print(errorResponse(agentError('bridge_start_failed', `The bridge exited (${code}) before connecting; see ${paths.log}.`)));
      resolve(1);
    });
  });
}

async function main(argv) {
  const print = value => process.stdout.write(JSON.stringify(value) + '\n');
  let parsed;
  try { parsed = parseArgs(argv); } catch (error) { print(errorResponse(error)); return 2; }
  const { options, positional } = parsed;
  const [command, method, json] = positional;
  if (!['serve', 'call', 'stop'].includes(command) || typeof options.app !== 'string' || !options.app ||
      (command === 'call' ? !method || positional.length > 3 : positional.length > 1)) {
    print(errorResponse(agentError('usage',
      'Usage: agent_client.mjs serve|stop --app <name> [--socket <path>] | call --app <name> [--brief] <method> [json|-]')));
    return 2;
  }
  const paths = bridgePaths(options.app, options.socket);
  try { ensurePrivateDir(dirname(paths.socket)); } catch (error) { print(errorResponse(error)); return 1; }
  return command === 'serve' ? serveBridge(argv, options, paths) : callBridge(command, options, paths, method, json);
}

const invoked = (() => {
  try { return realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
})();
if (invoked) {
  // A foreground server resolves only on failure; everything else exits after
  // its single JSON line is flushed (the detached server keeps running).
  main(process.argv.slice(2)).then(code => {
    process.stdout.write('', () => process.exit(code));
  });
}
