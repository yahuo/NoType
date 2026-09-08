async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const worker = page.context().serviceWorkers()[0] || await page.context().waitForEvent('serviceworker');
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  await worker.evaluate(async (id) => {
    await stopTab(id);
    Object.assign(testNative, { opened: 0, closed: 0, active: 0, peak: 0, requests: [], hold: false });
  }, tabId);
  await page.goto(page.url().replace(/\/tests\/.*$/, '/tests/cache-fixture.html'));
  await page.setViewportSize({ width: 1200, height: 1800 });
  await worker.evaluate(({id,url})=>testToggle({id,url}),{id:tabId,url:page.url()});
  for (const frame of page.frames()) await frame.waitForFunction(() => document.querySelectorAll('notype-translation').length === 4);
  const initial = await worker.evaluate(() => ({ requests:testNative.requests.length,
    texts:testNative.requests.flatMap(r=>r.items.map(i=>i.text)), peak:testNative.peak }));
  check(initial.texts.length===4 && new Set(initial.texts).size===4,'Expected four unique source texts');
  // Frames can arrive after a free slot starts; their load timing determines
  // batch count. Each unique text still appears in exactly one native request.
  check(initial.requests<=4 && initial.peak<=2,'Deduplication or the two-slot limit regressed');
  for(const frame of page.frames()) {
    const translated=await frame.locator('notype-translation').evaluateAll(nodes=>nodes.map(n=>n.shadowRoot.querySelector('span').textContent));
    check(translated.filter(t=>t==='译文：Undisclosed').length===3,'Duplicate positions were not all filled');
  }
  await page.evaluate(()=>{
    const frame=document.createElement('iframe');frame.name='cached';
    frame.srcdoc='<p>Undisclosed</p><p>Undisclosed</p>';document.body.append(frame);
  });
  await page.locator('iframe[name=cached]').scrollIntoViewIfNeeded();
  const cachedFrame=await (await page.locator('iframe[name=cached]').elementHandle()).contentFrame();
  await cachedFrame.waitForFunction(()=>document.querySelectorAll('notype-translation').length===2);
  check(await worker.evaluate(()=>testNative.requests.length)===initial.requests,'Cache hit sent another native request');
  await worker.evaluate(({id,url})=>testToggle({id,url}),{id:tabId,url:page.url()});
  for (const frame of page.frames()) await frame.waitForFunction(()=>!document.querySelector('notype-status,notype-translation'));
  return {result:'PASS: 12 positions use 4 unique texts; late iframe uses cache; global stop restores all frames',initial};
}
