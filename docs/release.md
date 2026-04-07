# NoType Release Guide

这份文档对应 `NoType` 当前默认采用的分发路径：`不加入付费 Apple Developer Program，但仍提供实验性二进制下载`。

1. 使用现有本机构建链路生成 `NoType.app`
2. 打包 `.zip`、`.dmg` 和 `SHA256SUMS.txt`
3. 通过 GitHub Actions 或本地命令打包
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
swift test
make build
open dist/NoType.app
```

## 1. 构建实验性发布产物

仓库已经提供了打包脚本：

```bash
make package
```

它会输出：

- `dist/release/NoType-<version>-macOS.zip`
- `dist/release/NoType-<version>-macOS.dmg`
- `dist/release/SHA256SUMS.txt`

仓库里的 GitHub Actions 也已经按同一条链路配置：

- `.github/workflows/ci.yml`：在 `push`、`pull_request`、`workflow_dispatch` 时跑 `swift test` 和 `make package`
- `.github/workflows/release.yml`：在打 `v*` tag 时构建并创建 GitHub Release

如果你想手动指定当前机器上的签名证书：

```bash
NOTYPE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make package
```

## 2. 本地验证

在上传 Release 前，至少做一次基础校验：

```bash
codesign --verify --deep --strict dist/NoType.app
```

如果你要模拟普通用户下载安装路径，建议再手动检查一次：

1. 双击 `.dmg`
2. 将 `NoType.app` 拖入 `/Applications`
3. 首次启动时，预期 macOS 会拦截并提示应用无法验证
4. 进入 `系统设置 -> 隐私与安全性`，选择“仍要打开”，或在 Finder 中对应用执行 `Open`
5. 完成 `Microphone`、`Accessibility` 授权
6. 验证 `Option + Space`、Doubao 转写、文本注入、AI Rewrite 开关

## 3. GitHub Releases

建议每次发布都带上这三类文件：

- `NoType-<version>-macOS.dmg`
- `NoType-<version>-macOS.zip`
- `SHA256SUMS.txt`

Release 文案至少写清楚：

- 适用系统：`macOS 14+`
- 这是 `experimental build`，未经过 Apple notarization
- 首次打开可能会被 Gatekeeper 拦截，需要手动放行
- 首次启动需要授权 `Microphone` 和 `Accessibility`
- 需要自行配置 Doubao 凭证
- 如果开启 `AI Rewrite`，还需要配置可用的 AI provider

如果你使用 GitHub Actions 自动发布，推荐的 tag 形式是：

```text
v1.0.0
```

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
