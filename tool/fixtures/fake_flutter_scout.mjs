#!/usr/bin/env node
// Test double for `flutter-scout --app <name> agent` (agentProtocol 2).
// FAKE_SCOUT_MODE selects a failure; FAKE_SCOUT_LOG appends received requests.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const mode = process.env.FAKE_SCOUT_MODE ?? 'ok';
const log = process.env.FAKE_SCOUT_LOG;
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const runtime = `runtime-${process.pid}`;
let revision = 1;
let pendingReceipt = null;
let unacknowledged = null;
let actions = 0;
const scene = () => ({
  ok: true, actionable: unacknowledged === null, inputBlockedReason: unacknowledged ? 'receipt_unacknowledged' : null,
  viewRevision: revision, view: { ok: true, screen: 'Home', runtimeInstanceId: runtime, interactables: [{ id: 'btn.save' }] },
  hand: { pendingAction: null, unacknowledgedAction: unacknowledged, halted: null, closed: false },
});

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
  if (log) appendFileSync(log, JSON.stringify({ pid: process.pid, method: request.method }) + '\n');
  if (mode === 'die_on_request' || (mode === 'die_on_start' && request.method === 'start')) {
    process.stderr.write('fatal: VM service closed\n');
    process.kill(process.pid, 'SIGKILL');
    return;
  }
  const reply = value => emit({ id: request.id, ...value });
  switch (request.method) {
    case 'observe': case 'status': return reply(scene());
    case 'start':
      if (request.viewRevision !== revision || unacknowledged) {
        return reply({ ok: false, dispatch: 'not_dispatched', error: { code: 'agent_request_rejected', message: 'agent_view_changed' } });
      }
      actions++;
      unacknowledged = `a${actions}`;
      pendingReceipt = { type: 'action', actionId: unacknowledged, result: { ok: true, dispatch: 'dispatched' } };
      return reply({ ok: true, actionId: unacknowledged, phase: 'accepted', dispatch: 'not_yet_established' });
    case 'next': {
      const event = pendingReceipt ?? { type: 'timeout' };
      pendingReceipt = null;
      if (event.type === 'action') revision++;
      return reply({ ok: true, event });
    }
    case 'acknowledge':
      unacknowledged = null;
      return reply(scene());
    case 'watch': return reply({ ok: true, conditionId: 'w1', oneShot: true, timeoutMs: request.timeoutMs });
    case 'query': return reply({ ok: true, queryResult: { ok: true, method: request.query.method, matches: 1 } });
    case 'close':
      reply({ ok: true, type: 'closed', inflightActionCancelled: false });
      return process.exit(0);
    default:
      return reply({ ok: false, dispatch: 'not_dispatched', error: { code: 'agent_request_rejected', message: 'Unsupported method' } });
  }
});
input.on('close', () => process.exit(0));
