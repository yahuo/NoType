async (page) => {
  const scriptURL = page.url().replace(/\/tests\/.*$/, "/extension/content.js") + `?test=${Date.now()}`;
  await page.setViewportSize({ width: 1200, height: 1500 });
  await page.reload();
  await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8"><style>
    body { font:18px/1.6 sans-serif; } .block { display:block; }
  </style><header><h1>Site navigation title</h1></header><main><article>
    <header><h1>Article title</h1><p>Article introduction.</p></header>
    <p>Line one<br>Line two</p>
    <p>Before<span class="block">Inside block</span>After</p>
    <p>An <strong>important</strong> word and inter<em>national</em>.</p>
    <p>Public text.<span hidden>Hidden text.</span><button>Control text.</button></p>
    <p style="opacity:0">Initially hidden content.</p>
  </article></main></html>`);
  await page.evaluate(() => {
    window.sent = [];
    window.chrome = {runtime:{connect() {
      const port = {onMessage:{addListener(fn){port.receive=fn;}},onDisconnect:{addListener(){}},disconnect(){},
        postMessage(message){ window.sent.push(...message.items.map(i=>i.text)); queueMicrotask(()=>port.receive({ok:true,items:message.items.map(i=>({id:i.id,text:"译文"}))})); }};
      return port;
    }}};
  });
  await page.addScriptTag({url:scriptURL});
  await page.waitForFunction(() => document.querySelector('notype-status')?.shadowRoot.textContent.includes('再次点击插件可恢复原文'));
  const sent = await page.evaluate(() => window.sent);
  const expected = ["Article title", "Article introduction.", "Line one Line two", "Before Inside block After",
    "An important word and international.", "Public text."];
  if (JSON.stringify(sent) !== JSON.stringify(expected)) throw new Error(`Wrong paragraph extraction: ${JSON.stringify(sent)}`);
  await page.addScriptTag({url:scriptURL});
  if (await page.locator('notype-translation,notype-status').count()) throw new Error('Toggle left translated nodes behind');
  return "PASS: article headers, site header exclusion, line/block boundaries, inline words and hidden/control exclusion";
}
