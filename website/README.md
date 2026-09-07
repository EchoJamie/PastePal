# 官网维护

PastePal 的静态介绍页，无第三方运行依赖或后端，由轻量脚本生成发布目录，与应用共用 Git 仓库。导航、首屏和底部下载入口统一指向 [GitHub Releases](https://github.com/EchoJamie/PastePal/releases)，安装包以该页面实际发布的内容为准。

## 预览与发布

在仓库根目录执行：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

打开 `http://127.0.0.1:4173`。正式部署执行 `node website/build.mjs`，以 `website/dist/` 为发布目录；页面使用相对资源路径，可放域名根路径或子路径。Vercel 接入方式见下文。

## 内容与资源

文案以[使用指南](../docs/使用指南.md)及当前源码为准；版本和系统要求以 `Package.swift`、应用 Info.plist 为准。发布前同步签名、公证状态和真实下载地址。

`assets/` 保存独立部署所需的图标和展示图片。Logo 来源为 `resources/IconSources/` 的选定图稿；面板图片使用合成内容的 AppKit 渲染，不含真实剪贴板记录，发布前应核对当前界面。

本站不使用远程字体、分析脚本或第三方请求。改动后检查桌面与窄屏、浅深截图切换、图片加载、页内导航和控制台错误；运行 `node --check website/script.js` 检查脚本语法。

## 更新面板截图

在 macOS 运行 `./scripts/render-website-previews.sh`，从当前原生界面导出 2880 × 712 的浅深色 PNG。导出使用独立临时历史和示例内容，不启动监听或读取用户历史。逐张检查后将输出的 `panel-light.png`、`panel-dark.png` 替换到 `website/assets/`。

两张图保持相同尺寸、内容、选中项和滚动位置；网页使用固定比例，窄屏在截图区域内横向查看。不要用压力测试长文本或不同显示器宽度的图片混搭。

## GitHub → Vercel 自动部署

在 Vercel 导入本 GitHub 仓库，Root Directory 设为 `website`，Framework Preset 选 Other，Production Branch 设为 `main`。构建命令及输出目录由 `website/vercel.json` 管理：`node build.mjs` → `dist/`，无需安装依赖。构建只复制页面、样式、脚本和 `assets/`，不会发布维护文档。

连接后，推送或合并到 `main` 自动更新生产站点，其他分支及 PR 生成预览部署；无需在 GitHub 保存 Vercel Token。`.github/workflows/website.yml` 负责站点语法和构建检查，实际部署由 Vercel Git 集成完成。首次接入需要在 Vercel 授权访问目标仓库，配置自定义域名后沿用同一生产部署。

具体平台行为见 [Vercel GitHub 集成说明](https://vercel.com/docs/git/vercel-for-github)。本地可执行 `node website/build.mjs` 检查发布目录。连接项目之前，仓库中的配置不会自行创建 Vercel 项目或上线站点。

下载链接在构建时使用 `VERCEL_GIT_REPO_OWNER` 和 `VERCEL_GIT_REPO_SLUG` 生成，三个下载入口统一指向对应仓库的 Releases 页面；本地没有这些变量时使用 `EchoJamie/PastePal`。Vercel 项目需启用自动暴露系统环境变量，无需手动填写仓库地址或 Token，变量变更后需重新部署。参见 [Vercel 系统环境变量](https://vercel.com/docs/environment-variables/system-environment-variables)。
