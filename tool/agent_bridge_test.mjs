// Exercises the shipped shell bridge (serve/call/stop) end to end against a
// fake `flutter-scout agent` child. Run: node --test tool/agent_bridge_test.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const client = fileURLToPath(new URL('../skills/flutter-scout/scripts/agent_client.mjs', import.meta.url));
const fake = fileURLToPath(new URL('./fixtures/fake_flutter_scout.mjs', import.meta.url));
const root = mkdtempSync(join(tmpdir(), 'scout-bridge-'));
const sockets = [];
after(async () => {
  for (const socket of sockets) await run(['stop', '--app', 'demo', '--socket', socket]);
  rmSync(root, { recursive: true, force: true });
});

function run(args, { env = {}, stdin } = {}) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [client, ...args], { env: { ...process.env, ...env } });
    let out = '';
    child.stdout.on('data', chunk => { out += chunk; });
    child.stderr.resume();
    if (stdin !== undefined) child.stdin.end(stdin); else child.stdin.end();
    child.on('exit', code => {
      const lines = out.trim().split('\n');
      assert.equal(lines.length, 1, `one JSON line expected: ${out}`);
      resolve({ code, json: JSON.parse(lines[0]) });
    });
  });
}

function bridge(name, mode = 'ok') {
  const dir = join(root, name);
  const socket = join(dir, 'demo.sock');
  const log = join(root, `${name}.jsonl`);
  const env = { FAKE_SCOUT_MODE: mode, FAKE_SCOUT_LOG: log };
  const call = (method, json, options = {}) =>
    run(['call', '--app', 'demo', '--socket', socket, method, ...(json === undefined ? [] : [json])], options);
  const requests = () => existsSync(log)
    ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
  const serve = () => run(['serve', '--app', 'demo', '--socket', socket, '--binary', fake], { env });
  sockets.push(socket);
  return { dir, socket, call, requests, serve };
}

test('serve, a 20-step observe/act loop, reload reconnect and stop', async () => {
  const b = bridge('loop');
  const served = await b.serve();
  assert.equal(served.code, 0, JSON.stringify(served.json));
  assert.equal(served.json.type, 'serving');
  assert.equal(served.json.scene.viewRevision, 1);
  assert.equal(statSync(b.socket).mode & 0o777, 0o600);
  assert.equal(statSync(b.dir).mode & 0o777, 0o700);
  assert.equal((await b.serve()).json.reused, true);

  for (let step = 0; step < 20; step++) {
    const scene = await b.call('observe');
    assert.equal(scene.code, 0);
    const outcome = await b.call('act', JSON.stringify({
      viewRevision: scene.json.viewRevision, action: { method: 'tap', args: ['btn.save'] } }));
    assert.equal(outcome.code, 0, JSON.stringify(outcome.json));
    assert.equal(outcome.json.result.dispatch, 'dispatched');
    assert.equal(outcome.json.scene.viewRevision, scene.json.viewRevision + 1);
  }
  const loop = b.requests();
  assert.equal(new Set(loop.map(r => r.pid)).size, 1, 'one persistent agent connection');
  assert.equal(loop.filter(r => r.method === 'start').length, 20);
  assert.equal(loop.filter(r => r.method === 'acknowledge').length, 20);

  // Sensitive input never travels in argv; stdin is accepted.
  const typed = { viewRevision: 21, action: { method: 'input', args: ['6015 secret'], params: { target: 'f' } } };
  const refused = await b.call('act', JSON.stringify(typed));
  assert.equal(refused.code, 2);
  assert.equal(refused.json.error.code, 'bridge_stdin_required');
  assert.equal(b.requests().length, loop.length, 'nothing sent');
  const viaStdin = await b.call('act', '-', { stdin: JSON.stringify(typed) });
  assert.equal(viaStdin.code, 0, JSON.stringify(viaStdin.json));

  // Before reload/restart: disconnect; the next call reconnects lazily.
  assert.equal((await b.call('disconnect')).json.type, 'disconnected');
  const reloaded = await b.call('observe');
  assert.equal(reloaded.code, 0);
  assert.deepEqual([reloaded.json.bridge.reconnected, reloaded.json.bridge.reason], [true, 'disconnected']);
  assert.equal(new Set(b.requests().map(r => r.pid)).size, 2);

  const stopped = await b.call('close');
  assert.equal(stopped.code, 0);
  await new Promise(resolve => setTimeout(resolve, 200));
  assert.equal(existsSync(b.socket), false);
  const gone = await b.call('observe');
  assert.deepEqual([gone.code, gone.json.error.code], [1, 'bridge_not_running']);
  assert.equal((await run(['stop', '--app', 'demo', '--socket', b.socket])).json.running, false);
});

test('a killed agent child reconnects lazily and gates stale revisions', async () => {
  const b = bridge('killed');
  assert.equal((await b.serve()).code, 0);
  const scene = await b.call('observe');
  const [first] = b.requests();
  process.kill(first.pid, 'SIGKILL');
  await new Promise(resolve => setTimeout(resolve, 200));
  const stale = await b.call('act', JSON.stringify({
    viewRevision: scene.json.viewRevision, action: { method: 'tap', args: ['btn.save'] } }));
  assert.equal(stale.code, 1);
  assert.equal(stale.json.error.code, 'bridge_reconnected');
  assert.equal(stale.json.dispatch, 'not_dispatched');
  assert.equal(stale.json.bridge.previousLoss.code, 'scout_agent_exited');
  assert.equal(stale.json.bridge.previousLoss.signal, 'SIGKILL');
  assert.equal(stale.json.bridge.previousLoss.dispatch, 'not_dispatched');
  assert.equal(b.requests().filter(r => r.method === 'start').length, 0, 'nothing sent');
  const fresh = await b.call('observe');
  const acted = await b.call('act', JSON.stringify({
    viewRevision: fresh.json.viewRevision, action: { method: 'tap', args: ['btn.save'] } }));
  assert.equal(acted.code, 0, JSON.stringify(acted.json));
});

test('loss during an input is reported once as unknown and never retried', async () => {
  const b = bridge('inflight', 'die_on_start');
  assert.equal((await b.serve()).code, 0);
  const lost = await b.call('act', JSON.stringify({ viewRevision: 1, action: { method: 'tap', args: ['btn.save'] } }));
  assert.equal(lost.code, 1);
  assert.equal(lost.json.dispatch, 'dispatch_outcome_unknown');
  assert.match(lost.json.error.message, /may have dispatched/);
  assert.equal(lost.json.error.stderr, 'fatal: VM service closed');
  const next = await b.call('observe');
  assert.equal(next.json.bridge.previousLoss.dispatch, 'dispatch_outcome_unknown');
  assert.equal(b.requests().filter(r => r.method === 'start').length, 1, 'no automatic retry');
});

test('default socket lives in a private per-user directory', async () => {
  const app = `bridge-test-${process.pid}-with-a-long-session-name`;
  const served = await run(['serve', '--app', app, '--binary', fake]);
  assert.equal(served.code, 0, JSON.stringify(served.json));
  const uid = process.getuid();
  assert.match(served.json.socket, new RegExp(`/flutter-scout-${uid}/app-[0-9a-f]{16}\\.sock$`));
  assert.ok(served.json.socket.length < 104);
  assert.equal(statSync(join(served.json.socket, '..')).mode & 0o777, 0o700);
  assert.equal((await run(['call', '--app', app, 'observe'])).code, 0);
  assert.equal((await run(['stop', '--app', app])).code, 0);
  rmSync(served.json.log, { force: true });
});

test('serve fails cleanly with the CLI cause and leaves no server', async () => {
  const b = bridge('missing', 'not_registered');
  const served = await b.serve();
  assert.equal(served.code, 1);
  assert.equal(served.json.error.code, 'session_not_registered');
  assert.equal(served.json.error.exitCode, 1);
  assert.equal(existsSync(b.socket), false);
});
