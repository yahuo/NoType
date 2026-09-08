(() => {
  let controlled = false;
  function start() {
    if (!globalThis.__noTypeBilingual) globalThis.__noTypeToggleTranslation();
  }
  globalThis.__noTypeStopTab = () => {
    globalThis.__noTypeBilingual?.stop();
    chrome.runtime.sendMessage({ type: "notype.stop" }).catch(() => {});
  };
  globalThis.__noTypeRetryTab = () => {
    chrome.runtime.sendMessage({ type: "notype.retry" }).catch(() => {});
  };
  chrome.runtime.onMessage.addListener((message, _sender, reply) => {
    if (["notype.start", "notype.stop"].includes(message?.type)) controlled = true;
    if (message?.type === "notype.start") start();
    if (message?.type === "notype.stop") globalThis.__noTypeBilingual?.stop();
    if (message?.type === "notype.retry") globalThis.__noTypeBilingual?.retry?.();
    if (message?.type === "notype.failures") globalThis.__noTypeBilingual?.setFailures?.(message.count, message.error, message.pending);
    if (message?.type === "notype.error") globalThis.__noTypeBilingual?.fail?.(message.error);
    if (["notype.start", "notype.stop"].includes(message?.type)) reply({ ok: true });
    if (["notype.retry", "notype.failures", "notype.error"].includes(message?.type)) reply({ ok: true });
  });
  chrome.runtime.sendMessage({ type: "notype.ready" }).then((state) => {
    if (state?.active && !controlled) start();
  }).catch(() => {});
  addEventListener("pagehide", () => globalThis.__noTypeBilingual?.stop());
})();
