import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { test } from 'node:test';
import { ScoutAgent } from '../skills/flutter-scout/scripts/agent_client.mjs';

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
  assert.equal((await result).ok, false);
  assert.deepEqual(requests.map(r => r.method), ['start', 'next', 'observe']);
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
  const rejection = assert.rejects(pending, /connection lost/);
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
