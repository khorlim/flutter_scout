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
const fastClient = fileURLToPath(new URL('../skills/flutter-scout/scripts/scout-call', import.meta.url));
const fake = fileURLToPath(new URL('./fixtures/fake_flutter_scout.mjs', import.meta.url));
const root = mkdtempSync(join(tmpdir(), 'scout-bridge-'));
const sockets = [];
after(async () => {
  for (const socket of sockets) await run(['stop', '--app', 'demo', '--socket', socket]);
  rmSync(root, { recursive: true, force: true });
});

function run(args, { env = {}, stdin, fast = false } = {}) {
  return new Promise(resolve => {
    const child = fast ? spawn(fastClient, args, { env: { ...process.env, ...env } })
      : spawn(process.execPath, [client, ...args], { env: { ...process.env, ...env } });
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
  // The zsh client: same requests and replies without starting node.
  const fast = (method, json, options = {}) =>
    run(['--app', 'demo', '--socket', socket, ...(options.brief ? ['--brief'] : []), method,
      ...(json === undefined ? [] : [json])], { ...options, fast: true });
  const requests = () => existsSync(log)
    ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
  const serve = () => run(['serve', '--app', 'demo', '--socket', socket, '--binary', fake], { env });
  sockets.push(socket);
  return { dir, socket, call, fast, requests, serve };
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

  // Secret input never travels in argv: a credential-named target, a field
  // Scout redacts, an unknown field, or no target at all. Nothing is sent.
  const input = (target, value = '6015 secret') => ({ viewRevision: 21,
    action: { method: 'input', args: [value], ...(target ? { params: { target } } : {}) } });
  for (const [target, code] of [['field.pin', 2], ['field.staff_code', 1], ['field.unknown', 1], [null, 2]]) {
    const refused = await b.call('act', JSON.stringify(input(target)));
    assert.equal(refused.code, code, JSON.stringify(refused.json));
    assert.equal(refused.json.error.code, 'bridge_stdin_required');
    assert.match(refused.json.error.message, /stdin/);
    assert.equal(b.requests().length, loop.length, 'nothing sent');
  }
  const fill = { viewRevision: 21, action: { method: 'fill', params: { json: {
    'field.customer_name': 'Ali', 'field.staff_code': '1234' } } } };
  assert.equal((await b.call('act', JSON.stringify(fill))).json.error.code, 'bridge_stdin_required');
  assert.equal(b.requests().length, loop.length, 'nothing sent');
  const viaStdin = await b.call('act', '-', { stdin: JSON.stringify(input('field.staff_code')) });
  assert.equal(viaStdin.code, 0, JSON.stringify(viaStdin.json));
  // An ordinary visible field accepts its value on the command line.
  const plain = await b.call('act', JSON.stringify({ ...input('field.customer_name', 'AI Smoke'), viewRevision: 22 }));
  assert.equal(plain.code, 0, JSON.stringify(plain.json));
  assert.deepEqual(b.requests().filter(r => r.method === 'start').at(-1).args, ['AI Smoke']);
  const typedCount = b.requests().length;

  // A blocking watch returns the condition's end directly; view updates are
  // counted, not returned. Not met is ok:false with the status.
  const met = await b.call('watch', JSON.stringify({ condition: { gone: 'Data sync' }, timeoutMs: 2000, wait: true }));
  assert.equal(met.code, 0, JSON.stringify(met.json));
  assert.deepEqual([met.json.status, met.json.conditionId, met.json.viewEvents, met.json.events], ['met', 'w1', 2, []]);
  assert.equal(met.json.view.screen, 'Home');
  const missed = await b.call('watch', JSON.stringify({ condition: { gone: 'never' }, timeoutMs: 2000, wait: true }));
  assert.deepEqual([missed.code, missed.json.status, missed.json.error.code], [1, 'timeout', 'watch_not_met']);
  const ticket = await b.call('watch', JSON.stringify({ condition: { text: 'Saved' }, timeoutMs: 2000 }));
  assert.deepEqual([ticket.code, ticket.json.conditionId], [0, 'w1']);
  assert.equal(b.requests().filter(r => r.method === 'watch').length, 3);
  assert.equal(b.requests().length > typedCount, true);

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

test('taps and act carry the next revision at the top level, like observe', async () => {
  const b = bridge('taps');
  assert.equal((await b.serve()).code, 0);
  const scene = await b.call('observe');
  const taps = await b.call('taps', JSON.stringify({ viewRevision: scene.json.viewRevision, targets: ['btn.save'] }));
  assert.equal(taps.code, 0, JSON.stringify(taps.json));
  assert.equal(taps.json.completed, 1);
  assert.equal(taps.json.taps[0].result.dispatch, 'dispatched');
  assert.equal(taps.json.viewRevision, taps.json.scene.viewRevision);
  const act = await b.call('act', JSON.stringify({ viewRevision: taps.json.viewRevision,
    action: { method: 'tap', args: ['btn.save'] } }));
  assert.equal(act.json.viewRevision, act.json.scene.viewRevision);
  assert.deepEqual(b.requests().filter(r => r.method === 'start').map(r => r.args), [['btn.save'], ['btn.save']]);
});

test('scout-call drives the same bridge without node, with the same input checks', async () => {
  const b = bridge('fast');
  assert.equal((await b.serve()).code, 0);
  const scene = await b.fast('observe', undefined, { brief: true });
  assert.equal(scene.code, 0, JSON.stringify(scene.json));
  // ok comes first; brief is applied by the bridge.
  assert.equal(Object.keys(scene.json)[0], 'ok');
  const acted = await b.fast('act', JSON.stringify({ viewRevision: scene.json.viewRevision,
    action: { method: 'tap', args: ['btn.save'] } }));
  assert.equal(acted.code, 0, JSON.stringify(acted.json));
  assert.equal(acted.json.result.dispatch, 'dispatched');
  const sent = b.requests().length;

  // Typed values from argv get the bridge's stdin-only checks; nothing sent.
  const revision = acted.json.viewRevision;
  const secret = { viewRevision: revision, action: { method: 'input', args: ['6015 1234'],
    params: { target: 'field.staff_code' } } };
  for (const params of [secret, { viewRevision: revision, actions: [secret.action] }]) {
    const refused = await b.fast(params.actions ? 'steps' : 'act', JSON.stringify(params));
    assert.deepEqual([refused.code, refused.json.error.code], [1, 'bridge_stdin_required'], JSON.stringify(refused.json));
  }
  // A caller cannot unmark its own argv values.
  const spoofed = await b.fast('act', JSON.stringify({ argv: false, ...secret }));
  assert.equal(spoofed.json.error.code, 'bridge_invalid_request');
  assert.equal(b.requests().length, sent, 'nothing sent');
  // Pretty-printed JSON on stdin is one request.
  const viaStdin = await b.fast('act', '-', { stdin: JSON.stringify(secret, null, 2) });
  assert.equal(viaStdin.code, 0, JSON.stringify(viaStdin.json));

  const steps = await b.fast('steps', JSON.stringify({ viewRevision: viaStdin.json.viewRevision, actions: [
    { method: 'input', args: ['AI Smoke'], params: { target: 'field.customer_name' } },
    { method: 'tap', args: ['btn.save'] }] }));
  assert.equal(steps.code, 0, JSON.stringify(steps.json));
  assert.equal(steps.json.completed, 2);
  assert.deepEqual(b.requests().filter(r => r.method === 'start').slice(-2).map(r => r.args), [['AI Smoke'], ['btn.save']]);

  const unknown = await b.fast('bogus');
  assert.deepEqual([unknown.code, unknown.json.error.code], [1, 'bridge_invalid_request']);
  const usage = await run(['observe'], { fast: true });
  assert.deepEqual([usage.code, usage.json.error.code], [2, 'usage']);
  assert.equal((await run(['stop', '--app', 'demo', '--socket', b.socket], { fast: true })).code, 0);
  await new Promise(resolve => setTimeout(resolve, 200));
  const gone = await b.fast('observe');
  assert.deepEqual([gone.code, gone.json.error.code, gone.json.dispatch], [1, 'bridge_not_running', 'not_dispatched']);
  assert.equal((await run(['stop', '--app', 'demo', '--socket', b.socket], { fast: true })).json.running, false);
});

test('scout-call finds the default socket and falls back to node for hashed names', async () => {
  const short = `fast-${process.pid}`;
  const long = `bridge-test-${process.pid}-with-a-long-session-name`;
  for (const app of [short, long]) {
    const served = await run(['serve', '--app', app, '--binary', fake]);
    assert.equal(served.code, 0, JSON.stringify(served.json));
    const observed = await run(['--app', app, '--brief', 'observe'], { fast: true });
    assert.equal(observed.code, 0, JSON.stringify(observed.json));
    assert.equal(observed.json.view.screen, 'Home');
    assert.equal((await run(['stop', '--app', app], { fast: true })).code, 0);
    rmSync(served.json.log, { force: true });
  }
});
