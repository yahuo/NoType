async (page) => {
  const check = (value, message) => { if (!value) throw new Error(message); };
  const worker = page.context().serviceWorkers()[0] || await page.context().waitForEvent('serviceworker');
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  await page.setViewportSize({ width: 1200, height: 600 });
  const texts = Array.from({ length: 72 }, (_, i) => `Paragraph ${i}. ` + 'This is a full paragraph used to exercise the translation request pool. '.repeat(2).trim());
  const start = async (hold) => {
    await worker.evaluate(async ({ id, hold, slowText }) => {
      await stopTab(id);
      Object.assign(testNative, { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold, slowText });
    }, { id: tabId, hold, slowText: texts[0] });
    await page.evaluate((texts) => {
      document.body.replaceChildren(); document.body.style.paddingBottom = '2000px';
      for (const [i, text] of texts.entries()) {
        const p = document.createElement('p'); p.id = 'part-' + i;
        p.textContent = text; p.style.cssText = 'min-height:120px;font:16px sans-serif';
        document.body.append(p);
      }
      scrollTo(0, 0);
    }, texts);
    await worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url: page.url() });
  };
  await start(false);
  // Hold the first batch, yet every other batch (including the last off-screen
  // paragraph) must finish without scrolling or waiting for that slow response.
  await page.waitForFunction(() => document.querySelectorAll('notype-translation').length === 68);
  check(await page.evaluate(() => scrollY === 0 && document.querySelector('#part-71').getBoundingClientRect().top > innerHeight), 'Off-screen case was not actually off screen');
  check(await page.locator('#part-71 + notype-translation').count() === 1, 'Later content waited for scrolling');
  const drained = await worker.evaluate(() => ({ active: testNative.active, peak: testNative.peak, requests: testNative.requests.length }));
  check(drained.active === 1 && drained.peak === 2 && drained.requests === 18, 'A slow batch blocked the pool or exceeded its limit');
  await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('notype-status,notype-translation'));
  check(await worker.evaluate(() => testNative.active === 0 && testNative.opened === testNative.closed), 'Closing leaked a slot');

  await start(true);
  for (let i = 0; i < 50 && await worker.evaluate(() => testNative.active) < 2; i++) await page.waitForTimeout(20);
  check(await worker.evaluate(() => testNative.active) === 2, 'Both slots did not start');
  await page.evaluate(() => document.querySelector('#part-71').scrollIntoView({ block: 'start' }));
  let prioritized = false;
  for (let i = 0; i < 50; i++) {
    prioritized = await worker.evaluate(({ id, text }) => {
      const next = sessions.get(id)?.peek();
      return next?.text === text && priority(next) === 0;
    }, { id: tabId, text: texts.at(-1) });
    if (prioritized) break;
    await page.waitForTimeout(20);
  }
  check(prioritized, 'Scrolling did not update queued priorities');
  await worker.evaluate(() => testNative.replies.get(testNative.requests[0].id)());
  for (let i = 0; i < 50 && await worker.evaluate(() => testNative.requests.length) < 3; i++) await page.waitForTimeout(20);
  check(await worker.evaluate(text => testNative.requests[2].items[0].text === text, texts.at(-1)), 'The free slot ignored the newly visible paragraph');
  await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
  await page.waitForFunction(() => !document.querySelector('notype-status,notype-translation'));
  check(await worker.evaluate(() => testNative.active === 0 && testNative.opened === testNative.closed), 'Priority test leaked connections');
  await worker.evaluate(() => { testNative.hold = false; testNative.slowText = null; });
  return { result: 'PASS: slow-batch isolation, full-page translation without scrolling, two slots, live viewport priority and cancellation', drained };
}
