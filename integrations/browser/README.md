# NoType 网页双语翻译（首版）

macOS 上的 Chrome / Edge 扩展。点击工具栏按钮，优先翻译视口附近的外文段落，以小批次请求并在原文下流式显示中文；滚动时继续处理已识别的段落。再次点击或点击右下角“关闭”，取消翻译并移除译文。

## 复用的通道

```text
网页段落 → 扩展后台 → Native Messaging 连接程序
        → NoType 已有 Unix socket → AIRewriteService.translateBrowserBatch（复用现有模型请求方法）
        → 原文下方插入纯文本译文
```

复用 NoType 当前登录态、模型请求方法和阅读型翻译超时；网页批次使用带段落 ID 的翻译提示词。当前网页模型仍为 `gpt-5.6-luna`，推理强度 `none`。扩展不保存凭据，也不监听 HTTP 端口。网页文本会通过 NoType 发送给当前翻译服务。浏览器仅在你点击按钮后读取当前标签页；连接程序只允许注册的扩展 ID 调用。

## 安装与使用

需要 macOS、Python 3、Chrome 或 Edge，以及包含 `translate_chinese_batch` bridge 方法的新版 NoType。升级到 0.2.1 时需同步更新 NoType、运行一次连接程序安装命令，并在扩展管理页重新加载扩展、刷新网页。0.2.2 仅调整译文排版，已安装 0.2.1 配套程序时，只需重新加载扩展并刷新网页。

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
- 点击时识别已有段落，优先处理视口与上下 300px 内的内容，滚动到附近时继续翻译；不自动识别之后新增的 DOM 或 SPA 新内容。点击时隐藏的段落（含 opacity:0 的滚动显现内容）不进入候选队列，显现后需关闭并重新开始翻译。
- 优先选择不包含其他段落的块。复杂容器中直接嵌入的零散文字可能被跳过；不支持 iframe、Shadow DOM、图片、PDF、视频字幕和浏览器内部页面。
- 译文跟随原段落的字体列表、字号、字重、行高、颜色和对齐方式；整段内联斜体/粗体同样保留。取消竖线、缩进和额外透明度。衬线字体列表补入 macOS 宋体（Songti SC）作为中文回退，其余中文缺字按原字体列表回退；段内局部格式暂不映射。
- 每批最多 4 段、总计 6000 个 UTF-16 字符；长段单独请求，上限 12000 字符。每次只有一个批次执行，复用页面会话的连接程序及其到 NoType 的长连接。全部段落完成或跳过后自动释放连接，保留已显示译文；尚有离屏段落等待滚动时继续复用连接。段落 ID 校验通过后确认结果；失败会移除当前批次的临时译文，之前成功批次保留。
- 关闭会断开页面端口；连接程序检测到浏览器管道关闭后断开 socket，NoType 取消当前任务。应用退出也会关闭长连接。断线/超时不自动重发当前批次；之前成功批次保留，用户重试会新建连接。取消清理期间或其他功能正在使用通道时，仍可能短暂返回 busy；本轮选择显示错误并停止，不自动重试，也不支持多个标签页同时翻译。
- 不包含跨页面缓存、自动翻译、付费接口配置或商店发布。

## 本地验证

```sh
swift test
python3 -m unittest discover -s integrations/browser/tests -v
node --test integrations/browser/tests/background.test.cjs
```

浏览器 DOM 回归脚本覆盖翻译交互、排版和段落边界，使用真实浏览器执行，但翻译回复由测试桩提供，不会请求真实模型：

```sh
python3 -m http.server 18765 --bind 127.0.0.1 --directory integrations/browser
# 在另一个终端执行（需要已安装 playwright-cli）：
playwright-cli -s=notype-browser open http://127.0.0.1:18765/tests/fixture.html --headed
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/browser-check.js
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/typography-check.js
playwright-cli -s=notype-browser run-code --filename integrations/browser/tests/paragraph-check.js
playwright-cli -s=notype-browser close
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
