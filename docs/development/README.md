# 开发指南

[返回文档索引](../README.md)。所有命令均在仓库根目录执行。

## 环境与构建

需要 macOS 15 或更高版本、完整 Xcode 和有效的代码签名身份。Swift 包定义见 `Package.swift`，依赖版本以 `Package.resolved` 为准；首次解析依赖需要联网。

| 用途 | 命令 | 输出 |
| --- | --- | --- |
| 本地调试 | `./scripts/build-app.sh` | Debug 的 `build/PastePal Preview.app` |
| 性能检查 | `./scripts/build-app.sh preview release` | Release 的 `build/PastePal Preview.app` |
| 正式构建 | `./scripts/build-app.sh release` | Release 的 `build/PastePal.app` |

`debug` 是默认 Preview 构建的别名。两种应用共用 Bundle ID `local.jamie.PastePal` 和数据，同一时间只运行一个实例。目标路径的应用正在运行时，脚本保留候选包到 `build/validation/` 并返回状态 4；正常退出后再构建，不覆盖运行中的包。

脚本仅为自身进程选择 `/Applications/Xcode.app/Contents/Developer`，可用 `DEVELOPER_DIR` 覆盖，不更改全局 `xcode-select`。请通过项目脚本构建和测试，确保依赖资源补丁生效。

## 签名与依赖资源

默认签名身份为 `Apple Development: echojamieee@outlook.com (9JHY98AJMC)`，Team ID `9CBN5694A4`，指纹 `EDAF5540E35BBA649726925FC5E5B0176BB07AEB`。其他开发环境可通过 `PASTEPAL_CODESIGN_IDENTITY` 指定钥匙串中的有效身份；缺少身份或校验失败会停止打包，不回退到临时签名。

```sh
security find-identity -v -p codesigning
codesign --verify --deep --strict build/PastePal.app
codesign -dvv build/PastePal.app
```

开发证书签名不等于公证。私钥只留在钥匙串，不进入仓库；移动或更换签名后需在实际运行路径确认系统权限。

KeyboardShortcuts 锁定 2.4.0 / `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`。`prepare-dependencies.py` 核对锁文件和检出提交后，只修改本地化资源查找：优先读取应用 `Contents/Resources`，再回退官方 `Bundle.module`。它只接受原文或已应用补丁，避免覆盖未知修改；升级依赖必须复核补丁和独立位置的资源加载。MIT 许可证随应用保留。

## 测试与交付检查

```sh
./scripts/swift-env.sh test
./scripts/swift-env.sh test -c release
./scripts/smoke-test.sh
python3 scripts/verify-docs.py
```

`Tests/ClipboardCoreTests/` 检查持久化、恢复、保留策略与查询资源边界；`Tests/PastePalTests/` 检查应用交互、权限、截图及生命周期；各自的 `Support/` 集中提供临时数据库、独立剪贴板和样例数据辅助方法。

用例应能独立执行，并释放临时资源。优先覆盖数据安全、状态转换及已知回归；布局检查关注遮挡和溢出，不重复固定样式常量。开发期导图与机器相关的耗时、内存阈值不作为单元测试通过条件。

原生冒烟默认构建优化后的 Preview，用隔离样例渲染窗口并检查应用包资源，不监听通用剪贴板；可通过 `PASTEPAL_APP_PATH` 指定已有包。截图输出集中放在 `build/validation/`，不写入测试源码或文档目录。实机检查按[验收清单](验收清单.md)执行，测试代码或旧包通过不等于当前版本验收通过。

只读常驻采样使用 `scripts/sample-resident.py`：先确认目标应用 PID，再指定 `--pid`、`--seconds`、`--interval`、`--output`。输出放 `build/validation/`；采样在 PID 退出或复用时停止，输出路径必须尚不存在。

## 资源与版本管理

`resources/IconSources/` 保存选定图稿及来源清单；`Sources/PastePal/Resources/` 保存应用内资源。执行 `./scripts/build-icon-assets.sh` 重建图标，预览输出到 `build/validation/`，不回写文档目录。

源码、测试、现行文档、官网资源及 `Package.resolved` 纳入 Git；构建产物、依赖缓存、运行数据、日志、个人配置和私钥由 `.gitignore` 排除。文档不记录开发过程或逐次测试输出，维护规则见[文档索引](../README.md)。

## GitHub Release 自动发布

`.github/workflows/release.yml` 在推送 `vX.Y.Z` 标签时执行，也可手动输入已存在的标签。流程核对标签与 `resources/Info.plist` 版本 → Release 测试 → 临时证书导入 → 正式应用与 DMG → 上传资产 → 发布 Release。使用 `macos-15` 的 arm64 runner，只交付 Apple Silicon 版本。

证书机制与 QuotaPeek 一致：加密 P12 与密码分别存入仓库 Actions Secrets，发布作业临时导入，构建后清理。首次接入，在 GitHub 仓库 Settings → Secrets and variables → Actions 中配置：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | 含签名私钥的 P12 文件内容，以 Base64 编码为单行 |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | 导出 P12 时设置的非空密码 |
| Variable（可选） | `PASTEPAL_CODESIGN_IDENTITY` | 其他签名证书的 SHA-1 指纹；默认沿用上述身份 |

证书只导入 runner 临时钥匙串，导入文件权限为 `0600`，仅授权 `codesign` 使用私钥，导入后即删除 P12，并核对所需签名身份。成功、失败或取消均安排钥匙串清理；发布使用作业自身的 `GITHUB_TOKEN`，无需额外 PAT。证书准备与导入方式见 [GitHub 官方签名说明](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。证书私钥及密码不得写入仓库。

先更新 Info.plist 的短版本号和递增构建号，再提交对应源码、创建并推送同版本标签。工作流创建草稿、上传并核验资产后自动公开；已公开的同名 Release 拒绝覆盖，失败留下的草稿可重跑续传。发布资产为 `PastePal-X.Y.Z-arm64.dmg`、`SHA256SUMS.txt` 和源码提交清单；不包含 Preview，当前不执行公证。

例如 Info.plist 已更新为 `0.1.1`，且对应源码已经提交并推送后，执行：

```sh
git tag -a v0.1.1 -m "Release 0.1.1"
git push origin v0.1.1
```

本地可用 `./scripts/package-dmg.sh` 封装已有正式应用；默认读取 `build/PastePal.app`，也接受应用路径参数。输出已存在时停止，避免覆盖已交付的安装包。
