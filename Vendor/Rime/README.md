# Vendor/Rime

此目录预留给后续 iOS 版 librime 依赖。

当前状态：目录结构已预留，但尚未提交真实 `rime_api.h`、`librime.a` 或 `Rime.xcframework`。因此 `SimpaninKeyboard/RimeBridge.swift` 仍保持占位实现，运行时会回退到现有 Swift 拼音引擎。

建议结构：

```text
Vendor/Rime/
  include/
    rime_api.h
  lib/
    librime.a
  # 或者：
  Rime.xcframework/
```

可用以下脚本检查本地 vendor 产物是否满足阶段 1 的最低要求：

```bash
bash Scripts/check-rime-vendor.sh
```

如需从源码路线准备本地构建工作区，可先运行：

```bash
bash Scripts/build-librime-ios.sh --check
bash Scripts/build-librime-ios.sh --prepare
```

当前构建脚本采用分阶段策略：默认只检查环境；`--prepare` 会创建 `build/rime-ios/` 工作区并拉取 librime 源码；真实依赖编译完成后再把最终产物复制回 `Vendor/Rime`。

脚本会检查：

- `Vendor/Rime/include/rime_api.h` 是否存在；
- `Vendor/Rime/lib/librime.a` 是否存在并包含 `arm64` 架构；
- 或者 `Vendor/Rime/Rime.xcframework` 是否存在并包含 iOS arm64 slice；
- 缺失项和后续 Xcode 接入提示。

接入真实库之后需要继续完成：

1. 在 Xcode target 中配置 Header Search Paths / Library Search Paths 或直接添加 xcframework。
2. 如使用 C/Objective-C 包装层，新增 bridging header。
3. 在 `SimpaninKeyboard/RimeBridge.swift` 中替换当前占位实现。
4. 检查所有依赖库是否可用于 App Extension。
5. 补齐第三方许可证声明。
