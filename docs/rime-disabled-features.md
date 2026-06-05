# Rime Disabled Features

This document tracks Rime features that are temporarily disabled for the iOS keyboard extension. The current priority is to avoid keyboard-switch crashes caused by large grammar assets, LevelDB/userdb access, and frequent extension-side disk writes.

## Disabled Features

| Feature | Config changed | Reason | User impact | Restore notes |
| --- | --- | --- | --- | --- |
| Grammar language model | Removed `wanxiang-lts-zh-hans.gram`, removed `grammar:` from `wanxiang.schema.yaml` and `wanxiang_t9.schema.yaml`, removed grammar fields from `rime-shared-manifest.json` | The grammar asset was about 235 MB and pushed the keyboard extension into memory pressure | Sentence ranking is less model-driven | Restore the `.gram` file, add the `grammar:` blocks back, re-add manifest file entry and optional grammar metadata, then test repeated keyboard switching on device |
| Prediction | Removed `prediction` switch and `wanxiang.user_predict` processor/translator/filter entries | `user_predict.lua` opens LevelDB and keeps prediction state | No post-commit prediction candidates or context reorder from the prediction module | Re-add the switch and three engine entries, restore the `user_predict:` block, then verify LevelDB closes cleanly across keyboard switches |
| Input statistics | Removed `wanxiang.input_statistics` translator and `input_stats:` config | `input_statistics.lua` opens a LevelDB database under `lua/stats` | `/tj`, `/rtj`, `/ztj`, `/ytj`, `/ntj`, `/htj` statistics commands are unavailable | Re-add the translator and config block after confirming userdb lifetime and memory behavior |
| User dictionary learning | Set `translator/enable_user_dict=false`, `enable_encoder=false`, `encode_commit_history=false`, `core_word_length=0`, `max_word_length=0` | User learning creates and updates Rime userdb files in the keyboard extension | Candidate order no longer learns from typed history | Restore one setting at a time, starting with `enable_user_dict`, and run switch-stability tests after each change |
| Auto phrase and custom word creation | Removed `wanxiang.auto_phrase` filter and removed `add_user_dict` / `user_dict_set` engine usage | Auto phrase depends on user-dictionary behavior and writes learned entries | No automatic phrase creation from selected candidates | Restore after user dictionary learning is stable |
| Manual candidate ordering | Removed `wanxiang.super_sequence` processor/filter and `super_sequence:` config | `super_sequence.lua` opens LevelDB under `lua/sequence` | Keyboard shortcuts for manual candidate ordering are unavailable | Restore the processor/filter/config together and verify no LevelDB locks remain on keyboard dismissal |
| Super tips | Removed `super_tips` switch, processor, and config | `super_tips.lua` opens LevelDB-backed tips data | Inline prompt tips for emoji, symbols, chemistry, and related hints are unavailable | Restore the switch/processor/config and test deploy memory before enabling in release builds |
| Super replacer | Removed `wanxiang.super_replacer` filter and config | `super_replacer.lua` opens LevelDB-backed replacement data | Emoji append, Chinese-English append, abbreviation injection, and replacement-chain behavior from this module are unavailable | Restore the filter/config after memory usage is measured on device |
| Wanxiang Lua enhancement chain | Added and selected `wanxiang_ios.schema.yaml` by default. It does not load Lua processors/translators/filters such as `wanxiang.super_processor`, `partial_commit`, `key_binder`, `version_display`, `set_schema`, `shijian`, `unicode`, `number_translator`, `super_calculator`, `super_lookup`, `super_english`, `charset_filter`, `super_comment_preedit`, or `super_filter` | Isolates possible empty-candidate, deployment-failure, and keyboard-extension resource-pressure issues from the Lua enhancement chain | `/wx`, `/zrm`, date/time, uppercase number conversion, calculator, Unicode, English formatting, charset filtering, and super comment/preedit features are unavailable | Restore one Lua component at a time, starting with translators; after each change verify deployment, pinyin candidates, and repeated keyboard switching on device |
| Lua/octagram deployer modules | Reduced native deployer modules from `deployer,lua,octagram` to `deployer` | `wanxiang_ios` does not depend on Lua or grammar, so deployment does not need the extra modules | Basic pinyin candidates are unaffected; schemas that depend on Lua or grammar cannot be deployed directly | When restoring Lua or grammar features, add the native deployer modules back and test deployment memory on device |
| Rime debug file logging | `RimeDebugLogger.isEnabled=false` | Per-key file logging adds disk writes inside the keyboard extension | `RimeDebug/rime-debug.log` and Rime-specific JSONL entries are not written | Set `isEnabled=true` only for short diagnostic builds |

## Still Enabled

Basic Rime input remains enabled: `wanxiang_ios` full pinyin schema selection, standard candidates, punctuation, reverse lookup, English table candidates, and custom phrases.

## Re-enable Checklist

1. Restore one feature at a time.
2. Recalculate `rime-shared-manifest.json` bytes and SHA values for every changed RimeShared file.
3. Build the app and confirm the keyboard extension package contains only the expected resources.
4. On a real device, switch to and away from the keyboard at least 20 times.
5. Check for new `0xDEAD10CC` or LevelDB-related crash logs before restoring the next feature.
