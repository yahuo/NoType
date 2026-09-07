const HOST = "com.opensource.notype.browser";

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    if (!/^https?:\/\//.test(tab.url || "")) throw new Error("unsupported_page");
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"],
    });
    await chrome.action.setBadgeText({ tabId: tab.id, text: "" });
    await chrome.action.setTitle({ tabId: tab.id, title: "NoType：翻译当前页 / 移除译文" });
  } catch {
    await chrome.action.setBadgeText({ tabId: tab.id, text: "!" });
    await chrome.action.setTitle({
      tabId: tab.id,
      title: "此页面不允许插件运行，请在普通 HTTP / HTTPS 网页上使用。",
    });
  }
});

chrome.runtime.onConnect.addListener((client) => {
  const sender = client.sender;
  if (client.name !== "notype.translate" || sender?.id !== chrome.runtime.id || !sender.tab ||
      sender.frameId !== 0 || !/^https?:\/\//.test(sender.url || "")) {
    client.disconnect();
    return;
  }
  const native = chrome.runtime.connectNative(HOST);
  let pending = null;
  let closed = false;
  function clearPending() {
    if (pending) clearTimeout(pending.timer);
    pending = null;
  }
  function close() {
    if (closed) return;
    closed = true;
    clearPending();
    native.disconnect();
    client.disconnect();
  }
  function fail(message) {
    if (closed) return;
    client.postMessage({ ok: false, error: { message } });
    close();
  }
  client.onDisconnect.addListener(close);
  client.onMessage.addListener((message) => {
    if (closed) return;
    const items = message?.items;
    if (pending || !Array.isArray(items) || items.length < 1 || items.length > 4 ||
        items.some((item) => !item || typeof item.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(item.id) ||
          typeof item.text !== "string" || !item.text.trim() || item.text.length > 12000) ||
        new Set(items.map((item) => item.id)).size !== items.length ||
        (items.length > 1 && items.reduce((sum, item) => sum + item.text.length, 0) > 6000)) {
      fail("翻译批次无效，或已有请求正在处理中。");
      return;
    }
    const id = crypto.randomUUID();
    pending = { id, timer: setTimeout(() => fail("等待 NoType 翻译超时，请重试。"), 195000) };
    native.postMessage({ version: 1, id, method: "translate_chinese_batch", items });
  });
  native.onMessage.addListener((response) => {
    if (closed) return;
    if (!pending || response?.id !== pending.id || response.version !== 1 || typeof response.ok !== "boolean" ||
        (response.partial === true && (!response.ok || typeof response.text !== "string"))) {
      fail("NoType 返回了无效响应。");
      return;
    }
    if (response.partial !== true) clearPending();
    client.postMessage(response);
  });
  native.onDisconnect.addListener(() => {
    const detail = chrome.runtime.lastError?.message;
    fail(`无法连接 NoType，请确认应用与连接程序均已更新。${detail ? `（${detail}）` : ""}`);
  });
});
