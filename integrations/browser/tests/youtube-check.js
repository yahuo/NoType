async (page) => {
  // Serves a fake www.youtube.com through request routing: nothing reaches YouTube.
  const check = (value, message) => { if (!value) throw new Error(message); };
  const context = page.context();
  const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
  const seconds = 220, rate = 8000;
  const wav = Buffer.alloc(44 + seconds * rate, 128);
  wav.write('RIFF', 0); wav.writeUInt32LE(36 + seconds * rate, 4); wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate, 28); wav.writeUInt16LE(1, 32); wav.writeUInt16LE(8, 34); wav.write('data', 36); wav.writeUInt32LE(seconds * rate, 40);
  const line = (video, n) => `${video} line ${n} explains the topic.`;
  const track = (video) => JSON.stringify({ events: Array.from({ length: 100 }, (_, n) =>
    ({ tStartMs: n * 2000, dDurationMs: 2000, segs: [{ utf8: line(video, n) }] })) });
  const html = `<!doctype html><meta charset="utf-8"><title>fake watch</title><body style="margin:0;font:16px sans-serif">
<div id="movie_player" class="html5-video-player" style="position:relative;width:960px;height:540px;background:#000;overflow:hidden">
  <video class="html5-main-video" muted preload="auto" src="/media.wav" style="width:100%;height:100%"></video>
  <div class="ytp-caption-window-container" style="position:absolute;bottom:80px;left:0;right:0;text-align:center;color:#fff">native caption</div>
  <div class="ytp-chrome-bottom" style="position:absolute;bottom:0;left:0;right:0;height:48px">
    <button class="ytp-subtitles-button" aria-pressed="false">CC</button></div>
</div>
<p id="desc">This description paragraph stays untouched while subtitles are translated.</p>
<script>
  const button = document.querySelector('.ytp-subtitles-button');
  const video = () => new URLSearchParams(location.search).get('v');
  window.loads = [];
  function load() {
    const url = '/api/timedtext?v=' + video() + '&lang=en&fmt=json3';
    loads.push(url);
    if (video() === 'vid2') { fetch(url).then((r) => r.text()); return; }
    const xhr = new XMLHttpRequest(); xhr.open('GET', url); xhr.send();
  }
  button.addEventListener('click', () => {
    const on = button.getAttribute('aria-pressed') !== 'true';
    button.setAttribute('aria-pressed', String(on));
    if (on) load();
  });
  window.navigateTo = (id) => { history.pushState({}, '', '/watch?v=' + id); if (button.getAttribute('aria-pressed') === 'true') load(); };
</script>`;
  await context.route('https://www.youtube.com/**', (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === '/media.wav') {
      // Byte ranges make the media seekable.
      const [, first, last] = (route.request().headers().range || '').match(/bytes=(\d+)-(\d*)/) || [];
      if (first === undefined) return route.fulfill({ status: 200, contentType: 'audio/wav', headers: { 'accept-ranges': 'bytes' }, body: wav });
      const end = last ? Math.min(Number(last), wav.length - 1) : wav.length - 1;
      return route.fulfill({ status: 206, contentType: 'audio/wav', body: wav.subarray(Number(first), end + 1),
        headers: { 'accept-ranges': 'bytes', 'content-range': `bytes ${first}-${end}/${wav.length}` } });
    }
    if (url.pathname === '/api/timedtext') return route.fulfill({ status: 200, contentType: 'application/json', body: track(url.searchParams.get('v')) });
    if (url.pathname === '/watch') return route.fulfill({ status: 200, contentType: 'text/html', body: html });
    return route.fulfill({ status: 404, body: '' });
  });
  const tabId = await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0].id);
  const toggle = () => worker.evaluate(({ id, url }) => testToggle({ id, url }), { id: tabId, url: page.url() });
  const texts = () => worker.evaluate(() => testNative.requests.flatMap((request) => request.items.map((item) => item.text)));
  const ready = () => page.waitForFunction(() => document.querySelector('video').readyState >= 1);
  const showing = (src, dst) => page.waitForFunction(([src, dst]) => {
    const root = document.querySelector('#movie_player > notype-subtitle')?.shadowRoot;
    return root?.querySelector('.src')?.textContent === src && root.querySelector('.dst')?.textContent === dst;
  }, [src, dst], { timeout: 10000 }).catch(async () => {
    const state = await page.evaluate(() => {
      const root = document.querySelector('notype-subtitle')?.shadowRoot;
      return { url: location.href, src: root?.querySelector('.src')?.textContent, dst: root?.querySelector('.dst')?.textContent,
        pill: root?.querySelector('.pill')?.textContent, time: document.querySelector('video').currentTime, loads };
    });
    throw new Error(`Expected subtitle ${src}; saw ${JSON.stringify(state)}`);
  });
  const seek = (time) => page.evaluate((time) => new Promise((resolve) => {
    const video = document.querySelector('video');
    video.addEventListener('seeked', resolve, { once: true }); video.currentTime = time;
  }), time);
  await worker.evaluate(async (id) => { await stopTab(id); Object.assign(testNative, { requests: [], hold: false, slowText: null, failText: null }); }, tabId);

  // 1. CC was already on before the click: the passively captured XHR track is used.
  await page.goto('https://www.youtube.com/watch?v=vid1');
  await ready();
  await page.click('.ytp-subtitles-button');
  await page.waitForTimeout(200);
  check(await worker.evaluate(() => testNative.requests.length) === 0, 'Translated before the button was clicked');
  check(await page.locator('notype-subtitle').count() === 0, 'Overlay appeared before the button was clicked');
  await toggle();
  await showing(line('vid1', 0), `译文：${line('vid1', 0)}`);
  check(await page.evaluate(() => getComputedStyle(document.querySelector('.ytp-caption-window-container')).opacity) === '0', 'Native captions still visible');
  await page.waitForTimeout(300);
  let sent = await texts();
  const index = (text) => Number(text.match(/line (\d+)/)[1]);
  check(sent.length >= 40 && sent.every((text) => text.startsWith('vid1') && index(text) <= 45), `Prefetch window wrong: ${sent.length}`);
  check(await worker.evaluate(() => testNative.requests.every((request) => request.items.length <= 12)), 'Batch exceeded 12 items');
  check(await page.locator('#desc + notype-translation').count() === 0 && await page.locator('notype-status').count() === 0, 'Page paragraphs were translated on a watch page');
  await page.locator('#movie_player').screenshot({ path: 'dist/youtube-subtitles.png' });

  // Playback moves the window edge one cue at a time; those cues wait to share a batch.
  const batches = await worker.evaluate(() => testNative.requests.length);
  for (let time = 2; time <= 20; time += 2) { await seek(time); await page.waitForTimeout(550); }
  check(await worker.evaluate(() => testNative.requests.length) === batches, 'Playback sent cues one by one');

  // 2. Seeking ahead translates the new window and follows the playhead.
  await seek(151);
  await showing(line('vid1', 75), `译文：${line('vid1', 75)}`);
  sent = await texts();
  check(sent.some((text) => index(text) === 99) && new Set(sent).size === sent.length, 'Seek window missing or duplicated');

  // 3. In-page navigation to another video uses its fetch-loaded track.
  await page.evaluate(() => navigateTo('vid2'));
  await seek(0);
  await showing(line('vid2', 0), `译文：${line('vid2', 0)}`);

  // 4. Turning CC off hides the overlay and restores native captions; the toolbar click removes everything.
  await page.click('.ytp-subtitles-button');
  await page.waitForFunction(() => !document.querySelector('#movie_player').hasAttribute('data-notype-subtitles') &&
    !document.querySelector('notype-subtitle').shadowRoot.querySelector('.box').checkVisibility());
  await page.click('.ytp-subtitles-button');
  await toggle();
  await page.waitForFunction(() => !document.querySelector('notype-subtitle') && !document.querySelector('#movie_player[data-notype-subtitles]'));
  check(await page.evaluate(() => getComputedStyle(document.querySelector('.ytp-caption-window-container')).opacity) === '1', 'Native captions stayed hidden');

  // 5. CC off at the click: subtitle mode turns CC on once and translates the track it loads.
  //    A failed batch is reported on the player and retried on click.
  await worker.evaluate((text) => { testNative.requests = []; testNative.failText = text; }, line('vid3', 0));
  await page.goto('https://www.youtube.com/watch?v=vid3');
  await ready();
  await toggle();
  await showing(line('vid3', 0), '');
  const pill = page.locator('notype-subtitle .pill');
  await page.waitForFunction(() => {
    const pill = document.querySelector('notype-subtitle').shadowRoot.querySelector('.pill');
    return /条字幕翻译失败/.test(pill.textContent) && !pill.disabled;
  });
  check(await page.evaluate(() => loads.length) === 1, 'Captions were requested more than once');
  await worker.evaluate(() => { testNative.failText = null; });
  await pill.click();
  await showing(line('vid3', 0), `译文：${line('vid3', 0)}`);
  await pill.waitFor({ state: 'hidden' });
  await toggle();
  await page.waitForFunction(() => !document.querySelector('notype-subtitle'));
  await context.unroute('https://www.youtube.com/**');
  return 'youtube subtitles ok';
}
