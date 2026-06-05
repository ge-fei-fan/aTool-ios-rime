import Foundation

private enum RimeDebugLogger {
    static let isEnabled = false

    private static let appGroupIdentifier = "group.com.local.fitnex"
    private static let directoryName = "RimeDebug"
    private static let fileName = "rime-debug.log"
    private static let appLogDirectoryName = "logs"
    private static let maxFileSize = 512 * 1024
    private static let queue = DispatchQueue(label: "com.local.simpanin.keyboard.rime.debug-log")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let appLogChunkFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter
    }()

    private static let appLogDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func record(_ message: String) {
        guard isEnabled else { return }

        let now = Date()
        let line = "\(timestampFormatter.string(from: now)) \(message)"

        queue.async {
            guard let containerURL = appGroupContainerURL() else { return }
            do {
                try appendPlainLog(line, in: containerURL)
                try appendAppLog(message, timestamp: now, in: containerURL)
            } catch {
                NSLog("[RimeDebug] failed to write debug log: %@", error.localizedDescription)
            }
        }
    }

    private static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static func appendPlainLog(_ line: String, in containerURL: URL) throws {
        let fileURL = containerURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        try appendLine(line, to: fileURL, rotateWhenLargerThan: maxFileSize)
    }

    private static func appendAppLog(_ message: String, timestamp: Date, in containerURL: URL) throws {
        let fileURL = containerURL
            .appendingPathComponent(appLogDirectoryName, isDirectory: true)
            .appendingPathComponent("\(appLogChunkFormatter.string(from: timestamp)).jsonl")
        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": appLogDateFormatter.string(from: timestamp),
            "source": "keyboard",
            "category": "keyboardDiagnostic",
            "level": "debug",
            "message": "[Rime] \(message)",
            "method": "",
            "url": "",
            "requestHeaders": [:],
            "requestBody": "",
            "statusCode": NSNull(),
            "responseHeaders": [:],
            "responseBody": "",
            "error": NSNull(),
            "durationMS": 0,
            "metadata": [
                "diagnosticArea": "keyboardExtension",
                "component": "Rime",
                "plainLog": "RimeDebug/rime-debug.log"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [])
        guard let line = String(data: data, encoding: .utf8) else { return }
        try appendLine(line, to: fileURL, rotateWhenLargerThan: maxFileSize)
    }

    private static func appendLine(_ line: String, to fileURL: URL, rotateWhenLargerThan limit: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > limit {
            try? fileManager.removeItem(at: fileURL)
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        if let data = "\(line)\n".data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }
}

struct RimeCandidate: Identifiable, Equatable {
    let text: String
    let comment: String?
    let index: Int
    let consumeLength: Int

    var id: String { "\(index)\t\(text)\t\(consumeLength)" }
}

enum RimeBridgeError: Error, Equatable {
    case nativeLibraryUnavailable
    case sharedDataDirectoryMissing(URL)
    case userDataDirectoryMissing(URL)
    case initializationFailed(String)

    var diagnosticText: String {
        switch self {
        case .nativeLibraryUnavailable:
            return "Rime启用失败：native 不可用（模拟器或未链接 librime）"
        case .sharedDataDirectoryMissing(let url):
            return "Rime启用失败：缺少共享数据目录 \(url.lastPathComponent)"
        case .userDataDirectoryMissing(let url):
            return "Rime启用失败：缺少用户数据目录 \(url.lastPathComponent)"
        case .initializationFailed(let message):
            return "Rime启用失败：\(message)"
        }
    }
}

final class RimeBridge {
    static let shared = RimeBridge()

    private enum KeyCode {
        static let backspace = 0xFF08
    }

    private let nativeBridge = RimeNativeBridge()
    private let queue = DispatchQueue(label: "com.local.simpanin.keyboard.rime")
    private var pendingCommitText = ""

    private(set) var isInitialized = false
    private(set) var lastError: RimeBridgeError?

    var isAvailable: Bool {
        queue.sync { isInitialized && nativeBridge.initialized }
    }

    var diagnosticFailureText: String? {
        queue.sync { lastError?.diagnosticText }
    }

    private init() {}

    func initializeIfNeeded(
        sharedDataURL: URL,
        userDataURL: URL,
        deployIfNeeded: Bool
    ) throws {
        try queue.sync {
            if isInitialized, nativeBridge.initialized {
                return
            }

            if isInitialized != nativeBridge.initialized {
                RimeDebugLogger.record(
                    "initialize state mismatch swift=\(isInitialized) native=\(nativeBridge.initialized); recovering"
                )
                isInitialized = false
                pendingCommitText = ""
            }

            guard RimeNativeBridge.nativeAvailable else {
                let error = RimeBridgeError.nativeLibraryUnavailable
                lastError = error
                throw error
            }

            guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
                let error = RimeBridgeError.sharedDataDirectoryMissing(sharedDataURL)
                lastError = error
                throw error
            }

            guard FileManager.default.fileExists(atPath: userDataURL.path) else {
                let error = RimeBridgeError.userDataDirectoryMissing(userDataURL)
                lastError = error
                throw error
            }

            do {
                try nativeBridge.initialize(
                    withSharedDataDirectory: sharedDataURL.path,
                    userDataDirectory: userDataURL.path,
                    deployIfNeeded: deployIfNeeded
                )
                nativeBridge.setOption("ascii_mode", enabled: false)
                isInitialized = true
                lastError = nil
                RimeDebugLogger.record(
                    "initialize ok deployIfNeeded=\(deployIfNeeded) asciiMode=\(nativeBridge.getOption("ascii_mode")) shared=\(sharedDataURL.path) user=\(userDataURL.path)"
                )
            } catch {
                let bridgeError = RimeBridgeError.initializationFailed(error.localizedDescription)
                isInitialized = false
                pendingCommitText = ""
                lastError = bridgeError
                RimeDebugLogger.record("initialize failed error=\(error.localizedDescription)")
                throw bridgeError
            }
        }
    }

    func reset() {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return }
            nativeBridge.reset()
            nativeBridge.setOption("ascii_mode", enabled: false)
            pendingCommitText = ""
            RimeDebugLogger.record("reset asciiMode=\(nativeBridge.getOption("ascii_mode"))")
        }
    }

    func shutdown() {
        queue.sync {
            nativeBridge.shutdown()
            isInitialized = false
            pendingCommitText = ""
            lastError = nil
            RimeDebugLogger.record("shutdown")
        }
    }

    func insertLetter(_ letter: String) {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return }
            guard let scalar = letter.unicodeScalars.first, letter.unicodeScalars.count == 1 else { return }
            let didConsume = nativeBridge.processKeyCode(Int(scalar.value), mask: 0)
            collectPendingCommitText()
            logCurrentState(action: "insert", details: "letter=\(letter) code=\(scalar.value) consumed=\(didConsume)")
        }
    }

    func deleteBackward() -> Bool {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return false }
            let didConsume = nativeBridge.processKeyCode(KeyCode.backspace, mask: 0)
            collectPendingCommitText()
            logCurrentState(action: "delete", details: "consumed=\(didConsume)")
            return didConsume
        }
    }

    func clearComposition() {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return }
            nativeBridge.clearComposition()
            pendingCommitText = ""
            logCurrentState(action: "clear", details: "")
        }
    }

    func setDisplayCursorOffset(_ offset: Int) {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return }
            nativeBridge.setCaretPosition(offset)
        }
    }

    var rawInput: String {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return "" }
            return nativeBridge.currentContext()?.input ?? ""
        }
    }

    var displayText: String {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return "" }
            return nativeBridge.currentContext()?.preedit ?? ""
        }
    }

    var displayCursorOffset: Int {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return 0 }
            return nativeBridge.currentContext()?.caretPosition ?? 0
        }
    }

    var hasComposition: Bool {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return false }
            guard let context = nativeBridge.currentContext() else { return false }
            return !context.input.isEmpty || !context.preedit.isEmpty
        }
    }

    var candidates: [RimeCandidate] {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return [] }
            return (nativeBridge.currentContext()?.candidates ?? []).map {
                RimeCandidate(
                    text: $0.text,
                    comment: $0.comment,
                    index: $0.index,
                    consumeLength: $0.consumeLength
                )
            }
        }
    }

    func selectCandidate(at index: Int) -> String? {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return nil }
            guard nativeBridge.selectCandidate(at: UInt(index)) else {
                logCurrentState(action: "select", details: "index=\(index) success=false")
                return nil
            }
            collectPendingCommitText()
            let text = consumePendingCommitText()
            logCurrentState(action: "select", details: "index=\(index) success=true commit=\(text ?? "<nil>")")
            return text
        }
    }

    func commitCompositionAsText() -> String? {
        queue.sync {
            guard isInitialized, nativeBridge.initialized else { return nil }
            if let text = consumePendingCommitText() {
                return text
            }
            if let text = nativeBridge.commitComposition(), !text.isEmpty {
                RimeDebugLogger.record("commitComposition direct commit=\(text)")
                return text
            }
            collectPendingCommitText()
            let text = consumePendingCommitText()
            logCurrentState(action: "commitComposition", details: "commit=\(text ?? "<nil>")")
            return text
        }
    }

    private func logCurrentState(action: String, details: String) {
        guard RimeDebugLogger.isEnabled else { return }

        guard let context = nativeBridge.currentContext() else {
            RimeDebugLogger.record("\(action) \(details) context=<nil> pendingCommit=\(pendingCommitText)")
            return
        }

        let candidateSummary = context.candidates
            .prefix(10)
            .map { candidate in
                let comment = candidate.comment.map { "(\($0))" } ?? ""
                return "#\(candidate.index):\(candidate.text)\(comment)"
            }
            .joined(separator: "|")
        RimeDebugLogger.record(
            "\(action) \(details) raw=\(context.input) preedit=\(context.preedit) caret=\(context.caretPosition) candidates=\(candidateSummary.isEmpty ? "<empty>" : candidateSummary) pendingCommit=\(pendingCommitText.isEmpty ? "<empty>" : pendingCommitText)"
        )
    }

    private func collectPendingCommitText() {
        guard let text = nativeBridge.consumeCommitText(), !text.isEmpty else { return }
        pendingCommitText += text
    }

    private func consumePendingCommitText() -> String? {
        guard !pendingCommitText.isEmpty else { return nil }
        let text = pendingCommitText
        pendingCommitText = ""
        return text
    }
}
