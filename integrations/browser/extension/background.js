const HOST = "com.opensource.notype.browser";
const sessions = new Map();
const tabKey = (id) => `translation:${id}`;

async function stopTab(tabId) {
  await chrome.storage.session.remove(tabKey(tabId));
  sessions.get(tabId)?.close();
  await chrome.tabs.sendMessage(tabId, { type: "notype.stop" }).catch(() => {});
}

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    if (!/^https?:\/\//.test(tab.url || "")) throw new Error("unsupported_page");
    const key = tabKey(tab.id);
    if ((await chrome.storage.session.get(key))[key]) await stopTab(tab.id);
    else {
      await chrome.storage.session.set({ [key]: true });
      try { await chrome.tabs.sendMessage(tab.id, { type: "notype.start" }); }
      catch (error) { await stopTab(tab.id); throw error; }
    }
    await chrome.action.setBadgeText({ tabId: tab.id, text: "" });
    await chrome.action.setTitle({ tabId: tab.id, title: "NoType：翻译当前页 / 移除译文" });
  } catch {
    await chrome.action.setBadgeText({ tabId: tab.id, text: "!" });
    await chrome.action.setTitle({ tabId: tab.id, title: "请刷新普通 HTTP / HTTPS 网页，并允许扩展访问页面及其 iframe。" });
  }
});

function allowedSender(sender) {
  return sender?.id === chrome.runtime.id && Number.isInteger(sender.tab?.id) &&
    Number.isInteger(sender.frameId) && sender.frameId >= 0 &&
    (/^https?:\/\//.test(sender.url || "") ||
      (sender.frameId > 0 && /^(about:(blank|srcdoc)(?:[?#]|$)|blob:|data:)/.test(sender.url || "")));
}

// The manifest loads the same listener into every frame, including later navigations.
// Session storage survives an idle service-worker restart without enabling new tabs.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!allowedSender(sender)) return;
  if (message?.type === "notype.ready") {
    const key = tabKey(sender.tab.id);
    chrome.storage.session.get(key).then((state) => reply({ active: !!state[key] }));
    return true;
  }
  if (message?.type === "notype.stop") {
    stopTab(sender.tab.id).then(() => reply({ ok: true }));
    return true;
  }
  if (message?.type === "notype.retry") {
    chrome.tabs.sendMessage(sender.tab.id, { type: "notype.retry" }).then(() => reply({ ok: true })).catch(() => reply({ ok: false }));
    return true;
  }
});
chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0) void stopTab(details.tabId);
});
chrome.tabs.onRemoved.addListener((tabId) => { void stopTab(tabId); });

// One extension-wide pool, not one pool per tab/frame. Each native port stays
// sequential, so the existing native host and socket protocol need no multiplexing.
const slots = Array.from({ length: 2 }, () => ({ native: null, job: null }));
let poolTimer = null;
let nextOrder = 0;
function priority(entry) {
  let result = 2;
  for (const owner of entry.waiters) result = Math.min(result, owner.priority);
  return result;
}
function compareEntries(a, b) { return priority(a) - priority(b) || a.order - b.order; }
function releaseSlot(slot) {
  if (slot.job) clearTimeout(slot.job.timer);
  slot.job = null;
  const native = slot.native;
  slot.native = null;
  native?.disconnect();
}
function rejectSlot(slot, message) {
  const current = slot.job;
  releaseSlot(slot);
  current?.session.reject(current.group, message);
  schedulePool();
}
function schedulePool() {
  if (poolTimer !== null) return;
  poolTimer = setTimeout(() => { poolTimer = null; pumpPool(); }, 0);
}
function pumpPool() {
  for (const slot of slots) {
    if (slot.job) continue;
    let selected, best;
    for (const session of sessions.values()) {
      const entry = session.peek();
      if (entry && (!best || compareEntries(entry, best) < 0)) { selected = session; best = entry; }
    }
    if (!selected) break;
    const group = selected.take();
    const id = crypto.randomUUID();
    const job = { session: selected, group, id };
    slot.job = job;
    job.timer = setTimeout(() => rejectSlot(slot, '等待 NoType 翻译超时，请重试。'), 195000);
    try {
      if (!slot.native) {
        const connection = chrome.runtime.connectNative(HOST);
        slot.native = connection;
        connection.onMessage.addListener((response) => {
          if (slot.native !== connection || !slot.job) return;
          const current = slot.job;
          if (response?.id !== current.id || response.version !== 1 || typeof response.ok !== 'boolean' ||
              (response.partial === true && (!response.ok || typeof response.text !== 'string'))) {
            rejectSlot(slot, 'NoType 返回了无效响应。'); return;
          }
          if (!response.ok && response.error?.code !== 'translation_failed') {
            current.session.fail(response.error?.message || 'NoType 翻译通道不可用。'); return;
          }
          if (response.partial === true) {
            if (current.partial !== response.text) {
              current.partial = response.text;
              current.session.progress(current.group, response.text);
            }
            return;
          }
          // Free this slot before delivering results: client completion may close its tab.
          clearTimeout(current.timer);
          slot.job = null;
          if (response.ok) current.session.finish(current.group, response.items);
          else {
            // Installed hosts exit after any final error. Never give their port
            // another batch while Chrome is still delivering the disconnect.
            releaseSlot(slot);
            current.session.reject(current.group, response.error?.message || 'NoType 翻译失败。');
          }
          schedulePool();
        });
        connection.onDisconnect.addListener(() => {
          const detail = chrome.runtime.lastError?.message;
          if (slot.native !== connection) return;
          const current = slot.job;
          releaseSlot(slot);
          current?.session.fail('无法连接 NoType，请确认应用与连接程序均已更新。' + (detail ? '（' + detail + '）' : ''));
          schedulePool();
        });
      }
      slot.native.postMessage({ version: 1, id, method: 'translate_chinese_batch', items: group.map(({ id, text }) => ({ id, text })) });
    } catch (error) { releaseSlot(slot); selected.fail(error.message); }
  }
  // Keep idle slots warm while their sibling is working; release both when drained.
  if (!slots.some(slot => slot.job)) slots.forEach(releaseSlot);
}

function createSession(tabId) {
  const clients = new Map();
  const entries = new Map();
  const queue = [];
  // Per-tab, memory-only FIFO cache: cap both object count and UTF-16 payload size.
  const cache = new Map();
  let cacheSize = 0;
  let nextItem = 0;
  let closed = false;
  let reportedFailures = 0;
  let reportedPending = false;
  function reportFailures() {
    const failures = [...clients.values()].flatMap(state => [...state.failed.values()]);
    const pending = [...clients.values()].some(state => state.requests.size);
    if (closed || failures.length === reportedFailures && (!failures.length || pending === reportedPending)) return;
    reportedFailures = failures.length;
    reportedPending = pending;
    chrome.tabs.sendMessage(tabId, { type: 'notype.failures', count: failures.length, error: failures[0] || '', pending }, { frameId: 0 }).catch(() => {});
  }
  function prune() {
    for (let i = queue.length - 1; i >= 0; i--) {
      if (!queue[i].waiters.size) { entries.delete(queue[i].text); queue.splice(i, 1); }
    }
    for (const slot of slots) {
      if (slot.job?.session === session && slot.job.group.every(entry => !entry.waiters.size)) {
        slot.job.group.forEach(entry => entries.delete(entry.text));
        releaseSlot(slot);
      }
    }
    schedulePool();
  }
  function close() {
    if (closed) return;
    closed = true;
    for (const slot of slots) if (slot.job?.session === session) releaseSlot(slot);
    clients.forEach((_state, client) => client.disconnect());
    clients.clear(); entries.clear(); queue.length = 0;
    cache.clear(); cacheSize = 0;
    if (sessions.get(tabId) === session) sessions.delete(tabId);
    schedulePool();
  }
  function fail(message) {
    if (closed) return;
    // The main page may have finished and disconnected before a late iframe fails.
    chrome.tabs.sendMessage(tabId, { type: 'notype.error', error: message }, { frameId: 0 }).catch(() => {});
    clients.forEach((_state, client) => client.postMessage({ ok: false, error: { message } }));
    close();
  }
  function remember(text, result) {
    const size = text.length + result.length;
    if (size > 524288) return;
    while (cache.size >= 512 || cacheSize + size > 524288) {
      const key = cache.keys().next().value;
      cacheSize -= key.length + cache.get(key).length;
      cache.delete(key);
    }
    cache.set(text, result); cacheSize += size;
  }
  function complete(request) {
    const state = clients.get(request.client);
    if (state?.requests.get(request.id) !== request || request.items.some(({ entry }) => entry.result === undefined && entry.error === undefined)) return;
    state.requests.delete(request.id);
    for (const owner of request.items) {
      owner.entry.waiters?.delete(owner); state.items.delete(owner.id);
      if (owner.entry.error !== undefined) state.failed.set(owner.id, owner.entry.error);
    }
    request.client.postMessage({ id: request.id, ok: true, items: request.items.map(({ id, entry }) =>
      entry.error === undefined ? { id, text: entry.result } : { id, error: entry.error }) });
    reportFailures();
  }
  function sendProgress(request, lines = new Map()) {
    if (lines.size && !request.items.some(({ entry }) => lines.has(entry.id))) return;
    const output = [];
    for (const { id, entry } of request.items) {
      if (entry.result !== undefined) output.push(JSON.stringify({ id, text: entry.result }));
      else if (lines.has(entry.id)) {
        output.push(lines.get(entry.id).replace(/^(\s*\{\s*"id"\s*:\s*)"(?:\\.|[^"\\])*"/,
          (_match, prefix) => prefix + JSON.stringify(id)));
      }
    }
    const failed = request.items.filter(({ entry }) => entry.error !== undefined).map(({ id, entry }) => ({ id, error: entry.error }));
    if (output.length || failed.length) request.client.postMessage({ id: request.id, ok: true, partial: true, text: output.join('\n'), failed });
  }
  function owners(group) {
    return new Set(group.flatMap(entry => [...entry.waiters].map(owner => owner.request)));
  }
  function progress(group, text) {
    const lines = new Map();
    for (const line of text.split('\n')) {
      const match = /^\s*\{\s*"id"\s*:\s*("(?:\\.|[^"\\])*")/.exec(line);
      if (match) {
        try {
          const id = JSON.parse(match[1]);
          if (group.some(entry => entry.id === id)) lines.set(id, line);
        } catch {}
      }
    }
    if (lines.size) owners(group).forEach(request => sendProgress(request, lines));
  }
  function finish(group, results) {
    if (closed) return;
    if (!Array.isArray(results) || results.length !== group.length ||
        new Set(results.map(item => item?.id)).size !== group.length ||
        results.some(item => !item || !group.some(entry => entry.id === item.id) ||
          typeof item.text !== 'string' || !item.text.trim())) {
      reject(group, '批量译文不完整或段落 ID 不匹配。'); return;
    }
    const requests = owners(group);
    for (const entry of group) {
      entry.result = results.find(item => item.id === entry.id).text;
      entries.delete(entry.text);
      remember(entry.text, entry.result);
    }
    requests.forEach(request => {
      complete(request);
      if (clients.get(request.client)?.requests.has(request.id)) sendProgress(request);
    });
  }
  function reject(group, message) {
    if (closed) return;
    const requests = owners(group);
    for (const entry of group) {
      entry.error = message;
      entries.delete(entry.text);
    }
    requests.forEach(request => {
      complete(request);
      if (clients.get(request.client)?.requests.has(request.id)) sendProgress(request);
    });
  }
  function peek() {
    return queue.reduce((best, entry) => !best || compareEntries(entry, best) < 0 ? entry : best, null);
  }
  function take() {
    queue.sort(compareEntries);
    const group = [];
    let length = 0, allShort = true;
    while (queue.length && group.length < 12) {
      const entry = queue[0];
      if (group.length >= 4 && (!allShort || entry.text.length > 100)) break;
      if (group.length && length + entry.text.length > 6000) break;
      queue.shift(); group.push(entry); length += entry.text.length;
      allShort = allShort && entry.text.length <= 100;
      if (length >= 6000) break;
    }
    return group;
  }
  function add(client) {
    const state = { requests: new Map(), items: new Map(), failed: new Map() };
    clients.set(client, state);
    client.onDisconnect.addListener(() => {
      clients.delete(client);
      state.items.forEach(owner => owner.entry.waiters?.delete(owner));
      if (!closed) { prune(); reportFailures(); }
    });
    client.onMessage.addListener((message) => {
      if (closed || !clients.has(client)) return;
      const items = message?.items;
      if (message?.type === 'priority') {
        if (!Array.isArray(items) || items.length > 512 || items.some(item => !item || ![0, 1, 2].includes(item.priority))) return;
        for (const item of items) {
          const owner = state.items.get(item.id);
          if (owner) owner.priority = item.priority;
        }
        schedulePool(); return;
      }
      const id = message?.id;
      if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(id) || state.requests.has(id) ||
          !Array.isArray(items) || items.length < 1 || items.length > 12 ||
          items.some(item => !item || typeof item.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(item.id) ||
            state.items.has(item.id) || typeof item.text !== 'string' || !item.text.trim() || item.text.length > 12000 ||
            (item.priority !== undefined && ![0, 1, 2].includes(item.priority))) ||
          new Set(items.map(item => item.id)).size !== items.length ||
          (items.length > 4 && items.some(item => item.text.length > 100)) ||
          (items.length > 1 && items.reduce((sum, item) => sum + item.text.length, 0) > 6000)) {
        fail('翻译批次无效，或段落 ID 重复。'); return;
      }
      const request = { client, id, items: [] };
      state.requests.set(id, request);
      for (const item of items) {
        state.failed.delete(item.id);
        let entry;
        if (cache.has(item.text)) entry = { result: cache.get(item.text) };
        else {
          entry = entries.get(item.text);
          if (!entry) {
            entry = { id: 't' + nextItem++, text: item.text, waiters: new Set(), order: nextOrder++ };
            entries.set(item.text, entry); queue.push(entry);
          }
        }
        const owner = { id: item.id, entry, request, priority: item.priority ?? 2 };
        entry.waiters?.add(owner);
        request.items.push(owner); state.items.set(owner.id, owner);
      }
      complete(request);
      if (state.requests.has(id)) sendProgress(request);
      reportFailures();
      schedulePool();
    });
  }
  const session = { add, close, fail, peek, take, progress, finish, reject };
  sessions.set(tabId, session);
  return session;
}

chrome.runtime.onConnect.addListener((client) => {
  const sender = client.sender;
  if (client.name !== "notype.translate" || !allowedSender(sender)) { client.disconnect(); return; }
  // Install listeners synchronously: the content script posts its first batch immediately.
  // Only frames activated by our listener may translate; the listener checks tab session state.
  (sessions.get(sender.tab.id) || createSession(sender.tab.id)).add(client);
});
