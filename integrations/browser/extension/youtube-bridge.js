// Runs in the YouTube page's MAIN world from document_start. It only copies the
// player's own caption (timedtext) responses to youtube.js; it never translates,
// sends anything off the page, or changes the original request and response.
(() => {
  const marker = Symbol.for("notype.youtubeTimedText");
  if (window[marker]) return;
  window[marker] = true;
  const maxText = 4000000;

  function captionUrl(value) {
    try {
      const url = new URL(String(value), location.href);
      return url.origin === location.origin && url.pathname === "/api/timedtext" ? url.href : "";
    } catch { return ""; }
  }
  function requestUrl(input) {
    if (typeof input === "string") return input;
    if (input instanceof URL) return input.href;
    return typeof input?.url === "string" ? input.url : "";
  }
  function publish(url, text) {
    if (typeof text !== "string" || !text || text.length > maxText) return;
    try { window.postMessage({ source: "notype-youtube", type: "timedtext", url, text }, location.origin); }
    catch {}
  }

  const originalFetch = window.fetch;
  if (typeof originalFetch === "function") {
    window.fetch = function fetch(input, init) {
      const result = originalFetch.apply(this, arguments);
      const url = captionUrl(requestUrl(input));
      if (!url) return result;
      // Clone before the page receives the response, so its own read cannot win the race.
      return result.then((response) => {
        try { if (response.ok) response.clone().text().then((text) => publish(url, text), () => {}); }
        catch {}
        return response;
      });
    };
  }

  const open = XMLHttpRequest.prototype.open;
  const send = XMLHttpRequest.prototype.send;
  const urls = new WeakMap();
  XMLHttpRequest.prototype.open = function (method, url) {
    // A reused XHR must not publish the URL of its previous request.
    const caption = captionUrl(url);
    if (caption) urls.set(this, caption); else urls.delete(this);
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    const url = urls.get(this);
    if (url) {
      this.addEventListener("load", () => {
        if (urls.get(this) !== url) return;
        try {
          if (this.status >= 200 && this.status < 300 && (this.responseType === "" || this.responseType === "text")) {
            publish(url, this.responseText);
          }
        } catch {}
      }, { once: true });
    }
    return send.apply(this, arguments);
  };
})();
