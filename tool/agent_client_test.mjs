import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ScoutAgent, briefResponse } from '../skills/flutter-scout/scripts/agent_client.mjs';

const fakeBinary = fileURLToPath(new URL('./fixtures/fake_flutter_scout.mjs', import.meta.url));
async function connectFake(mode) {
  process.env.FAKE_SCOUT_MODE = mode;
  try { return await ScoutAgent.connect({ app: 'demo', binary: fakeBinary }); }
  finally { delete process.env.FAKE_SCOUT_MODE; }
}

function fixture() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const requests = [];
  child.stdin = new Writable({ write(bytes, _, done) { requests.push(JSON.parse(bytes)); done(); } });
  child.kill = () => {};
  const client = new ScoutAgent(child);
  const send = ({ok = true, ...value}) => child.stdout.write(JSON.stringify({ok, result: value}) + '\n');
  send({ type: 'ready', ok: true, agentProtocol: 2, viewRevision: 1, view: {} });
  return { child, client, requests, send };
}

test('correlates out-of-order responses while the observation wait is pending', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const eyes = client.next();
  const hand = client.start(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[1].id, ok: true, actionId: 'a1', phase: 'accepted' });
  assert.equal((await hand).actionId, 'a1');
  send({ id: requests[0].id, ok: true, event: { type: 'view', viewRevision: 2, view: { screen: 'Changed' } } });
  assert.equal((await eyes).event.type, 'view');
  assert.equal(client.latest.view.screen, 'Changed');
  client.abort();
});

test('old retained events do not regress the latest decision view', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const observed = client.observe();
  send({ id: requests[0].id, ok: true, viewRevision: 5, view: { screen: 'Now' } });
  await observed;
  const historical = client.next();
  send({ id: requests[1].id, ok: true, event: { type: 'view', viewRevision: 2, view: { screen: 'Before' } } });
  await historical;
  assert.equal(client.latest.view.screen, 'Now');
  client.abort();
});

test('out-of-order observe responses cannot regress the latest view', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const first = client.observe();
  const second = client.observe();
  send({ id: requests[1].id, viewRevision: 5, view: { screen: 'Now' } });
  await second;
  send({ id: requests[0].id, viewRevision: 2, view: { screen: 'Before' } });
  await first;
  assert.equal(client.latest.view.screen, 'Now');
  client.abort();
});

test('act surfaces a failed receipt without acknowledgement or another tap', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const result = client.act(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await new Promise(resolve => setImmediate(resolve));
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: false, dispatch: 'not_dispatched', error: { code: 'target_ambiguous' } } } });
  await new Promise(resolve => setImmediate(resolve));
  send({ id: requests[2].id, ok: false, viewRevision: 2, view: { screen: 'Same' } });
  const outcome = await result;
  assert.equal(outcome.ok, false);
  // The reason reaches the top level, never ok:false with no error.
  assert.deepEqual(outcome.error, { code: 'target_ambiguous' });
  assert.equal(outcome.dispatch, 'not_dispatched');
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'observe']);
  client.abort();
});

test('a rejected start returns the current scene for one new decision', async () => {
  const { client, requests, child } = fixture();
  await client.ready;
  const result = client.act(1, { method: 'tap', args: ['btn.save'] });
  child.stdout.write(JSON.stringify({ id: requests[0].id, ok: false, dispatch: 'not_dispatched',
    error: { code: 'agent_request_rejected', message: 'agent_view_changed' },
    scene: { viewRevision: 3, view: { screen: 'Now' } } }) + '\n');
  const outcome = await result;
  assert.equal(outcome.ok, false);
  assert.equal(outcome.scene.viewRevision, 3);
  assert.equal(client.latest.view.screen, 'Now');
  assert.deepEqual(requests.map(r => r.method), ['start']);
  client.abort();
});

test('act acknowledges a successful receipt before refreshing the scene', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const result = client.act(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await new Promise(resolve => setImmediate(resolve));
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched' } } });
  await new Promise(resolve => setImmediate(resolve));
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await new Promise(resolve => setImmediate(resolve));
  send({ id: requests[3].id, ok: true, viewRevision: 2, view: { screen: 'Saved' } });
  assert.equal((await result).ok, true);
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'observe']);
  client.abort();
});

test('transport loss rejects the action as unknown without retry', async () => {
  const { client, requests, child } = fixture();
  await client.ready;
  const action = client.start(1, { method: 'tap', args: ['btn.save'] });
  const rejection = assert.rejects(action, error => error.dispatch === 'dispatch_outcome_unknown');
  child.emit('exit', 1);
  await rejection;
  assert.equal(requests.length, 1);
});

test('malformed or uncorrelated output invalidates the connection', async () => {
  const { client, child } = fixture();
  await client.ready;
  const pending = client.observe();
  const rejection = assert.rejects(pending, error => error.code === 'scout_agent_protocol_error' &&
    error.dispatch === 'not_dispatched' && /connection lost/.test(error.message));
  child.stdout.write('{bad json}\n');
  await rejection;
  assert.equal(client.closed, true);
});

test('close drains and is idempotent', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const closing = client.close();
  assert.equal(client.close(), closing);
  send({ id: requests[0].id, ok: true, type: 'closed' });
  await closing;
  assert.equal(client.closed, true);
});

test('read-only transport loss is not blamed on an in-flight action', async () => {
  const { client, child } = fixture();
  await client.ready;
  const pending = client.observe();
  child.stderr.write('note\nfatal: VM service closed\n');
  const rejection = assert.rejects(pending, error => {
    assert.equal(error.code, 'scout_agent_exited');
    assert.equal(error.dispatch, 'not_dispatched');
    assert.equal(error.exitCode, 255);
    assert.equal(error.stderr, 'fatal: VM service closed');
    assert.doesNotMatch(error.message, /may have dispatched/);
    assert.match(error.message, /exit code 255/);
    return true;
  });
  await new Promise(resolve => setImmediate(resolve));
  child.emit('exit', 255, null);
  await rejection;
});

test('an accepted but unread input makes a later loss an unknown dispatch', async () => {
  const { client, requests, send, child } = fixture();
  await client.ready;
  const ticket = client.start(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await ticket;
  const observe = client.observe();
  const rejection = assert.rejects(observe, error => error.dispatch === 'dispatch_outcome_unknown' &&
    /may have dispatched/.test(error.message) && error.signal === 'SIGKILL');
  child.emit('exit', null, 'SIGKILL');
  await rejection;
});

test('a consumed receipt clears the in-flight state', async () => {
  const { client, requests, send, child } = fixture();
  await client.ready;
  const ticket = client.start(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await ticket;
  const next = client.next();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true } } });
  await next;
  assert.equal(client.inFlight, false);
  const observe = client.observe();
  const rejection = assert.rejects(observe, error => error.dispatch === 'not_dispatched');
  child.emit('exit', 1, null);
  await rejection;
});

test('connect reports the CLI cause, exit code and stderr for an unknown session', async () => {
  await assert.rejects(connectFake('not_registered'), error => {
    assert.equal(error.code, 'session_not_registered');
    assert.equal(error.dispatch, 'not_dispatched');
    assert.equal(error.exitCode, 1);
    assert.equal(error.stderr, 'no session named demo');
    return true;
  });
});

test('connect distinguishes a missing helper from an unreachable app', async () => {
  await assert.rejects(connectFake('helper_missing'), error =>
    error.code === 'scout_helper_missing' && error.cause === 'flutter_scout_helper_not_registered');
  await assert.rejects(connectFake('unreachable'), error =>
    error.code === 'scout_app_unreachable' && error.cause === 'not_attached');
});

test('a killed agent child reports its signal and last stderr line', async () => {
  const client = await connectFake('die_on_request');
  await assert.rejects(client.observe(), error => {
    assert.equal(error.code, 'scout_agent_exited');
    assert.equal(error.signal, 'SIGKILL');
    assert.equal(error.stderr, 'fatal: VM service closed');
    assert.equal(error.dispatch, 'not_dispatched');
    return true;
  });
  await assert.rejects(client.observe(), error => error.code === 'scout_client_closed' &&
    error.cause === 'scout_agent_exited');
});

test('brief output drops protocol metadata but keeps outcome and safety fields', () => {
  const full = {
    ok: false, dispatch: 'not_dispatched', error: { code: 'target_not_visible' },
    capabilities: { typedEnvelopeV1: true }, timings: { totalMs: 9 }, runId: 'r',
    scene: { viewRevision: 3, actionable: false, blockedBy: { reason: 'rendering_suspended' },
      view: { screen: 'Chat', protocolVersion: 15, omittedSections: { reason: 'brief_mode' },
        safetyEvidenceStatus: 'complete', interactables: [{ id: 'btn.ok', label: 'OK',
          physicalRect: [1, 2, 3, 4], rect: [0, 0, 1, 1] }] } },
  };
  assert.deepEqual(briefResponse(full), {
    ok: false, dispatch: 'not_dispatched', error: { code: 'target_not_visible' },
    scene: { viewRevision: 3, actionable: false, blockedBy: { reason: 'rendering_suspended' },
      view: { screen: 'Chat', omittedSections: { reason: 'brief_mode' },
        safetyEvidenceStatus: 'complete', interactables: [{ id: 'btn.ok', label: 'OK', rect: [0, 0, 1, 1] }] } },
  });
});
