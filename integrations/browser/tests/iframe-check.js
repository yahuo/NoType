async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const context = page.context();
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  const url = page.url();
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  const toggle = () => worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url });
  const translated = async (frame) => frame.locator('notype-translation').count();
  const waitText = (frame, text) => frame.waitForFunction((text) =>
    [...document.querySelectorAll('notype-translation')].some((node) => node.shadowRoot.textContent.includes(text)), text);
  await worker.evaluate(async (id) => {
    await stopTab(id);
    Object.assign(testNative, { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold: false });
  }, tabId);
  await page.setViewportSize({ width: 1200, height: 1800 });
  await page.reload();
  await page.waitForFunction(() => [...document.querySelectorAll('iframe')].every((frame) => frame.contentWindow));
  check((await worker.evaluate(() => testNative.requests.length)) === 0, 'Page loaded text without a click');
  await toggle();
  for (const [name, text] of [['', 'Main page'], ['same', 'Embedded chart'], ['cross', 'Embedded chart'],
      ['nested', 'Nested frame'], ['srcdoc', 'Inline document'], ['blank', 'Blank frame']]) {
    const frame = name ? page.frame({ name }) : page.mainFrame();
    check(!!frame, `Missing ${name} frame`);
    await waitText(frame, text);
    check(await translated(frame) === 1, `Wrong translation count in ${name}`);
  }
  check(await translated(page.frame({ name: 'hidden' })) === 0, 'Hidden frame translated');
  await page.waitForTimeout(150);
  const first = await worker.evaluate(() => ({ opened: testNative.opened, closed: testNative.closed, peak: testNative.peak }));
  check(first.peak >= 1 && first.peak <= 2 && first.opened === first.closed, `Connection queue or release failed: ${JSON.stringify(first)}`);

  await page.evaluate(() => {
    const frame = document.createElement('iframe'); frame.name = 'dynamic';
    frame.src = document.querySelector('#cross').src.replace('?nested', '?dynamic');
    document.body.append(frame);
  });
  await page.locator('iframe[name=dynamic]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await waitText(page.frame({ name: 'dynamic' }), 'Embedded chart');
  await page.evaluate(() => {
    const frame = document.createElement('iframe'); frame.name = 'blob';
    frame.src = URL.createObjectURL(new Blob(['<p>Blob frame paragraph.</p>'], { type: 'text/html' }));
    document.body.append(frame);
  });
  await page.locator('iframe[name=blob]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await waitText(page.frame({ name: 'blob' }), 'Blob frame');

  await page.evaluate(() => {
    const frame = document.createElement('iframe'); frame.name = 'data';
    frame.src = 'data:text/html,<p>Data frame paragraph.</p>'; document.body.append(frame);
    const sandbox = document.createElement('iframe'); sandbox.name = 'sandbox';
    sandbox.setAttribute('sandbox', 'allow-scripts'); sandbox.srcdoc = '<p>Sandbox frame paragraph.</p>'; document.body.append(sandbox);
  });
  await page.locator('iframe[name=sandbox]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await waitText(page.frame({ name: 'data' }), 'Data frame');
  await waitText(await (await page.locator('iframe[name=sandbox]').elementHandle()).contentFrame(), 'Sandbox frame');
  await page.evaluate(() => { document.querySelector('iframe[name=dynamic]').src += '&navigated'; });
  await page.locator('iframe[name=dynamic]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(200);
  await waitText(page.frame({ name: 'dynamic' }), 'Embedded chart');
  check(await translated(page.frame({ name: 'dynamic' })) === 1, 'Child navigation duplicated or lost translations');

  // Only the top document owns progress UI, including when new or nested frames join.
  for (const frame of page.frames()) {
    check(await frame.locator('notype-status').count() === (frame === page.mainFrame() ? 1 : 0),
      `Unexpected progress bar in ${frame.name() || 'main'}`);
  }
  // The main close button clears the whole tab, including earlier off-screen frames.
  await page.locator('notype-status').getByRole('button', { name: '关闭', exact: true }).click();
  for (const frame of page.frames()) await frame.waitForFunction(() => !document.querySelector('notype-status,notype-translation'));
  await page.evaluate(() => {
    const frame = document.createElement('iframe'); frame.name = 'afterStop'; frame.srcdoc = '<p>Must stay untranslated.</p>'; document.body.append(frame);
  });
  await page.locator('iframe[name=afterStop]').scrollIntoViewIfNeeded();
  await page.waitForTimeout(250);
  check(await translated(page.frame({ name: 'afterStop' })) === 0, 'Late frame restarted after close');

  // Cancel a real extension-port request while the fake native host is withholding its response.
  await worker.evaluate(() => { testNative.hold = true; });
  await toggle();
  for (let i = 0; i < 50; i++) {
    if (await worker.evaluate(() => testNative.active > 0)) break;
    await page.waitForTimeout(50);
  }
  check(await worker.evaluate(() => testNative.active > 0), 'No in-flight batch for cancellation test');
  await toggle();
  check(await worker.evaluate(() => testNative.active === 0 && testNative.opened === testNative.closed), 'Cancellation leaked native connection');
  await worker.evaluate(() => { testNative.hold = false; });
  await toggle();
  await waitText(page.frame({ name: 'afterStop' }), 'Must stay');
  await page.reload();
  await page.waitForTimeout(200);
  check(await translated(page.mainFrame()) === 0, 'Main navigation translated without a new click');
  return { result: 'PASS: real extension injection, cross-origin/nested/srcdoc/blank/blob/dynamic frames, shared queue, release, global close, cancellation and navigation reset', first };
}
