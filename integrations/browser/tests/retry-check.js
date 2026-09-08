async (page) => {
  const check = (value, message) => { if (!value) throw new Error(message); };
  const worker = page.context().serviceWorkers()[0] || await page.context().waitForEvent('serviceworker');
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  const bad = 'Failed source: ' + 'A'.repeat(7000);
  const good = 'Successful source: ' + 'B'.repeat(7000);
  const child = 'Child source: ' + 'C'.repeat(7000);
  await worker.evaluate(async id => {
    await stopTab(id);
    Object.assign(testNative, { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold: true, slowText: null, failText: null });
  }, tabId);
  await page.evaluate(({ bad, good, child }) => {
    document.body.replaceChildren();
    const a = document.createElement('p'); a.id = 'bad'; a.textContent = bad;
    const b = document.createElement('p'); b.id = 'good'; b.textContent = good;
    const frame = document.createElement('iframe'); frame.name = 'retry';
    frame.srcdoc = `<p id="bad">${bad}</p><p id="good">${child}</p>`;
    document.body.append(a, b, frame); scrollTo(0, 0);
  }, { bad, good, child });
  const embedded = await (await page.locator('iframe[name=retry]').elementHandle()).contentFrame();
  await embedded.waitForSelector('#bad');
  await worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url: page.url() });
  for (let i = 0; i < 100; i++) {
    if (await worker.evaluate(text => slots.some(slot => slot.job?.group.some(entry => entry.text === text && entry.waiters.size === 2)), bad)) break;
    await page.waitForTimeout(20);
  }
  check(await worker.evaluate(text => slots.some(slot => slot.job?.group.some(entry => entry.text === text && entry.waiters.size === 2)), bad), 'Duplicate frame did not join in-flight work');
  await worker.evaluate(text => {
    const request = testNative.requests.find(request => request.items.some(item => item.text === text));
    testNative.partials.get(request.id)(JSON.stringify({ id: request.items[0].id, text: '临时译文' }));
  }, bad);
  await page.waitForFunction(() => !!document.querySelector('#bad + notype-translation'));
  await worker.evaluate(text => {
    testNative.hold = false;
    const failed = testNative.requests.find(request => request.items.some(item => item.text === text));
    testNative.replies.get(failed.id)('模拟模型超时');
    for (const finish of [...testNative.replies.values()]) finish();
  }, bad);
  for (const frame of [page.mainFrame(), embedded]) {
    await frame.waitForFunction(() => !!document.querySelector('#good + notype-translation') && !document.querySelector('#bad + notype-translation'));
    await frame.evaluate(() => { window.keptTranslation = document.querySelector('#good + notype-translation'); });
  }
  const retry = page.locator('notype-status').getByRole('button', { name: '重试失败段落', exact: true });
  await retry.waitFor({ state: 'visible' });
  await page.locator('notype-status').screenshot({ path: 'dist/browser-retry.png' });
  check(await page.locator('notype-status').count() === 1 && await embedded.locator('notype-status').count() === 0, 'Retry created an iframe progress bar');
  const before = await worker.evaluate(() => ({ requests: testNative.requests.length, active: testNative.active, opened: testNative.opened, closed: testNative.closed }));
  check(before.requests === 3 && before.active === 0 && before.opened === before.closed, 'Failure blocked the queue or leaked native connections');
  // Losing idle extension ports must not discard failed paragraph state or restart successful work.
  await worker.evaluate(id => sessions.get(id).close(), tabId);
  await page.waitForTimeout(50);
  await retry.click();
  for (const frame of [page.mainFrame(), embedded]) {
    await frame.waitForFunction(() => !!document.querySelector('#bad + notype-translation'));
    check(await frame.evaluate(() => window.keptTranslation === document.querySelector('#good + notype-translation')), 'Retry replaced a successful translation');
  }
  await retry.waitFor({ state: 'hidden' });
  check(await worker.evaluate(() => testNative.requests.length) === before.requests + 1, 'Retry resent successful or duplicate text');
  check(await worker.evaluate(() => testNative.peak === 2 && testNative.opened === testNative.closed), 'Retry exceeded or leaked the pool');
  await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
  for (const frame of [page.mainFrame(), embedded]) await frame.waitForFunction(() => !document.querySelector('notype-status,notype-translation'));
  // An error belonging only to a late iframe must still reach a completed main page.
  await page.evaluate(good => { document.body.innerHTML = '<p id="good"></p>'; document.querySelector('#good').textContent = good; }, good);
  await worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url: page.url() });
  await page.waitForFunction(() => !!document.querySelector('#good + notype-translation'));
  await worker.evaluate(bad => { testNative.failText = bad; }, bad);
  await page.evaluate(bad => {
    const frame = document.createElement('iframe'); frame.id = 'failed-frame';
    frame.srcdoc = `<p>${bad}</p>`; document.body.append(frame);
  }, bad);
  await retry.waitFor({ state: 'visible' });
  check(await page.locator('notype-status').count() === 1, 'Late iframe duplicated the status');
  await page.locator('#failed-frame').evaluate(frame => frame.remove());
  await retry.waitFor({ state: 'hidden' });
  await worker.evaluate(() => { testNative.failText = null; testNative.hold = true; });
  // Channel errors must remain visible when only a late iframe has an open port.
  await page.evaluate(bad => {
    const frame = document.createElement('iframe'); frame.id = 'fatal-frame';
    frame.srcdoc = `<p>${bad}</p>`; document.body.append(frame);
  }, bad);
  for (let i = 0; i < 100 && !await worker.evaluate(() => testNative.replies.size); i++) await page.waitForTimeout(20);
  check(await worker.evaluate(() => testNative.replies.size === 1), 'Late iframe did not submit its channel-error test request');
  await worker.evaluate(() => {
    testNative.hold = false;
    [...testNative.replies.values()][0]({ code: 'missing_codex_auth', message: '模拟登录失效' });
  });
  await page.waitForFunction(() => document.querySelector('notype-status')?.shadowRoot.textContent.includes('翻译已停止：模拟登录失效'));
  check(await page.locator('#good + notype-translation').count() === 1, 'A late iframe channel error removed a completed translation');
  check(await page.locator('notype-status').count() === 1 && await retry.isHidden(), 'A channel error duplicated status or offered a paragraph retry');
  check(await worker.evaluate(() => testNative.active === 0 && testNative.opened === testNative.closed), 'Channel error leaked native connections');
  await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
  return { result: 'PASS: per-batch failure, host exit, iframe retry, idle port recovery, deduplication, removed-frame failures, late iframe channel errors and global close', before };
}
