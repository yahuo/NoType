const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
function harness() {
  const event = () => {
    const listeners = [];
    return { addListener(fn) { listeners.push(fn); }, emit(...args) { return listeners.map((fn) => fn(...args)); } };
  };
  const natives = [], broadcasts = [], timers = new Set(), state = {};
  const immediate = new Set();
  const chrome = {
    action: { onClicked: event(), async setBadgeText() {}, async setTitle() {} },
    tabs: { onRemoved: event(), async sendMessage(tabId, message, options) { broadcasts.push({ tabId, message, options }); } },
    webNavigation: { onCommitted: event() },
    storage: { session: {
      async get(key) { return { [key]: state[key] }; },
      async set(value) { Object.assign(state, value); },
      async remove(key) { delete state[key]; },
    } },
    runtime: { id: "own-id", onConnect: event(), onMessage: event(), connectNative(name) {
      const native = { name, sent: [], closed: false, onMessage: event(), onDisconnect: event(),
        postMessage(message) { this.sent.push(message); }, disconnect() { this.closed = true; this.onDisconnect.emit(); } };
      natives.push(native); return native;
    } },
  };
  let id = 0;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../extension/background.js"), "utf8"), {
    chrome, crypto: { randomUUID: () => `request-${++id}` },
    setTimeout(fn, delay) { (delay === 0 ? immediate : timers).add(fn); return fn; },
    clearTimeout(fn) { timers.delete(fn); immediate.delete(fn); },
  });
  function connect(senderOverride = {}) {
    let nextRequest = 0;
    const client = { name: "notype.translate", closed: false, replies: [],
      sender: { id: "own-id", tab: { id: 1 }, frameId: 0, url: "https://example.test/article", ...senderOverride },
      onMessage: event(), onDisconnect: event(),
      postMessage(message) { this.replies.push(message); },
      disconnect() { if (!this.closed) { this.closed = true; this.onDisconnect.emit(); } },
      send(message) { this.onMessage.emit(message.type ? message : { id: `r${nextRequest++}`, ...message }); },
    };
    chrome.runtime.onConnect.emit(client); return client;
  }
  const finish = (native, text = "你好") => {
    const request = native.sent.at(-1);
    native.onMessage.emit({ version: 1, id: request.id, ok: true, items: request.items.map(({ id }) => ({ id, text })) });
  };
  const flush = () => { for (const fn of [...immediate]) { immediate.delete(fn); fn(); } };
  return { chrome, connect, natives, broadcasts, timers, state, finish, flush };
}
const request = { items: [{ id: "p0", text: "Hello" }] };
test("only owned web frames and related blank/blob/data child frames can translate", () => {
  for (const sender of [{ id: "other" }, { frameId: -1 }, { url: "file:///private" }, { url: "about:blank" }]) {
    const h = harness(); assert.equal(h.connect(sender).closed, true); assert.equal(h.natives.length, 0);
  }
  for (const url of ["https://unrelated.test/chart", "about:blank", "about:srcdoc", "blob:https://any.test/id", "data:text/html,test"]) {
    const h = harness(); h.connect({ frameId: 2, url }).send(request); h.flush(); assert.equal(h.natives.length, 1);
  }
});
test("invalid, duplicate, and oversized batches never reach the native host", () => {
  for (const items of [[], [{ id: "x", text: "x".repeat(12001) }], [request.items[0], request.items[0]],
    [{ id: "x", text: "x".repeat(3001) }, { id: "y", text: "y".repeat(3000) }]]) {
    const h = harness(), client = h.connect(); client.send({ items });
    assert.equal(client.replies[0].ok, false); assert.equal(h.natives.length, 0);
  }
});
test("frames share one batch and identical paragraph IDs route to their owner", () => {
  const h = harness(), top = h.connect(), child = h.connect({ frameId: 4 });
  top.send(request); child.send({ items: [{ id: "p0", text: "Other text" }] }); h.flush();
  const native = h.natives[0];
  assert.equal(h.natives.length, 1); assert.equal(native.sent.length, 1);
  native.onMessage.emit({ version: 1, id: native.sent[0].id, ok: true, partial: true, text: '{"id":"t0","text":"译文' });
  assert.equal(top.replies.length, 1); assert.equal(child.replies.length, 0);
  h.finish(native, "主页面"); h.flush(); assert.equal(native.sent.length, 1);
  top.disconnect(); assert.equal(native.closed, true);
  assert.equal(child.replies.at(-1).items[0].text, "主页面");
  child.disconnect(); assert.equal(native.closed, true); assert.equal(h.timers.size, 0);
});
test("frame removal cancels its unused slot and ignores late results", () => {
  const h = harness(), first = h.connect(), removed = h.connect({ frameId: 2 }), last = h.connect({ frameId: 3 });
  first.send(request); h.flush(); removed.send({items:[{id:"p0",text:"Removed"}]}); last.send({items:[{id:"p0",text:"Last"}]});
  first.disconnect(); removed.disconnect(); h.flush();
  assert.equal(h.natives[0].closed, true);
  assert.equal(h.natives[1].sent[0].items[0].text, "Last");
  h.finish(h.natives[0]); assert.equal(last.replies.length, 0);
  h.finish(h.natives[1]); h.flush();
  assert.equal(first.replies.length, 0); assert.equal(last.replies.length, 1);
  assert.equal(h.natives[1].closed, true);
});
test("invalid client requests and unavailable channels still stop the tab", () => {
  for (const kind of ["missing_codex_auth", "busy", "bridge_unavailable", "overlap", "nativeDisconnect"]) {
    const h = harness(), client = h.connect(), child = h.connect({ frameId: 2 }); client.send(request); child.send(request); h.flush();
    const native = h.natives[0];
    if (kind === "overlap") client.send(request);
    else if (kind === "nativeDisconnect") native.onDisconnect.emit();
    else native.onMessage.emit({ version: 1, id: native.sent[0].id, ok: false, error: { code: kind, message: "通道不可用" } });
    assert.equal(client.replies.at(-1).ok, false); assert.equal(child.replies.at(-1).ok, false);
    assert.equal(native.closed, true); assert.equal(h.timers.size, 0);
  }
});
test("tab toggle and top navigation stop all frames; child navigation preserves activation", async () => {
  const h = harness();
  await h.chrome.action.onClicked.emit({ id: 1, url: "https://example.test" })[0];
  assert.equal(h.state['translation:1'], true);
  const active = await new Promise((resolve) => h.chrome.runtime.onMessage.emit({ type: "notype.ready" }, h.connect({ frameId: 5 }).sender, resolve));
  assert.equal(active.active, true);
  h.chrome.webNavigation.onCommitted.emit({ tabId: 1, frameId: 5 });
  assert.equal(h.state['translation:1'], true);
  const client = h.connect(); client.send(request); h.flush();
  await h.chrome.action.onClicked.emit({ id: 1, url: "https://example.test" })[0];
  assert.equal(h.state['translation:1'], undefined); assert.equal(h.natives[0].closed, true);
  assert.equal(h.broadcasts.at(-1).message.type, "notype.stop");
  await h.chrome.action.onClicked.emit({ id: 1, url: "https://example.test" })[0];
  h.chrome.webNavigation.onCommitted.emit({ tabId: 1, frameId: 0 });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(h.state['translation:1'], undefined);
});

test("duplicate text shares queued and in-flight work and a completed session cache", async () => {
  const h = harness(), a = h.connect(), b = h.connect({frameId:2});
  a.send({items:[{id:"a",text:"Undisclosed"},{id:"b",text:"Undisclosed"}]}); h.flush();
  b.send({items:[{id:"x",text:"Undisclosed"}]}); h.flush();
  assert.equal(h.natives[0].sent.length,1); assert.equal(h.natives[0].sent[0].items.length,1);
  h.finish(h.natives[0],"未披露");
  assert.deepEqual(Array.from(a.replies.at(-1).items,i=>[i.id,i.text]),[["a","未披露"],["b","未披露"]]);
  assert.equal(b.replies.at(-1).items[0].id,"x");
  a.disconnect(); b.disconnect(); h.flush(); assert.equal(h.natives[0].closed,true);
  const c=h.connect({frameId:3}); c.send({items:[{id:"late",text:"Undisclosed"}]}); h.flush();
  assert.equal(h.natives.length,1); assert.equal(c.replies.at(-1).items[0].text,"未披露");
  await h.chrome.runtime.onMessage.emit({type:"notype.stop"},c.sender,()=>{})[0];
  await new Promise(resolve=>setImmediate(resolve));
  const d=h.connect(); d.send({items:[{id:"again",text:"Undisclosed"}]}); h.flush(); assert.equal(h.natives.length,2);
});
test("cross-frame batching respects limits and remaps partial and final IDs", () => {
  const h=harness(), a=h.connect(), b=h.connect({frameId:2});
  a.send({items:[{id:"p0",text:"First"}]}); b.send({items:[{id:"p0",text:"Second"}]}); h.flush();
  const n=h.natives[0], items=n.sent[0].items;
  assert.equal(items.length,2); assert.notEqual(items[0].id,items[1].id);
  n.onMessage.emit({version:1,id:n.sent[0].id,ok:true,partial:true,text:`{"id":"${items[1].id}","text":"第二\\n段`});
  assert.equal(a.replies.length,0);
  assert.equal(b.replies[0].text,'{"id":"p0","text":"第二\\n段');
  n.onMessage.emit({version:1,id:n.sent[0].id,ok:true,items:[{id:items[1].id,text:"第二段"},{id:items[0].id,text:"第一段"}]});
  assert.equal(a.replies.at(-1).items[0].text,"第一段"); assert.equal(b.replies.at(-1).items[0].text,"第二段");
});
test("cache hits and split batches return exactly one complete original group", () => {
  const h=harness(), a=h.connect(); a.send(request); h.flush(); h.finish(h.natives[0],"缓存");
  const b=h.connect({frameId:2}); b.send({items:[{id:"b0",text:"x".repeat(3500)},{id:"b1",text:"Another"}]});
  a.send({items:[{id:"a0",text:"Hello"},{id:"a1",text:"y".repeat(3000)},{id:"a2",text:"Third"}]}); h.flush();
  assert.equal(h.natives[0].sent.at(-1).items.length,2);
  assert.equal(a.replies.at(-1).partial,true);
  h.finish(h.natives[0],"批次二"); h.flush();
  assert.equal(a.replies.filter(r=>!r.partial).length,1);
  h.finish(h.natives[1],"批次三");
  assert.deepEqual(Array.from(a.replies.at(-1).items,i=>i.text),["缓存","批次三","批次三"]);
});
test("invalid final output is not cached and cancellation discards queued work", () => {
  const h=harness(), a=h.connect(); a.send(request); h.flush();
  const n=h.natives[0]; n.onMessage.emit({version:1,id:n.sent[0].id,ok:true,items:[{id:"wrong",text:"bad"}]});
  assert.ok(a.replies.at(-1).items[0].error);
  const b=h.connect(); b.send(request); b.disconnect(); h.flush(); assert.equal(h.natives.length,1);
  const c=h.connect(); c.send(request); h.flush(); assert.equal(h.natives.length,2);
});

test("cache stays bounded by entry count and total text size, and is isolated by tab", () => {
  for (const [count, width] of [[513,1],[30,10000]]) {
    const h=harness(), client=h.connect();
    const text=i=>`${i}:`+"x".repeat(width);
    for(let i=0;i<count;i++) { client.send({items:[{id:"p0",text:text(i)}]}); h.flush(); h.finish(h.natives[0],"译".repeat(width)); }
    const sent = () => h.natives.flatMap(n => n.sent).length;
    const before=sent();
    client.send({items:[{id:"p0",text:text(count-1)}]}); h.flush();
    assert.equal(sent(),before);
    client.send({items:[{id:"p0",text:text(0)}]}); h.flush();
    assert.equal(sent(),before+1); h.finish(h.natives.at(-1));
    const other=h.connect({tab:{id:2}}); other.send({items:[{id:"p0",text:text(count-1)}]}); h.flush();
    assert.equal(sent(),before+2);
  }
});
test("a long paragraph remains alone and removing one duplicate owner preserves others", () => {
  const h=harness(), a=h.connect(), b=h.connect({frameId:2});
  a.send({items:[{id:"a",text:"x".repeat(7000)}]});
  b.send({items:[{id:"b",text:"Short"},{id:"c",text:"Short"}]}); h.flush();
  assert.equal(h.natives[0].sent[0].items.length,1); h.finish(h.natives[0]); h.flush();
  assert.equal(h.natives[1].sent[0].items.length,1);
  const c=h.connect({frameId:3});c.send({items:[{id:"owner",text:"Short"}]});b.disconnect();
  h.finish(h.natives[1],"短句");assert.equal(c.replies.at(-1).items[0].text,"短句");
});

test("twelve short texts stream and finish with their original IDs", () => {
  const h = harness(), client = h.connect();
  const items = Array.from({ length: 12 }, (_, i) => ({ id: `p${i}`, text: `${i}:` + "😀".repeat(48) }));
  client.send({ items }); h.flush();
  assert.equal(h.natives.length, 1);
  const native = h.natives[0], sent = native.sent[0];
  assert.equal(sent.items.length, 12);
  native.onMessage.emit({ version: 1, id: sent.id, ok: true, partial: true,
    text: sent.items.map(({ id }, i) => JSON.stringify({ id, text: `译${i}` })).join("\n") });
  assert.deepEqual(client.replies[0].text.split("\n").map(line => JSON.parse(line).id), items.map(i => i.id));
  native.onMessage.emit({ version: 1, id: sent.id, ok: true,
    items: sent.items.map(({ id }, i) => ({ id, text: `译${i}` })).reverse() });
  assert.deepEqual(Array.from(client.replies.at(-1).items, i => [i.id, i.text]), items.map((i, n) => [i.id, `译${n}`]));
  client.disconnect(); h.flush(); assert.equal(native.closed, true); assert.equal(h.timers.size, 0);
});

test("expanded batches reject long text and still cap both size and count", () => {
  const short = Array.from({ length: 12 }, (_, i) => ({ id: `p${i}`, text: "Short" }));
  for (const items of [short.concat({ id: "extra", text: "Short" }),
    short.slice(0, 4).concat({ id: "long", text: "x".repeat(101) }),
    short.slice(0, 4).concat({ id: "long", text: "😀".repeat(51) })]) {
    const h = harness(), client = h.connect(); client.send({ items }); h.flush();
    assert.equal(client.replies.at(-1).ok, false); assert.equal(h.natives.length, 0);
  }
});

test("cross-frame short batching stops at twelve or before a long paragraph", () => {
  for (const longIndex of [-1, 6]) {
    const h = harness(), clients = [];
    for (let i = 0; i < 15; i++) {
      const client = h.connect({ frameId: i }); clients.push(client);
      client.send({ items: [{ id: "p0", text: i === longIndex ? "L".repeat(101) : `Short ${i}` }] });
    }
    h.flush(); const native = h.natives[0];
    assert.equal(native.sent[0].items.length, longIndex < 0 ? 12 : 6);
    h.finish(native); h.flush();
    assert.equal(h.natives[1].sent[0].items.length, longIndex < 0 ? 3 : 4);
    h.finish(h.natives[1]); h.flush();
    if (longIndex >= 0) { assert.equal(native.sent[1].items.length, 5); h.finish(native); }
    for (const client of clients) { assert.equal(client.replies.at(-1).items[0].id, "p0"); client.disconnect(); }
    h.flush(); assert.ok(h.natives.every(n => n.closed));
  }
});

test("a slow batch does not block the other slot from taking more page work", () => {
  const h = harness(), client = h.connect();
  for (let i = 0; i < 3; i++) client.send({ id: `r${i}`, items: [{ id: `p${i}`, text: `${i}`.repeat(7000), priority: 0 }] });
  h.flush();
  assert.equal(h.natives.length, 2);
  assert.equal(h.natives[0].sent.length, 1);
  h.finish(h.natives[1]); h.flush();
  assert.equal(h.natives[1].sent.length, 2);
  assert.equal(client.replies.at(-1).id, "r1");
  h.finish(h.natives[1]); h.flush();
  assert.equal(client.replies.at(-1).id, "r2");
  h.finish(h.natives[0]); h.flush();
  assert.deepEqual(client.replies.filter(r => !r.partial).map(r => r.id), ["r1", "r2", "r0"]);
  assert.ok(h.natives.every(n => n.closed));
});

test("all tabs share two slots and queued priorities can change", async () => {
  const h = harness(), first = h.connect(), second = h.connect({ tab: { id: 2 } });
  first.send({ id: "r0", items: [{ id: "p0", text: "A".repeat(7000), priority: 0 }] });
  first.send({ id: "r1", items: [{ id: "p1", text: "B".repeat(7000), priority: 0 }] });
  first.send({ id: "r2", items: [{ id: "p2", text: "C".repeat(7000), priority: 1 }] });
  second.send({ id: "r0", items: [{ id: "p0", text: "D".repeat(7000), priority: 2 }] });
  h.flush(); assert.equal(h.natives.length, 2);
  second.send({ type: "priority", items: [{ id: "p0", priority: 0 }] });
  h.finish(h.natives[1]); h.flush();
  assert.equal(h.natives[1].sent.at(-1).items[0].text, "D".repeat(7000));
  await h.chrome.runtime.onMessage.emit({ type: "notype.stop" }, first.sender, () => {})[0];
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.natives[0].closed, true); assert.equal(h.natives[1].closed, false);
  h.finish(h.natives[1]); h.flush();
  assert.equal(second.replies.at(-1).ok, true);
  assert.ok(h.natives.every(n => n.closed));
});

test("one request can span both slots while duplicates share its out-of-order results", () => {
  const h = harness(), client = h.connect(), other = h.connect({ frameId: 2 });
  client.send({ id: "split", items: [
    { id: "first", text: "A".repeat(1000), priority: 0 },
    { id: "last", text: "C".repeat(1000), priority: 2 },
  ] });
  other.send({ items: [{ id: "middle", text: "B".repeat(5000), priority: 1 }] });
  h.flush();
  const [first, second] = h.natives;
  assert.equal(first.sent[0].items.length, 2);
  assert.equal(second.sent[0].items.length, 1);
  client.send({ id: "duplicate", items: [{ id: "copy", text: "C".repeat(1000) }] });
  h.finish(second, "最后一段"); h.flush();
  assert.deepEqual(client.replies.filter(r => !r.partial).map(r => r.id), ["duplicate"]);
  const request = first.sent[0];
  first.onMessage.emit({ version: 1, id: request.id, ok: true, partial: true,
    text: JSON.stringify({ id: request.items[0].id, text: "第一段" }) });
  const progress = client.replies.at(-1);
  assert.equal(progress.id, "split");
  assert.deepEqual(progress.text.split("\n").map(JSON.parse), [
    { id: "first", text: "第一段" }, { id: "last", text: "最后一段" },
  ]);
  h.finish(first, "首批"); h.flush();
  assert.deepEqual(client.replies.filter(r => !r.partial).map(r => r.id), ["duplicate", "split"]);
  assert.deepEqual(Array.from(client.replies.at(-1).items, i => [i.id, i.text]), [
    ["first", "首批"], ["last", "最后一段"],
  ]);
  assert.equal(h.natives.reduce((count, native) => count + native.sent.length, 0), 2);
  assert.ok(h.natives.every(n => n.closed));
});

test("model failure isolates one batch and only an explicit retry submits its text again", () => {
  const h = harness(), client = h.connect();
  for (let i = 0; i < 3; i++) client.send({ id: `r${i}`, items: [{ id: `p${i}`, text: `${i}`.repeat(7000) }] });
  h.flush();
  const [failed, healthy] = h.natives;
  failed.onMessage.emit({ version: 1, id: failed.sent[0].id, ok: false,
    error: { code: "translation_failed", message: "翻译超时" } });
  assert.equal(client.closed, false);
  assert.equal(healthy.closed, false);
  assert.equal(client.replies.at(-1).items[0].error, "翻译超时");
  assert.equal(h.broadcasts.at(-1).message.pending, true);
  h.flush();
  assert.equal(failed.closed, true);
  const replacement = h.natives[2];
  assert.equal(replacement.sent[0].items[0].text, "2".repeat(7000));
  h.finish(healthy, "成功"); h.finish(replacement, "后续成功"); h.flush();
  assert.equal(h.natives.reduce((n, port) => n + port.sent.length, 0), 3);
  assert.equal(h.broadcasts.at(-1).message.count, 1);
  assert.equal(h.broadcasts.at(-1).message.pending, false);
  assert.equal(h.broadcasts.at(-1).options.frameId, 0);
  client.send({ id: "retry", items: [{ id: "p0", text: "0".repeat(7000) }] }); h.flush();
  assert.equal(h.natives.at(-1).sent[0].items.length, 1);
  h.finish(h.natives.at(-1), "重试成功"); h.flush();
  assert.equal(client.replies.at(-1).items[0].text, "重试成功");
  assert.equal(h.broadcasts.at(-1).message.count, 0);
});

test("a native host exiting after a model failure cannot cancel replacement work", () => {
  const h = harness(), client = h.connect();
  for (let i = 0; i < 3; i++) client.send({ items: [{ id: `p${i}`, text: `${i}`.repeat(7000) }] });
  h.flush();
  const [failed, healthy] = h.natives;
  failed.onMessage.emit({ version: 1, id: failed.sent[0].id, ok: false,
    error: { code: "translation_failed", message: "翻译超时" } });
  h.flush();
  // The installed Python host exits after writing any final error; Chrome can
  // deliver that disconnect after the pool has already started its next batch.
  failed.onDisconnect.emit();
  assert.equal(client.closed, false);
  assert.equal(healthy.closed, false);
  assert.equal(failed.sent.length, 1);
  const replacement = h.natives[2];
  assert.equal(replacement.sent[0].items[0].text, "2".repeat(7000));
  h.finish(replacement); h.finish(healthy); h.flush();
  assert.equal(client.replies.filter(reply => !reply.partial && reply.ok).length, 3);
  assert.ok(h.natives.every(native => native.closed));
  assert.equal(h.timers.size, 0);
});

test("a late iframe channel error reaches the completed main page without stopping another tab", () => {
  const h = harness(), top = h.connect();
  top.send(request); h.flush(); h.finish(h.natives[0]); top.disconnect(); h.flush();
  const child = h.connect({ frameId: 2 }), other = h.connect({ tab: { id: 2 } });
  child.send({ items: [{ id: "p0", text: "Late iframe" }] }); other.send(request); h.flush();
  const [failed, healthy] = h.natives.slice(1);
  failed.onMessage.emit({ version: 1, id: failed.sent[0].id, ok: false,
    error: { code: "missing_codex_auth", message: "请先登录 NoType" } });
  const notification = h.broadcasts.find(({ tabId, message }) => tabId === 1 && message.type === "notype.error");
  assert.equal(notification?.message.error, "请先登录 NoType");
  assert.equal(notification.options.frameId, 0);
  assert.equal(child.closed, true);
  assert.equal(other.closed, false);
  h.finish(healthy); h.flush();
  assert.equal(other.replies.at(-1).ok, true);
});

test("a split request preserves successful rows and reports failed rows to every duplicate owner", () => {
  const h = harness(), client = h.connect(), other = h.connect({ frameId: 2 });
  client.send({ id: "split", items: [
    { id: "a", text: "A".repeat(1000), priority: 0 },
    { id: "c", text: "C".repeat(1000), priority: 2 },
  ] });
  other.send({ items: [{ id: "b", text: "B".repeat(5000), priority: 1 }] }); h.flush();
  const duplicate = h.connect({ frameId: 3 });
  duplicate.send({ items: [{ id: "copy", text: "A".repeat(1000) }] });
  const [failed, healthy] = h.natives;
  failed.onMessage.emit({ version: 1, id: failed.sent[0].id, ok: true, items: [{ id: "wrong", text: "坏结果" }] });
  assert.equal(client.replies.at(-1).partial, true);
  assert.equal(client.replies.at(-1).failed[0].id, "a");
  assert.equal(duplicate.replies.at(-1).items[0].id, "copy");
  assert.ok(duplicate.replies.at(-1).items[0].error);
  h.finish(healthy, "成功"); h.flush();
  const final = client.replies.at(-1);
  assert.equal(final.id, "split"); assert.equal(final.items[1].text, "成功");
  assert.ok(final.items[0].error);
  assert.equal(h.broadcasts.at(-1).message.count, 3);
  duplicate.disconnect(); assert.equal(h.broadcasts.at(-1).message.count, 2);
});

test("a timed-out slot is replaced without cancelling its sibling or accepting late output", () => {
  const h = harness(), client = h.connect();
  for (let i = 0; i < 3; i++) client.send({ items: [{ id: `p${i}`, text: `${i}`.repeat(7000) }] });
  h.flush();
  [...h.timers][0](); h.flush();
  assert.equal(h.natives[0].closed, true); assert.equal(h.natives[1].closed, false);
  assert.equal(h.natives[2].sent[0].items[0].text, "2".repeat(7000));
  const count = client.replies.length;
  h.finish(h.natives[0]); assert.equal(client.replies.length, count);
  h.finish(h.natives[1]); h.finish(h.natives[2]); h.flush();
  assert.ok(h.natives.every(n => n.closed)); assert.equal(h.timers.size, 0);
});

test("retry is broadcast to the whole tab without restarting completed frames", async () => {
  const h = harness(), client = h.connect();
  const pending = h.chrome.runtime.onMessage.emit({ type: "notype.retry" }, client.sender, () => {})[0];
  await pending;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.broadcasts.at(-1).message.type, "notype.retry");
  assert.equal(h.broadcasts.at(-1).options, undefined);
});
