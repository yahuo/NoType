# NoType Release Guide

这份文档对应 `NoType` 当前默认采用的分发路径：`不加入付费 Apple Developer Program，但仍提供实验性二进制下载`。

1. 使用现有本机构建链路生成 `NoType.app`
2. 打包 `.zip`、`.dmg` 和 `SHA256SUMS.txt`
3. 从本机上传签名后的产物到 GitHub Release；GitHub Actions 只做 CI 验证
4. 官网下载按钮指向 GitHub Releases
5. 在官网和 Release 文案里明确标注“未 notarize，需要手动放行”

## 当前分发定位

- 这不是正式 notarized release，而是 `experimental build`
- 适合已经知道如何在 macOS 上手动放行未 notarize app 的用户
- 不适合完全没有开发经验的普通终端用户
- 如果你后面愿意加入付费 Apple Developer Program，可以再升级到 `Developer ID + notarization` 路径

## 前置条件

- 已安装 Xcode command line tools
- 当前机器至少能用 `Apple Development` 或 ad-hoc 方式签名
- 建议先完成一次本地功能验证：

```bash
swift test --no-parallel
node scripts/test_neo_media.mjs
make build
open dist/NoType.app
```

## 1. 构建实验性发布产物

仓库已经提供了打包脚本：

发布前同步 `packaging/Info.plist`、`NoType.xcodeproj/project.pbxproj` 和 `scripts/generate_xcodeproj.rb` 中的版本号与构建号。当前版本为 `2.0.0`，构建号为 `2`。`NOTYPE_VERSION` 只影响产物文件名，不能代替包内版本更新。

```bash
make package
```

它会输出：

- `dist/release/NoType-<version>-macOS.zip`
- `dist/release/NoType-<version>-macOS.dmg`
- `dist/release/SHA256SUMS.txt`

`.github/workflows/ci.yml` 在 `push`、`pull_request`、`workflow_dispatch` 时运行测试和打包检查，只保存 CI artifact。打 `v*` tag 不会触发云端发布，GitHub Release 使用本机产物。

如果你想手动指定当前机器上的签名证书：

```bash
NOTYPE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make package
```

## 2. 本地验证

在上传 Release 前，至少做一次基础校验：

```bash
codesign --verify --deep --strict dist/NoType.app
(cd dist/release && shasum -a 256 -c SHA256SUMS.txt)
```

如果你要模拟普通用户下载安装路径，建议再手动检查一次：

1. 双击 `.dmg`
2. 将 `NoType.app` 拖入 `/Applications`
3. 首次启动时，预期 macOS 会拦截并提示应用无法验证
4. 进入 `系统设置 -> 隐私与安全性`，选择“仍要打开”，或在 Finder 中对应用执行 `Open`
5. 完成 `Microphone`、`Accessibility` 授权；Neo 离线唤醒还需要 `Speech Recognition` 权限
6. 验证听写、文本注入、翻译及所选语音服务；使用 Neo 时检查唤醒、对话打断和结束会话

## 3. GitHub Releases

建议每次发布都带上这三类文件：

- `NoType-<version>-macOS.dmg`
- `NoType-<version>-macOS.zip`
- `SHA256SUMS.txt`

Release 文案至少写清楚：

- 适用系统：`macOS 14+`，本机发布包为 Apple Silicon（arm64）
- 这是 `experimental build`，未经过 Apple notarization
- 首次打开可能会被 Gatekeeper 拦截，需要手动放行
- 首次启动需要授权 `Microphone` 和 `Accessibility`
- Codex 听写、AI Rewrite 和翻译复用本机 Codex 登录；Doubao 语音需要自行配置凭证
- Neo 需要本机已安装并登录 Codex，以及语音识别权限

测试和本机打包通过后，提交版本变更、推送代码和 tag，再上传明确命名的本机产物。不要使用 `dist/release/*`，该目录可能保留旧版本：

```bash
git push origin master
git tag -a v2.0.0 -m 'NoType 2.0.0'
git push origin v2.0.0
gh release create v2.0.0 \
  dist/release/NoType-2.0.0-macOS.zip \
  dist/release/NoType-2.0.0-macOS.dmg \
  dist/release/SHA256SUMS.txt \
  --verify-tag --title 'NoType 2.0.0' --notes-file /path/to/release-notes.md
```

发布后重新下载附件，核对 SHA256、包内版本、签名和启动情况。构建通过或签名有效不代表已完成真人麦克风与目标应用操作验收。

## 4. 官网下载链接

官网不要直接把二进制托管在 Vercel 上，推荐做法是：

- 官网和文档部署到 Vercel
- 下载按钮指向 GitHub Releases
- 最简单的入口直接用：

```text
https://github.com/yahuo/NoType/releases/latest
```

## 5. 如果以后要升级到正式官网分发

等你后面加入付费 Apple Developer Program 后，再补下面两步：

1. `Developer ID Application`
2. `notarytool` notarization

那时可以直接使用仓库里现成的 `make notarize` 流程。
