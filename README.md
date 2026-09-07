# 贴伴（PastePal）

macOS 菜单栏剪贴板工具，以底部横向卡片浏览和取回文字、链接、富文本、图片及 Finder 文件引用。支持分组、搜索、区域与窗口截屏、标注、贴图和美化保存。

仅支持 Mac，历史与设置保存在本机，无账号、订阅或云同步。独立网页链接会直接请求目标站点补全标题和预览。当前版本 0.1.0，最低 macOS 15；已有 Apple Silicon 本地构建，尚未公证或公开分发。

## 快速开始

在仓库根目录执行，需要完整 Xcode、可用的开发签名身份，首次构建需联网下载依赖：

```sh
./scripts/build-app.sh
open "build/PastePal Preview.app"
```

默认生成本地调试包 `PastePal Preview.app`；正式包使用 `./scripts/build-app.sh release`，输出 `build/PastePal.app`。签名配置与测试命令见[开发指南](docs/development/README.md)。

首次启动按引导授予辅助功能权限，之后的复制才会归档。默认 **⌘⇧V** 打开历史，回车或双击直接粘贴；截图在设置中单独启用，默认 **⌘⇧A**，另需屏幕录制权限。Preview 与正式包共用数据和应用身份，同一时间只运行一个实例。

## 文档

- [文档索引](docs/README.md)：按使用与维护任务查阅。
- [使用指南](docs/使用指南.md)：快捷键、分组、保留规则及截图操作。
- [开发指南](docs/development/README.md)：构建、签名、测试、GitHub Release 及资源维护。
- [架构与数据](docs/development/架构与数据.md)：模块职责、数据流程及已知限制。
- [验收清单](docs/development/验收清单.md)：交付前需要检查的行为。
- [官网维护](website/README.md)：静态页面预览与 GitHub → Vercel 自动部署。

快捷键依赖 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)，其 MIT 许可证保留在应用资源中。
