import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ScoutAgent, briefResponse, stepDrift, stepHandles } from '../skills/flutter-scout/scripts/agent_client.mjs';

const fakeBinary = fileURLToPath(new URL('./fixtures/fake_flutter_scout.mjs', import.meta.url));
async function connectFake(mode) {
  process.env.FAKE_SCOUT_MODE = mode;
  try { return await ScoutAgent.connect({ app: 'demo', binary: fakeBinary }); }
  finally { delete process.env.FAKE_SCOUT_MODE; }
}

const tick = () => new Promise(resolve => setImmediate(resolve));

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

test('act acknowledges a successful receipt, then settles an in-place change before returning the scene', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  client.latest = { viewRevision: 1, view: { screen: 'Order', visibleText: ['Total RM 0.00'],
    interactables: [{ id: 'btn.payment', kind: 'btn', enabled: false }] } };
  const result = client.act(1, { method: 'tap', args: ['btn.add'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  // The receipt was taken before the app recomputed the total.
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched',
    delta: { screenChanged: false, newText: [], removedText: [] } } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 2, view: { screen: 'Order', visibleText: ['Total RM 0.00'] } });
  await tick();
  send({ id: requests[4].id, event: { type: 'view', viewRevision: 3, view: { screen: 'Order' } } });
  await tick();
  send({ id: requests[5].id, event: { type: 'timeout' } });
  await tick();
  send({ id: requests[6].id, ok: true, viewRevision: 3, view: { screen: 'Order', visibleText: ['Total RM 12.00'],
    interactables: [{ id: 'btn.payment', kind: 'btn', label: 'Payment', enabled: true }] } });
  const outcome = await result;
  assert.equal(outcome.ok, true);
  assert.equal(outcome.viewRevision, 3);
  assert.deepEqual(outcome.settle.sinceInput, {
    appearedText: ['Total RM 12.00'], goneText: ['Total RM 0.00'],
    changedControls: [{ id: 'btn.payment', enabled: { before: false, after: true },
      label: { before: null, after: 'Payment' } }],
  });
  assert.equal(outcome.settle.status, 'settled');
  assert.equal(outcome.settle.trigger, 'none');
  assert.equal(outcome.settle.viewChanges, 1);
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'observe', 'next', 'next', 'observe']);
  client.abort();
});

test('act returns after one eyes interval when the input changed nothing', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const view = { screen: 'Order', visibleText: ['Total RM 0.00'], interactables: [{ id: 'btn.add', kind: 'btn' }] };
  client.latest = { viewRevision: 1, view };
  const result = client.act(1, { method: 'tap', args: ['btn.add'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched',
    delta: { screenChanged: false, newText: [], removedText: [] } } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 1, view });
  await tick();
  // One eyes interval (not the 500 ms quiet window) passes with no change.
  assert.equal(requests[4].method, 'next');
  assert.equal(requests[4].timeoutMs, 250);
  send({ id: requests[4].id, event: { type: 'timeout' } });
  const outcome = await result;
  assert.equal(outcome.ok, true);
  assert.equal(outcome.viewRevision, 1);
  assert.equal(outcome.settle.status, 'unchanged');
  assert.equal(outcome.settle.trigger, 'none');
  assert.equal(outcome.settle.viewChanges, 0);
  // The scene taken after the receipt is returned; no second observe.
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'observe', 'next']);
  client.abort();
});

test('act skips the eyes interval when the helper saw the input go idle', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const view = { screen: 'Order', visibleText: ['Pay with cash'] };
  client.latest = { viewRevision: 1, view };
  const result = client.act(1, { method: 'tap', args: ['tap.lt_180_days'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched',
    lateWindow: { ms: 1000, waitedMs: 0, ended: 'input_idle', inputWork: { tracked: true } } } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 1, view });
  const outcome = await result;
  assert.deepEqual(outcome.settle, { status: 'unchanged', trigger: 'none', waitedMs: 0, viewChanges: 0, basis: 'input_idle' });
  // No eyes interval after the scene: the helper already proved it.
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'observe']);
  client.abort();
});

test('a tap that only repainted its target names it in settle', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const view = { screen: 'Order' };
  client.latest = { viewRevision: 1, view };
  const result = client.act(1, { method: 'tap', args: ['tap.points'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched',
    paintOnlyChange: { target: 'tap.points', hint: 'crop' },
    lateWindow: { ms: 1000, waitedMs: 0, ended: 'input_idle' } } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 1, view });
  const outcome = await result;
  assert.equal(outcome.settle.status, 'unchanged');
  assert.equal(outcome.settle.paintOnlyChange, 'tap.points');
  client.abort();
});

test('a window the helper did not see go idle still gets the eyes interval', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const view = { screen: 'Order' };
  client.latest = { viewRevision: 1, view };
  const result = client.act(1, { method: 'tap', args: ['btn.sync'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched',
    lateWindow: { ms: 1000, waitedMs: 1010, ended: 'window_elapsed', inputWork: { busy: 'app_microtask' } } } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 1, view });
  await tick();
  assert.equal(requests[4].timeoutMs, 250);
  send({ id: requests[4].id, event: { type: 'timeout' } });
  assert.equal((await result).settle.status, 'unchanged');
  client.abort();
});

test('a change that lands during the short sample gets the full settle', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const view = { screen: 'Order', visibleText: ['Total RM 0.00'] };
  client.latest = { viewRevision: 1, view };
  const result = client.act(1, { method: 'tap', args: ['btn.add'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched' } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, ok: true, viewRevision: 1, view });
  await tick();
  assert.equal(requests[4].timeoutMs, 250);
  send({ id: requests[4].id, event: { type: 'view', viewRevision: 2, view: { screen: 'Order' } } });
  await tick();
  assert.equal(requests[5].timeoutMs, 500);
  send({ id: requests[5].id, event: { type: 'timeout' } });
  await tick();
  send({ id: requests[6].id, ok: true, viewRevision: 2, view: { screen: 'Order', visibleText: ['Total RM 12.00'] } });
  const outcome = await result;
  assert.equal(outcome.settle.status, 'settled');
  assert.equal(outcome.settle.viewChanges, 1);
  assert.equal(outcome.viewRevision, 2);
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'observe', 'next', 'next', 'observe']);
  client.abort();
});

test('a failed input returns its scene without settling', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const result = client.act(1, { method: 'tap', args: ['btn.save'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: false, dispatch: 'dispatched',
    error: { code: 'target_occluded' }, delta: { newText: ['x'] } } } });
  await tick();
  send({ id: requests[2].id, ok: true, viewRevision: 2, view: { screen: 'Same' } });
  const outcome = await result;
  assert.equal(outcome.settle, undefined);
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'observe']);
  client.abort();
});

test('taps sends observed handles in order, stops at the first failure, then one scene', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const result = client.taps(1, ['btn.1', 'btn.2', 'btn.3'], { allowUnrelatedChanges: true });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  send({ id: requests[1].id, event: { type: 'action', actionId: 'a1', result: { ok: true, dispatch: 'dispatched' } } });
  await tick();
  send({ id: requests[2].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[3].id, actionId: 'a2', phase: 'accepted' });
  await tick();
  send({ id: requests[4].id, event: { type: 'action', actionId: 'a2',
    result: { ok: false, dispatch: 'dispatched', error: { code: 'target_occluded' } } } });
  await tick();
  send({ id: requests[5].id, ok: true, viewRevision: 4, view: { screen: 'Contact' } });
  const outcome = await result;
  assert.equal(outcome.ok, false);
  assert.equal(outcome.completed, 1);
  assert.deepEqual(outcome.error, { code: 'target_occluded' });
  assert.deepEqual(outcome.taps.map(tap => [tap.target, tap.ok]), [['btn.1', true], ['btn.2', false]]);
  assert.equal(outcome.taps[1].result.error.code, 'target_occluded');
  // Same decision revision and explicit authority for every tap; btn.3 is never sent.
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'acknowledge', 'start', 'next', 'observe']);
  for (const start of requests.filter(r => r.method === 'start')) {
    assert.equal(start.viewRevision, 1);
    assert.equal(start.action.allowUnrelatedChanges, true);
  }
  assert.deepEqual(requests.filter(r => r.method === 'start').map(r => r.action.args[0]), ['btn.1', 'btn.2']);
  assert.equal(outcome.viewRevision, 4);
  assert.equal(outcome.scene.viewRevision, 4);
  await assert.rejects(client.taps(4, []), /1..32 observed handles/);
  client.abort();
});

test('act returns a settled scene after it changed the screen', async () => {
  const { client, requests, send } = fixture();
  await client.ready;
  const result = client.act(1, { method: 'tap', args: ['btn.members'] });
  send({ id: requests[0].id, actionId: 'a1', phase: 'accepted' });
  await tick();
  // A view update before the receipt is counted, not returned in full.
  send({ id: requests[1].id, event: { type: 'view', viewRevision: 2, view: { screen: 'Home' } } });
  await tick();
  send({ id: requests[2].id, event: { type: 'action', actionId: 'a1',
    result: { ok: true, dispatch: 'dispatched', delta: { screenChanged: true } } } });
  await tick();
  send({ id: requests[3].id, ok: true, hand: { unacknowledgedAction: null } });
  await tick();
  send({ id: requests[4].id, ok: true, viewRevision: 3, view: { screen: 'Members' } });
  await tick();
  // The list loads (one view change), then a full quiet window passes.
  send({ id: requests[5].id, event: { type: 'view', viewRevision: 4, view: { screen: 'Members' } } });
  await tick();
  send({ id: requests[6].id, event: { type: 'timeout' } });
  await tick();
  send({ id: requests[7].id, ok: true, viewRevision: 4, view: { screen: 'Members', visibleText: ['Ali'] } });
  const outcome = await result;
  assert.equal(outcome.ok, true);
  assert.equal(outcome.settle.status, 'settled');
  assert.equal(outcome.settle.viewChanges, 1);
  assert.equal(outcome.viewRevision, 4);
  assert.equal(outcome.scene.viewRevision, 4);
  assert.deepEqual(outcome.events, []);
  assert.equal(outcome.viewEvents, 1);
  assert.deepEqual(requests.map(r => r.method),
    ['start', 'next', 'next', 'acknowledge', 'observe', 'next', 'next', 'observe']);
  assert.equal(requests[6].timeoutMs, 500);
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

test('steps accept only exact-handle actions', () => {
  assert.deepEqual(stepHandles({ method: 'tap', args: ['btn.save'], params: { lateWaitMs: 200 } }), ['btn.save']);
  assert.deepEqual(stepHandles({ method: 'input', args: ['Ali'], params: { target: 'field.name' } }), ['field.name']);
  assert.deepEqual(stepHandles({ method: 'fill', params: { json: { 'field.a': '1', 'field.b': '2' } } }), ['field.a', 'field.b']);
  assert.deepEqual(stepHandles({ method: 'scroll', params: { target: 'scroll.list', distance: 300 } }), ['scroll.list']);
  for (const action of [
    { method: 'tap-text', args: ['Save'] },
    { method: 'tap', params: { x: 10, y: 20 } },
    { method: 'tap', args: ['btn.save'], params: { expectText: 'Saved' } },
    { method: 'input', args: ['Ali'] },
    { method: 'back' },
    { method: 'deeplink', args: ['app://x'] },
    { method: 'tap', args: ['btn.save'], allowUnrelatedChanges: 'yes' },
    { method: 'tap', args: ['btn.save'], viewRevision: 3 },
  ]) assert.equal(typeof stepHandles(action), 'string', JSON.stringify(action));
});

test('a later step is not sent when its screen, surface, settle or target drifted', () => {
  const decision = { screen: 'Order', activeSurface: { kind: 'route', instance: 1 },
    interactables: [{ id: 'btn.save', kind: 'btn', label: 'Save', instance: 4 }], fieldValues: { 'field.name': '' } };
  const same = { ...decision, visibleText: ['Total RM 120'], fieldValues: { 'field.name': 'Ali' } };
  assert.equal(stepDrift(decision, same, ['btn.save'], { status: 'settled' }), null);
  assert.equal(stepDrift(decision, same, ['field.name'], { status: 'unchanged' }), null);
  assert.equal(stepDrift(decision, same, ['btn.save'], { status: 'still_changing' }).code, 'steps_view_unsettled');
  assert.equal(stepDrift(decision, { ...same, screen: 'Payment' }, ['btn.save'], null).code, 'steps_screen_changed');
  assert.equal(stepDrift(decision, { ...same, activeSurface: { kind: 'dialog', instance: 9 } }, ['btn.save'], null).code,
    'steps_screen_changed');
  const replaced = { ...same, interactables: [{ id: 'btn.save', kind: 'btn', label: 'Save', instance: 7 }] };
  const drift = stepDrift(decision, replaced, ['btn.save'], null);
  assert.equal(drift.code, 'steps_target_changed');
  assert.deepEqual(drift.staleChanges, [{ target: 'btn.save', field: 'instance', before: 4, after: 7 }]);
  assert.equal(stepDrift(decision, { ...same, interactables: [] }, ['btn.save'], null).code, 'steps_target_changed');
});

test('steps send observed inputs in order with one receipt each and refuse a stale decision', async () => {
  const client = await connectFake('ok');
  try {
    const scene = await client.observe();
    const stale = await client.steps(scene.viewRevision - 1, [{ method: 'tap', args: ['btn.save'] }]);
    assert.deepEqual([stale.ok, stale.dispatch, stale.error.code, stale.completed], [false, 'not_dispatched', 'steps_decision_stale', 0]);
    const unseen = await client.steps(scene.viewRevision, [{ method: 'tap', args: ['btn.other'] }]);
    assert.equal(unseen.error.code, 'steps_target_not_observed');
    await assert.rejects(client.steps(scene.viewRevision, [{ method: 'back' }]), /steps\[0\]: steps take only/);
    const outcome = await client.steps(scene.viewRevision, [
      { method: 'input', args: ['Ali'], params: { target: 'field.customer_name' } },
      { method: 'tap', args: ['btn.save'] },
    ]);
    assert.equal(outcome.ok, true, JSON.stringify(outcome));
    assert.deepEqual([outcome.completed, outcome.requested], [2, 2]);
    assert.deepEqual(outcome.steps.map(step => [step.method, step.targets, step.ok, step.dispatch]),
      [['input', ['field.customer_name'], true, 'dispatched'], ['tap', ['btn.save'], true, 'dispatched']]);
    assert.equal(outcome.steps[1].result.dispatch, 'dispatched');
    assert.equal(outcome.viewRevision, outcome.scene.viewRevision);
    assert.equal(outcome.scene.viewRevision, scene.viewRevision + 2);
  } finally { client.abort(); }
});
