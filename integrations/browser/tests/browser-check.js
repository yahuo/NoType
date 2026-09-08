async (page) => {
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const inject = async () => { await page.addScriptTag({ url: page.url().replace(/\/tests\/.*$/, "/extension/content.js") + `?test=${Date.now()}` }); await page.evaluate(() => window.__noTypeToggleTranslation()); };
  await page.setViewportSize({ width: 1200, height: 1800 });
  await page.reload();
  await page.evaluate(() => {
    window.requests = [];
    window.ports = [];
    window.linkClicks = 0;
    document.querySelector("#first a").addEventListener("click", (event) => { event.preventDefault(); window.linkClicks++; });
    window.reply = (message, port) => port.receive({ id: message.id, ok: true, items: message.items.map(({id, text}) => ({id, text: `中文译文：${text}`})) });
    window.chrome = { runtime: { connect: () => {
      const port = {
        closed: false,
        onMessage: { addListener(fn) { port.receive = fn; } },
        onDisconnect: { addListener(fn) { port.disconnected = fn; } },
        disconnect() { if (!port.closed) { port.closed = true; port.disconnected?.(); } },
        postMessage(message) { if (message.type) return; window.requests.push(message); queueMicrotask(() => window.reply(message, port)); },
      };
      window.ports.push(port);
      return port;
    } } };
    window.originalHTML = document.querySelector("main").innerHTML;
  });
  await inject();
  await page.waitForFunction(() => document.querySelector("notype-status")?.shadowRoot.textContent.includes("已翻译 8 / 8"));
  const result = await page.evaluate(() => ({
    batches: window.requests.map((request) => request.items.length),
    requests: window.requests.flatMap((request) => request.items.map((item) => item.text)),
    count: document.querySelectorAll("notype-translation").length,
    first: document.querySelector("#first").nextElementSibling.tagName,
    cell: !!document.querySelector("#cell > notype-translation"),
    list: !!document.querySelector("#list-item > notype-translation"),
    ports: window.ports.length,
  }));
  check(result.count === 8 && result.batches.join(',') === '8', "Expected one batch of 8 short paragraphs");
  check(result.ports === 1, "Connection was not reused");
  check(await page.evaluate(() => window.ports[0].closed), "Completed page kept its native connection open");
  check(await page.evaluate(() => !document.querySelector("notype-status").shadowRoot.textContent.includes("翻译已停止")), "Intentional disconnect was treated as failure");
  check(result.requests[1] === "Browser extensions can read a page and preserve its layout.", "Inline nodes were not joined");
  check(result.requests[2].includes("textContent"), "Inline code context was lost");
  check(result.requests.at(-1) === "Visible text.", "Hidden text or button leaked");
  check(!result.requests.some((text) => /Private|Navigation|Footer|Hidden|codeBlock|Do not translate/.test(text)), "Excluded content was sent");
  check(result.first === "NOTYPE-TRANSLATION" && result.cell && result.list, "Translation placement invalid");
  await page.locator("#first a").click();
  check(await page.evaluate(() => window.linkClicks === 1), "Original click listener was lost");
  await inject();
  check(await page.evaluate(() => !document.querySelector("notype-translation,notype-status") &&
    document.querySelector("main").innerHTML === window.originalHTML && window.ports[0].closed), "Toggle did not restore DOM or close the stream");

  // Hold the final response: incomplete JSON strings must render safely during streaming.
  await page.evaluate(() => {
    window.requests = [];
    window.reply = (message, port) => { if (!window.held) window.held = {message, port}; };
  });
  await inject();
  await page.waitForFunction(() => !!window.held);
  check(await page.evaluate(() => document.querySelector("notype-status").shadowRoot.textContent.includes("等待模型响应")), "Missing waiting status");
  await page.evaluate(() => window.held.port.receive({id:window.held.message.id,ok:true, partial:true,
    text: '{"id":"p0","text":"第一段\\n路径 \\\\ 与引号 \\"测试\\"，Unicode \\u4f'}));
  await page.waitForFunction(() => document.querySelector("notype-translation")?.shadowRoot.querySelector("span").textContent === '第一段\n路径 \\ 与引号 "测试"，Unicode ');
  check(await page.evaluate(() => document.querySelector("notype-status").shadowRoot.textContent.includes("正在接收译文")), "Missing receiving status");
  await page.evaluate(() => {
    const heading = document.querySelector("h1");
    const original = heading.textContent;
    heading.textContent = "Temporary page change";
    window.held.port.receive({id:window.held.message.id,ok:true,partial:true,text:'{"id":"p0","text":"暂时译文'});
    heading.textContent = original;
    window.held.port.receive({id:window.held.message.id,ok:true,partial:true,text:'{"id":"p0","text":"恢复后的译文'});
  });
  await page.waitForFunction(() => document.querySelector("h1").nextElementSibling.shadowRoot?.textContent.includes("恢复后的译文"));
  await inject();
  await page.evaluate(() => window.held.port.receive({id:window.held.message.id,ok:true, items:window.held.message.items.map(({id})=>({id,text:"迟到译文"}))}));
  check(await page.evaluate(() => window.requests.length === 1 && !document.querySelector("notype-translation")), "Late result escaped cancellation");

  await page.evaluate(() => { window.held = null; });
  await inject();
  await page.waitForFunction(() => !!window.held);
  await page.evaluate(() => {
    document.querySelector("h1").textContent = "A changed heading";
    window.held.port.receive({id:window.held.message.id,ok:true, items:window.held.message.items.map(({id})=>({id,text:"译文"})).reverse()});
  });
  check(await page.evaluate(() => document.querySelector("h1").nextElementSibling.tagName !== "NOTYPE-TRANSLATION"), "Stale heading received old translation");
  await inject();

  // Invalid final output must not leave provisional translations on the page.
  await page.evaluate(() => { window.held = null; });
  await inject();
  await page.waitForFunction(() => !!window.held);
  await page.evaluate(() => {
    window.held.port.receive({id:window.held.message.id,ok:true,partial:true,text:'{"id":"p0","text":"暂时译文'});
    window.held.port.receive({id:window.held.message.id,ok:true,items:[{id:"wrong-id",text:"错误译文"}]});
  });
  check(await page.evaluate(() => !document.querySelector("notype-translation") &&
    document.querySelector("notype-status").shadowRoot.textContent.includes("ID 不匹配")), "Invalid final result was accepted");
  await inject();

  await page.evaluate(() => { window.reply = (message, port) => port.receive({ok:false,error:{message:"NoType busy"}}); });
  await inject();
  await page.waitForFunction(() => document.querySelector("notype-status")?.shadowRoot.textContent.includes("NoType busy"));
  await inject();

  // All loaded paragraphs translate without scrolling; HTML-like replies stay text.
  await page.evaluate(() => {
    const paragraph = document.createElement("p");
    paragraph.id = "far-away";
    paragraph.style.marginTop = "4000px";
    paragraph.textContent = "This distant paragraph should translate without scrolling.";
    document.querySelector("main").append(paragraph);
    window.requests = [];
    window.reply = (message, port) => port.receive({id:message.id,ok:true,items:message.items.map(({id})=>({id,text:'<img src=x onerror="window.injected=true">'}))});
  });
  await inject();
  await page.waitForFunction(() => document.querySelector("notype-status")?.shadowRoot.textContent.includes("已翻译 9 / 9"));
  check(await page.evaluate(() => window.requests.flatMap((r)=>r.items).some((item)=>item.text.includes("distant"))), "Off-screen text was not queued");
  check(await page.evaluate(() => window.ports.at(-1).closed), "Completed page kept its connection");
  await page.locator("#far-away").scrollIntoViewIfNeeded();
  await page.waitForFunction(() => document.querySelector("notype-status")?.shadowRoot.textContent.includes("已翻译 9 / 9"));
  check(await page.evaluate(() => !window.injected && !document.querySelector("notype-translation").shadowRoot.querySelector("img")), "Translation was interpreted as HTML");
  await inject();
  return "PASS: batching, port reuse, viewport priority, streaming/escapes, cancellation, stale source, ID validation, DOM restore, errors and HTML safety";
}
