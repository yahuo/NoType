// Test extension only: installed by prepare-iframe-test.py, never shipped to users.
const addClick = chrome.action.onClicked.addListener.bind(chrome.action.onClicked);
chrome.action.onClicked.addListener = (fn) => { globalThis.testToggle = fn; addClick(fn); };
globalThis.testNative = { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold: false, slowText: null, failText: null, replies: new Map(), partials: new Map() };
chrome.runtime.connectNative = () => {
  testNative.opened++;
  let receive, disconnected, alive = true, timer, requestID;
  function close() {
    if (!alive) return;
    alive = false; testNative.closed++;
    testNative.replies.delete(requestID);
    testNative.partials.delete(requestID);
    if (timer) { clearTimeout(timer); timer = null; testNative.active--; }
  }
  return {
    onMessage: { addListener(fn) { receive = fn; } }, onDisconnect: { addListener(fn) { disconnected = fn; } },
    disconnect: close,
    postMessage(request) {
      requestID = request.id;
      testNative.requests.push(request); testNative.active++;
      testNative.peak = Math.max(testNative.peak, testNative.active);
      const finish = (error) => {
        if (!alive || !timer) return;
        clearTimeout(timer); timer = null; testNative.active--;
        testNative.replies.delete(request.id);
        testNative.partials.delete(request.id);
        if (error || request.items.some(item => item.text === testNative.failText)) {
          receive({ version: 1, id: request.id, ok: false,
            error: typeof error === 'object' ? error : { code: 'translation_failed', message: error || '模拟批次失败' } });
          // The real native host exits after writing an error. Its disconnect
          // can arrive after the extension has scheduled another pool turn.
          setTimeout(() => { if (alive) { close(); disconnected?.(); } }, 0);
          return;
        }
        receive({ version: 1, id: request.id, ok: true,
          items: request.items.map(({ id, text }) => ({ id, text: `译文：${text}` })) });
      };
      testNative.replies.set(request.id, finish);
      testNative.partials.set(request.id, (text) => { if (alive && timer) receive({ version: 1, id: request.id, ok: true, partial: true, text }); });
      timer = setTimeout(finish, testNative.hold || request.items.some(item => item.text === testNative.slowText) ? 30000 : 80);
    },
  };
};
