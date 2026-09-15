import { spawn } from 'node:child_process';

/** Persistent JSONL client. No ports, screenshots, implicit retries or app logic. */
export class ScoutAgent {
  static async connect({ app, binary = 'flutter-scout', cwd, intervalMs = 250, maxItems = 60 } = {}) {
    if (typeof app !== 'string' || !app || !Number.isInteger(intervalMs) ||
        intervalMs < 100 || intervalMs > 10000 || !Number.isInteger(maxItems) ||
        maxItems < 1 || maxItems > 100) throw new TypeError('A named app and bounded polling options are required');
    const child = spawn(binary, ['--app', app, 'agent', '--interval-ms', String(intervalMs),
      '--max-items', String(maxItems)], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    const client = new ScoutAgent(child);
    const ready = await client.ready;
    if (!ready.ok || ready.agentProtocol !== 2) {
      client.abort();
      throw new Error('Scout agent unavailable; check the named session and update its helper');
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
    this.buffer = Buffer.alloc(0);
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.readyTimer = setTimeout(() => this.fail(), 45000);
    child.stdout.on('data', chunk => this.receive(chunk));
    // Drain diagnostics, but do not copy application data into client errors.
    child.stderr.on('data', () => {});
    child.on('error', () => this.fail());
    child.stdin.on('error', () => this.fail());
    child.on('exit', () => { if (!this.closed) this.fail(); });
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const end = this.buffer.indexOf(10);
      if (end < 0) break;
      if (end > 8 * 1024 * 1024) return this.fail();
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
      } catch { return this.fail(); }
      if (value.type === 'ready' && this.resolveReady) {
        clearTimeout(this.readyTimer);
        this.latest = value;
        const resolve = this.resolveReady;
        this.resolveReady = this.rejectReady = null;
        resolve(value);
        continue;
      }
      if (this.rejectReady && value.ok === false && !value.id) {
        const error = Object.assign(new Error(value.error?.message ?? 'Scout agent could not open'),
          { code: value.error?.code ?? 'scout_agent_unavailable', dispatch: 'not_dispatched' });
        this.rejectReady(error);
        this.resolveReady = this.rejectReady = null;
        this.fail();
        return;
      }
      const request = this.pending.get(value.id);
      if (!request) return this.fail();
      this.pending.delete(value.id);
      clearTimeout(request.timer);
      if (value.view && (value.viewRevision ?? -1) >= (this.latest?.viewRevision ?? -1)) this.latest = value;
      if (value.event?.view) {
        // Historical events stay historical: never overwrite a newer view.
        if ((value.event.viewRevision ?? -1) >= (this.latest?.viewRevision ?? -1)) {
          this.latest = { view: value.event.view, viewRevision: value.event.viewRevision };
        }
      }
      if (request.method === 'close' && value.ok === true && value.type === 'closed') {
        this.closed = true;
        this.child.stdin.end();
      }
      request.resolve(value);
    }
    if (this.buffer.length > 8 * 1024 * 1024) this.fail();
  }

  fail() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.readyTimer);
    const error = Object.assign(new Error('Scout connection lost; an in-flight action may have dispatched. Reconcile; never retry automatically.'),
      { code: 'scout_agent_transport_lost', dispatch: 'dispatch_outcome_unknown' });
    this.rejectReady?.(error);
    this.resolveReady = this.rejectReady = null;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
    this.child.kill();
  }

  request(method, params = {}, timeoutMs = 45000) {
    if (this.closed || (this.closing && method !== 'close')) return Promise.reject(new Error('Scout client closed'));
    if (this.pending.size >= 16) return Promise.reject(new Error('At most 16 concurrent requests'));
    const id = `q${++this.serial}`;
    const line = JSON.stringify({ ...params, id, method }) + '\n';
    if (Buffer.byteLength(line) > 65536) return Promise.reject(new Error('Request exceeds 64 KiB'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail(), timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      this.child.stdin.write(line, error => { if (error) this.fail(); });
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
  abort() { this.fail(); }
}
