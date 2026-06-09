# Rime Grammar 语言模型集成方案

## 结论

Grammar 语言模型可以“继承”到当前万象方案里，但它不是 Swift 侧的继承，而是 Rime schema 层的配置继承/补丁叠加：把 `grammar:` 配置恢复到目标 schema，让 `script_translator` 在部署时生成带语言模型排序能力的产物。

当前项目为了 iOS 键盘扩展稳定性，已把 Grammar 作为禁用项处理。原因是 `wanxiang-lts-zh-hans.gram` 约 235 MB，键盘扩展启动、部署和切换键盘时容易触发内存压力。因此建议不要直接在运行时启用完整 Grammar，而是走“主 App 或构建阶段预部署 + 键盘扩展只加载 build 产物”的方案。

当前仓库还没有 `SimpaninKeyboard/RimeShared/wanxiang-lts-zh-hans.gram`，所以现在只能先接好校验、预部署和配置方案；真正启用前必须先补齐模型文件。

## “继承”的可行方式

Rime 没有 Swift/面向对象意义上的继承，但有三种等价集成方式：

- **schema 直接配置**：在 `wanxiang.schema.yaml` 中直接加入 `grammar:`，最直接，但会影响默认方案。
- **custom patch 叠加**：用 `wanxiang.custom.yaml` 给 `wanxiang.schema.yaml` 打补丁，适合本地或灰度启用。
- **独立 schema 灰度**：新增 `wanxiang_grammar.schema.yaml`，复制/继承万象配置后只在新 schema 上打开 Grammar，默认仍保留稳定方案。

推荐顺序是：先用独立 schema 或 custom patch 验证，再决定是否合入默认 `wanxiang`。

## 推荐路线

### 方案 A：轻量方案保持现状

适合优先保证键盘稳定、候选可用、切换不崩溃的版本。

- 继续使用 `wanxiang_ios.schema.yaml` 或当前稳定 schema。
- 不打包 `wanxiang-lts-zh-hans.gram`。
- 不在 native deployer 中启用 `octagram` 模块。
- 优点是包体和内存压力最低；缺点是句子排序不使用语言模型强化。

### 方案 B：完整万象 Grammar，构建期预部署

适合想恢复完整万象句子排序，但能接受包体增大和真机压测成本的版本。

1. 用带 `librime-octagram` 的 librime 构建产物：
   ```bash
   ENABLE_WANXIANG_PLUGINS=1 bash Scripts/build-librime-ios.sh --build-iphoneos
   bash Scripts/build-librime-ios.sh --install-vendor
   ```
2. 恢复 Grammar 资源：把 `wanxiang-lts-zh-hans.gram` 放入 `SimpaninKeyboard/RimeShared/`。
3. 在目标 schema 中恢复 Grammar 配置，例如 `wanxiang.schema.yaml` 的 `translator:` 前：
   ```yaml
   grammar:
     language: wanxiang-lts-zh-hans
     collocation_max_length: 5
     collocation_min_length: 2
   ```
4. 如果不想直接改 schema，可用 patch 叠加：
   ```yaml
   # wanxiang.custom.yaml
   patch:
     grammar:
       language: wanxiang-lts-zh-hans
       collocation_max_length: 5
       collocation_min_length: 2
     translator/contextual_suggestions: true
   ```
5. 用桌面端 `rime_deployer` 预生成 build 产物：
   ```bash
   REQUIRE_GRAMMAR=1 SCHEMA_ID=wanxiang TABLE_NAME=wanxiang bash Scripts/prebuild-rime-shared.sh
   ```
6. 重新打包 App，并确认 `SimpaninKeyboard/RimeShared/build/` 已包含目标 schema 的 `.schema.yaml`、`.prism.bin`、`.table.bin` 等产物；`.gram` 本体保留在 `SimpaninKeyboard/RimeShared/` 根目录并进入 manifest。
7. 真机反复切换键盘测试，重点观察内存峰值、首次初始化耗时和是否出现 `0xDEAD10CC`。

### 方案 C：折中灰度方案

适合逐步验证 Grammar 是否可接受。

- 保留 `wanxiang_ios` 作为默认稳定方案。
- 新增一个单独 schema，例如 `wanxiang_grammar.schema.yaml`，继承/复制 `wanxiang`，只在这个 schema 上启用 `grammar:`。
- Native 默认仍选择稳定 schema；通过调试构建或用户开关切换到 Grammar schema。
- 这样即使 Grammar 方案不稳定，也不会影响默认输入体验。

## Native 侧启用点

如果键盘扩展需要在设备内执行部署，而不是只加载预编译 `build/`，需要同步恢复 deployer 模块：

```objc
const char *deployerModules[] = {"deployer", "octagram", nullptr};
```

如果 schema 同时依赖 Lua 增强链路，则需要：

```objc
const char *deployerModules[] = {"deployer", "lua", "octagram", nullptr};
```

不建议在键盘扩展内首次部署完整 Grammar。更稳妥的做法是构建期或主 App 预部署，键盘扩展只读取已经生成好的 `build/`。

## Manifest 和资源要求

- `rime-shared-manifest.json` 需要包含 `.gram` 文件条目。
- 如果使用独立下载包，可以恢复 `grammarAssetName` 和 `grammarAssetSHA256` 元数据。
- 每次修改 `RimeShared` 后，都要重新运行 `Scripts/prebuild-rime-shared.sh` 更新 manifest。
- 如果 schema id 从 `wanxiang` 改成 `wanxiang_ios` 或新建 `wanxiang_grammar`，需要同步 native 选择的 schema id。

## 验收标准

- `REQUIRE_WANXIANG_GRAMMAR=1 bash Scripts/check-rime-vendor.sh` 通过，并能识别 `librime.a` 中的 `octagram`/`grammar` 插件符号和 `.gram` 资源。
- `REQUIRE_GRAMMAR=1 bash Scripts/prebuild-rime-shared.sh` 能生成完整 build 产物，并把 `.gram` 资源写入 manifest。
- 真机上连续切入/切出键盘至少 20 次不崩溃。
- 拼音长句候选排序相较无 Grammar 有明显改善。
- App 包体和键盘扩展内存峰值在可接受范围内。

## 风险

- 完整 Grammar 资源会显著增大包体。
- 键盘扩展内存预算低，完整语言模型可能导致初始化或切换键盘时被系统杀掉。
- 如果在键盘扩展内执行部署，部署阶段会同时消耗 CPU、内存和磁盘 IO，风险高于预部署方案。