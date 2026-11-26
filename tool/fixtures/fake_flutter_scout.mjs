#!/usr/bin/env node
// Test double for `flutter-scout --app <name> agent` (agentProtocol 2).
// FAKE_SCOUT_MODE selects a failure; FAKE_SCOUT_LOG appends received requests.
import { appendFileSync, existsSync, rmSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const mode = process.env.FAKE_SCOUT_MODE ?? 'ok';
const log = process.env.FAKE_SCOUT_LOG;
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const runtime = `runtime-${process.pid}`;
let revision = 1;
const queued = [];
let unacknowledged = null;
let actions = 0;
const scene = () => ({
  ok: true, actionable: unacknowledged === null, inputBlockedReason: unacknowledged ? 'receipt_unacknowledged' : null,
  viewRevision: revision, view: { ok: true, screen: 'Home', runtimeInstanceId: runtime, interactables: [{ id: 'btn.save' }],
    fieldValues: { 'field.customer_name': '', 'field.staff_code': { redacted: true, isEmpty: true, hasValue: false } } },
  hand: { pendingAction: null, unacknowledgedAction: unacknowledged, halted: null, closed: false },
});

// overflow / overflow_receipt: the first connection's first observe finds it
// halted by event overflow (the latter with a receipt still unread); later
// connections are healthy.
const overflowMarker = log && `${log}.overflowed`;
const overflowScene = () => {
  const halted = { ...scene(), ok: false, actionable: false, inputBlockedReason: 'agent_event_overflow',
    blockedBy: { code: 'agent_hand_unavailable', reason: 'connection_overflow', message: 'connection_overflow: fake',
      nextStep: 'reconnect', details: { halted: 'agent_event_overflow', unreadAlerts: 65, maxEvents: 64,
        renderingAffected: false } } };
  halted.hand = { ...halted.hand, halted: 'agent_event_overflow',
    unacknowledgedAction: mode === 'overflow_receipt' ? 'a1' : null };
  return { ...halted, error: halted.blockedBy };
};
let overflowed = false;
// Like the real agent lease, these modes hold the app until the process has
// exited, a moment after its close reply.
const lease = mode.startsWith('overflow') && log ? `${log}.lease` : null;
if (lease && existsSync(lease)) {
  emit({ messageType: 'response', ok: false, result: null,
    structuredError: { code: 'agent_session_busy', message: 'This named app already has an agent connection.' } });
  process.exit(1);
}
if (lease) {
  writeFileSync(lease, '');
  process.on('exit', () => rmSync(lease, { force: true }));
}
const exitSoon = () => (lease ? setTimeout(() => process.exit(0), 300) : process.exit(0));

if (mode === 'not_registered') {
  process.stderr.write('flutter-scout: resolving session\nno session named demo\n');
  emit({ messageType: 'response', ok: false, result: null,
    structuredError: { code: 'session_not_registered', message: 'No registered session named `demo`.' } });
  process.exit(1);
}
if (mode === 'helper_missing' || mode === 'unreachable') {
  const code = mode === 'helper_missing' ? 'flutter_scout_helper_not_registered' : 'not_attached';
  emit({ type: 'ready', ok: false, agentProtocol: 2, actionable: false, inputBlockedReason: 'agent_observation_unavailable',
    viewRevision: 1, view: { ok: false, error: { code, message: 'fake cause' } }, hand: { halted: 'agent_observation_unavailable' } });
} else {
  emit({ type: 'ready', ...scene(), agentProtocol: 2 });
}

const input = createInterface({ input: process.stdin });
input.on('line', line => {
  const request = JSON.parse(line);
  if (log) {
    appendFileSync(log, JSON.stringify({ pid: process.pid, method: request.method,
      ...(request.action ? { action: request.action.method, args: request.action.args } : {}) }) + '\n');
  }
  if (mode === 'die_on_request' || (mode === 'die_on_start' && request.method === 'start')) {
    process.stderr.write('fatal: VM service closed\n');
    process.kill(process.pid, 'SIGKILL');
    return;
  }
  const reply = value => emit({ id: request.id, ...value });
  switch (request.method) {
    case 'observe': case 'status':
      if (mode.startsWith('overflow') && (overflowed || !existsSync(overflowMarker))) {
        overflowed = true;
        writeFileSync(overflowMarker, '');
        return reply(overflowScene());
      }
      return reply(scene());
    case 'start':
      if (request.viewRevision !== revision || unacknowledged) {
        return reply({ ok: false, dispatch: 'not_dispatched', error: { code: 'agent_request_rejected', message: 'agent_view_changed' } });
      }
      actions++;
      unacknowledged = `a${actions}`;
      queued.push({ type: 'action', actionId: unacknowledged, result: { ok: true, dispatch: 'dispatched' } });
      return reply({ ok: true, actionId: unacknowledged, phase: 'accepted', dispatch: 'not_yet_established' });
    case 'next': {
      const event = queued.shift() ?? { type: 'timeout' };
      if (event.type === 'action') revision++;
      return reply({ ok: true, event });
    }
    case 'acknowledge':
      unacknowledged = null;
      return reply(scene());
    case 'watch':
      // Two view updates, then the condition ends.
      queued.push({ type: 'view', viewRevision: revision, view: scene().view },
        { type: 'view', viewRevision: revision, view: scene().view },
        { type: 'condition', conditionId: 'w1', status: request.condition?.gone === 'never' ? 'timeout' : 'met',
          viewRevision: revision, view: scene().view, inflightActionCancelled: false });
      return reply({ ok: true, conditionId: 'w1', oneShot: true, timeoutMs: request.timeoutMs });
    case 'query': return reply({ ok: true, queryResult: { ok: true, method: request.query.method, matches: 1 } });
    case 'close':
      reply({ ok: true, type: 'closed', inflightActionCancelled: false });
      return exitSoon();
    default:
      return reply({ ok: false, dispatch: 'not_dispatched', error: { code: 'agent_request_rejected', message: 'Unsupported method' } });
  }
});
input.on('close', exitSoon);
