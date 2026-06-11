#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="$(mktemp -t simpanin-local-prediction-test)"
MAIN_PATH="$(mktemp -d -t simpanin-local-prediction-main)/main.swift"

cat > "$MAIN_PATH" <<'SWIFT'
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("fail: \(message)\n", stderr)
        exit(1)
    }
}

let testURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("simpanin-local-predict-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("local-predict.json")
let store = LocalPredictionStore(fileURL: testURL)
store.removeAllData()

_ = store.recordCommittedText("天气", now: Date(timeIntervalSince1970: 1_000))
_ = store.recordCommittedText("真好", now: Date(timeIntervalSince1970: 1_001))
_ = store.recordCommittedText("天气", now: Date(timeIntervalSince1970: 1_002))
_ = store.recordCommittedText("不错", now: Date(timeIntervalSince1970: 1_003))
let predictions = store.recordCommittedText("天气", now: Date(timeIntervalSince1970: 1_004))
require(predictions.first?.text == "不错", "expected latest prediction 不错 after 天气, got \(predictions.map(\.text))")
require(predictions.dropFirst().contains(where: { $0.text == "真好" }), "expected 真好 to remain in multi-predictions, got \(predictions.map(\.text))")

let rankMap = store.currentPredictionRankMap(now: Date(timeIntervalSince1970: 1_005))
require(rankMap["不错"] == 0, "expected 不错 to be top-ranked")
require(rankMap["真好"] != nil, "expected 真好 to remain ranked")

let invalidPredictions = store.recordCommittedText("abc", now: Date(timeIntervalSince1970: 1_006))
require(invalidPredictions.isEmpty, "expected non-Chinese commit to reset predictions")

_ = store.recordCommittedText("天气", now: Date(timeIntervalSince1970: 1_100))
_ = store.recordCommittedText("很好", now: Date(timeIntervalSince1970: 1_120))
let timeoutPredictions = store.recordCommittedText("天气", now: Date(timeIntervalSince1970: 1_121))
require(timeoutPredictions.map(\.text) == ["不错", "真好"], "expected stale context not to overwrite learned 天气 predictions, got \(timeoutPredictions.map(\.text))")

store.removeAllData()
try? FileManager.default.removeItem(at: testURL.deletingLastPathComponent())
print("pass: true")
SWIFT

swiftc \
  "$ROOT_DIR/SimpaninKeyboard/LocalPredictionStore.swift" \
  "$MAIN_PATH" \
  -o "$BIN_PATH"

"$BIN_PATH"
rm -f "$BIN_PATH"
rm -rf "$(dirname "$MAIN_PATH")"
