globalThis.__noTypeToggleTranslation = () => {
  const key = "__noTypeBilingual";
  if (globalThis[key]) {
    globalThis[key].stop();
    return;
  }

  const candidates = "p,h1,h2,h3,h4,h5,h6,li,blockquote,td,th,div,section,article";
  const excluded = "script,style,noscript,pre,textarea,input,select,button,nav,header:not(article header):not(main header),[role='banner'],footer," +
    "svg,math,iframe,[hidden],[aria-hidden='true'],[translate='no'],.notranslate," +
    "[role='navigation'],[role='menu'],[role='button'],notype-translation,notype-status";
  const nodes = [];
  let active = true;
  let observer;
  let visibleObserver;
  let visibilityChanged;
  let port;
  let pumpTimer;
  let renderFrame;
  const pendingViews = new Map();
  const requests = new Map();
  const receiving = new Set();
  let nextRequest = 0;
  let stopped = false;
  let status;
  const state = { stop };
  globalThis[key] = state;

  function stop() {
    active = false;
    clearTimeout(pumpTimer);
    cancelAnimationFrame(renderFrame);
    pendingViews.clear();
    observer?.disconnect();
    visibleObserver?.disconnect();
    document.removeEventListener("visibilitychange", visibilityChanged);
    port?.disconnect();
    nodes.forEach((node) => node.remove());
    if (globalThis[key] === state) delete globalThis[key];
  }

  function eligible(element) {
    return !element.closest(excluded) && !element.closest("code") && !element.isContentEditable &&
      eligibleText(element) && element.getClientRects().length > 0;
  }

  function sourceText(element) {
    // Read inline links/emphasis together; omit controls, hidden text and old translations.
    const parts = [];
    function visit(node) {
      if (node.nodeType === Node.TEXT_NODE) { parts.push(node.textContent); return; }
      if (node.nodeType !== Node.ELEMENT_NODE || node.matches(excluded) ||
          node.isContentEditable || !eligibleText(node)) return;
      if (node.tagName === "BR") { parts.push(" "); return; }
      // Preserve rendered block boundaries without splitting inline words such as inter<em>national</em>.
      const display = getComputedStyle(node).display;
      const block = display !== "contents" && !display.startsWith("inline");
      if (block) parts.push(" ");
      node.childNodes.forEach(visit);
      if (block) parts.push(" ");
    }
    visit(element);
    return parts.join("").replace(/\s+/g, " ").trim();
  }

  function eligibleText(element) {
    for (let parent = element; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      if (style.display === "none" || style.visibility !== "visible" || style.opacity === "0") return false;
    }
    return true;
  }

  function createView(tag, status = false) {
    const host = document.createElement(tag);
    host.setAttribute("translate", "no");
    host.lang = "zh-CN";
    const root = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = status
      ? ":host{all:initial!important;position:fixed!important;right:20px!important;bottom:20px!important;z-index:2147483647!important;display:block!important}div{font:14px/1.6 system-ui,sans-serif;background:#20272f;color:#fff;padding:12px 16px;border-radius:10px;box-shadow:0 4px 20px #0003;max-width:360px;overflow-wrap:anywhere;display:flex;align-items:center;gap:12px}.actions{display:flex;gap:8px;flex-shrink:0}button{cursor:pointer;background:transparent;color:inherit;border:1px solid #ffffff70;border-radius:4px;padding:2px 6px;white-space:nowrap}button:disabled{opacity:.5;cursor:default}"
      : ":host{display:block!important;margin:0.4em 0 0.85em!important}div{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;word-spacing:inherit;color:inherit;white-space:pre-wrap;overflow-wrap:anywhere}";
    const body = document.createElement("div");
    const text = document.createElement("span");
    let retry;
    body.append(text);
    root.append(style, body);
    if (status) {
      body.setAttribute("role", "status");
      const actions = document.createElement("span");
      actions.className = "actions";
      retry = document.createElement("button");
      retry.textContent = "重试失败段落";
      retry.hidden = true;
      retry.addEventListener("click", () => (globalThis.__noTypeRetryTab || state.retry)());
      actions.append(retry);
      const close = document.createElement("button");
      close.textContent = "关闭";
      close.addEventListener("click", () => (globalThis.__noTypeStopTab || stop)());
      actions.append(close);
      body.append(actions);
    }
    nodes.push(host);
    return { host, text, retry };
  }

  function setStatus(text) {
    if (globalThis.top !== globalThis) return;
    if (!status) {
      status = createView("notype-status", true);
      document.documentElement.append(status.host);
    }
    if (status.text.textContent !== text) status.text.textContent = text;
  }

  // Decode only a JSON string's available prefix, including split escape sequences.
  function stringPrefix(raw) {
    let output = "";
    for (let i = 0; i < raw.length; i++) {
      const char = raw[i];
      if (char === '"') break;
      if (char !== "\\") { output += char; continue; }
      const escaped = raw[++i];
      if (!escaped) break;
      if (escaped === "u") {
        const digits = raw.slice(i + 1, i + 5);
        if (!/^[a-fA-F0-9]{4}$/.test(digits)) break;
        output += String.fromCharCode(parseInt(digits, 16));
        i += 4;
      } else {
        const escapes = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
        if (!(escaped in escapes)) break;
        output += escapes[escaped];
      }
    }
    return output;
  }

  function run() {
    const visible = [...document.querySelectorAll(candidates)].filter(eligible);
    const containers = new Set();
    for (const element of visible) {
      for (let parent = element.parentElement; parent; parent = parent.parentElement) containers.add(parent);
    }
    const paragraphs = visible.filter((element) => !containers.has(element))
      .map((element) => ({ element, text: sourceText(element) }))
      .filter(({ text }) => /\p{L}/u.test(text) && !/^[\p{Script=Han}\p{P}\p{N}\p{Z}\p{S}\s]+$/u.test(text))
      .map((item, index) => ({ ...item, id: `p${index}`, state: "pending", view: null }));
    const byElement = new Map(paragraphs.map((item) => [item.element, item]));
    let completed = 0;
    let skipped = 0;
    let failed = 0;
    let tabFailures = 0;
    let tabPending = false;
    let failureMessage = "";

    state.fail = fail;
    state.setFailures = (count, message, pending) => {
      tabFailures = count;
      tabPending = !!pending;
      failureMessage = message || "";
      updateStatus();
    };
    state.retry = () => {
      if (!active || stopped) return;
      for (const item of paragraphs) {
        if (item.state !== "failed") continue;
        item.state = "pending";
        delete item.error;
      }
      failed = 0;
      tabFailures = 0;
      updateStatus();
      schedule();
    };

    function updateStatus() {
      if (!active || stopped) return;
      if (!requests.size && completed + skipped === paragraphs.length && port) {
        const completedPort = port;
        port = null;
        completedPort.disconnect();
      }
      const failures = Math.max(failed, tabFailures);
      const scope = tabFailures > failed ? "主页面" : "";
      setStatus((!paragraphs.length ? `${scope}未找到可翻译的外文段落。` :
        `${scope}已翻译 ${completed} / ${paragraphs.length} 段${skipped ? `，跳过 ${skipped} 段` : ""}。` +
        (requests.size ? (receiving.size ? "正在接收译文…" : "等待模型响应…") : completed + skipped + failed < paragraphs.length ? "正在准备翻译…" : failures ? "" : "再次点击插件可恢复原文。")) +
        (failures ? `全页有 ${failures} 段失败，可重试。` : ""));
      if (status) {
        status.retry.hidden = !failures;
        status.retry.disabled = !!requests.size || tabPending;
        status.retry.title = failureMessage;
      }
    }
    function isCurrent(item) {
      return item.element.isConnected && eligible(item.element) && sourceText(item.element) === item.text;
    }
    function show(item, text) {
      if (item.view?.text.textContent === text) return;
      if (!isCurrent(item)) { item.view?.host.remove(); item.view = null; return; }
      if (!item.view) {
        item.view = createView("notype-translation");
        // A whole-paragraph inline wrapper (for example <p><em>…</em></p>)
        // owns its typography; a partly emphasized word must not style the whole translation.
        let source = item.element;
        while (source.children.length === 1 && sourceText(source.firstElementChild) === item.text) {
          source = source.firstElementChild;
        }
        const style = getComputedStyle(source);
        const paragraphStyle = getComputedStyle(item.element);
        for (const property of ["font-size", "font-weight", "font-style", "font-stretch",
          "font-variant", "font-feature-settings", "font-variation-settings", "line-height",
          "letter-spacing", "word-spacing", "color"]) {
          item.view.host.style.setProperty(property, style.getPropertyValue(property), "important");
        }
        // Chrome's generic serif can still fall back to a sans-serif CJK font.
        const family = style.fontFamily.replace(/(^|,\s*)serif(?=\s*(?:,|$))/gi, '$1"Songti SC", serif');
        item.view.host.style.setProperty("font-family", family, "important");
        for (const property of ["text-align", "direction"]) {
          item.view.host.style.setProperty(property, paragraphStyle.getPropertyValue(property), "important");
        }
        if (item.element.matches("li,td,th")) item.element.append(item.view.host);
        else item.element.after(item.view.host);
      }
      item.view.text.textContent = text;
    }
    function fail(message) {
      if (!active || stopped) return;
      stopped = true;
      clearTimeout(pumpTimer);
      cancelAnimationFrame(renderFrame);
      pendingViews.clear();
      observer?.disconnect();
      visibleObserver?.disconnect();
      document.removeEventListener("visibilitychange", visibilityChanged);
      requests.forEach(group => group.forEach(item => item.view?.host.remove()));
      port?.disconnect();
      setStatus(`翻译已停止：${message} 关闭后可重新点击插件重试。`);
      if (status) status.retry.hidden = true;
    }
    function queueViews(response, inFlight) {
      const ids = new Map(inFlight.map(item => [item.id, item]));
      for (const failure of response.failed || []) {
        const item = ids.get(failure.id);
        if (!item) continue;
        item.error = failure.error;
        pendingViews.delete(item);
        item.view?.host.remove(); item.view = null;
      }
      for (const line of response.text.split("\n")) {
        let parsed;
        try { parsed = JSON.parse(line); }
        catch {
          const prefix = /^\s*\{\s*"id"\s*:\s*("(?:\\.|[^"\\])*")\s*,\s*"text"\s*:\s*"/.exec(line);
          if (!prefix) continue;
          try { parsed = { id: JSON.parse(prefix[1]), text: stringPrefix(line.slice(prefix[0].length)) }; }
          catch { continue; }
        }
        const item = ids.get(parsed?.id);
        if (item && !item.error && typeof parsed.text === "string" && parsed.text) {
          if (item.view?.text.textContent === parsed.text) pendingViews.delete(item);
          else pendingViews.set(item, parsed.text);
        }
      }
      if (pendingViews.size && !renderFrame) renderFrame = requestAnimationFrame(() => {
        renderFrame = null;
        if (!active || stopped) return;
        for (const [item, text] of pendingViews) {
          if (item.state === "waiting" && !item.error) show(item, text);
        }
        pendingViews.clear();
      });
    }
    function handleResponse(response) {
      if (!active || stopped) return;
      if (!response?.ok) { fail(response?.error?.message || "NoType 返回了错误。"); return; }
      const inFlight = requests.get(response.id);
      if (!inFlight) { fail("翻译响应的批次 ID 不匹配。"); return; }
      const ids = new Map(inFlight.map((item) => [item.id, item]));
      if (response.partial === true) {
        if (typeof response.text !== "string") { fail("流式响应无效。"); return; }
        if (!receiving.has(response.id)) { receiving.add(response.id); updateStatus(); }
        queueViews(response, inFlight);
        return;
      }
      const results = response.items;
      if (!Array.isArray(results) || results.length !== inFlight.length ||
          new Set(results.map((item) => item?.id)).size !== inFlight.length ||
          results.some((item) => !item || !ids.has(item.id) ||
            !(typeof item.error === "string" && item.error.trim() && item.text === undefined) &&
            !(typeof item.text === "string" && item.text.trim() && item.error === undefined))) {
        fail("批量译文不完整或段落 ID 不匹配。");
        return;
      }
      for (const result of results) {
        const item = ids.get(result.id);
        pendingViews.delete(item);
        if (result.error && isCurrent(item)) {
          item.view?.host.remove(); item.view = null;
          item.error = result.error;
          failureMessage = result.error;
          item.state = "failed"; failed++;
          continue;
        }
        if (!result.error && isCurrent(item)) { show(item, result.text); item.state = "done"; completed++; }
        else { item.view?.host.remove(); item.state = "skipped"; skipped++; }
        observer.unobserve(item.element);
        visibleObserver.unobserve(item.element);
      }
      requests.delete(response.id);
      receiving.delete(response.id);
      updateStatus();
      schedule();
    }
    function schedule() {
      if (!active || stopped || pumpTimer) return;
      pumpTimer = setTimeout(() => { pumpTimer = null; pump(); }, 0);
    }
    function priority(item) {
      return document.hidden ? 2 : item.visible ? 0 : item.near ? 1 : 2;
    }
    function submit(group) {
      const id = 'r' + nextRequest++;
      requests.set(id, group);
      group.forEach(item => { item.state = 'waiting'; item.priority = priority(item); });
      if (!port) {
        const connectedPort = chrome.runtime.connect({ name: 'notype.translate' });
        port = connectedPort;
        connectedPort.onMessage.addListener(handleResponse);
        connectedPort.onDisconnect.addListener(() => {
          if (port !== connectedPort) return;
          const detail = chrome.runtime.lastError?.message;
          port = null;
          if (active && !stopped && requests.size) fail(detail || '本地连接已断开。');
        });
      }
      port.postMessage({ id, items: group.map(({ id, text, priority }) => ({ id, text, priority })) });
    }
    function pump() {
      if (!active || stopped) return;
      try {
        // Register all loaded paragraphs; the background pool chooses when to run
        // each one. A frame can own multiple batches without blocking on its first.
        const queued = paragraphs.filter(item => item.state === 'pending');
        queued.sort((a, b) => priority(a) - priority(b));
        let group = [], length = 0, allShort = true;
        for (const item of queued) {
          if (stopped) return;
          if (!isCurrent(item) || item.text.length > 12000) {
            item.state = 'skipped'; skipped++;
            observer.unobserve(item.element); visibleObserver.unobserve(item.element); continue;
          }
          if (group.length && ((group.length >= 4 && (!allShort || item.text.length > 100)) || length + item.text.length > 6000)) {
            submit(group); group = []; length = 0; allShort = true;
          }
          group.push(item); length += item.text.length; allShort = allShort && item.text.length <= 100;
          if (group.length === 12 || (!allShort && group.length === 4) || length >= 6000) {
            submit(group); group = []; length = 0; allShort = true;
          }
        }
        if (group.length && !stopped) submit(group);
        // Only send changed priorities, including after scrolling, resizing, or
        // the tab becoming active. No extra model calls or fixed polling interval.
        const changed = [];
        for (const item of paragraphs) {
          if (item.state === 'waiting' && item.priority !== priority(item)) {
            item.priority = priority(item);
            changed.push({ id: item.id, priority: item.priority });
          }
        }
        for (let i = 0; i < changed.length && !stopped; i += 512) {
          port?.postMessage({ type: 'priority', items: changed.slice(i, i + 512) });
        }
        updateStatus();
      } catch (error) { fail(error.message); }
    }
    visibleObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const item = byElement.get(entry.target);
        if (item) item.visible = entry.isIntersecting;
      }
      schedule();
    });
    observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const item = byElement.get(entry.target);
        if (item) item.near = entry.isIntersecting;
      }
      schedule();
    }, { rootMargin: '300px 0px' });
    visibilityChanged = schedule;
    document.addEventListener('visibilitychange', visibilityChanged);
    paragraphs.forEach(item => { visibleObserver.observe(item.element); observer.observe(item.element); });
    updateStatus();
  }
  try { run(); }
  catch (error) {
    observer?.disconnect();
    visibleObserver?.disconnect();
    document.removeEventListener("visibilitychange", visibilityChanged);
    port?.disconnect();
    setStatus(`无法翻译此页面：${error.message}`);
  }
};
