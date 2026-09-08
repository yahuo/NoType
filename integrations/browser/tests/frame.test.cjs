const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
function harness() {
  let ready, listener, hidden, starts = 0, stops = 0;
  const sent = [];
  const context = {
    chrome: { runtime: {
      onMessage: { addListener(fn) { listener = fn; } },
      sendMessage(message) { sent.push(message); return message.type === 'notype.ready' ? new Promise((resolve) => { ready = resolve; }) : Promise.resolve(); },
    } },
    __noTypeToggleTranslation() { starts++; context.__noTypeBilingual = { stop() { stops++; delete context.__noTypeBilingual; } }; },
    addEventListener(name, fn) { if (name === 'pagehide') hidden = fn; },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../extension/frame.js'), 'utf8'), context);
  return { context, sent, ready: (active) => ready({ active }), hidden: () => hidden(),
    command: (type, extra = {}) => listener({ type, ...extra }, {}, () => {}), counts: () => ({ starts, stops }) };
}
test('inactive pages only register; active newly loaded frames start once', async () => {
  const inactive = harness(); inactive.ready(false); await Promise.resolve(); assert.equal(inactive.counts().starts, 0);
  const h = harness(); h.ready(true); await Promise.resolve(); h.command('notype.start');
  assert.equal(h.counts().starts, 1); h.command('notype.stop'); assert.equal(h.counts().stops, 1);
});
test('late ready response cannot restart after a stop; close controls the entire tab', async () => {
  const h = harness(); h.command('notype.start'); h.command('notype.stop'); h.ready(true); await Promise.resolve();
  assert.equal(h.counts().starts, 1);
  h.command('notype.start'); h.context.__noTypeStopTab();
  assert.equal(h.sent.at(-1).type, 'notype.stop'); assert.equal(h.counts().stops, 2);
});
test('frame unload disconnects its own translation without stopping other frames', () => {
  const h = harness(); h.command('notype.start'); h.hidden();
  assert.equal(h.counts().stops, 1); assert.equal(h.sent.length, 1);
});
test('retry controls the tab and failure notifications reach the existing page state', () => {
  const h = harness(); h.command('notype.start');
  let retries = 0;
  h.context.__noTypeBilingual.retry = () => { retries++; };
  h.context.__noTypeRetryTab();
  assert.equal(h.sent.at(-1).type, 'notype.retry');
  h.command('notype.retry'); assert.equal(retries, 1);
  let summary;
  h.context.__noTypeBilingual.setFailures = (...args) => { summary = args; };
  h.command('notype.failures', { count: 2, error: '翻译超时', pending: true });
  assert.deepEqual(summary, [2, '翻译超时', true]);
  assert.equal(h.counts().starts, 1);
});
test('channel errors reach a completed page without restarting translation', () => {
  const h = harness(); h.command('notype.start');
  let error;
  h.context.__noTypeBilingual.fail = message => { error = message; };
  h.command('notype.error', { error: '请先登录 NoType' });
  assert.equal(error, '请先登录 NoType');
  assert.equal(h.counts().starts, 1);
});
