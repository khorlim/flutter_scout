// Runtime verification only. Navigate to the test app's Eye-hand probe first.
// These fixture-specific conditions are NOT built into the shipped client.
import assert from 'node:assert/strict';
import { ScoutAgent } from '../skills/flutter-scout/scripts/agent_client.mjs';

const [app, binary = 'flutter-scout', ...modes] = process.argv.slice(2);
if (!app || modes.some(mode => !['hold', 'flash', 'quiet'].includes(mode))) {
  throw new Error('Usage: node tool/agent_runtime_smoke.mjs APP [BINARY] [hold flash quiet ...]');
}
const results = [];
for (const mode of modes.length ? modes : ['hold', 'flash', 'quiet']) {
  const agent = await ScoutAgent.connect({app, binary});
  const events = [];
  const readEvent = async () => {
    const response = await agent.next(1000);
    assert.equal(response.ok, true);
    events.push(response.event);
    return response.event;
  };
  try {
    const scene = await agent.observe();
    assert.equal(scene.view.screen, 'EyeHandProbeScreen');
    assert.equal(scene.view.rendering.status, 'active');
    const target = scene.view.interactables.find(node => node.id === `btn.probe_start_${mode}`);
    assert.ok(target && target.enabled !== false && target.hitTestable !== false);
    const startTime = Date.now();
    const ticket = await agent.start(scene.viewRevision, {method: 'tap', args: [target.id]});
    assert.equal(ticket.ok, true);
    assert.equal(ticket.dispatch, 'not_yet_established');
    const ticketMs = Date.now() - startTime;
    let receipt;
    const deadline = startTime + 14000;
    while (Date.now() < deadline) {
      const event = await readEvent();
      if (event.type === 'action' && event.actionId === ticket.actionId) { receipt = event.result; break; }
      assert.notEqual(event.type, 'stopped');
    }
    assert.equal(receipt?.ok, true);
    assert.equal(receipt.dispatch, 'dispatched');
    assert.equal(receipt.postcondition, 'postcondition_not_requested');
    assert.equal((await agent.acknowledge(ticket.actionId)).ok, true);
    const receiptMs = Date.now() - startTime;
    const working = await agent.observe();
    assert.ok(working.view.visibleText.includes('Phase: Working'));
    assert.ok(working.view.visibleText.includes('Notice: None'));
    const pause = working.view.interactables.find(node => node.id === 'btn.probe_pause');
    assert.ok(pause && pause.enabled !== false && pause.hitTestable !== false);
    const rule = await agent.react(working.viewRevision, {text: 'Notice: Pause requested'},
      {type: 'tap', target: pause.id}, mode === 'quiet' ? 3000 : 6000);
    assert.equal(rule.ok, true);
    const completion = await agent.watch({text: mode === 'quiet' ? 'Phase: Ready' : 'Phase: Paused'}, 11000);
    let condition;
    while (Date.now() < deadline) {
      const event = await readEvent();
      assert.notEqual(event.type, 'stopped');
      if (event.type === 'action') assert.equal(event.result.ok, true);
      if (event.conditionId === completion.conditionId && event.type === 'condition') {
        condition = event;
        break;
      }
    }
    assert.equal(condition?.status, 'met');
    // Condition observation may precede the canonical input receipt.
    const triggered = events.find(event => event.type === 'reaction' && event.status === 'triggered');
    if (triggered) {
      while (!events.some(event => event.type === 'action' && event.actionId === triggered.actionId) && Date.now() < deadline) {
        await readEvent();
      }
      assert.equal(events.find(event => event.type === 'action' && event.actionId === triggered.actionId)?.result?.ok, true);
      assert.equal((await agent.acknowledge(triggered.actionId)).ok, true);
    }
    const final = await agent.observe();
    const callbacks = Object.fromEntries(final.view.visibleText.flatMap(text => {
      const match = /^Event (\w+): (\d+)$/.exec(text);
      return match ? [[match[1], Number(match[2])]] : [];
    }));
    assert.ok(final.view.visibleText.includes('Late pauses: 0'));
    const actions = events.filter(event => event.type === 'action');
    assert.equal(actions.length, mode === 'quiet' ? 1 : 2);
    if (mode === 'quiet') {
      assert.equal(callbacks.paused, undefined);
      assert.equal(events.find(event => event.conditionId === rule.conditionId)?.status, 'timeout');
    } else {
      assert.ok(callbacks.paused > callbacks.notice);
      assert.equal(callbacks.ready, undefined);
    }
    const result = {mode, success: true, ticketMs, receiptMs,
      pauseAfterNoticeMs: callbacks.paused ? callbacks.paused - callbacks.notice : null,
      elapsedMs: Date.now() - startTime, actions: actions.length,
      rendering: final.view.rendering.status, callbacks};
    results.push(result);
    console.log(JSON.stringify(result));
  } finally {
    await agent.close();
  }
}
console.log(JSON.stringify({runs: results.length, passed: results.every(result => result.success)}));
