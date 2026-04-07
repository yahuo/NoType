# NoType Website

这个目录是 `NoType` 的零依赖静态官网，可以部署到：

- Vercel
- GitHub Pages
- 任何支持静态文件的网站托管服务

## 本地预览

在仓库根目录运行：

```bash
make site-serve
```

然后打开：

```text
http://localhost:4173
```

## Vercel 部署建议

最简单的方式是把 Vercel 项目的 Root Directory 设置成 `site`。

页面结构：

- `/` 首页
- `/download/` 下载页
- `/docs/` 使用文档
- `/privacy/` 隐私说明

## 下载策略

官网只放文档和下载入口，不直接托管安装包。

下载按钮默认跳转到：

```text
https://github.com/yahuo/NoType/releases/latest
```

这样版本管理、历史回滚和校验文件都可以继续走 GitHub Releases。当前建议把 Release 标成 `experimental build`，并明确说明它尚未经过 Apple notarization。
