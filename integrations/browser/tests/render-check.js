async (page) => {
  const check = (value, message) => { if (!value) throw new Error(message); };
  const scriptURL = page.url().replace(/\/tests\/.*$/, '/extension/content.js');
  await page.reload();
  await page.setContent('<main><p id="source">This paragraph verifies coalesced translation rendering.</p></main>');
  await page.evaluate(() => {
    window.chrome = { runtime: { connect() {
      const port = { onMessage: { addListener(fn) { window.receive = fn; } },
        onDisconnect: { addListener() {} }, disconnect() {},
        postMessage(message) { if (!message.type) window.request = message; } };
      return port;
    } } };
  });
  await page.addScriptTag({ url: scriptURL });
  await page.evaluate(() => window.__noTypeToggleTranslation());
  await page.waitForFunction(() => !!window.request);
  await page.evaluate(() => {
    window.partial = (text) => receive({ id: request.id, ok: true, partial: true,
      text: JSON.stringify({ id: request.items[0].id, text }) });
    partial('起始');
  });
  await page.waitForFunction(() => document.querySelector('notype-translation')?.shadowRoot.querySelector('span').textContent === '起始');
  const results = await page.evaluate(async () => {
    const view = document.querySelector('notype-translation').shadowRoot;
    const frames = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const writes = new MutationObserver(records => { window.writeCount += records.length; });
    writes.observe(view.querySelector('span'), { childList: true, characterData: true, subtree: true });
    const originalStyle = window.getComputedStyle;
    window.getComputedStyle = (...args) => { window.styleReads++; return originalStyle(...args); };
    window.writeCount = 0; window.styleReads = 0;
    for (let i = 0; i < 200; i++) partial(`译文 ${i}`);
    await frames();
    const burst = { writes: writeCount, styleReads, text: view.querySelector('span').textContent };
    window.writeCount = 0; window.styleReads = 0;
    for (let i = 0; i < 500; i++) partial('译文 199');
    await frames();
    const duplicate = { writes: writeCount, styleReads };
    partial('不应显示的中间结果'); partial('译文 199'); await frames();
    const latest = view.querySelector('span').textContent;
    partial('过期的流式内容');
    receive({ id: request.id, ok: true, items: [{ id: request.items[0].id, text: '最终译文' }] });
    await frames();
    const final = view.querySelector('span').textContent;
    window.getComputedStyle = originalStyle;
    writes.disconnect();
    return { burst, duplicate, latest, final };
  });
  check(results.burst.writes === 1 && results.burst.styleReads < 30 && results.burst.text === '译文 199', 'Streaming burst was not coalesced');
  check(results.duplicate.writes === 0 && results.duplicate.styleReads === 0, 'Unchanged text triggered DOM/style work');
  check(results.latest === '译文 199', 'An older queued value overwrote the latest partial');
  check(results.final === '最终译文', 'Pending partial overwrote the final result');
  await page.evaluate(() => window.__noTypeToggleTranslation());
  await page.evaluate(() => { window.request = null; window.__noTypeToggleTranslation(); });
  await page.waitForFunction(() => !!window.request);
  await page.evaluate(async () => {
    partial('取消前排队的内容');
    window.__noTypeToggleTranslation();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  check(await page.locator('notype-translation,notype-status').count() === 0, 'A queued frame rendered after cancellation');
  await page.evaluate(() => {
    document.body.innerHTML = '<p id="one">First paragraph.</p><p id="two">Second paragraph.</p><p id="three">Third paragraph.</p>';
    window.request = null; window.__noTypeToggleTranslation();
  });
  await page.waitForFunction(() => window.request?.items.length === 3);
  await page.evaluate(() => {
    window.previousRequest = request.id;
    receive({ id: request.id, ok: true, items: request.items.map(({ id }, index) =>
      index === 1 ? { id, error: '模拟翻译失败' } : { id, text: '成功译文' }) });
    window.kept = document.querySelector('#one + notype-translation');
  });
  check(await page.locator('notype-translation').count() === 2, 'A mixed response lost successful rows');
  await page.locator('notype-status').getByRole('button', { name: '重试失败段落', exact: true }).click();
  await page.waitForFunction(() => request.id !== previousRequest);
  check(await page.evaluate(() => request.items.length === 1 && request.items[0].id === 'p1'), 'Retry submitted successful rows from a mixed response');
  await page.evaluate(() => receive({ id: request.id, ok: true, items: [{ id: 'p1', text: '重试成功' }] }));
  check(await page.locator('notype-translation').count() === 3 && await page.evaluate(() => window.kept === document.querySelector('#one + notype-translation')), 'Mixed retry did not preserve successful views');
  await page.evaluate(() => window.__noTypeToggleTranslation());
  return { result: 'PASS: coalesced writes, unchanged text, latest partial, final ordering, cancellation and mixed-result retry', ...results };
}
