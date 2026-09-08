async (page) => {
  const scriptURL = page.url().replace(/\/tests\/.*$/, "/extension/content.js") + `?test=${Date.now()}`;
  await page.setViewportSize({ width: 1280, height: 1200 });
  await page.reload();
  await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8"><style>
    body { margin: 40px auto; max-width: 1120px; color: #1e2934; background: white; font: 22px/1.6 Georgia, "Times New Roman", serif; }
    h1 { font: 500 44px/1.2 Georgia, "Times New Roman", serif; margin: 0; color: #111; }
    p { margin: 26px 0 0; }
    #credit { font: 400 18px/1.5 Arial, sans-serif; color: #536273; }
    #bio { font-size: 20px; line-height: 1.65; }
    #aligned { text-align: center; letter-spacing: .4px; font-weight: 600; }
    a { color: inherit; }
  </style><main>
    <h1>Read the web in two languages</h1>
    <p id="body"><strong>Browser extensions</strong> can preserve the page’s typography while translating its paragraphs.</p>
    <p id="credit">Alex contributed to this report.</p>
    <p id="bio"><em>Alex is a reporter covering technology and research. Read more <a href="#">here</a>.</em></p>
    <p id="aligned">A centered paragraph keeps its alignment.</p>
  </main></html>`);
  await page.evaluate(() => {
    const translations = [
      "用两种语言阅读网页",
      "浏览器扩展可以在翻译段落的同时，保留网页原有的字体和排版。",
      "Alex 对本文亦有贡献。",
      "Alex 是一位关注科技与研究的记者。点击此处了解更多。",
      "居中的段落仍然保持居中。",
    ];
    window.chrome = { runtime: { connect() {
      const port = { onMessage: { addListener(fn) { port.receive = fn; } },
        onDisconnect: { addListener() {} }, disconnect() {},
        postMessage(message) { if (message.type) return; queueMicrotask(() => port.receive({id:message.id,ok:true,
          items:message.items.map(({id}) => ({id, text:translations[Number(id.slice(1))]}))})); }
      }; return port;
    } } };
  });
  await page.addScriptTag({ url: scriptURL });
  await page.evaluate(() => window.__noTypeToggleTranslation());
  await page.waitForFunction(() => document.querySelector("notype-status")?.shadowRoot.textContent.includes("已翻译 5 / 5"));
  const checks = await page.evaluate(() => {
    const result = [];
    for (const selector of ["h1", "#body", "#credit", "#bio", "#aligned"]) {
      const source = document.querySelector(selector);
      const expected = getComputedStyle(selector === "#bio" ? source.querySelector("em") : source);
      const view = source.nextElementSibling;
      const actual = getComputedStyle(view.shadowRoot.querySelector("div"));
      for (const property of ["fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "color", "letterSpacing", "textAlign"]) {
        const expectedValue = property === "fontFamily"
          ? expected[property].replace(/(^|,\s*)serif(?=\s*(?:,|$))/gi, '$1"Songti SC", serif') : expected[property];
        if (actual[property] !== expectedValue) throw new Error(`${selector} ${property}: ${actual[property]} != ${expectedValue}`);
      }
      if (actual.borderLeftWidth !== "0px" || actual.paddingLeft !== "0px" || actual.opacity !== "1") {
        throw new Error(`${selector}: translation decoration still present`);
      }
      result.push({selector, font:actual.fontFamily, size:actual.fontSize, weight:actual.fontWeight, style:actual.fontStyle});
    }
    return result;
  });
  await page.screenshot({ path: "dist/browser-typography.png", fullPage: true });
  return { result: "PASS: heading, body, sans-serif, full-paragraph italic, partial bold and alignment", checks };
}
