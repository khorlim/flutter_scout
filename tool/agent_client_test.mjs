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
  send({ type: 'ready', ok: true, agentProtocol: 1, viewRevision: 1, view: {} });
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
