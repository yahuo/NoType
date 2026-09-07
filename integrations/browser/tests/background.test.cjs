const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
function harness(senderOverride = {}) {
  const callbacks = {};
  const events = [];
  const replies = [];
  const event = (key) => ({ addListener(fn) { callbacks[key] = fn; } });
  const native = {
    onMessage: event("nativeMessage"), onDisconnect: event("nativeDisconnect"),
    postMessage(message) { events.push(message); }, disconnect() { events.push("nativeClosed"); },
  };
  const client = {
    name: "notype.translate",
    sender: { id: "own-id", tab: { id: 1 }, frameId: 0, url: "https://example.test/article", ...senderOverride },
    onMessage: event("message"), onDisconnect: event("disconnect"),
    postMessage(message) { replies.push(message); }, disconnect() { events.push("clientClosed"); },
  };
  const chrome = {
    action: { onClicked: event("click"), async setBadgeText() {}, async setTitle() {} },
    scripting: { async executeScript() {} },
    runtime: { id: "own-id", onConnect: event("connect"), connectNative(name) { events.push(name); return native; } },
  };
  let id = 0;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../extension/background.js"), "utf8"), {
    chrome, crypto: { randomUUID: () => `request-${++id}` },
    setTimeout(fn) { callbacks.timeout = fn; return 1; }, clearTimeout() {},
  });
  callbacks.connect(client);
  return { callbacks, events, replies, chrome };
}
const request = { items: [{ id: "p0", text: "Hello" }] };
test("only the extension's top-level web content can open the native host", () => {
  for (const sender of [{ id: "other" }, { frameId: 1 }, { url: "file:///private" }]) {
    assert.deepEqual(harness(sender).events, ["clientClosed"]);
  }
});
test("invalid, duplicate, and oversized batches are rejected before being sent", () => {
  for (const items of [[], [{ id: "x", text: "x".repeat(12001) }], [request.items[0], request.items[0]],
    [{ id: "x", text: "x".repeat(3001) }, { id: "y", text: "y".repeat(3000) }]]) {
    const h = harness(); h.callbacks.message({ items });
    assert.equal(h.replies[0].ok, false);
    assert.equal(h.events.filter((event) => typeof event === "object").length, 0);
  }
});
test("partial frames arrive before the final result and the native connection is reused", () => {
  const h = harness(); h.callbacks.message(request);
  assert.equal(h.events[1].method, "translate_chinese_batch");
  h.callbacks.nativeMessage({ version: 1, id: "request-1", ok: true, partial: true, text: "译文" });
  assert.equal(h.replies.length, 1);
  assert.equal(h.events.includes("nativeClosed"), false);
  h.callbacks.nativeMessage({ version: 1, id: "request-1", ok: true, items: [{ id: "p0", text: "你好" }] });
  h.callbacks.message(request);
  assert.equal(h.events[2].id, "request-2");
  assert.equal(h.events.filter((event) => event === "com.opensource.notype.browser").length, 1);
  h.callbacks.disconnect();
  assert.equal(h.events.includes("nativeClosed"), true);
});
test("wrong IDs, overlapping requests, timeout and disconnect stop the stream", () => {
  for (const kind of ["wrongId", "overlap", "timeout", "nativeDisconnect"]) {
    const h = harness(); h.callbacks.message(request);
    if (kind === "wrongId") h.callbacks.nativeMessage({ version: 1, id: "other", ok: true });
    else if (kind === "overlap") h.callbacks.message(request);
    else h.callbacks[kind]();
    assert.equal(h.replies.at(-1).ok, false);
    assert.equal(h.events.includes("nativeClosed"), true);
    h.callbacks.nativeMessage({ version: 1, id: "request-1", ok: true });
    assert.equal(h.replies.length, 1);
  }
});
