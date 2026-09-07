(() => {
  const key = "__noTypeBilingual";
  if (globalThis[key]) {
    globalThis[key].stop();
    return;
  }
  if (!/^https?:$/.test(location.protocol)) return;

  const candidates = "p,h1,h2,h3,h4,h5,h6,li,blockquote,td,th,div,section,article";
  const excluded = "script,style,noscript,pre,textarea,input,select,button,nav,header:not(article header):not(main header),[role='banner'],footer," +
    "svg,math,iframe,[hidden],[aria-hidden='true'],[translate='no'],.notranslate," +
    "[role='navigation'],[role='menu'],[role='button'],notype-translation,notype-status";
  const nodes = [];
  let active = true;
  let observer;
  let port;
  let pumpTimer;
  let inFlight;
  let receiving = false;
  let stopped = false;
  const state = { stop };
  globalThis[key] = state;

  function stop() {
    active = false;
    clearTimeout(pumpTimer);
    observer?.disconnect();
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
      ? ":host{all:initial!important;position:fixed!important;right:20px!important;bottom:20px!important;z-index:2147483647!important;display:block!important}div{font:14px/1.6 system-ui,sans-serif;background:#20272f;color:#fff;padding:12px 16px;border-radius:10px;box-shadow:0 4px 20px #0003;max-width:360px;overflow-wrap:anywhere}button{margin-left:12px;cursor:pointer;background:transparent;color:inherit;border:1px solid #ffffff70;border-radius:4px;padding:2px 6px}"
      : ":host{display:block!important;margin:0.4em 0 0.85em!important}div{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;word-spacing:inherit;color:inherit;white-space:pre-wrap;overflow-wrap:anywhere}";
    const body = document.createElement("div");
    const text = document.createElement("span");
    body.append(text);
    root.append(style, body);
    if (status) {
      body.setAttribute("role", "status");
      const close = document.createElement("button");
      close.textContent = "关闭";
      close.addEventListener("click", stop);
      body.append(close);
    }
    nodes.push(host);
    return { host, text };
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
    const status = createView("notype-status", true);
    document.documentElement.append(status.host);
    let completed = 0;
    let skipped = 0;

    function updateStatus() {
      if (!active || stopped) return;
      if (!inFlight && completed + skipped === paragraphs.length && port) {
        const completedPort = port;
        port = null;
        completedPort.disconnect();
      }
      status.text.textContent = !paragraphs.length ? "未找到可翻译的外文段落。" :
        `已翻译 ${completed} / ${paragraphs.length} 段${skipped ? `，跳过 ${skipped} 段` : ""}。` +
        (inFlight ? (receiving ? "正在接收译文…" : "等待模型响应…") : completed + skipped < paragraphs.length ? "滚动页面继续翻译。" : "再次点击插件可恢复原文。");
    }
    function isCurrent(item) {
      return item.element.isConnected && eligible(item.element) && sourceText(item.element) === item.text;
    }
    function show(item, text) {
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
      observer?.disconnect();
      inFlight?.forEach((item) => item.view?.host.remove());
      port?.disconnect();
      status.text.textContent = `翻译已停止：${message} 关闭后可重新点击插件重试。`;
    }
    function handleResponse(response) {
      if (!active || stopped || !inFlight) return;
      if (!response?.ok) { fail(response?.error?.message || "NoType 返回了错误。"); return; }
      const ids = new Map(inFlight.map((item) => [item.id, item]));
      if (response.partial === true) {
        receiving = true;
        updateStatus();
        if (typeof response.text !== "string") { fail("流式响应无效。"); return; }
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
          if (item && typeof parsed.text === "string" && parsed.text) show(item, parsed.text);
        }
        return;
      }
      const results = response.items;
      if (!Array.isArray(results) || results.length !== inFlight.length ||
          new Set(results.map((item) => item?.id)).size !== inFlight.length ||
          results.some((item) => !item || !ids.has(item.id) || typeof item.text !== "string" || !item.text.trim())) {
        fail("批量译文不完整或段落 ID 不匹配。");
        return;
      }
      for (const result of results) {
        const item = ids.get(result.id);
        if (isCurrent(item)) { show(item, result.text); item.state = "done"; completed++; }
        else { item.view?.host.remove(); item.state = "skipped"; skipped++; }
        observer.unobserve(item.element);
      }
      inFlight = null;
      updateStatus();
      schedule();
    }
    function schedule() {
      if (!active || stopped || pumpTimer) return;
      pumpTimer = setTimeout(() => { pumpTimer = null; pump(); }, 0);
    }
    function pump() {
      if (!active || stopped || inFlight) return;
      const queued = paragraphs.filter((item) => item.state === "queued");
      // Re-evaluate the current viewport after scrolling and inserted translations.
      const priority = (item) => {
        const rect = item.element.getBoundingClientRect();
        return rect.bottom >= 0 && rect.top <= innerHeight ? Math.max(0, rect.top) : innerHeight + Math.abs(rect.top);
      };
      queued.sort((a, b) => priority(a) - priority(b));
      const group = [];
      let length = 0;
      for (const item of queued) {
        if (!isCurrent(item) || item.text.length > 12000) {
          item.state = "skipped"; skipped++; observer.unobserve(item.element); continue;
        }
        const rect = item.element.getBoundingClientRect();
        if (rect.bottom < -300 || rect.top > innerHeight + 300) continue;
        if (group.length && length + item.text.length > 6000) break;
        group.push(item); length += item.text.length;
        if (group.length === 4 || length >= 6000) break;
      }
      if (!group.length) { updateStatus(); return; }
      inFlight = group;
      receiving = false;
      group.forEach((item) => { item.state = "translating"; });
      updateStatus();
      try {
        if (!port) {
          const connectedPort = chrome.runtime.connect({ name: "notype.translate" });
          port = connectedPort;
          connectedPort.onMessage.addListener(handleResponse);
          connectedPort.onDisconnect.addListener(() => {
            if (port !== connectedPort) return;
            const detail = chrome.runtime.lastError?.message;
            if (active && !stopped) fail(detail || "本地连接已断开。");
          });
        }
        port.postMessage({ items: group.map(({ id, text }) => ({ id, text })) });
      } catch (error) { fail(error.message); }
    }
    observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const item = byElement.get(entry.target);
        if (item && ["pending", "queued"].includes(item.state)) item.state = entry.isIntersecting ? "queued" : "pending";
      }
      schedule();
    }, { rootMargin: "300px 0px" });
    paragraphs.forEach((item) => observer.observe(item.element));
    updateStatus();
  }
  try { run(); }
  catch (error) {
    observer?.disconnect();
    port?.disconnect();
    const status = createView("notype-status", true);
    status.text.textContent = `无法翻译此页面：${error.message}`;
    document.documentElement.append(status.host);
  }
})();
