# NoType 网页双语翻译（首版）

macOS 上的 Chrome / Edge 扩展。点击工具栏按钮，将页面已加载的外文段落全部入队，优先翻译可见内容，并在原文下流式显示中文；两个工作槽位持续处理后续批次，无需滚动也能翻译离屏段落。再次点击或点击右下角“关闭”，取消翻译并移除译文。

## 复用的通道

```text
网页段落 → 扩展后台 → Native Messaging 连接程序
        → NoType 已有 Unix socket → AIRewriteService.translateBrowserBatch（复用现有模型请求方法）
        → 原文下方插入纯文本译文
```

复用 NoType 当前登录态、模型请求方法和阅读型翻译超时；网页批次使用带段落 ID 的翻译提示词。当前网页模型仍为 `gpt-5.6-luna`，推理强度 `none`。扩展不保存凭据，也不监听 HTTP 端口。网页文本会通过 NoType 发送给当前翻译服务。扩展在所有 HTTP / HTTPS 页及其框架中注册轻量消息监听器，点击按钮后才扫描当前标签页的段落并发送翻译；连接程序只允许注册的扩展 ID 调用。

## 安装与使用

需要 macOS、Python 3、Chrome / Edge 119 或更新版本，以及支持两个浏览器批次并发的新版 NoType。0.4.0 增加全页排队和全局两个工作槽位，需更新本地 NoType、重新加载扩展并刷新网页；已安装 0.3.3 的连接程序可以继续使用。0.4.1 增加流式刷新合并和失败段落重试，从 0.4.0 升级只需重新加载扩展并刷新网页。更早版本的连接程序需重新运行下方安装命令，以支持每批最多 12 条短文本。首次从 0.2.x 升级还需同意 iframe 所需的网站访问权限。

1. 在仓库根目录执行 `make install`，退出旧 NoType 后启动 `/Applications/NoType.app`。确保已有的中文选词翻译可以使用。
2. 打开 `chrome://extensions`（Edge 为 `edge://extensions`），开启开发者模式，选择“加载已解压的扩展程序”，选择本目录下的 **extension** 文件夹。
3. 复制扩展卡片上的 ID，在仓库根目录执行：

   ```sh
   python3 integrations/browser/install.py <扩展ID>
   ```

   安装程序将连接程序复制到 `~/Library/Application Support/NoType/Browser/`，并注册到当前用户的 Chrome / Edge；不需要管理员权限。若两个浏览器产生不同的 ID，分别执行一次。更新连接程序后需重新运行这条命令。

4. 打开普通 HTTP / HTTPS 网页，点击 NoType 扩展按钮。右下角会显示进度或连接错误。页面中的原文、链接、事件监听器保持原样，译文只作为新节点插入。

扩展目录改动后，在扩展管理页点击“重新加载”，并刷新之前使用过扩展的网页。

## 首版范围

- 支持段落、标题、简单列表、表格单元格和仅包含行内内容的 div；将段内链接、强调和行内代码作为上下文一起翻译。
- 跳过隐藏内容、导航、网站页头页尾（保留 article/main 内的文章 header）、输入框、可编辑区域、代码块和声明不翻译的内容。
- 点击时识别已有段落并全部入队，包括尚未阅读的离屏段落。排队优先级依次为视口内、上下 300px 附近、其余内容；滚动、缩放或切换标签页后更新排队优先级，不打断正在执行的批次。不自动识别之后新增的 DOM 或 SPA 新内容。点击时隐藏的段落（含 opacity:0 的滚动显现内容）不进入候选队列，显现后需关闭并重新开始翻译。
- 优先选择不包含其他段落的块。复杂容器中直接嵌入的零散文字可能被跳过；不支持 Shadow DOM、图片、PDF、视频字幕和浏览器内部页面。
- 支持同源、跨域、嵌套 iframe，以及由网页创建的 about:blank、srcdoc、blob/data 框架；不写死任何域名。翻译开启后，新加载或导航的子框架自动加入，主页面导航则停止。整页只在主页面显示一条进度提示（计数为主页面段落），iframe 内仅插入译文；主页面点击“关闭”会移除整页译文。需要允许扩展访问框架来源；浏览器禁止注入的页面仍无法翻译。iframe 内的 Canvas/图片文字同样不属于 DOM 文本。
- 译文跟随原段落的字体列表、字号、字重、行高、颜色和对齐方式；整段内联斜体/粗体同样保留。取消竖线、缩进和额外透明度。衬线字体列表补入 macOS 宋体（Songti SC）作为中文回退，其余中文缺字按原字体列表回退；段内局部格式暂不映射。
- 流式译文按浏览器绘制帧合并更新，跳过未变化的文字；最终结果立即确认，不等待绘制帧。关闭、失败或收到最终结果时清理对应的待绘制内容，避免旧的流式内容重新出现。
- 每条不超过 100 个 UTF-16 字符的短文本，每批最多 12 条（合计最多 1200 字符）；其他批次最多 4 段、总计 6000 字符；超过 6000 字符的长段单独请求，上限 12000 字符。同一标签页所有框架共享一个待译文本队列；完全相同的原文（含正在请求的原文）只请求一次，再按各框架的原始 ID 回填。已到达的文本可跨框架合批，仍遵守上述条数和字符上限；只让出一次事件循环收集消息，不增加固定等待窗口。
- 整个扩展的所有标签页、框架共享两个工作槽位，按段落优先级领取批次。一批等待时另一槽位继续处理；批次可以乱序返回，按请求与段落 ID 回填。每个槽位复用一条 Native Messaging 连接及一个 socket，连接内仍逐批请求。队列全部处理完后自动释放两条连接，保留已显示译文。模型超时、翻译失败或无效批次结果只影响对应段落，移除其临时译文，其余批次继续；收到翻译失败时立即释放该槽位连接，避免复用即将退出的连接程序；同一请求拆到不同模型批次时，仍分别保留成功与失败结果。
- 主页面统一显示失败段落数和“重试失败段落”按钮，覆盖正文与 iframe；本轮其余批次完成后可点击，悬停按钮可查看失败原因。点击后仅提交仍失败且原文未变化的段落，成功译文保留，重复文本继续共享请求。未点击时不会自动重发失败请求。重试状态保存在页面中，空闲扩展端口断开后仍可重新连接重试。页面进度始终只有一条；子框架移除时清除其失败计数。
- 移除或导航子框架会丢弃其排队请求与迟到结果；共享批次若还有其他框架等待则继续执行，否则释放该槽位。关闭整页翻译会立即断开该页所有框架端口及使用中的槽位；连接程序检测到浏览器管道关闭后断开 socket，NoType 取消对应任务。应用退出也会关闭长连接。NoType 不可连接、缺少登录态、busy 等通道错误仍停止当前标签页，并在主页面显示原因（包括主页面已完成后的 iframe 错误），其他标签页独立处理。NoType 最多同时执行两个浏览器批次，编辑器等其他桥接操作仍独占通道。
- 当前标签页翻译会话使用内存缓存，最多 512 条，原文加译文合计最多 524288 个 UTF-16 字符，超出时按写入顺序淘汰。缓存仅接受校验通过的完整译文；同一会话固定复用当前中文翻译通道。全部请求完成后释放本地连接，但缓存可供之后新框架使用；关闭翻译、主页面导航或关闭标签页会清空缓存，扩展后台被浏览器回收也可能丢失缓存。不写磁盘、不跨标签页共享。
- 不包含跨页面缓存、自动翻译、付费接口配置或商店发布。

## 本地验证

```sh
swift test
python3 -m unittest discover -s integrations/browser/tests -v
node --test integrations/browser/tests/*.test.cjs
```

浏览器 DOM 回归脚本覆盖翻译交互、排版和段落边界，使用真实浏览器执行，但翻译回复由测试桩提供，不会请求真实模型：

```sh
python3 -m http.server 18765 --bind 127.0.0.1 --directory integrations/browser
# 在另一个终端执行（需要已安装 playwright-cli）：
playwright-cli -s=notype-browser open http://127.0.0.1:18765/tests/fixture.html --headed
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/browser-check.js
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/typography-check.js
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/paragraph-check.js
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/render-check.js
playwright-cli -s=notype-browser close
```

## iframe 扩展回归

以下测试在独立 Chromium 测试配置中加载真实扩展，使用两个本地来源验证跨域、嵌套、空白、srcdoc、动态框架与全页取消，以及重复文本回填、新框架缓存命中、慢批次隔离和滚动优先级。仅替换 Native Messaging 为测试桩，不调用本地 NoType 或真实模型，不使用日常浏览器登录态：

```sh
# 保持上方 18765 HTTP 测试服务器运行
npx --package=playwright playwright install chromium
python3 integrations/browser/tests/prepare-iframe-test.py
playwright-cli -s=notype-frames open http://127.0.0.1:18765/tests/iframe-fixture.html --headed --persistent --config dist/iframe-tests/config.json
playwright-cli -s=notype-frames run-code --filename integrations/browser/tests/iframe-check.js
playwright-cli -s=notype-frames run-code --filename integrations/browser/tests/cache-check.js
playwright-cli -s=notype-frames run-code --filename integrations/browser/tests/batch-check.js
playwright-cli -s=notype-frames run-code --filename integrations/browser/tests/pool-check.js
playwright-cli -s=notype-frames run-code --filename integrations/browser/tests/retry-check.js
playwright-cli -s=notype-frames close
```

## 卸载连接程序

先在扩展管理页移除扩展。然后手动移除以下本集成专用文件即可，NoType 的其他通道不受影响：

- `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.opensource.notype.browser.json`
- `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.opensource.notype.browser.json`
- `~/Library/Application Support/NoType/Browser/`

协议参考：[Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)。浏览器消息使用本机字节序，NoType socket 使用大端长度前缀，连接程序负责转换。

## 模型测速

[本次测速与取舍](benchmark-results.md)记录真实模型和已安装本地通道的数据。`benchmark.py` 默认不会调用模型；明确执行以下命令才使用已有登录态发送请求（单段模式 9 次，批次模式 3 次）：

```sh
python3 integrations/browser/benchmark.py --live
python3 integrations/browser/benchmark.py --live --batch --output dist/model-benchmark/batch-models.json
```

测速文本是固定的合成样本，不读取实际网页、浏览历史或其他私有文档；认证只在内存中用于请求，不写入结果文件。

## 卡住时查看日志

连接程序日志：`~/Library/Logs/NoType/browser-bridge.log`。应用连接日志的查询命令见 [桥接诊断说明](../../docs/bridge.md#浏览器连接诊断)。两者通过请求 ID 对应；日志只保存计数、耗时和状态，不保存网页原文、译文或凭据。
