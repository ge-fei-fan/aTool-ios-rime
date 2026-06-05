# Rime 已禁用功能

本文档记录 iOS 键盘扩展中暂时禁用的 Rime 功能。当前优先级是避免因大型 grammar 资源、LevelDB/userdb 访问，以及键盘扩展内频繁磁盘写入导致的切换键盘崩溃。

## 已禁用功能

| 功能 | 配置变更 | 禁用原因 | 用户影响 | 恢复说明 |
| --- | --- | --- | --- | --- |
| Grammar 语言模型 | 删除 `wanxiang-lts-zh-hans.gram`，从 `wanxiang.schema.yaml` 和 `wanxiang_t9.schema.yaml` 删除 `grammar:` 配置，并从 `rime-shared-manifest.json` 删除 grammar 字段 | grammar 资源约 235 MB，会让键盘扩展进入内存压力状态 | 句子排序不再依赖语言模型强化 | 恢复 `.gram` 文件，重新加入 `grammar:` 配置块，在 manifest 中恢复文件条目和可选 grammar 元数据，然后在真机上反复切换键盘测试 |
| 预测联想 | 删除 `prediction` 开关，以及 `wanxiang.user_predict` 的 processor/translator/filter 引擎项 | `user_predict.lua` 会打开 LevelDB 并维护预测状态 | 上屏后的预测候选和预测模块的上下文调序不可用 | 重新加入开关和三个引擎项，恢复 `user_predict:` 配置块，然后确认切换键盘时 LevelDB 能干净关闭 |
| 输入统计 | 删除 `wanxiang.input_statistics` translator 和 `input_stats:` 配置 | `input_statistics.lua` 会打开 `lua/stats` 下的 LevelDB 数据库 | `/tj`、`/rtj`、`/ztj`、`/ytj`、`/ntj`、`/htj` 等统计命令不可用 | 在确认 userdb 生命周期和内存行为稳定后，重新加入 translator 和配置块 |
| 用户词学习 | 设置 `translator/enable_user_dict=false`、`enable_encoder=false`、`encode_commit_history=false`、`core_word_length=0`、`max_word_length=0` | 用户学习会在键盘扩展中创建并更新 Rime userdb 文件 | 候选排序不再根据输入历史自动学习 | 从 `enable_user_dict` 开始一次只恢复一个设置，每次恢复后都运行键盘切换稳定性测试 |
| 自动造词和自定义造词 | 删除 `wanxiang.auto_phrase` filter，并移除 `add_user_dict` / `user_dict_set` 的引擎使用 | 自动造词依赖用户词典行为，并会写入学习词条 | 不再从已选择候选自动造词 | 等用户词学习稳定后再恢复 |
| 手动候选排序 | 删除 `wanxiang.super_sequence` processor/filter 和 `super_sequence:` 配置 | `super_sequence.lua` 会打开 `lua/sequence` 下的 LevelDB | 手动调整候选顺序的快捷键不可用 | 同时恢复 processor、filter 和配置，并确认键盘退出后没有残留 LevelDB 锁 |
| Super tips | 删除 `super_tips` 开关、processor 和配置 | `super_tips.lua` 会打开 LevelDB 支撑的提示数据 | 表情、符号、化学式等内联提示不可用 | 恢复开关、processor 和配置；正式启用前先测试 deploy 阶段内存占用 |
| Super replacer | 删除 `wanxiang.super_replacer` filter 和配置 | `super_replacer.lua` 会打开 LevelDB 支撑的替换数据 | 表情追加、中英释义追加、简码插入和替换链路行为不可用 | 在真机测量内存占用后，再恢复 filter 和配置 |
| Wanxiang Lua 增强链路 | 新增并默认选择 `wanxiang_ios.schema.yaml`，不加载 `wanxiang.super_processor`、`partial_commit`、`key_binder`、`version_display`、`set_schema`、`shijian`、`unicode`、`number_translator`、`super_calculator`、`super_lookup`、`super_english`、`charset_filter`、`super_comment_preedit`、`super_filter` 等 Lua processor/translator/filter | 先排除 Lua 增强链路导致候选为空、部署失败或键盘扩展资源压力的可能 | `/wx`、`/zrm`、日期时间、数字金额大写、计算器、Unicode、英文格式化、字符集过滤、超级注释/preedit 等增强功能暂不可用 | 从 translator 开始一次只恢复一个 Lua 组件；每恢复一个组件都确认部署成功、拼音候选存在、反复切换键盘不崩溃 |
| Lua/octagram 部署模块 | native deployer 模块列表从 `deployer,lua,octagram` 收窄为 `deployer` | `wanxiang_ios` 不依赖 Lua 或 grammar，部署阶段无需加载额外模块 | 当前基础拼音候选不受影响；依赖 Lua 或 grammar 的方案不能直接部署使用 | 恢复 Lua 或 grammar 功能时，同步把 native deployer 模块加回并真机测试部署内存 |
| Rime 调试文件日志 | 设置 `RimeDebugLogger.isEnabled=false` | 每次按键写文件会增加键盘扩展内的磁盘写入 | 不再写入 `RimeDebug/rime-debug.log` 和 Rime 专用 JSONL 日志 | 仅在短期诊断构建中把 `isEnabled` 设回 `true` |

## 仍然启用的功能

基础 Rime 输入仍然启用：`wanxiang_ios` 全拼方案选择、标准候选、标点、反查、英文表候选和自定义短语。

## 重新启用检查清单

1. 一次只恢复一个功能。
2. 为每个变更过的 `RimeShared` 文件重新计算 `rime-shared-manifest.json` 中的 bytes 和 SHA 值。
3. 构建应用，并确认键盘扩展包只包含预期资源。
4. 在真机上至少连续切入和切出键盘 20 次。
5. 恢复下一个功能前，先确认没有新的 `0xDEAD10CC` 或 LevelDB 相关崩溃日志。
