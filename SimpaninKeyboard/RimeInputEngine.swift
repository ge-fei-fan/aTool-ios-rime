import Foundation

struct KeyboardInputCandidate: Identifiable, Equatable {
    let text: String
    let consumeLength: Int
    let comment: String?
    let rimeIndex: Int?

    init(text: String, consumeLength: Int, comment: String? = nil, rimeIndex: Int? = nil) {
        self.text = text
        self.consumeLength = consumeLength
        self.comment = comment
        self.rimeIndex = rimeIndex
    }

    var id: String { "\(rimeIndex ?? -1)\t\(text)\t\(consumeLength)\t\(comment ?? "")" }
}

protocol KeyboardInputEngine {
    var isUsingRime: Bool { get }
    var failureText: String? { get }
    var rawPinyin: String { get }
    var displayText: String { get }
    var hasComposition: Bool { get }
    var displayCursorOffset: Int { get }
    var candidates: [KeyboardInputCandidate] { get }

    mutating func insertLetter(_ letter: String)
    mutating func deleteBackward() -> Bool
    mutating func clearComposition()
    mutating func clearAssociationContext()
    mutating func setDisplayCursorOffset(_ offset: Int)
    mutating func select(_ candidate: KeyboardInputCandidate) -> String?
    mutating func commitCompositionAsText() -> String?
    mutating func commitRawInputAsText() -> String?
    mutating func shutdown()
}

/// Rime-backed input engine facade.
///
/// Rime is the only input engine. If librime fails to initialize, the engine
/// reports the failure instead of falling back to another implementation.
struct RimeInputEngine: KeyboardInputEngine {
    private let bridge = RimeBridge.shared
    private var preparationFailureText: String?

    var isUsingRime: Bool { bridge.isAvailable }

    var failureText: String? {
        guard !bridge.isAvailable else { return nil }
        return preparationFailureText
            ?? bridge.diagnosticFailureText
    }

    var rawPinyin: String {
        bridge.isAvailable ? bridge.rawTypedText : ""
    }

    var displayText: String {
        bridge.isAvailable ? bridge.displayText : (failureText ?? "")
    }

    var hasComposition: Bool {
        bridge.isAvailable ? bridge.hasComposition : failureText != nil
    }

    var displayCursorOffset: Int {
        bridge.isAvailable ? bridge.displayCursorOffset : displayText.count
    }

    var candidates: [KeyboardInputCandidate] {
        if bridge.isAvailable {
            return bridge.candidates.map {
                KeyboardInputCandidate(text: $0.text, consumeLength: $0.consumeLength, comment: $0.comment, rimeIndex: $0.index)
            }
        }

        return []
    }

    mutating func initializeRimeIfPossible(
        sharedDataURL: URL,
        userDataURL: URL,
        deployIfNeeded: Bool
    ) {
        preparationFailureText = nil
        do {
            try bridge.initializeIfNeeded(
                sharedDataURL: sharedDataURL,
                userDataURL: userDataURL,
                deployIfNeeded: deployIfNeeded
            )
        } catch {
            // Strict Rime mode: keep the failure in RimeBridge for diagnostics
            // and do not fall back to the bundled Swift pinyin engine.
            preparationFailureText = bridge.diagnosticFailureText
                ?? error.localizedDescription
        }
    }

    mutating func setPreparationFailure(_ message: String) {
        preparationFailureText = message
    }

    mutating func insertLetter(_ letter: String) {
        if bridge.isAvailable {
            bridge.insertLetter(letter)
        }
    }

    mutating func deleteBackward() -> Bool {
        if bridge.isAvailable {
            return bridge.deleteBackward()
        }
        return false
    }

    mutating func clearComposition() {
        if bridge.isAvailable {
            bridge.clearComposition()
        }
    }

    mutating func clearAssociationContext() {
        if bridge.isAvailable {
            bridge.clearComposition()
        }
    }

    mutating func setDisplayCursorOffset(_ offset: Int) {
        if bridge.isAvailable {
            bridge.setDisplayCursorOffset(offset)
        }
    }

    mutating func select(_ candidate: KeyboardInputCandidate) -> String? {
        if bridge.isAvailable, let index = candidate.rimeIndex {
            return bridge.selectCandidate(at: index)
        }

        return nil
    }

    mutating func commitCompositionAsText() -> String? {
        if bridge.isAvailable {
            return bridge.commitCompositionAsText()
        }
        return nil
    }

    mutating func commitRawInputAsText() -> String? {
        if bridge.isAvailable {
            return bridge.commitRawInputAsText()
        }
        return nil
    }

    mutating func shutdown() {
        bridge.shutdown()
    }
}
