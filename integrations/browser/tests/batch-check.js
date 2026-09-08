async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const worker = page.context().serviceWorkers()[0] || await page.context().waitForEvent('serviceworker');
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  await page.setViewportSize({ width: 1200, height: 1800 });
  const results = [];
  for (const kind of ['short', 'mixed']) {
    await worker.evaluate(async (id) => {
      await stopTab(id);
      Object.assign(testNative, { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold: false });
    }, tabId);
    const texts = Array.from({ length: kind === 'short' ? 24 : 12 }, (_, i) =>
      kind === 'mixed' && i >= 6 ? `Long paragraph ${i}: ` + 'This is a longer passage for translation. '.repeat(4).trim() : `Table label ${i}`);
    await page.evaluate((texts) => {
      const table = document.createElement('table');
      table.style.cssText = 'font:14px sans-serif;width:100%;table-layout:fixed';
      for (let i = 0; i < texts.length; i += 4) {
        const row = table.insertRow();
        for (const text of texts.slice(i, i + 4)) row.insertCell().textContent = text;
      }
      document.body.replaceChildren(table);
      document.body.style.paddingBottom = '';
      scrollTo(0, 0);
    }, texts);
    await worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url: page.url() });
    await page.waitForFunction((texts) => {
      const translations = [...document.querySelectorAll('notype-translation')];
      return translations.length === texts.length && translations.every((node, i) =>
        node.shadowRoot.querySelector('span').textContent === `译文：${texts[i]}`);
    }, texts);
    const result = await worker.evaluate(() => ({ batches: testNative.requests.map(r => r.items.map(i => i.text)), peak: testNative.peak }));
    check(result.peak <= 2, 'Requests exceeded the two-slot limit');
    check(result.batches.flat().join('\n') === texts.join('\n'), 'Source text was lost, reordered or duplicated');
    if (kind === 'short') check(result.batches.map(b => b.length).join(',') === '12,12', 'Short texts were not combined into two batches');
    else check(result.batches.map(b => b.length).join(',') === '6,4,2', 'Mixed batches expanded long paragraphs');
    check(await page.locator('notype-status').count() === 1, 'Progress UI duplicated');
    await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
    await page.waitForFunction(() => !document.querySelector('notype-status,notype-translation'));
    check(await worker.evaluate(() => testNative.opened === testNative.closed), 'Native connection leaked');
    results.push({ kind, batchSizes: result.batches.map(b => b.length) });
  }
  return { result: 'PASS: short texts use 12-item batches, long paragraphs keep small batches, all translations map correctly and close restores the page', results };
}
