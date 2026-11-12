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

/** Why an input or its follow-up observation failed, from the canonical
 * receipt first, then the scene. */
function inputFailure(result, scene) {
  const receipt = result && typeof result === 'object' ? result : {};
  const error = receipt.error ?? receipt.structuredError ??
    (receipt.ok === true ? scene?.error ?? scene?.blockedBy : null) ??
    { code: 'input_failed_without_reason', message: 'The input receipt reported ok:false without a reason; read result and scene.' };
  return { error, dispatch: receipt.dispatch ?? null };
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
        if (event?.type === 'closed') {
          throw agentError('scout_agent_closed_before_receipt',
            'Scout closed before delivering the input receipt; reconcile before further input',
            { dispatch: 'dispatch_outcome_unknown' });
        }
        if (event?.type !== 'action' || event.actionId !== ticket.actionId) continue;
        if (event.result?.ok === true) {
          const acknowledged = await this.acknowledge(ticket.actionId);
          if (!acknowledged.ok) return { ...acknowledged, actionId: ticket.actionId, result: event.result, events };
        }
        const scene = await this.observe();
        const ok = event.result?.ok === true && scene.ok === true;
        // A failed input keeps its reason in the receipt; lift it so a caller
        // reading only the top level never sees ok:false with no error.
        const failure = ok ? null : inputFailure(event.result, scene);
        return { ok, actionId: ticket.actionId,
          ...(failure ? { error: failure.error, dispatch: failure.dispatch } : {}),
          result: event.result, scene, events };
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
//   node agent_client.mjs call --app <name> act - <<'JSON'   # input/fill: stdin only
//   node agent_client.mjs call --app <name> disconnect   # before reload/restart
//   node agent_client.mjs stop --app <name>              # close Scout and the bridge
// ---------------------------------------------------------------------------

const bridgeParams = {
  observe: [], status: [], foreground: [], bridge: [], disconnect: [], close: [],
  act: ['viewRevision', 'action', 'timeoutMs'],
  start: ['viewRevision', 'action'],
  acknowledge: ['actionId'],
  reconcile: ['actionId', 'viewRevision'],
  next: ['timeoutMs'],
  watch: ['condition', 'timeoutMs'],
  react: ['viewRevision', 'condition', 'reaction', 'timeoutMs'],
  cancel: ['scope', 'conditionId'],
  query: ['method', 'params', 'args'],
};
// Allowed on a reconnected connection before the caller has observed it.
// Revisions, action ids and condition ids restart with every connection.
const freshSafe = new Set(['observe', 'status', 'query', 'bridge', 'disconnect', 'close']);
const idleShutdownMs = 30 * 60 * 1000;

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
    const bridge = await this.ensureAgent();
    const tag = value => (bridge ? { ...value, bridge } : value);
    if (this.fresh && !freshSafe.has(method)) {
      return tag(errorResponse(agentError('bridge_reconnected',
        'Scout reconnected; revisions and ids restarted. Observe and decide again. Nothing was sent.')));
    }
    const agent = this.agent;
    const p = params;
    let result;
    switch (method) {
      case 'observe': result = await agent.observe(); break;
      case 'status': result = await agent.status(); break;
      case 'foreground': result = await agent.foreground(); break;
      case 'act': result = await agent.act(p.viewRevision, p.action, p.timeoutMs ?? 45000); break;
      case 'start': result = await agent.start(p.viewRevision, p.action); break;
      case 'acknowledge': result = await agent.acknowledge(p.actionId); break;
      case 'reconcile': result = await agent.reconcile(p.actionId, p.viewRevision); break;
      case 'next': result = await agent.next(p.timeoutMs ?? 10000); break;
      case 'watch': result = await agent.watch(p.condition, p.timeoutMs ?? 5000); break;
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
        response = await bridge.handle(request);
      } catch (error) { response = errorResponse(error); }
      socket.end(JSON.stringify(response) + '\n');
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
    if (json !== '-' && ['input', 'fill'].includes(params?.action?.method)) {
      print(errorResponse(agentError('bridge_stdin_required',
        'input/fill values must come through stdin (pass - and a heredoc), never process arguments. Nothing was sent.')));
      return 2;
    }
  }
  const request = { method: command === 'stop' ? 'close' : method, params };
  try {
    const response = await sendBridge(paths.socket, request, 150000);
    print(options.brief ? briefResponse(response) : response);
    return response.ok === true ? 0 : 1;
  } catch (error) {
    if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) {
      if (command === 'stop') { print({ ok: true, type: 'closed', running: false }); return 0; }
      print(errorResponse(agentError('bridge_not_running',
        `No Scout bridge for ${options.app}. Start one: node agent_client.mjs serve --app ${options.app}`)));
      return 1;
    }
    const unknown = error.code === 'bridge_call_timeout' && ['act', 'start', 'react'].includes(request.method);
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
