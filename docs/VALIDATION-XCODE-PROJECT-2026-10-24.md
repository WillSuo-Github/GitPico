# 原生 Xcode 工程 — 2026-10-24

原项目是 Swift Package，已有可构建的 SwiftUI macOS app 源码和打包脚本，缺少独立 `.xcodeproj`。本轮新增真正的原生工程，没有复制源码到第二套目录，也没有替换成调用 SwiftPM 的 External Build Tool target。

## 使用

打开根目录 `GitPico.xcodeproj`，选择共享 Scheme `GitPico`、运行目标 `My Mac`，按 ⌘R。普通构建不需要先执行终端脚本，也不需要在另一台机器安装 XcodeGen。Swift/macOS 26 SDK 所需 Xcode 仍须正常安装。

- `GitPico`：原生 macOS Application target，链接并嵌入 `GitCore.framework`。
- `GitCore`：独立 Swift framework，继续使用 `Sources/GitCore`。
- `GitCoreTests`：原生无 App 宿主的 unit-test bundle。
- `GitPicoTests`：原生 App-hosted unit-test bundle，使用真实 GitPico 模块与测试宿主。
- Debug/Release、应用 Run/Profile/Archive 与两个 Test target 均接入共享 Scheme。本轮不做发布、公证或 Apple Developer 分发准备。

源码、测试均为 Xcode synchronized groups，新 Swift 文件自动纳入各自 target。`Package.swift` 保留；`project.yml` 与生成的 `.xcodeproj` 一起保存。只有调整 target、scheme 或构建设置时，维护者才需用已安装的 XcodeGen 2.46+ 执行 `./script/generate_project.sh`。参照 [XcodeGen specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)。

## 版本和本地签名

- App 营销版本固定为 `0.01`，最低部署目标 `26.0`。
- Build Phase 调用 `script/xcode_build_metadata.py`，复用现有 `build_number.py`，在 DerivedData 生成 Info.plist。每次 app build 使用上海时区 `yyyyMMddHHmmss`，参考上一次派生/已构建/暂存包的日期 Build 保持递增。
- 构建不修改 `project.pbxproj` 或源码 Info.plist 来更新版本。Settings 继续读取真实 bundle 值。
- 本地 Debug/Release 使用 ad-hoc 签名，无需指定 Apple Developer Team；Debug 可调试。App Sandbox 关闭，以支持原有 Git CLI 与仓库文件访问。这不是上架或正式分发的签名配置。
- `script/build_and_run.sh` 与 Codex Run action 改用原生 Xcode scheme，完整暂存 app 和内嵌 framework 到 `dist/GitPico.app`。原有 `--verify`、`--background`、`--build-only`、demo、LLDB 与日志入口保留。

## 后台测试

Run action 没有后台参数，供用户主动运行正常界面。Test action 独立设置 `--background-testing`，不继承 Run 参数；测试宿主在入口直接使用 prohibited activation policy，跳过 SwiftUI scenes、窗口恢复及实际应用启动加载。

新增原生宿主测试验证：确实收到后台参数、activation policy 为 prohibited、应用不活跃、可见窗口为 0，以及 bundle 中实际的版本/日期 Build/最低系统版本。SwiftPM 路径没有原生宿主，自动跳过该专用测试。

Scheme 允许隔离仓库用例在进程内并行，避免把原有大量 Git 测试逐个串行执行。本轮没有打开 Xcode、Tower、浏览器或 GitPico 的前台窗口；没有执行新前台鼠标/键盘/视觉验收。

## 结果

原生 `build-for-testing` 已编译 App、framework 与两个测试 bundle。最初串行 App 宿主运行 43 项通过，含窗口抑制/实际 bundle 值测试，见 [宿主日志](evidence/xcode-app-tests.log)。随后验证最终并行 scheme。

- 最终原生 scheme 测试 **239 项通过、0 失败、0 跳过**，196 项 GitCore 与 43 项 App 测试，合计 356.55 秒。见 [Xcode 原生日志](evidence/xcode-native-tests.log)、[xcresult 原生摘要](evidence/xcode-native-test-summary.json)。完整结果包位于本机 `.build/xcode/NativeTests.xcresult`。
- App/framework/两个测试 bundle 的编译见 [build-for-testing](evidence/xcode-build-for-testing.log)；项目 target/configuration/scheme 列表见 [工程列表](evidence/xcode-project-list.log)。
- 命令行主入口已使用同一原生 scheme 构建、签名并完整复制 bundle，见 [后台构建](evidence/xcode-background-build.log)。最终开发包 **0.01 / 20261024220803**，内嵌 GitCore.framework；全部文件及符号链接与 Xcode 原生产物一致。
- [bundle 元数据](evidence/xcode-bundle-metadata.json)和[构建前源码指纹](evidence/xcode-build-source-hashes.json)核对通过：构建期间工程、project.yml 和源码 plist 均未被改写。
- [后台报告](evidence/xcode-background-verification.json)：应用不活跃、可见窗口 0，前台仍为 Safari；没有打开或激活测试界面。
- [签名验证](evidence/xcode-signature.log)通过；[Mach-O 部署目标](evidence/xcode-deployment-target.log)为 macOS 26.0，SDK 27.0。实际测试主机 macOS 27.0.1 / Xcode 27.1，macOS 26 运行仍未验收。
- [SwiftPM 兼容编译](evidence/xcode-swiftpm-compatibility.log)通过；新增原生宿主专用测试按条件跳过，不把这条 skip 当作功能运行证明。实际宿主路径已由上述原生 239 项测试覆盖。
- 没有运行普通 Run action 的前台视觉验收，没有 Archive/Release 分发、公证或源码提交。用户自行 ⌘R 时会进入正常 app 界面。

