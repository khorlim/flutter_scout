import { spawn } from 'node:child_process';

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

/** Persistent JSONL client. No ports, screenshots, implicit retries or app logic. */
export class ScoutAgent {
  static async connect({ app, binary = 'flutter-scout', cwd, intervalMs = 250, maxItems = 60 } = {}) {
    if (typeof app !== 'string' || !app || !Number.isInteger(intervalMs) ||
        intervalMs < 100 || intervalMs > 10000 || !Number.isInteger(maxItems) ||
        maxItems < 1 || maxItems > 100) throw new TypeError('A named app and bounded polling options are required');
    const child = spawn(binary, ['--app', app, 'agent', '--interval-ms', String(intervalMs),
      '--max-items', String(maxItems)], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    const client = new ScoutAgent(child);
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
    if (this.serial >= 9999) {
      return Promise.reject(agentError('scout_agent_request_limit',
        'This connection used its 10,000 request identities; close it and open a new connection.'));
    }
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
   * business completion. Returns all intervening events, including failures.
   * Do not run another next()/act() consumer concurrently. */
  async act(viewRevision, action, timeoutMs = 45000) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new TypeError('act timeout must be 1..120000 ms');
    if (this.acting) throw new Error('Only one act/event consumer at a time');
    this.acting = true;
    const events = [];
    const deadline = Date.now() + timeoutMs;
    try {
      const ticket = await this.start(viewRevision, action);
      if (!ticket.ok) return { ...ticket, events };
      for (;;) {
        const remaining = deadline - Date.now();
        if (remaining <= 0 || events.length > 80) {
          this.abort();
          throw Object.assign(new Error('Input receipt unavailable within the bounded action budget; reconcile before further input'),
            { code: 'scout_agent_receipt_unavailable', dispatch: 'dispatch_outcome_unknown' });
        }
        const response = await this.next(Math.min(10000, remaining));
        if (!response.ok) return { ...response, actionId: ticket.actionId, events };
        const event = response.event;
        if (event?.type === 'timeout') continue;
        if (event?.type !== 'action' || event.actionId !== ticket.actionId) events.push(event);
        if (event?.type === 'closed') throw new Error('Scout closed before delivering the input receipt; reconcile before further input');
        if (event?.type !== 'action' || event.actionId !== ticket.actionId) continue;
        if (event.result?.ok === true) {
          const acknowledged = await this.acknowledge(ticket.actionId);
          if (!acknowledged.ok) return { ...acknowledged, actionId: ticket.actionId, result: event.result, events };
        }
        const scene = await this.observe();
        return { ok: event.result?.ok === true && scene.ok === true,
          actionId: ticket.actionId, result: event.result, scene, events };
      }
    } finally { this.acting = false; }
  }
  watch(condition, timeoutMs = 5000) { return this.request('watch', { condition, timeoutMs }); }
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
