# Simpanin Keyboard Rime / 雾凇 / 万象迁移实施计划

本文档记录把当前 Swift 内置拼音引擎迁移到 Rime 输入引擎，并接入雾凇拼音、万象模型相关资源的分阶段方案。当前工程已切到 Rime-only：不再编译、打包或运行 Swift 内置拼音引擎。

## 目标

- 使用 `RimeBridge` / `RimeInputEngine` 作为 Swift 与 librime 之间的适配层。
- 为 `RimeShared` schema/opencc/dict 等资源和 `Vendor/Rime` 头文件、静态库预留标准目录。
- 候选生成来源固定为 Rime，不提供 Swift 拼音回退。

## 当前检查结论（2026-06-04）

- Rime vendor 文件已放入并链接到键盘扩展 target。
- Objective-C++ 桥接层、Swift Rime facade、RimeShared 资源部署路径已接入。
- 旧 Swift 拼音引擎、TSV/IDX 词库资源、主 App 输入引擎切换入口已移除。
- Rime 初始化失败时只显示 Rime 失败信息，不回退到其他输入引擎。

## 非目标

- 不再维护 Swift 内置拼音回退路径。
- 不再打包 `PinyinLexicon.*` / `PinyinAssociations.*` 词库资源。

## 阶段 0：安全骨架（当前阶段）

1. 复制原项目到 `I:\个人项目\aTool-ios-rime`，避免直接影响原项目。
2. 新增 `SimpaninKeyboard/RimeBridge.swift`：集中管理 Rime 生命周期、部署目录、候选查询接口。
3. 新增 `SimpaninKeyboard/RimeInputEngine.swift`：对齐键盘输入接口，并在 Rime 不可用时暴露诊断信息。
4. 新增 `SimpaninKeyboard/RimeShared/README.md`：说明 schema、词典、OpenCC 等资源放置规则。
5. 新增 `Vendor/Rime/README.md`：说明后续 librime 头文件、库文件放置规则。
6. 修改 Xcode 工程，将新增 Swift 文件加入 `SimpaninKeyboard` target。

验收标准：

- 新增文件能被 Xcode 识别并参与键盘扩展编译。
- 缺少或初始化失败时能显示 Rime 诊断信息。

## 阶段 1：准备 iOS 版 librime

当前执行状态：本地 vendor 文件已放入并用于键盘扩展链接。项目包含 `Vendor/Rime/include/` 与 `Vendor/Rime/lib/` 目录，并新增 `Scripts/check-rime-vendor.sh` 用于验证 iOS 版 librime 产物。

构建准备状态：已新增 `Scripts/build-librime-ios.sh` 作为源码构建入口。该脚本采用分阶段策略，先检查本机 Xcode/iPhoneOS SDK/CMake/Ninja/autotools 等环境，再创建 `build/rime-ios/` 工作区并拉取 librime 源码。当前本机已检测到 Xcode 与 iPhoneOS SDK，但缺少 `cmake`、`ninja`、`autoconf`、`automake`、`libtoolize/glibtoolize`，需要先安装这些构建工具后再继续源码编译。

1. 选定构建方式：源码交叉编译、预编译 xcframework，或静态库聚合。
2. 目标产物建议放置为：
   - `Vendor/Rime/include/rime_api.h`
   - `Vendor/Rime/lib/librime.a` 或 `Vendor/Rime/Rime.xcframework`
3. 确认依赖库：Boost、yaml-cpp、glog、marisa、opencc、leveldb 等是否已静态合入。
4. 确认架构：`arm64-iphoneos`，如需模拟器再补 `arm64/x86_64-iphonesimulator`。
5. 确认 App Extension 安全性：不得调用 extension 不允许的 API。

本阶段新增检查入口：

```bash
bash Scripts/check-rime-vendor.sh
```

本阶段新增构建入口：

```bash
bash Scripts/build-librime-ios.sh --check
bash Scripts/build-librime-ios.sh --prepare
```

该脚本只做本地文件与架构检查，不修改 Xcode 工程。

验收标准：

- librime 可被一个最小 iOS target 链接通过。
- 能初始化、部署 schema，并完成一次简单候选查询。

## 阶段 2：Objective-C/C 桥接层

1. 新增 C/Objective-C 包装层，隔离 Swift 与 `rime_api.h` 的直接交互。
2. 提供最小 API：
   - `initialize(sharedDataDir:userDataDir:)`
   - `createSession()` / `destroySession()`
   - `processKey(_:)`
   - `getComposition()`
   - `getCandidates()`
   - `selectCandidate(index:)`
   - `commit()` / `clear()`
3. 使用 `SimpaninKeyboard-Bridging-Header.h` 暴露包装接口给 Swift。
4. 在 `RimeBridge` 中接入真实实现。

验收标准：

- Swift 能稳定调用桥接层。
- Rime 初始化失败时能返回明确错误。

## 阶段 3：资源部署与万象接入

1. 将雾凇/万象 schema 资源放入 `RimeShared`。
2. 首次启动或版本变化时，将只读 bundle 资源复制到 App Group 或键盘容器可写目录。
3. 调用 Rime deploy，使 schema 可用。
4. 增加资源版本号，避免每次启动重复部署。
5. 如万象模型资源过大，评估：
   - 是否放在主 App bundle，由键盘按需读取/复制；
   - 是否使用 App Group；
   - 是否拆分下载或手动导入。

验收标准：

- 键盘扩展能加载目标 schema。
- 候选结果来自 Rime 资源而非旧 TSV 词库。

## 阶段 4：Rime-only UI 与输入行为

1. 在 `KeyboardViewController` 中把输入引擎抽象成协议，减少 UI 与具体引擎耦合。
2. 移除运行时输入引擎开关，固定使用 Rime。
3. 对齐行为：
   - 组合文本显示
   - 光标位置
   - 候选分页
   - 删除键
   - 空格提交
   - 回车/标点提交
   - 候选选择
4. 移除旧引擎回退，Rime 失败时显示诊断信息。

验收标准：

- 常规拼音输入路径可由 Rime 完成。
- Rime 初始化失败时显示明确诊断信息，不回退到旧引擎。

当前执行状态：已完成 Rime-only 切换。`KeyboardViewController` 中的候选刷新、删除、空格提交、回车/确认提交、候选选择等路径都通过 Rime facade 执行；主 App 设置页不再提供“输入引擎”开关。

## 阶段 5：优化与发布准备

1. 性能：初始化耗时、首候选耗时、内存占用。
2. 稳定性：App Extension 内存限制、后台切换、键盘重载。
3. 日志：Debug 详细日志、Release 降噪。
4. 许可证：补充 librime、雾凇、万象、OpenCC 等第三方声明。
5. 构建脚本：更新 TrollStore IPA 构建流程，确保资源和库文件打包完整。

验收标准：

- 真机长时间输入稳定。
- Release 包资源完整，许可证完整。

## 风险点

- librime iOS 交叉编译复杂，依赖链较长。
- 键盘扩展内存限制较严格，万象资源可能需要裁剪或懒加载。
- Rime 用户目录需要可写，bundle 内资源不能直接作为用户目录。
- App Group 配置和 entitlements 需要与签名环境一致。
- 候选分页、编码串编辑等行为与当前自研引擎差异较大，需要逐项适配。
