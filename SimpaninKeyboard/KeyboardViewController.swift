import KeyboardKit
import SwiftUI
import UIKit

final class KeyboardViewController: KeyboardInputViewController {
    private let pinyinState = PinyinKeyboardInputState()

    override func viewDidLoad() {
        super.viewDidLoad()
        setKeyboardCase(.lowercased)
        let standardActionHandler = services.actionHandler
        services.actionHandler = PinyinKeyboardActionHandler(
            controller: self,
            standardActionHandler: standardActionHandler,
            pinyinState: pinyinState
        )
    }

    override func viewWillSetupKeyboardView() {
        pinyinState.resetInputContextForKeyboardOpen()
        applyLockedKeyboardCaseDeferred()
        setupKeyboardView { [pinyinState] controller in
            PinyinKeyboardView(
                keyboardContext: controller.state.keyboardContext,
                services: controller.services,
                pinyinState: pinyinState,
                hasFullAccess: controller.hasFullAccess,
                insertText: { [weak controller] text in
                    controller?.textDocumentProxy.insertText(text)
                },
                dismissKeyboard: { [weak controller] in
                    controller?.dismissKeyboard()
                }
            )
        }
        pinyinState.scheduleDelayedRimeInputEngineReload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pinyinState.shutdownRimeInputEngine()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyLockedKeyboardCaseDeferred()
    }

    private func applyLockedKeyboardCase() {
        setKeyboardCase(pinyinState.isUppercaseLocked ? .uppercased : .lowercased)
    }

    private func applyLockedKeyboardCaseDeferred() {
        applyLockedKeyboardCase()
        DispatchQueue.main.async { [weak self] in
            self?.applyLockedKeyboardCase()
        }
    }
}

private enum PinyinKeyboardMetrics {
    static let candidateToolbarHeight: CGFloat = 77
    static let quickFillAddBarHeight: CGFloat = 106
    static let compositionBarHeight: CGFloat = 30
    static let candidateInputTopPadding: CGFloat = 4
    static let compositionCandidateSpacing: CGFloat = 7
    static let expandedCandidateOverlayTopOffset: CGFloat = candidateInputTopPadding + compositionBarHeight + compositionCandidateSpacing
    static let candidateExpandHitWidth: CGFloat = 48
    static let candidateExpandHitHeight: CGFloat = 44
    static let candidateToggleHitAreaDebugOpacity: Double = 0.35
    static let expandedCandidateMinHitHeight: CGFloat = 44
    static let expandedCandidateVerticalPadding: CGFloat = 10
    static let utilityIconPointSize: CGFloat = 24
    static let quickFillPanelAnimationDuration: TimeInterval = 0.22
    static let bottomRowKeyHeight: CGFloat = 48
    static let bottomRowHorizontalInset: CGFloat = 3
    static let bottomRowShadowBottomInset: CGFloat = 4
}

private enum PinyinBottomRowWidthConfig {
    // Order: keyboard switch, punctuation/symbol switch, space, Chinese/English, return/confirm.
    static let alphabeticRatios: [CGFloat] = [1.35, 1.00, 4.10, 1.00, 1.75]
    static let numericAndSymbolicRatios: [CGFloat] = [1.35, 1.00, 4.10, 1.00, 1.75]
}

private struct RimeUserDataPreparation {
    let sharedDataURL: URL
    let userDataURL: URL
    let deployIfNeeded: Bool
    let deploymentMarker: RimeDeploymentMarker?
    let deploymentMarkerURL: URL?
}

private struct RimeSharedManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let path: String
        let sha256: String
        let bytes: Int
    }

    let tag: String
    let sourceCommit: String
    let baseAssetName: String
    let baseAssetSHA256: String
    let grammarAssetName: String?
    let grammarAssetSHA256: String?
    let schemaID: String
    let files: [FileEntry]
}

private struct RimeManagedDataInstallation {
    let didUpdateResources: Bool
    let manifest: RimeSharedManifest
}

private struct RimePreparedDataCache {
    let preparation: RimeUserDataPreparation
    let bundledBuildSummary: String
    let userBuildSummary: String
}

private struct RimeDeploymentMarker: Codable, Equatable {
    let schemaID: String
    let tag: String
    let sourceCommit: String
    let fileCount: Int

    init(manifest: RimeSharedManifest) {
        schemaID = manifest.schemaID
        tag = manifest.tag
        sourceCommit = manifest.sourceCommit
        fileCount = manifest.files.count
    }
}

private enum RimeDataPreparationError: LocalizedError {
    case bundledSharedDataMissing
    case writableUserDataUnavailable([String])
    case createUserDataDirectoryFailed(URL, Error)
    case manifestReadFailed(URL, Error)
    case manifestDecodeFailed(URL, Error)
    case sourceFileMissing(String)
    case copyFileFailed(String, Error)
    case writeInstalledManifestFailed(URL, Error)
    case prebuiltDeploymentMissing(schemaID: String)
    case removeDeployedBuildFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .bundledSharedDataMissing:
            return "Rime启用失败：应用包内缺少 RimeShared 资源目录"
        case .writableUserDataUnavailable(let failures):
            let failureSummary = failures.isEmpty ? "未找到候选目录" : failures.joined(separator: "；")
            return "Rime启用失败：无法获取可写数据目录（\(failureSummary)）"
        case .createUserDataDirectoryFailed(let url, let error):
            return "Rime启用失败：无法创建用户数据目录 \(url.lastPathComponent)：\(error.localizedDescription)"
        case .manifestReadFailed(let url, let error):
            return "Rime启用失败：无法读取资源清单 \(url.lastPathComponent)：\(error.localizedDescription)"
        case .manifestDecodeFailed(let url, let error):
            return "Rime启用失败：资源清单格式错误 \(url.lastPathComponent)：\(error.localizedDescription)"
        case .sourceFileMissing(let path):
            return "Rime启用失败：应用包内缺少资源文件 \(path)"
        case .copyFileFailed(let path, let error):
            return "Rime启用失败：复制资源文件 \(path) 失败：\(error.localizedDescription)"
        case .writeInstalledManifestFailed(let url, let error):
            return "Rime启用失败：无法写入安装清单 \(url.lastPathComponent)：\(error.localizedDescription)"
        case .prebuiltDeploymentMissing(let schemaID):
            return "Rime启用失败：缺少预编译部署文件（\(schemaID)）。为避免键盘扩展内首次部署导致闪退，已跳过 Rime 初始化；请先把 build/*.bin 部署产物打包进 RimeShared 或由主 App 预部署。"
        case .removeDeployedBuildFailed(let url, let error):
            return "Rime启用失败：无法清理旧部署目录 \(url.lastPathComponent)：\(error.localizedDescription)"
        }
    }
}

private enum PinyinEmojiCategory: String, CaseIterable, Identifiable {
    case frequent
    case faces
    case hands
    case animals
    case food
    case activity
    case objects
    case symbols
    case currency
    case flags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frequent: return "常用"
        case .faces: return "表情"
        case .hands: return "手势"
        case .animals: return "动物"
        case .food: return "食物"
        case .activity: return "活动"
        case .objects: return "物品"
        case .symbols: return "符号"
        case .currency: return "货币"
        case .flags: return "旗帜"
        }
    }

    var systemImageName: String {
        switch self {
        case .frequent: return "clock"
        case .faces: return "face.smiling"
        case .hands: return "hand.raised"
        case .animals: return "pawprint"
        case .food: return "fork.knife"
        case .activity: return "gamecontroller"
        case .objects: return "cube.box"
        case .symbols: return "number"
        case .currency: return "dollarsign.circle"
        case .flags: return "flag"
        }
    }
}

private struct PinyinEmojiSection: Identifiable, Equatable {
    let category: PinyinEmojiCategory
    let items: [String]

    var id: PinyinEmojiCategory { category }
}

private final class PinyinKeyboardInputState: ObservableObject {
    private struct PartialSelectionStep: Equatable {
        let committedText: String
        let consumedRawPinyin: String
    }

    private static let candidateRefreshDelay: TimeInterval = 0.012
    private static let sharedDefaultsSuiteName = "group.com.local.fitnex"
    private static let quickFillItemsDefaultsKey = "quickFill.items"
    private static let rimeSharedManifestName = "rime-shared-manifest.json"
    private static let installedRimeSharedManifestName = ".simpanin-rime-shared-manifest.json"
    private static let installedRimeDeploymentMarkerName = ".simpanin-rime-deploy-marker.json"
    private static let emojiDataRelativePath = "RimeShared/lua/data/emoji.txt"
    private static let keyboardDiagnosticLogQueue = DispatchQueue(label: "com.local.simpanin.keyboard.diagnostic-log")
    private static let keyboardDiagnosticLogChunkFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter
    }()
    private static let keyboardDiagnosticLogDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let rimePreparationCacheQueue = DispatchQueue(label: "com.local.simpanin.keyboard.rime-preparation-cache")
    private static var rimePreparationCache: RimePreparedDataCache?

    private var engine: any KeyboardInputEngine = RimeInputEngine()
    private let rimeInitializationQueue = DispatchQueue(label: "com.local.simpanin.keyboard.rime-initialization", qos: .userInitiated)
    private var rimeInitializationWorkItem: DispatchWorkItem?
    private var rimeInitializationGeneration = 0
    private var isRimeInitializationInProgress = false
    private let candidateQueue = DispatchQueue(label: "com.local.simpanin.keyboard.candidates", qos: .userInitiated)
    private var candidateRefreshWorkItem: DispatchWorkItem?
    private var candidateRefreshGeneration = 0
    private var appliedCandidateGeneration = 0
    private var shouldResetCandidateScrollAfterRefresh = false
    private var partialSelectionSteps: [PartialSelectionStep] = []

    @Published private(set) var displayText = ""
    @Published private(set) var rawPinyinText = ""
    @Published private(set) var displayCursorOffset = 0
    @Published private(set) var hasComposition = false
    @Published private(set) var candidates: [KeyboardInputCandidate] = []
    @Published private(set) var candidateScrollResetToken = 0
    @Published private(set) var isCandidateRefreshPending = false
    @Published private(set) var isUsingRimeEngine = false
    @Published private(set) var inputEngineFailureText: String?
    @Published var isChineseInputEnabled = true
    @Published var isCandidatePageVisible = false
    @Published var isUppercaseLocked = false
    @Published var isQuickFillPanelVisible = false
    @Published var isQuickFillAddInputVisible = false
    @Published var isSpaceTrackpadActive = false
    @Published var spaceTrackpadPreviewOffset = 0
    @Published var quickFillItems: [String] = []
    @Published var quickFillDraftText = ""
    @Published var quickFillDraftCursorOffset = 0
    @Published var isEmojiPanelVisible = false
    @Published var emojiItems: [String] = []
    @Published var emojiSections: [PinyinEmojiSection] = []
    @Published var isTranslationPanelVisible = false
    @Published var isNumericOrSymbolicKeyboardVisible = false
    @Published var isNineGridNumericKeyboardVisible = false
    @Published var translationText = ""
    @Published var translationStatusText = ""
    private var quickFillEditingOriginalText: String?
    private var translationTask: URLSessionDataTask?
    private var translationStreamDelegate: OllamaTranslationStreamDelegate?
    private var activeTranslationRequestID = 0

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.sharedDefaultsSuiteName)
    }

    deinit {
        rimeInitializationGeneration += 1
        rimeInitializationWorkItem?.cancel()
        candidateRefreshWorkItem?.cancel()
        cancelTranslationRequest()
        // Keep the process-wide Rime runtime alive for the extension process.
        // iOS may recreate the controller during keyboard switches; native
        // teardown here can race with a new controller's initialization.
    }

    init() {
        reloadQuickFillItems()
    }

    func scheduleDelayedRimeInputEngineReload() {
        guard !engine.isUsingRime, !isRimeInitializationInProgress else {
            updatePublishedEngineState()
            return
        }

        rimeInitializationGeneration += 1
        rimeInitializationWorkItem?.cancel()
        rimeInitializationWorkItem = nil
        Self.logInputEngineInfo("rime startup scheduled immediately")
        reloadRimeInputEngine()
    }

    func reloadRimeInputEngine() {
        guard !engine.isUsingRime else {
            updatePublishedEngineState()
            return
        }

        guard !isRimeInitializationInProgress else {
            updatePublishedEngineState()
            return
        }

        let previousWasUsingRime = engine.isUsingRime
        let currentFailureText = engine.failureText ?? "<none>"
        rimeInitializationGeneration += 1
        let generation = rimeInitializationGeneration
        isRimeInitializationInProgress = true
        rimeInitializationWorkItem?.cancel()
        cancelPendingCandidateRefresh(clearCandidates: true)
        clearPartialSelection()
        engine.clearComposition()
        refreshPublishedComposition()
        Self.logInputEngineInfo(
            "rime reload scheduled previousWasUsingRime=\(previousWasUsingRime), previousFailure=\(currentFailureText)"
        )

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self, !workItem.isCancelled else { return }
            let preparedEngine = self.makeRimeInputEngine()
            guard !workItem.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.rimeInitializationGeneration == generation,
                      !workItem.isCancelled else {
                    return
                }
                self.rimeInitializationWorkItem = nil
                self.isRimeInitializationInProgress = false
                self.engine = preparedEngine
                self.resetCandidateScrollPosition()
                self.hideCandidatePageIfNeeded()
                self.refreshPublishedComposition()
                Self.logInputEngineInfo(
                    "rime reload finished previousWasUsingRime=\(previousWasUsingRime), isUsingRime=\(self.engine.isUsingRime), previousFailure=\(currentFailureText)"
                )
                self.scheduleCandidateRefresh(resetCandidatesWhenEmpty: true)
            }
        }
        rimeInitializationWorkItem = workItem
        rimeInitializationQueue.async(execute: workItem)
    }

    func resetInputContextForKeyboardOpen() {
        cancelPendingCandidateRefresh(clearCandidates: true)
        clearPartialSelection()
        engine.clearComposition()
        hideCandidatePageIfNeeded()
        setNineGridNumericKeyboardVisible(false)
        displayText = ""
        rawPinyinText = ""
        displayCursorOffset = 0
        hasComposition = false
        candidates = []
        isCandidateRefreshPending = false
    }

    private func makeRimeInputEngine() -> any KeyboardInputEngine {
        var rimeEngine = RimeInputEngine()
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let preparedData = try prepareRimeUserData()
            let preparationTimeMS = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            rimeEngine.initializeRimeIfPossible(
                sharedDataURL: preparedData.sharedDataURL,
                userDataURL: preparedData.userDataURL,
                deployIfNeeded: preparedData.deployIfNeeded
            )
            let totalTimeMS = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            Self.logInputEngineInfo("rime engine make finished preparationMS=\(preparationTimeMS), totalMS=\(totalTimeMS), isUsingRime=\(rimeEngine.isUsingRime)")
            if preparedData.deployIfNeeded,
               rimeEngine.isUsingRime,
               let deploymentMarker = preparedData.deploymentMarker,
               let deploymentMarkerURL = preparedData.deploymentMarkerURL {
                do {
                    try Self.writeRimeDeploymentMarker(deploymentMarker, to: deploymentMarkerURL)
                } catch {
                    Self.logInputEngineInfo("failed to write Rime deployment marker: \(error.localizedDescription)")
                }
            }
        } catch {
            let totalTimeMS = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            Self.logInputEngineInfo("rime engine make failed totalMS=\(totalTimeMS), error=\(error.localizedDescription)")
            rimeEngine.setPreparationFailure(error.localizedDescription)
        }
        return rimeEngine
    }

    func shutdownRimeInputEngine() {
        rimeInitializationGeneration += 1
        rimeInitializationWorkItem?.cancel()
        rimeInitializationWorkItem = nil
        isRimeInitializationInProgress = false
        cancelPendingCandidateRefresh(clearCandidates: true)
        hideCandidatePageIfNeeded()
        setEmojiPanelVisible(false)
        setTranslationPanelVisible(false)
        setNineGridNumericKeyboardVisible(false)

        // Do not clear or shutdown the process-wide Rime session while the
        // keyboard extension is disappearing. iOS can call this during input
        // mode switches while an async Rime initialization/candidate refresh is
        // still winding down. Touching librime during that transition can race
        // with the next keyboard instance and make the extension exit, which
        // appears to users as a brief flash back to the previous keyboard.
        clearPartialSelection()
        displayText = ""
        rawPinyinText = ""
        displayCursorOffset = 0
        hasComposition = false
        candidates = []
        isCandidateRefreshPending = false
    }

    private var bundledRimeSharedDataURL: URL? {
        Bundle(for: KeyboardViewController.self).url(forResource: "RimeShared", withExtension: nil)
            ?? Bundle.main.url(forResource: "RimeShared", withExtension: nil)
    }

    private func writableRimeUserDataURL() throws -> URL {
        let fileManager = FileManager.default
        var candidateBaseURLs: [(label: String, url: URL)] = []
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.sharedDefaultsSuiteName) {
            candidateBaseURLs.append(("App Group", appGroupURL))
        }
        if let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidateBaseURLs.append(("Application Support", applicationSupportURL.appendingPathComponent("Simpanin", isDirectory: true)))
        }
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidateBaseURLs.append(("Documents", documentsURL.appendingPathComponent("Simpanin", isDirectory: true)))
        }
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidateBaseURLs.append(("Caches", cachesURL.appendingPathComponent("Simpanin", isDirectory: true)))
        }
        candidateBaseURLs.append(("Temporary", fileManager.temporaryDirectory.appendingPathComponent("Simpanin", isDirectory: true)))

        var failures: [String] = []
        for candidate in candidateBaseURLs {
            let userDataURL = candidate.url.appendingPathComponent("RimeUser", isDirectory: true)
            do {
                try fileManager.createDirectory(at: userDataURL, withIntermediateDirectories: true)
                try Self.verifyDirectoryIsWritable(userDataURL, fileManager: fileManager)
                return userDataURL
            } catch {
                failures.append("\(candidate.label): \(userDataURL.path) - \(error.localizedDescription)")
            }
        }

        throw RimeDataPreparationError.writableUserDataUnavailable(failures)
    }

    private static func verifyDirectoryIsWritable(_ directoryURL: URL, fileManager: FileManager) throws {
        let testFileURL = directoryURL.appendingPathComponent(".simpanin-write-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: testFileURL) }
        try Data().write(to: testFileURL, options: .atomic)
    }

    private func prepareRimeUserData() throws -> RimeUserDataPreparation {
        if let cachedPreparation = Self.cachedRimePreparation() {
            Self.logInputEngineInfo(
                "rime data prepared from cache bundledShared=true, bundledBuild=\(cachedPreparation.bundledBuildSummary), userBuild=\(cachedPreparation.userBuildSummary), deployInKeyboard=false"
            )
            return cachedPreparation.preparation
        }

        guard let bundledRimeSharedDataURL else {
            throw RimeDataPreparationError.bundledSharedDataMissing
        }
        let userDataURL = try writableRimeUserDataURL()

        let manifestURL = bundledRimeSharedDataURL.appendingPathComponent(Self.rimeSharedManifestName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RimeDataPreparationError.manifestReadFailed(manifestURL, error)
        }
        let manifest: RimeSharedManifest
        do {
            manifest = try JSONDecoder().decode(RimeSharedManifest.self, from: manifestData)
        } catch {
            throw RimeDataPreparationError.manifestDecodeFailed(manifestURL, error)
        }

        let deploymentMarker = RimeDeploymentMarker(manifest: manifest)
        let deploymentMarkerURL = userDataURL.appendingPathComponent(Self.installedRimeDeploymentMarkerName)
        let hasBundledBuild = Self.rimeBuildIsInstalled(in: bundledRimeSharedDataURL, schemaID: manifest.schemaID)
        let hasUserBuild = Self.rimeBuildIsInstalled(in: userDataURL, schemaID: manifest.schemaID)
        let hasCurrentBuild = hasBundledBuild || hasUserBuild
        let hasCurrentDeploymentMarker = Self.installedRimeDeploymentMarker(at: deploymentMarkerURL) == deploymentMarker
        let bundledBuildSummary = Self.rimeBuildDiagnosticSummary(in: bundledRimeSharedDataURL, schemaID: manifest.schemaID)
        let userBuildSummary = Self.rimeBuildDiagnosticSummary(in: userDataURL, schemaID: manifest.schemaID)
        Self.logInputEngineInfo(
            "rime bundled build detail: \(bundledBuildSummary)"
        )
        Self.logInputEngineInfo(
            "rime user build detail: \(userBuildSummary)"
        )
        Self.logInputEngineInfo(
            "rime data prepared bundledShared=true, hasBundledBuild=\(hasBundledBuild), hasUserBuild=\(hasUserBuild), hasBuild=\(hasCurrentBuild), hasMarker=\(hasCurrentDeploymentMarker), deployInKeyboard=false"
        )

        // Do not run librime deployment inside the keyboard extension. The
        // extension has a very small launch-time/memory budget and users have
        // observed keyboard switching briefly shows our keyboard, then exits
        // about one second later when first deployment is attempted. Only allow
        // initialization when a deployed build already exists; otherwise surface
        // a diagnostic in the candidate/composition bar instead of crashing.
        guard hasCurrentBuild else {
            throw RimeDataPreparationError.prebuiltDeploymentMissing(schemaID: manifest.schemaID)
        }

        let preparation = RimeUserDataPreparation(
            sharedDataURL: bundledRimeSharedDataURL,
            userDataURL: userDataURL,
            deployIfNeeded: false,
            deploymentMarker: deploymentMarker,
            deploymentMarkerURL: deploymentMarkerURL
        )
        Self.cacheRimePreparation(
            RimePreparedDataCache(
                preparation: preparation,
                bundledBuildSummary: bundledBuildSummary,
                userBuildSummary: userBuildSummary
            )
        )
        return preparation
    }

    private static func cachedRimePreparation() -> RimePreparedDataCache? {
        rimePreparationCacheQueue.sync { rimePreparationCache }
    }

    private static func cacheRimePreparation(_ cache: RimePreparedDataCache) {
        rimePreparationCacheQueue.sync { rimePreparationCache = cache }
    }

    private func installManagedRimeSharedData(from sourceURL: URL, to userDataURL: URL) throws -> RimeManagedDataInstallation {
        let fileManager = FileManager.default
        let manifestURL = sourceURL.appendingPathComponent(Self.rimeSharedManifestName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RimeDataPreparationError.manifestReadFailed(manifestURL, error)
        }
        let manifest: RimeSharedManifest
        do {
            manifest = try JSONDecoder().decode(RimeSharedManifest.self, from: manifestData)
        } catch {
            throw RimeDataPreparationError.manifestDecodeFailed(manifestURL, error)
        }
        let installedManifestURL = userDataURL.appendingPathComponent(Self.installedRimeSharedManifestName)
        let installedManifest: RimeSharedManifest?
        if let installedManifestData = try? Data(contentsOf: installedManifestURL) {
            installedManifest = try? JSONDecoder().decode(RimeSharedManifest.self, from: installedManifestData)
        } else {
            installedManifest = nil
        }

        let isCurrentManifestInstalled = installedManifest == manifest
        let hasAllManagedFiles = manifest.files.allSatisfy { entry in
            Self.managedRimeFileIsInstalled(
                at: userDataURL.appendingPathComponent(entry.path),
                expectedByteCount: entry.bytes
            )
        }
        guard !isCurrentManifestInstalled || !hasAllManagedFiles else {
            return RimeManagedDataInstallation(didUpdateResources: false, manifest: manifest)
        }

        if let installedManifest {
            for entry in installedManifest.files {
                let targetURL = userDataURL.appendingPathComponent(entry.path)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try? fileManager.removeItem(at: targetURL)
                }
            }
        }

        for entry in manifest.files {
            let sourceFileURL = sourceURL.appendingPathComponent(entry.path)
            let targetFileURL = userDataURL.appendingPathComponent(entry.path)
            guard fileManager.fileExists(atPath: sourceFileURL.path) else {
                throw RimeDataPreparationError.sourceFileMissing(entry.path)
            }
            if Self.managedRimeFileIsInstalled(at: targetFileURL, expectedByteCount: entry.bytes) {
                continue
            }
            let parentURL = targetFileURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: targetFileURL.path) {
                    try fileManager.removeItem(at: targetFileURL)
                }
                try fileManager.copyItem(at: sourceFileURL, to: targetFileURL)
            } catch {
                throw RimeDataPreparationError.copyFileFailed(entry.path, error)
            }
        }

        do {
            try manifestData.write(to: installedManifestURL, options: .atomic)
        } catch {
            throw RimeDataPreparationError.writeInstalledManifestFailed(installedManifestURL, error)
        }
        return RimeManagedDataInstallation(didUpdateResources: true, manifest: manifest)
    }

    private static func managedRimeFileIsInstalled(at url: URL, expectedByteCount: Int) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.intValue == expectedByteCount
    }

    private static func rimeBuildIsInstalled(in baseURL: URL, schemaID: String) -> Bool {
        rimeRequiredBuildPaths(schemaID: schemaID).allSatisfy { path in
            FileManager.default.fileExists(atPath: baseURL.appendingPathComponent(path).path)
        }
    }

    private static func rimeRequiredBuildPaths(schemaID: String) -> [String] {
        let requiredBuildPaths = [
            "build/\(schemaID).schema.yaml",
            "build/\(schemaID).prism.bin",
            "build/\(schemaID).table.bin"
        ]
        return requiredBuildPaths
    }

    private static func rimeBuildDiagnosticSummary(in baseURL: URL, schemaID: String) -> String {
        rimeRequiredBuildPaths(schemaID: schemaID).map { relativePath in
            let url = baseURL.appendingPathComponent(relativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attributes[.size] as? NSNumber else {
                return "\(relativePath)=missing"
            }
            return "\(relativePath)=\(fileSize.intValue)B"
        }.joined(separator: ", ")
    }

    private static func installedRimeDeploymentMarker(at url: URL) -> RimeDeploymentMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RimeDeploymentMarker.self, from: data)
    }

    private static func writeRimeDeploymentMarker(_ marker: RimeDeploymentMarker, to url: URL) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: url, options: .atomic)
    }

    private static func removeDeployedRimeBuild(in userDataURL: URL) throws {
        let fileManager = FileManager.default
        let buildURL = userDataURL.appendingPathComponent("build", isDirectory: true)
        do {
            if fileManager.fileExists(atPath: buildURL.path) {
                try fileManager.removeItem(at: buildURL)
            }
        } catch {
            throw RimeDataPreparationError.removeDeployedBuildFailed(buildURL, error)
        }
        let deploymentMarkerURL = userDataURL.appendingPathComponent(Self.installedRimeDeploymentMarkerName)
        try? fileManager.removeItem(at: deploymentMarkerURL)
    }

    private static func splitRawPinyin(
        afterConsuming consumeLength: Int,
        from rawPinyin: String
    ) -> (consumed: String, remaining: String) {
        guard consumeLength > 0 else { return ("", rawPinyin) }
        guard consumeLength < rawPinyin.count else { return (rawPinyin, "") }
        let splitIndex = rawPinyin.index(rawPinyin.startIndex, offsetBy: consumeLength)
        return (
            String(rawPinyin[..<splitIndex]),
            String(rawPinyin[splitIndex...])
        )
    }

    private static func splitRawPinyinAfterCandidateSelection(
        _ candidate: KeyboardInputCandidate,
        selectedText: String?,
        rawPinyinBeforeSelect: String,
        rawPinyinAfterSelect: String
    ) -> (consumed: String, remaining: String) {
        if let consumeLength = consumeLengthFromSelectionRemainder(
            rawPinyinBeforeSelect: rawPinyinBeforeSelect,
            rawPinyinAfterSelect: rawPinyinAfterSelect
        ) {
            return splitRawPinyin(afterConsuming: consumeLength, from: rawPinyinBeforeSelect)
        }

        if let consumeLength = inferredPinyinConsumeLength(
            for: selectedText,
            from: rawPinyinBeforeSelect
        ) {
            return splitRawPinyin(afterConsuming: consumeLength, from: rawPinyinBeforeSelect)
        }

        return splitRawPinyin(afterConsuming: candidate.consumeLength, from: rawPinyinBeforeSelect)
    }

    private static func consumeLengthFromSelectionRemainder(
        rawPinyinBeforeSelect: String,
        rawPinyinAfterSelect: String
    ) -> Int? {
        guard !rawPinyinAfterSelect.isEmpty,
              rawPinyinAfterSelect.count < rawPinyinBeforeSelect.count,
              rawPinyinBeforeSelect.hasSuffix(rawPinyinAfterSelect) else {
            return nil
        }

        return rawPinyinBeforeSelect.count - rawPinyinAfterSelect.count
    }

    private static func inferredPinyinConsumeLength(
        for selectedText: String?,
        from rawPinyin: String
    ) -> Int? {
        guard let selectedText,
              !selectedText.isEmpty,
              containsHanCharacter(in: selectedText),
              isASCIIPinyinInput(rawPinyin) else {
            return nil
        }

        let syllables = PinyinCompositionFormatter.segmentASCIILetters(rawPinyin)
        guard syllables.count > 1,
              syllables.joined().count == rawPinyin.count else {
            return nil
        }

        let syllableCountToConsume = min(selectedText.count, syllables.count)
        guard syllableCountToConsume > 0 else { return nil }
        return syllables
            .prefix(syllableCountToConsume)
            .reduce(0) { length, syllable in length + syllable.count }
    }

    private static func containsHanCharacter(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value >= 0x3400 && value <= 0x4DBF)
                || (value >= 0x4E00 && value <= 0x9FFF)
                || (value >= 0xF900 && value <= 0xFAFF)
                || (value >= 0x20000 && value <= 0x2CEAF)
                || (value >= 0x30000 && value <= 0x3134F)
        }
    }

    private static func isASCIIPinyinInput(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    private var partialSelectionPrefixText: String {
        partialSelectionSteps.reduce(into: "") { text, step in
            text += step.committedText
        }
    }

    private var partialSelectionRawPinyinPrefixText: String {
        partialSelectionSteps.reduce(into: "") { text, step in
            text += step.consumedRawPinyin
        }
    }

    private func partialSelectionDisplayText(with remainingRawPinyin: String) -> String {
        let prefixText = partialSelectionPrefixText
        guard !prefixText.isEmpty else { return remainingRawPinyin }
        guard !remainingRawPinyin.isEmpty else { return prefixText }
        let remainingText = PinyinCompositionFormatter.segmentedDisplayText(from: remainingRawPinyin)
        return "\(prefixText)'\(remainingText)"
    }

    private func clearPartialSelection() {
        partialSelectionSteps.removeAll()
    }

    private func resolvedCommittedText(
        for candidate: KeyboardInputCandidate,
        committedText: String?
    ) -> String? {
        if let committedText, !committedText.isEmpty {
            return committedText
        }
        return candidate.text.isEmpty ? nil : candidate.text
    }

    private func finalizeCommittedText(_ committedText: String?) -> String? {
        let prefixText = partialSelectionPrefixText
        if let committedText, !committedText.isEmpty {
            return prefixText + committedText
        }
        return prefixText.isEmpty ? committedText : prefixText
    }

    private func rebuildComposition(with rawPinyin: String) {
        engine.clearComposition()
        guard !rawPinyin.isEmpty else { return }
        for scalar in rawPinyin.unicodeScalars {
            engine.insertLetter(String(scalar))
        }
    }

    func insertLetter(_ letter: String) {
        hideQuickFillPanelIfNeeded()
        engine.insertLetter(letter)
        resetCandidateScrollPosition()
        hideCandidatePageIfNeeded()
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: false)
    }

    func deleteBackward() -> Bool {
        if let lastPartialSelection = partialSelectionSteps.popLast() {
            let restoredRawPinyin = lastPartialSelection.consumedRawPinyin + engine.rawPinyin
            rebuildComposition(with: restoredRawPinyin)
            resetCandidateScrollPosition()
            refreshPublishedComposition()
            scheduleCandidateRefresh(resetCandidatesWhenEmpty: !engine.hasComposition)
            return true
        }

        let didDelete = engine.deleteBackward()
        if didDelete {
            resetCandidateScrollPosition()
        }
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: !engine.hasComposition)
        return didDelete
    }

    func select(_ candidate: KeyboardInputCandidate) -> String? {
        guard !isCandidateRefreshPending else { return nil }
        let rawPinyinBeforeSelect = engine.rawPinyin
        let committedText = engine.select(candidate)
        let rawPinyinAfterSelect = engine.rawPinyin
        let selectedText = resolvedCommittedText(for: candidate, committedText: committedText)
        let splitRawPinyin = Self.splitRawPinyinAfterCandidateSelection(
            candidate,
            selectedText: selectedText,
            rawPinyinBeforeSelect: rawPinyinBeforeSelect,
            rawPinyinAfterSelect: rawPinyinAfterSelect
        )

        if !splitRawPinyin.remaining.isEmpty,
           let selectedText,
           !selectedText.isEmpty {
            partialSelectionSteps.append(
                PartialSelectionStep(
                    committedText: selectedText,
                    consumedRawPinyin: splitRawPinyin.consumed
                )
            )
            rebuildComposition(with: splitRawPinyin.remaining)
            requestCandidateScrollResetAfterRefresh()
            refreshPublishedComposition()
            scheduleCandidateRefresh(resetCandidatesWhenEmpty: false)
            return nil
        }

        let finalCommittedText = finalizeCommittedText(selectedText ?? committedText)

        if finalCommittedText != nil {
            clearPartialSelection()
            hideCandidatePageIfNeeded()
        }
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: false)
        return finalCommittedText
    }

    func commitCompositionAsText() -> String? {
        let text = engine.commitCompositionAsText()
        let finalText = finalizeCommittedText(text)
        clearPartialSelection()
        hideCandidatePageIfNeeded()
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: false)
        return finalText
    }

    func commitRawInputAsText() -> String? {
        let text = engine.commitRawInputAsText()
        let finalText = finalizeCommittedText(text)
        clearPartialSelection()
        hideCandidatePageIfNeeded()
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: true)
        return finalText
    }

    func toggleChineseInput() {
        isChineseInputEnabled.toggle()
        clearPartialSelection()
        hideCandidatePageIfNeeded()
        refreshPublishedComposition()
        scheduleCandidateRefresh(resetCandidatesWhenEmpty: true)
    }

    func firstFreshCandidateForCommit() -> KeyboardInputCandidate? {
        guard isChineseInputEnabled else { return nil }
        if isCandidateRefreshPending || appliedCandidateGeneration != candidateRefreshGeneration {
            candidateRefreshWorkItem?.cancel()
            candidateRefreshWorkItem = nil
            candidateRefreshGeneration += 1
            let generation = candidateRefreshGeneration
            applyCandidateRefreshResult(engine.candidates, generation: generation)
        }
        return candidates.first
    }

    func firstFreshCompositionCandidateForCommit() -> KeyboardInputCandidate? {
        guard hasComposition else { return nil }
        return firstFreshCandidateForCommit()
    }

    func toggleQuickFillPanel() {
        reloadQuickFillItems()
        setEmojiPanelVisible(false)
        setTranslationPanelVisible(false)
        if isQuickFillAddInputVisible {
            returnToQuickFillPanel()
            return
        }
        isQuickFillAddInputVisible = false
        quickFillDraftText = ""
        quickFillDraftCursorOffset = 0
        isQuickFillPanelVisible.toggle()
        if isQuickFillPanelVisible {
            hideCandidatePageIfNeeded()
        }
    }

    func setQuickFillPanelVisible(_ visible: Bool) {
        if visible {
            reloadQuickFillItems()
            setEmojiPanelVisible(false)
            setTranslationPanelVisible(false)
            hideCandidatePageIfNeeded()
        } else {
            isQuickFillAddInputVisible = false
            quickFillDraftText = ""
            quickFillDraftCursorOffset = 0
        }
        if isQuickFillPanelVisible != visible {
            isQuickFillPanelVisible = visible
        }
    }

    func showQuickFillAddInput() {
        setEmojiPanelVisible(false)
        setTranslationPanelVisible(false)
        quickFillDraftText = ""
        quickFillDraftCursorOffset = 0
        quickFillEditingOriginalText = nil
        isQuickFillAddInputVisible = true
        isQuickFillPanelVisible = false
        hideCandidatePageIfNeeded()
    }

    func closeQuickFillAddInput() {
        isQuickFillAddInputVisible = false
        quickFillDraftText = ""
        quickFillDraftCursorOffset = 0
        quickFillEditingOriginalText = nil
    }

    func returnToQuickFillPanel() {
        reloadQuickFillItems()
        isQuickFillAddInputVisible = false
        quickFillDraftText = ""
        quickFillDraftCursorOffset = 0
        quickFillEditingOriginalText = nil
        isQuickFillPanelVisible = true
        hideCandidatePageIfNeeded()
    }

    func beginEditingQuickFillItem(_ item: String) {
        quickFillEditingOriginalText = item
        quickFillDraftText = item
        quickFillDraftCursorOffset = item.count
        isQuickFillAddInputVisible = true
        isQuickFillPanelVisible = false
        hideCandidatePageIfNeeded()
    }

    func appendQuickFillDraftText(_ text: String) {
        guard isQuickFillAddInputVisible, !text.isEmpty else { return }
        let insertionOffset = clampedQuickFillDraftCursorOffset
        let insertionIndex = quickFillDraftText.index(quickFillDraftText.startIndex, offsetBy: insertionOffset)
        quickFillDraftText.insert(contentsOf: text, at: insertionIndex)
        quickFillDraftCursorOffset = insertionOffset + text.count
    }

    func deleteQuickFillDraftBackward() -> Bool {
        guard isQuickFillAddInputVisible,
              !quickFillDraftText.isEmpty,
              clampedQuickFillDraftCursorOffset > 0 else { return false }
        let cursorOffset = clampedQuickFillDraftCursorOffset
        let endIndex = quickFillDraftText.index(quickFillDraftText.startIndex, offsetBy: cursorOffset)
        let deleteIndex = quickFillDraftText.index(before: endIndex)
        quickFillDraftText.remove(at: deleteIndex)
        quickFillDraftCursorOffset = cursorOffset - 1
        return true
    }

    func moveQuickFillDraftCursor(by offset: Int) {
        guard isQuickFillAddInputVisible, offset != 0 else { return }
        quickFillDraftCursorOffset = max(0, min(quickFillDraftText.count, clampedQuickFillDraftCursorOffset + offset))
    }

    func setQuickFillDraftCursorOffset(_ offset: Int) {
        guard isQuickFillAddInputVisible else { return }
        quickFillDraftCursorOffset = max(0, min(quickFillDraftText.count, offset))
    }

    func moveQuickFillDraftCursorToEnd() {
        quickFillDraftCursorOffset = quickFillDraftText.count
    }

    func saveQuickFillDraft() {
        if hasComposition, let text = commitCompositionAsText() {
            appendQuickFillDraftText(text)
        }
        let text = quickFillDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let editingOriginalText = quickFillEditingOriginalText
        var items = quickFillItems.filter { item in
            item != text && item != editingOriginalText
        }
        if let editingOriginalText,
           let originalIndex = quickFillItems.firstIndex(of: editingOriginalText) {
            items.insert(text, at: min(originalIndex, items.count))
        } else {
            items.insert(text, at: 0)
        }
        persistQuickFillItems(items)
        returnToQuickFillPanel()
    }

    func deleteQuickFillItem(_ item: String) {
        let items = quickFillItems.filter { $0 != item }
        persistQuickFillItems(items)
    }

    func reloadQuickFillItems() {
        sharedDefaults?.synchronize()
        quickFillItems = sharedDefaults?.stringArray(forKey: Self.quickFillItemsDefaultsKey) ?? []
    }

    func clearAssociationSuggestions() {
        engine.clearAssociationContext()
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        candidateRefreshGeneration += 1
        appliedCandidateGeneration = candidateRefreshGeneration
        setCandidateRefreshPending(false)
        if !candidates.isEmpty {
            candidates = []
        }
        hideCandidatePageIfNeeded()
    }

    func updateSpaceTrackpadPreview(offset: Int) {
        if !isSpaceTrackpadActive {
            isSpaceTrackpadActive = true
        }
        if spaceTrackpadPreviewOffset != offset {
            spaceTrackpadPreviewOffset = offset
        }
    }

    func endSpaceTrackpadPreview() {
        if isSpaceTrackpadActive {
            isSpaceTrackpadActive = false
        }
        if spaceTrackpadPreviewOffset != 0 {
            spaceTrackpadPreviewOffset = 0
        }
    }

    func openTranslationPanel(hasFullAccess: Bool) {
        setEmojiPanelVisible(false)
        isQuickFillPanelVisible = false
        isQuickFillAddInputVisible = false
        quickFillDraftText = ""
        quickFillDraftCursorOffset = 0
        quickFillEditingOriginalText = nil
        hideCandidatePageIfNeeded()
        setTranslationPanelVisible(true)
        startClipboardTranslation(hasFullAccess: hasFullAccess)
    }

    func setTranslationPanelVisible(_ visible: Bool) {
        guard isTranslationPanelVisible != visible else { return }
        isTranslationPanelVisible = visible
        if visible {
            isEmojiPanelVisible = false
            isQuickFillPanelVisible = false
            isQuickFillAddInputVisible = false
            hideCandidatePageIfNeeded()
        } else {
            cancelTranslationRequest()
        }
    }

    private func startClipboardTranslation(hasFullAccess: Bool) {
        cancelTranslationRequest()
        activeTranslationRequestID += 1
        let requestID = activeTranslationRequestID

        guard hasFullAccess else {
            translationText = "请在系统设置中为键盘开启“允许完全访问”，用于读取粘贴板并访问翻译服务。"
            translationStatusText = "需要权限"
            return
        }

        let sourceText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourceText.isEmpty else {
            translationText = "粘贴板暂无可翻译文本。"
            translationStatusText = "空粘贴板"
            return
        }

        translationText = ""
        translationStatusText = "翻译中…"
        requestStreamingTranslation(for: sourceText, requestID: requestID)
    }

    private func requestStreamingTranslation(for text: String, requestID: Int) {
        let storedBaseURL = sharedDefaults?.string(forKey: "translate.baseURL") ?? "http://192.168.2.88:11434"
        let storedModel = sharedDefaults?.string(forKey: "translate.model") ?? "transgemma4b"
        let baseURL = storedBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = storedModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/api/generate") else {
            translationText = "翻译服务地址无效，请在 App 的设置中检查服务地址。"
            translationStatusText = "配置错误"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        let prompt = """
        请自动识别以下文本的语言，并将内容翻译成简体中文。
        如果文本已经是中文，请保持中文原文，不要翻译成其他语言，也不要润色改写。
        只返回译文，不要返回解释、标签、原文或额外说明。

        \(text)
        """
        let body: [String: Any] = [
            "model": model.isEmpty ? "transgemma4b" : model,
            "prompt": prompt,
            "stream": true
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            translationText = "翻译请求构造失败。"
            translationStatusText = "请求错误"
            return
        }
        request.httpBody = data

        var accumulated = ""
        let delegate = OllamaTranslationStreamDelegate(
            onToken: { [weak self] (token: String) in
                DispatchQueue.main.async {
                    guard let self, self.activeTranslationRequestID == requestID else { return }
                    accumulated += token
                    self.translationText = accumulated
                }
            },
            onComplete: { [weak self] (errorMessage: String?) in
                DispatchQueue.main.async {
                    guard let self, self.activeTranslationRequestID == requestID else { return }
                    if let errorMessage {
                        self.translationStatusText = "失败"
                        if accumulated.isEmpty {
                            self.translationText = errorMessage
                        }
                    } else {
                        self.translationStatusText = "完成"
                    }
                    self.translationTask = nil
                    self.translationStreamDelegate = nil
                }
            }
        )
        translationStreamDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        translationTask = task
        task.resume()
    }

    private func cancelTranslationRequest() {
        activeTranslationRequestID += 1
        translationTask?.cancel()
        translationTask = nil
        translationStreamDelegate = nil
    }

    func toggleEmojiPanel() {
        reloadEmojiItemsIfNeeded()
        setEmojiPanelVisible(!isEmojiPanelVisible)
    }

    func setNumericOrSymbolicKeyboardVisible(_ visible: Bool) {
        if isNumericOrSymbolicKeyboardVisible != visible {
            isNumericOrSymbolicKeyboardVisible = visible
        }
        if !visible {
            setNineGridNumericKeyboardVisible(false)
        }
    }

    func toggleNineGridNumericKeyboard() {
        setNineGridNumericKeyboardVisible(!isNineGridNumericKeyboardVisible)
    }

    func setNineGridNumericKeyboardVisible(_ visible: Bool) {
        guard isNineGridNumericKeyboardVisible != visible else { return }
        if visible {
            isQuickFillPanelVisible = false
            isQuickFillAddInputVisible = false
            quickFillDraftText = ""
            quickFillDraftCursorOffset = 0
            quickFillEditingOriginalText = nil
            setEmojiPanelVisible(false)
            setTranslationPanelVisible(false)
            hideCandidatePageIfNeeded()
        }
        isNineGridNumericKeyboardVisible = visible
    }

    func setEmojiPanelVisible(_ visible: Bool) {
        if visible {
            reloadEmojiItemsIfNeeded()
            isQuickFillPanelVisible = false
            isQuickFillAddInputVisible = false
            quickFillDraftText = ""
            quickFillDraftCursorOffset = 0
            quickFillEditingOriginalText = nil
            setTranslationPanelVisible(false)
            hideCandidatePageIfNeeded()
        }
        if isEmojiPanelVisible != visible {
            isEmojiPanelVisible = visible
        }
    }

    private func reloadEmojiItemsIfNeeded() {
        guard emojiSections.isEmpty else { return }
        let loadedSections = Self.loadEmojiSectionsFromBundle()
        emojiSections = loadedSections
        emojiItems = loadedSections
            .filter { $0.category != .frequent }
            .flatMap(\.items)
    }

    private static func loadEmojiSectionsFromBundle() -> [PinyinEmojiSection] {
        let bundle = Bundle(for: KeyboardViewController.self)
        let fileURL: URL?
        if let directURL = bundle.url(forResource: emojiDataRelativePath, withExtension: nil) {
            fileURL = directURL
        } else {
            fileURL = bundle.url(forResource: "emoji", withExtension: "txt", subdirectory: "RimeShared/lua/data")
        }

        guard let fileURL,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var seen = Set<String>()
        var itemsByCategory: [PinyinEmojiCategory: [String]] = [:]
        var frequentItems: [String] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard columns.count == 2 else { continue }
            let keyword = String(columns[0])
            for rawItem in columns[1].split(separator: "|", omittingEmptySubsequences: true) {
                let item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty, !seen.contains(item) else { continue }
                seen.insert(item)
                if frequentItems.count < 84 {
                    frequentItems.append(item)
                }
                let category = emojiCategory(keyword: keyword, item: item)
                itemsByCategory[category, default: []].append(item)
            }
        }
        itemsByCategory[.frequent] = frequentItems
        return PinyinEmojiCategory.allCases.compactMap { category in
            guard let items = itemsByCategory[category], !items.isEmpty else { return nil }
            return PinyinEmojiSection(category: category, items: items)
        }
    }

    private static func emojiCategory(keyword: String, item: String) -> PinyinEmojiCategory {
        if isFlagEmoji(keyword: keyword, item: item) { return .flags }
        if isCurrencyEmoji(keyword: keyword, item: item) { return .currency }
        if keywordContains(keyword, ["手", "掌", "指", "拳", "拇指", "握", "拍手", "合十"]) || hasScalar(in: item, ranges: [0x1F44A...0x1F450, 0x1F590...0x1F596, 0x1F64F...0x1F64F, 0x1F91A...0x1F91F, 0x1FAF0...0x1FAFF]) { return .hands }
        if keywordContains(keyword, ["笑", "脸", "哭", "表情", "嘴", "眼", "吐舌", "眨眼", "生气", "惊讶"]) || hasScalar(in: item, ranges: [0x1F600...0x1F64F, 0x1F970...0x1F97F]) { return .faces }
        if keywordContains(keyword, ["猫", "狗", "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "猪", "鸟", "鱼", "动物"]) || hasScalar(in: item, ranges: [0x1F400...0x1F43F, 0x1F980...0x1F9AE]) { return .animals }
        if keywordContains(keyword, ["饭", "面", "食", "餐", "咖啡", "酒", "茶", "水果", "蛋糕", "糖", "披萨"]) || hasScalar(in: item, ranges: [0x1F32D...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9FF]) { return .food }
        if keywordContains(keyword, ["球", "游戏", "运动", "比赛", "奖", "牌", "靶", "节日", "烟花"]) || hasScalar(in: item, ranges: [0x1F3A0...0x1F3FF]) { return .activity }
        if keywordContains(keyword, ["电话", "电脑", "键盘", "表", "钟", "工具", "剑", "锚", "齿轮", "医疗", "按钮", "相机", "书", "笔"]) || hasScalar(in: item, ranges: [0x1F4A0...0x1F5FF]) { return .objects }
        return .symbols
    }

    private static func isFlagEmoji(keyword: String, item: String) -> Bool {
        keywordContains(keyword, ["旗", "国旗", "红旗", "白旗", "黑旗", "彩虹旗", "海盗旗"])
            || hasScalar(in: item, ranges: [0x1F1E6...0x1F1FF])
            || item.contains("🏳")
            || item.contains("🏴")
            || item.contains("🎌")
            || item.contains("🎏")
            || item.contains("🏁")
    }

    private static func isCurrencyEmoji(keyword: String, item: String) -> Bool {
        if keywordContains(keyword, ["美元", "美刀", "港元", "港币", "澳门元", "澳门币", "葡币", "新加坡元", "新加坡币", "英镑", "欧元", "卢比", "人民币", "比特币", "泰铢", "货币", "钱", "币"]) {
            return true
        }
        let currencyItems: Set<String> = ["$", "HK$", "MOP$", "S$", "£", "€", "￥", "¥", "₨", "₹", "₿", "฿", "💵", "💲", "💷", "💶", "💴", "💰", "🪙"]
        return currencyItems.contains(item)
    }

    private static func keywordContains(_ keyword: String, _ values: [String]) -> Bool {
        values.contains { keyword.localizedCaseInsensitiveContains($0) }
    }

    private static func hasScalar(in item: String, ranges: [ClosedRange<UInt32>]) -> Bool {
        item.unicodeScalars.contains { scalar in
            ranges.contains { $0.contains(scalar.value) }
        }
    }

    private func persistQuickFillItems(_ items: [String]) {
        quickFillItems = items
        sharedDefaults?.set(items, forKey: Self.quickFillItemsDefaultsKey)
        sharedDefaults?.synchronize()
    }

    private static func logInputEngineInfo(_ message: String) {
        appendKeyboardDiagnosticLog(component: "InputEngine", level: "info", message: message)
    }

    private static func appendKeyboardDiagnosticLog(
        component: String,
        level: String,
        message: String,
        error: String? = nil
    ) {
        let now = Date()
        keyboardDiagnosticLogQueue.async {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedDefaultsSuiteName) else { return }
            let fileURL = containerURL
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("\(keyboardDiagnosticLogChunkFormatter.string(from: now)).jsonl")
            let entry: [String: Any] = [
                "id": UUID().uuidString,
                "timestamp": keyboardDiagnosticLogDateFormatter.string(from: now),
                "source": "keyboard",
                "category": "keyboardDiagnostic",
                "level": level,
                "message": "[\(component)] \(message)",
                "method": "",
                "url": "",
                "requestHeaders": [:],
                "requestBody": "",
                "statusCode": NSNull(),
                "responseHeaders": [:],
                "responseBody": "",
                "error": error.map { $0 as Any } ?? NSNull(),
                "durationMS": 0,
                "metadata": [
                    "diagnosticArea": "keyboardExtension",
                    "component": component
                ]
            ]

            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let data = try JSONSerialization.data(withJSONObject: entry, options: [])
                guard let line = String(data: data, encoding: .utf8), let lineData = "\(line)\n".data(using: .utf8) else { return }
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            } catch {
                NSLog("[KeyboardDiagnostic] failed to write app-group log: %@", error.localizedDescription)
            }
        }
    }

    private var clampedQuickFillDraftCursorOffset: Int {
        max(0, min(quickFillDraftCursorOffset, quickFillDraftText.count))
    }

    private func scheduleCandidateRefresh(resetCandidatesWhenEmpty: Bool) {
        candidateRefreshGeneration += 1
        candidateRefreshWorkItem?.cancel()
        let generation = candidateRefreshGeneration

        guard isChineseInputEnabled else {
            applyCandidateRefreshResult([], generation: generation)
            return
        }

        if resetCandidatesWhenEmpty, !engine.hasComposition {
            applyCandidateRefreshResult([], generation: generation)
            return
        }

        let engineSnapshot = engine
        setCandidateRefreshPending(true)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            guard !workItem.isCancelled else { return }
            let refreshedCandidates = engineSnapshot.candidates
            guard !workItem.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.candidateRefreshGeneration == generation,
                      !workItem.isCancelled else {
                    return
                }
                self.applyCandidateRefreshResult(refreshedCandidates, generation: generation)
            }
        }
        candidateRefreshWorkItem = workItem
        candidateQueue.asyncAfter(deadline: .now() + Self.candidateRefreshDelay, execute: workItem)
    }

    private func cancelPendingCandidateRefresh(clearCandidates: Bool) {
        candidateRefreshGeneration += 1
        candidateRefreshWorkItem?.cancel()
        candidateRefreshWorkItem = nil
        appliedCandidateGeneration = candidateRefreshGeneration
        setCandidateRefreshPending(false)
        if clearCandidates, !candidates.isEmpty {
            candidates = []
        }
    }

    private func applyCandidateRefreshResult(
        _ refreshedCandidates: [KeyboardInputCandidate],
        generation: Int
    ) {
        guard generation == candidateRefreshGeneration else { return }
        candidateRefreshWorkItem = nil
        setCandidateRefreshPending(false)
        appliedCandidateGeneration = generation
        if candidates != refreshedCandidates {
            candidates = refreshedCandidates
        }
        if shouldResetCandidateScrollAfterRefresh {
            shouldResetCandidateScrollAfterRefresh = false
            resetCandidateScrollPosition()
        }
        if refreshedCandidates.isEmpty {
            hideCandidatePageIfNeeded()
        }
    }

    private func refreshPublishedComposition() {
        updatePublishedEngineState()

        let partialPrefixText = partialSelectionPrefixText
        let engineDisplayText = engine.displayText
        let nextDisplayText: String
        if partialPrefixText.isEmpty {
            nextDisplayText = engineDisplayText
        } else if engine.hasComposition {
            nextDisplayText = partialPrefixText + engineDisplayText
        } else {
            nextDisplayText = partialPrefixText
        }
        if displayText != nextDisplayText {
            displayText = nextDisplayText
        }

        let partialRawPinyinPrefixText = partialSelectionRawPinyinPrefixText
        let nextRawPinyinText: String
        if !partialPrefixText.isEmpty {
            nextRawPinyinText = partialSelectionDisplayText(with: engine.rawPinyin)
        } else if engine.hasComposition || !partialRawPinyinPrefixText.isEmpty {
            nextRawPinyinText = partialRawPinyinPrefixText + engine.rawPinyin
        } else {
            nextRawPinyinText = ""
        }
        if rawPinyinText != nextRawPinyinText {
            rawPinyinText = nextRawPinyinText
        }

        let nextDisplayCursorOffset: Int
        if partialPrefixText.isEmpty {
            nextDisplayCursorOffset = engine.displayCursorOffset
        } else if engine.hasComposition {
            nextDisplayCursorOffset = partialPrefixText.count + engine.displayCursorOffset
        } else {
            nextDisplayCursorOffset = partialPrefixText.count
        }
        if displayCursorOffset != nextDisplayCursorOffset {
            displayCursorOffset = nextDisplayCursorOffset
        }

        let nextHasComposition = engine.hasComposition || !partialPrefixText.isEmpty
        if hasComposition != nextHasComposition {
            hasComposition = nextHasComposition
        }

        let nextInputEngineFailureText = engine.failureText
        if inputEngineFailureText != nextInputEngineFailureText {
            inputEngineFailureText = nextInputEngineFailureText
        }
    }

    private func updatePublishedEngineState() {
        let nextIsUsingRimeEngine = engine.isUsingRime
        if isUsingRimeEngine != nextIsUsingRimeEngine {
            isUsingRimeEngine = nextIsUsingRimeEngine
        }
    }

    private func setCandidateRefreshPending(_ isPending: Bool) {
        if isCandidateRefreshPending != isPending {
            isCandidateRefreshPending = isPending
        }
    }

    private func hideCandidatePageIfNeeded() {
        if isCandidatePageVisible {
            isCandidatePageVisible = false
        }
    }

    private func hideQuickFillPanelIfNeeded() {
        if isQuickFillPanelVisible {
            setQuickFillPanelVisible(false)
        }
    }

    private func resetCandidateScrollPosition() {
        candidateScrollResetToken += 1
    }

    private func requestCandidateScrollResetAfterRefresh() {
        shouldResetCandidateScrollAfterRefresh = true
    }
}

private final class PinyinKeyboardActionHandler: KeyboardActionHandler {
    private static let languageSwitchActionName = "simpanin.inputMode.toggleChineseEnglish"
    private static let smartPunctuationActionName = "simpanin.punctuation.smartCommaPeriod"
    private static let numericSymbolicPlaceholderActionName = "simpanin.keyboard.bottomRowPlaceholder1234"
    private static let spaceCursorHorizontalPointsPerCharacter: CGFloat = 4.0
    private static let spaceCursorVerticalPointsPerCharacter: CGFloat = 20

    private weak var controller: KeyboardInputViewController?
    private let standardActionHandler: any KeyboardActionHandler
    private let pinyinState: PinyinKeyboardInputState
    private var appliedSpaceCursorDragOffset = 0
    private var didMoveCursorWithSpaceDrag = false

    init(
        controller: KeyboardInputViewController,
        standardActionHandler: any KeyboardActionHandler,
        pinyinState: PinyinKeyboardInputState
    ) {
        self.controller = controller
        self.standardActionHandler = standardActionHandler
        self.pinyinState = pinyinState
    }

    func canHandle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) -> Bool {
        if shouldHandlePinyinAction(action) {
            return true
        }
        return standardActionHandler.canHandle(gesture, on: action)
    }

    func handle(_ action: KeyboardAction) {
        switch action {
        case .custom(named: Self.numericSymbolicPlaceholderActionName):
            handleNineGridNumericKeyboardToggle()
        case .custom(named: Self.languageSwitchActionName):
            handleLanguageSwitch()
        case .custom(named: Self.smartPunctuationActionName):
            handleSmartPunctuation()
        case .shift(let keyboardCase):
            handleShift(keyboardCase)
        case .character(let value) where pinyinState.isQuickFillAddInputVisible:
            handleQuickFillAddCharacter(value)
            applyLockedKeyboardCase()
        case .character(let value) where shouldDirectlyInsertURLCharacter(value):
            handleURLDirectCharacter(value)
        case .character(let value) where directPunctuationText(for: value) != nil:
            handleDirectPunctuation(value)
        case .character(let value) where shouldRouteCharacterToInputEngine(value):
            pinyinState.insertLetter(value)
            applyLockedKeyboardCase()
        case .backspace where pinyinState.isQuickFillAddInputVisible:
            handleQuickFillAddBackspace()
            applyLockedKeyboardCase()
        case .backspace where pinyinState.hasComposition:
            if pinyinState.deleteBackward() {
                applyLockedKeyboardCase()
            } else {
                standardActionHandler.handle(action)
                applyLockedKeyboardCase()
            }
        case .backspace:
            if pinyinState.deleteQuickFillDraftBackward() {
                applyLockedKeyboardCase()
                return
            }
            handlePlainBackspace()
        case .primary:
            if pinyinState.isQuickFillAddInputVisible {
                handleQuickFillAddPrimary()
                applyLockedKeyboardCaseDeferred()
                return
            }
            if pinyinState.hasComposition,
               let text = pinyinState.commitRawInputAsText() {
                commitText(text)
                applyLockedKeyboardCaseDeferred()
                return
            }
            standardActionHandler.handle(action)
            applyLockedKeyboardCaseDeferred()
        case .keyboardType(.alphabetic):
            handleAlphabeticKeyboardTypeSwitch(action)
        default:
            standardActionHandler.handle(action)
            applyLockedKeyboardCase()
        }
    }

    func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
        guard gesture == .release else {
            if shouldConsumePreReleaseGesture(on: action) {
                return
            }
            standardActionHandler.handle(gesture, on: action)
            return
        }

        switch action {
        case .custom(named: Self.numericSymbolicPlaceholderActionName):
            handleNineGridNumericKeyboardToggle()
        case .custom(named: Self.languageSwitchActionName):
            handleLanguageSwitch()
        case .custom(named: Self.smartPunctuationActionName):
            handleSmartPunctuation()
        case .shift(let keyboardCase):
            handleShift(keyboardCase)
        case .character(let value):
            if pinyinState.isQuickFillAddInputVisible {
                handleQuickFillAddCharacter(value)
                applyLockedKeyboardCase()
                return
            }
            if shouldDirectlyInsertURLCharacter(value) {
                handleURLDirectCharacter(value)
                return
            }
            if directPunctuationText(for: value) != nil {
                handleDirectPunctuation(value)
                return
            }
            guard shouldRouteCharacterToInputEngine(value) else {
                handleStandardAction(gesture, on: action)
                return
            }
            pinyinState.insertLetter(value)
            applyLockedKeyboardCase()
        case .backspace:
            if pinyinState.isQuickFillAddInputVisible {
                handleQuickFillAddBackspace()
                applyLockedKeyboardCase()
                return
            }
            guard pinyinState.hasComposition else {
                if pinyinState.deleteQuickFillDraftBackward() {
                    applyLockedKeyboardCase()
                    return
                }
                handlePlainBackspace()
                return
            }
            if pinyinState.deleteBackward() {
                applyLockedKeyboardCase()
            } else {
                handleStandardAction(gesture, on: action)
            }
        case .space:
            if didMoveCursorWithSpaceDrag {
                resetSpaceCursorDrag()
                applyLockedKeyboardCase()
                return
            }
            if pinyinState.isQuickFillAddInputVisible {
                handleQuickFillAddSpace()
                applyLockedKeyboardCase()
                return
            }
            guard let first = pinyinState.firstFreshCompositionCandidateForCommit() else {
                handleStandardAction(gesture, on: action)
                return
            }
            if let text = pinyinState.select(first) {
                commitText(text)
            }
            applyLockedKeyboardCase()
        case .primary:
            if pinyinState.isQuickFillAddInputVisible {
                handleQuickFillAddPrimary()
                applyLockedKeyboardCaseDeferred()
                return
            }
            if pinyinState.hasComposition,
               let text = pinyinState.commitRawInputAsText() {
                commitText(text)
                applyLockedKeyboardCaseDeferred()
                return
            }
            handleStandardAction(gesture, on: action)
            applyLockedKeyboardCaseDeferred()
        case .keyboardType(.alphabetic):
            if pinyinState.hasComposition,
               let text = pinyinState.commitCompositionAsText() {
                commitText(text)
            }
            handleAlphabeticKeyboardTypeSwitch(gesture, on: action)
        default:
            if pinyinState.hasComposition,
               let text = pinyinState.commitCompositionAsText() {
                commitText(text)
            }
            handleStandardAction(gesture, on: action)
        }
    }

    func handle(_ suggestion: Autocomplete.Suggestion) {
        standardActionHandler.handle(suggestion)
    }

    func handleDrag(
        on action: KeyboardAction,
        from startLocation: CGPoint,
        to currentLocation: CGPoint
    ) {
        if case .custom(named: Self.numericSymbolicPlaceholderActionName) = action {
            return
        }
        if isSpaceAction(action) {
            guard !pinyinState.isQuickFillAddInputVisible else {
                resetSpaceCursorDrag()
                return
            }
            handleSpaceCursorDrag(from: startLocation, to: currentLocation)
        } else {
            resetSpaceCursorDrag()
            standardActionHandler.handleDrag(on: action, from: startLocation, to: currentLocation)
        }
    }

    private func isSpaceAction(_ action: KeyboardAction) -> Bool {
        switch action {
        case .space:
            return true
        default:
            return false
        }
    }

    private func handleSpaceCursorDrag(
        from startLocation: CGPoint,
        to currentLocation: CGPoint
    ) {
        guard !pinyinState.isQuickFillAddInputVisible else {
            resetSpaceCursorDrag()
            return
        }

        let targetOffset = spaceCursorTargetOffset(from: startLocation, to: currentLocation)
        let offset = targetOffset - appliedSpaceCursorDragOffset
        guard offset != 0 else { return }

        appliedSpaceCursorDragOffset = targetOffset
        didMoveCursorWithSpaceDrag = true
        pinyinState.updateSpaceTrackpadPreview(offset: targetOffset)
        controller?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    private func spaceCursorTargetOffset(
        from startLocation: CGPoint,
        to currentLocation: CGPoint
    ) -> Int {
        let translation = CGSize(
            width: currentLocation.x - startLocation.x,
            height: currentLocation.y - startLocation.y
        )
        let horizontalOffset = Int((translation.width / Self.spaceCursorHorizontalPointsPerCharacter).rounded())
        let verticalOffset = Int((translation.height / Self.spaceCursorVerticalPointsPerCharacter).rounded())
        return horizontalOffset + verticalOffset
    }

    private func resetSpaceCursorDrag() {
        appliedSpaceCursorDragOffset = 0
        didMoveCursorWithSpaceDrag = false
        pinyinState.endSpaceTrackpadPreview()
    }

    func triggerFeedback(for gesture: Keyboard.Gesture, on action: KeyboardAction) {
        // Disable KeyboardKit's combined feedback path to avoid key haptics.
    }

    func triggerAudioFeedback(_ feedback: Feedback.Audio) {
        standardActionHandler.triggerAudioFeedback(feedback)
    }

    func triggerHapticFeedback(_ feedback: Feedback.Haptic) {
        // Key vibration is intentionally disabled for this keyboard.
    }

    private func isPinyinLetter(_ value: String) -> Bool {
        value.count == 1 && value.rangeOfCharacter(from: .letters) != nil
    }

    private func shouldRouteCharacterToInputEngine(_ value: String) -> Bool {
        guard !isURLInputType else { return false }
        guard pinyinState.isChineseInputEnabled, value.count == 1 else { return false }
        if directPunctuationText(for: value) != nil {
            return false
        }
        if isPinyinLetter(value) {
            return true
        }
        guard pinyinState.isUsingRimeEngine else {
            return false
        }
        if value == "/" || value == "'" {
            return true
        }
        return pinyinState.hasComposition && isRimeCompositionCharacter(value)
    }

    private var isURLInputType: Bool {
        controller?.state.keyboardContext.keyboardInputType == .url
    }

    private func shouldDirectlyInsertURLCharacter(_ value: String) -> Bool {
        isURLInputType && !pinyinState.isQuickFillAddInputVisible && !value.isEmpty
    }

    private func handleURLDirectCharacter(_ value: String) {
        if pinyinState.hasComposition,
           let text = pinyinState.commitRawInputAsText() {
            commitText(text)
        }
        commitText(value)
        applyLockedKeyboardCase()
    }

    private func isRimeCompositionCharacter(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else { return false }
        let asciiValue = scalar.value
        if asciiValue >= 48 && asciiValue <= 57 {
            return true
        }
        return Set("';/\\-=,.").contains(Character(value))
    }

    private func handleQuickFillAddCharacter(_ value: String) {
        if shouldRouteCharacterToInputEngine(value) {
            pinyinState.insertLetter(value)
        } else {
            pinyinState.appendQuickFillDraftText(value)
        }
    }

    private func handleQuickFillAddBackspace() {
        if pinyinState.hasComposition {
            _ = pinyinState.deleteBackward()
        } else {
            _ = pinyinState.deleteQuickFillDraftBackward()
        }
    }

    private func handleQuickFillAddSpace() {
        if pinyinState.hasComposition,
           let first = pinyinState.firstFreshCandidateForCommit(),
           let text = pinyinState.select(first) {
            commitText(text)
        } else {
            pinyinState.appendQuickFillDraftText(" ")
        }
    }

    private func handleQuickFillAddPrimary() {
        if pinyinState.hasComposition,
           let text = pinyinState.commitCompositionAsText() {
            commitText(text)
        } else {
            pinyinState.saveQuickFillDraft()
        }
    }

    private func shouldHandlePinyinAction(_ action: KeyboardAction) -> Bool {
        switch action {
        case .custom(named: Self.languageSwitchActionName),
             .custom(named: Self.smartPunctuationActionName),
             .custom(named: Self.numericSymbolicPlaceholderActionName):
            return true
        case .character(let value):
            if pinyinState.isQuickFillAddInputVisible {
                return true
            }
            if shouldDirectlyInsertURLCharacter(value) {
                return pinyinState.hasComposition
            }
            return directPunctuationText(for: value) != nil || shouldRouteCharacterToInputEngine(value)
        case .backspace, .shift, .space, .primary:
            return true
        case .keyboardType(.alphabetic):
            return true
        default:
            return false
        }
    }

    private func shouldConsumePreReleaseGesture(on action: KeyboardAction) -> Bool {
        switch action {
        case .custom(named: Self.smartPunctuationActionName),
             .custom(named: Self.numericSymbolicPlaceholderActionName):
            return true
        case .character(let value):
            if pinyinState.isQuickFillAddInputVisible {
                return true
            }
            if shouldDirectlyInsertURLCharacter(value) {
                return pinyinState.hasComposition
            }
            return directPunctuationText(for: value) != nil || shouldRouteCharacterToInputEngine(value)
        case .backspace:
            return true
        case .space:
            return pinyinState.isQuickFillAddInputVisible
        case .primary:
            return pinyinState.hasComposition || pinyinState.isQuickFillAddInputVisible
        case .keyboardType(.alphabetic):
            return false
        default:
            return false
        }
    }

    private func handleShift(_ keyboardCase: Keyboard.KeyboardCase) {
        pinyinState.isUppercaseLocked.toggle()
        applyLockedKeyboardCase()
    }

    private func handleLanguageSwitch() {
        if pinyinState.hasComposition,
           let text = pinyinState.commitCompositionAsText() {
            commitText(text)
        }
        pinyinState.toggleChineseInput()
        applyLockedKeyboardCase()
    }

    private func handleNineGridNumericKeyboardToggle() {
        if pinyinState.hasComposition,
           let text = pinyinState.commitCompositionAsText() {
            commitText(text)
        }
        pinyinState.toggleNineGridNumericKeyboard()
        applyLockedKeyboardCase()
    }

    private func handleSmartPunctuation() {
        guard !pinyinState.isNumericOrSymbolicKeyboardVisible else {
            applyLockedKeyboardCase()
            return
        }
        if pinyinState.isChineseInputEnabled {
            if pinyinState.hasComposition,
               let first = pinyinState.firstFreshCompositionCandidateForCommit(),
               let text = pinyinState.select(first) {
                commitText(text)
            }
            commitText("，")
        } else {
            commitText(".")
        }
        applyLockedKeyboardCase()
    }

    private func handleDirectPunctuation(_ value: String) {
        guard let punctuation = directPunctuationText(for: value) else { return }
        if pinyinState.hasComposition,
           let text = pinyinState.commitCompositionAsText() {
            commitText(text)
        }
        commitText(punctuation)
        applyLockedKeyboardCase()
    }

    private func directPunctuationText(for value: String) -> String? {
        guard !isURLInputType else { return nil }
        if value == "'" {
            return pinyinState.isChineseInputEnabled ? "’" : "'"
        }
        return directChinesePunctuationText(for: value)
    }

    private func directChinesePunctuationText(for value: String) -> String? {
        guard pinyinState.isChineseInputEnabled else { return nil }
        switch value {
        case "-", "/", "“", "”", "’":
            return value
        case "'":
            return "’"
        case "\"":
            return "“"
        default:
            return nil
        }
    }

    private func handleAlphabeticKeyboardTypeSwitch(_ action: KeyboardAction) {
        applyLockedKeyboardCase()
        standardActionHandler.handle(action)
        applyLockedKeyboardCaseDeferred()
    }

    private func handleAlphabeticKeyboardTypeSwitch(
        _ gesture: Keyboard.Gesture,
        on action: KeyboardAction
    ) {
        applyLockedKeyboardCase()
        standardActionHandler.handle(gesture, on: action)
        applyLockedKeyboardCaseDeferred()
    }

    private func commitText(_ text: String) {
        if pinyinState.isQuickFillAddInputVisible {
            pinyinState.appendQuickFillDraftText(text)
        } else {
            controller?.insertText(text)
        }
    }

    private func handleStandardAction(_ gesture: Keyboard.Gesture, on action: KeyboardAction) {
        standardActionHandler.handle(gesture, on: action)
        applyLockedKeyboardCase()
    }

    private func handlePlainBackspace() {
        if pinyinState.isQuickFillAddInputVisible,
           pinyinState.deleteQuickFillDraftBackward() {
            applyLockedKeyboardCase()
            return
        }
        controller?.textDocumentProxy.deleteBackward()
        applyLockedKeyboardCase()
    }

    private func applyLockedKeyboardCase() {
        controller?.setKeyboardCase(pinyinState.isUppercaseLocked ? .uppercased : .lowercased)
    }

    private func applyLockedKeyboardCaseDeferred() {
        applyLockedKeyboardCase()
        DispatchQueue.main.async { [weak self] in
            self?.applyLockedKeyboardCase()
        }
    }
}

private struct PinyinKeyboardView: View {
    private static let languageSwitchActionName = "simpanin.inputMode.toggleChineseEnglish"
    private static let smartPunctuationActionName = "simpanin.punctuation.smartCommaPeriod"
    private static let numericSymbolicPlaceholderActionName = "simpanin.keyboard.bottomRowPlaceholder1234"

    @ObservedObject var keyboardContext: KeyboardContext
    let services: Keyboard.Services
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let hasFullAccess: Bool
    let insertText: (String) -> Void
    let dismissKeyboard: () -> Void

    var body: some View {
        KeyboardView(
            layout: keyboardLayout,
            services: services,
            buttonContent: { params in
                if case .shift(let keyboardCase) = params.item.action {
                    PinyinShiftButtonContent(keyboardCase: keyboardCase)
                } else if case .custom(named: Self.languageSwitchActionName) = params.item.action {
                    PinyinLanguageSwitchButtonContent(isChineseInputEnabled: pinyinState.isChineseInputEnabled)
                } else if case .custom(named: Self.smartPunctuationActionName) = params.item.action {
                    PinyinSmartPunctuationButtonContent(value: smartPunctuationText)
                } else if case .custom(named: Self.numericSymbolicPlaceholderActionName) = params.item.action {
                    PinyinNumericSymbolicPlaceholderButtonContent()
                } else if case .primary = params.item.action, pinyinState.hasComposition || pinyinState.isQuickFillAddInputVisible {
                    PinyinPrimaryConfirmButtonContent(title: pinyinState.isQuickFillAddInputVisible && !pinyinState.hasComposition ? "保存" : "确认")
                } else if let value = centeredChinesePunctuationText(for: params.item.action) {
                    PinyinCenteredPunctuationButtonContent(value: value)
                } else {
                    params.view
                }
            },
            buttonView: { $0.view },
            collapsedView: { $0.view },
            emojiKeyboard: { $0.view },
            toolbar: { _ in
                PinyinCandidateToolbar(
                    pinyinState: pinyinState,
                    insertText: insertText,
                    dismissKeyboard: dismissKeyboard,
                    openQuickFillPanel: {
                        pinyinState.toggleQuickFillPanel()
                    },
                    openTranslationPanel: {
                        pinyinState.openTranslationPanel(hasFullAccess: hasFullAccess)
                    },
                    openEmojiPanel: {
                        pinyinState.toggleEmojiPanel()
                    }
                )
            }
        )
        .overlay(alignment: .top) {
            expandedCandidateOverlay
        }
        .overlay(alignment: .top) {
            quickFillOverlay
        }
        .overlay(alignment: .top) {
            translationOverlay
        }
        .overlay(alignment: .top) {
            emojiOverlay
        }
        .overlay(alignment: .topLeading) {
            edgeBlankTapOverlay
        }
        .overlay {
            nineGridNumericKeyboardOverlay
        }
        .overlay {
            spaceTrackpadOverlay
        }
        .onAppear {
            pinyinState.setNumericOrSymbolicKeyboardVisible(isNumericOrSymbolicKeyboard)
            pinyinState.scheduleDelayedRimeInputEngineReload()
        }
        .onChange(of: isNumericOrSymbolicKeyboard) { isNumericOrSymbolicKeyboard in
            pinyinState.setNumericOrSymbolicKeyboardVisible(isNumericOrSymbolicKeyboard)
        }
    }

    @ViewBuilder
    private var nineGridNumericKeyboardOverlay: some View {
        if pinyinState.isNineGridNumericKeyboardVisible && isNumericOrSymbolicKeyboard {
            PinyinNineGridNumericKeyboard(
                insertText: insertText,
                deleteBackward: {
                    pinyinState.setNineGridNumericKeyboardVisible(true)
                    services.actionHandler.handle(.backspace)
                },
                switchToAlphabetic: {
                    pinyinState.setNineGridNumericKeyboardVisible(false)
                    services.actionHandler.handle(.keyboardType(.alphabetic))
                },
                closeNineGrid: {
                    pinyinState.setNineGridNumericKeyboardVisible(false)
                }
            )
            .padding(.top, currentToolbarHeight)
            .transition(.opacity)
            .animation(.easeInOut(duration: PinyinKeyboardMetrics.quickFillPanelAnimationDuration), value: pinyinState.isNineGridNumericKeyboardVisible)
        }
    }

    @ViewBuilder
    private var spaceTrackpadOverlay: some View {
        if pinyinState.isSpaceTrackpadActive {
            PinyinSpaceTrackpadOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var edgeBlankTapOverlay: some View {
        if pinyinState.isChineseInputEnabled
            && keyboardContext.keyboardType == .alphabetic
            && keyboardContext.keyboardInputType != .url
            && !pinyinState.isCandidatePageVisible
            && !pinyinState.isQuickFillPanelVisible
            && !pinyinState.isQuickFillAddInputVisible
            && !pinyinState.isTranslationPanelVisible
            && !pinyinState.isEmojiPanelVisible
            && !pinyinState.isSpaceTrackpadActive {
            PinyinKeyboardEdgeBlankTapOverlay(
                topInset: currentToolbarHeight,
                isUppercaseLocked: pinyinState.isUppercaseLocked
            ) { letter in
                pinyinState.insertLetter(letter)
            }
        }
    }

    private var keyboardLayout: KeyboardLayout {
        var layout = KeyboardLayout.standard(for: keyboardContext)
        layout.itemRows = layout.itemRows.map { row in
            row.map { item in
                localizedPunctuationItem(lowercasedAlphabeticItem(item))
            }
        }

        switch keyboardContext.keyboardType {
        case .alphabetic:
            return alphabeticKeyboardLayout(layout)
        case .numeric:
            return numericOrSymbolicKeyboardLayout(layout)
        case .symbolic:
            return numericOrSymbolicKeyboardLayout(layout)
        default:
            return layout
        }
    }

    private var smartPunctuationText: String {
        pinyinState.isChineseInputEnabled ? "，" : "."
    }

    private var isNumericOrSymbolicKeyboard: Bool {
        switch keyboardContext.keyboardType {
        case .numeric, .symbolic:
            return true
        default:
            return false
        }
    }

    private func lowercasedAlphabeticItem(_ item: KeyboardLayout.Item) -> KeyboardLayout.Item {
        guard !pinyinState.isUppercaseLocked,
              case .character(let value) = item.action,
              let lowercasedValue = lowercasedASCIICharacter(value) else {
            return item
        }

        return KeyboardLayout.Item(
            action: .character(lowercasedValue),
            secondaryAction: item.secondaryAction,
            size: item.size,
            alignment: item.alignment,
            edgeInsets: item.edgeInsets
        )
    }

    private func lowercasedASCIICharacter(_ value: String) -> String? {
        guard value.count == 1,
              let scalar = value.unicodeScalars.first,
              scalar.value >= 65,
              scalar.value <= 90 else {
            return nil
        }
        return value.lowercased()
    }

    private func localizedPunctuationItem(_ item: KeyboardLayout.Item) -> KeyboardLayout.Item {
        guard keyboardContext.keyboardInputType != .url,
              pinyinState.isChineseInputEnabled,
              case .character(let value) = item.action,
              let localizedValue = localizedChinesePunctuation(for: value) else {
            return item
        }

        return KeyboardLayout.Item(
            action: .character(localizedValue),
            secondaryAction: item.secondaryAction,
            size: item.size,
            alignment: item.alignment,
            edgeInsets: item.edgeInsets
        )
    }

    private func localizedChinesePunctuation(for value: String) -> String? {
        switch value {
        case ":":
            return "："
        case ";":
            return "；"
        case "(":
            return "（"
        case ")":
            return "）"
        case "\"":
            return "“"
        case ".":
            return "。"
        case ",":
            return "，"
        case "?":
            return "？"
        case "!":
            return "！"
        case "'":
            return "’"
        case "[":
            return "【"
        case "]":
            return "】"
        case "{":
            return "《"
        case "}":
            return "》"
        case "%":
            return "％"
        case "\\":
            return "、"
        case "|":
            return "｜"
        case "~":
            return "～"
        case "<":
            return "〈"
        case ">":
            return "〉"
        default:
            return nil
        }
    }

    private func centeredChinesePunctuationText(for action: KeyboardAction) -> String? {
        guard keyboardContext.keyboardInputType != .url,
              pinyinState.isChineseInputEnabled,
              case .character(let value) = action,
              isCenteredChinesePunctuation(value) else {
            return nil
        }
        return value
    }

    private func isCenteredChinesePunctuation(_ value: String) -> Bool {
        switch value {
        case "：", "；", "（", "）", "“", "”", "‘", "’", "。", "，", "？", "！", "【", "】", "《", "》", "％", "、", "｜", "～", "〈", "〉":
            return true
        default:
            return false
        }
    }

    private func isPrimaryAction(_ action: KeyboardAction) -> Bool {
        if case .primary = action {
            return true
        }
        return false
    }

    private func alphabeticKeyboardLayout(_ layout: KeyboardLayout) -> KeyboardLayout {
        var layout = layout
        guard let bottomRowIndex = bottomRowIndex(in: layout),
              let numericItem = keyboardTypeSwitchItem(in: layout.itemRows[bottomRowIndex], for: .numeric),
              let spaceItem = layout.itemRows[bottomRowIndex].first(where: { isSpaceAction($0.action) }),
              let primaryItem = layout.itemRows[bottomRowIndex].first(where: { isPrimaryAction($0.action) }) else {
            return layout
        }

        let widths = bottomRowWidths(from: PinyinBottomRowWidthConfig.alphabeticRatios)
        layout.itemRows[bottomRowIndex] = [
            bottomRowItem(numericItem, width: widths[0]),
            bottomRowItem(action: .custom(named: Self.smartPunctuationActionName), width: widths[1]),
            bottomRowItem(spaceItem, width: widths[2]),
            bottomRowItem(action: .custom(named: Self.languageSwitchActionName), width: widths[3]),
            bottomRowItem(primaryItem, width: widths[4])
        ]
        return layout
    }

    private func numericOrSymbolicKeyboardLayout(_ layout: KeyboardLayout) -> KeyboardLayout {
        var layout = layout
        guard let bottomRowIndex = bottomRowIndex(in: layout),
              let spaceItem = layout.itemRows[bottomRowIndex].first(where: { isSpaceAction($0.action) }),
              let primaryItem = layout.itemRows[bottomRowIndex].first(where: { isPrimaryAction($0.action) }) else {
            return layout
        }

        let row = layout.itemRows[bottomRowIndex]
        let widths = bottomRowWidths(from: PinyinBottomRowWidthConfig.numericAndSymbolicRatios)
        let alphabeticItem = keyboardTypeSwitchItem(in: row, for: .alphabetic)
            ?? bottomRowItem(action: .keyboardType(.alphabetic), width: widths[0])

        layout.itemRows[bottomRowIndex] = [
            bottomRowItem(alphabeticItem, width: widths[0]),
            bottomRowItem(action: .custom(named: Self.numericSymbolicPlaceholderActionName), width: widths[1]),
            bottomRowItem(spaceItem, width: widths[2]),
            bottomRowItem(action: .custom(named: Self.languageSwitchActionName), width: widths[3]),
            bottomRowItem(primaryItem, width: widths[4])
        ]
        return layout
    }

    private func isSpaceAction(_ action: KeyboardAction) -> Bool {
        if case .space = action {
            return true
        }
        return false
    }

    private func bottomRowIndex(in layout: KeyboardLayout) -> Int? {
        layout.itemRows.lastIndex { row in
            row.contains(where: { isSpaceAction($0.action) })
                && row.contains(where: { isPrimaryAction($0.action) })
        }
    }

    private func keyboardTypeSwitchItem(
        in row: KeyboardLayout.ItemRow,
        for keyboardType: Keyboard.KeyboardType
    ) -> KeyboardLayout.Item? {
        row.first { item in
            if case .keyboardType(let itemKeyboardType) = item.action {
                return itemKeyboardType == keyboardType
            }
            return false
        }
    }

    private func bottomRowWidths(from ratios: [CGFloat]) -> [KeyboardLayout.ItemWidth] {
        let values = Array(ratios.prefix(5)).map { max($0, 0) }
        guard values.count == 5 else {
            return Array(repeating: .percentage(0.2), count: 5)
        }

        let total = values.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: .percentage(0.2), count: 5)
        }

        return values.map { .percentage($0 / total) }
    }

    private func bottomRowItem(
        _ item: KeyboardLayout.Item,
        width: KeyboardLayout.ItemWidth
    ) -> KeyboardLayout.Item {
        bottomRowItem(
            action: item.action,
            secondaryAction: item.secondaryAction,
            width: width
        )
    }

    private func bottomRowItem(
        action: KeyboardAction,
        secondaryAction: KeyboardAction? = nil,
        width: KeyboardLayout.ItemWidth
    ) -> KeyboardLayout.Item {
        KeyboardLayout.Item(
            action: action,
            secondaryAction: secondaryAction,
            size: .init(width: width, height: PinyinKeyboardMetrics.bottomRowKeyHeight),
            alignment: .center,
            edgeInsets: .init(
                top: 0,
                leading: PinyinKeyboardMetrics.bottomRowHorizontalInset,
                bottom: PinyinKeyboardMetrics.bottomRowShadowBottomInset,
                trailing: PinyinKeyboardMetrics.bottomRowHorizontalInset
            )
        )
    }

    @ViewBuilder
    private var expandedCandidateOverlay: some View {
        if pinyinState.isCandidatePageVisible {
            PinyinExpandedCandidateOverlay(
                pinyinState: pinyinState,
                insertText: insertText
            )
            .padding(.top, expandedCandidateOverlayTopOffset)
        }
    }

    @ViewBuilder
    private var quickFillOverlay: some View {
        if pinyinState.isQuickFillPanelVisible {
            PinyinQuickFillPanel(
                pinyinState: pinyinState,
                insertText: insertText
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: PinyinKeyboardMetrics.quickFillPanelAnimationDuration), value: pinyinState.isQuickFillPanelVisible)
        }
    }

    @ViewBuilder
    private var translationOverlay: some View {
        if pinyinState.isTranslationPanelVisible {
            PinyinTranslationPanel(pinyinState: pinyinState)
                .padding(.top, PinyinKeyboardMetrics.candidateToolbarHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: PinyinKeyboardMetrics.quickFillPanelAnimationDuration), value: pinyinState.isTranslationPanelVisible)
        }
    }

    @ViewBuilder
    private var emojiOverlay: some View {
        if pinyinState.isEmojiPanelVisible {
            PinyinEmojiPanel(
                pinyinState: pinyinState,
                insertText: insertText
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: PinyinKeyboardMetrics.quickFillPanelAnimationDuration), value: pinyinState.isEmojiPanelVisible)
        }
    }

    private var currentToolbarHeight: CGFloat {
        PinyinKeyboardMetrics.candidateToolbarHeight
            + (pinyinState.isQuickFillAddInputVisible ? PinyinKeyboardMetrics.quickFillAddBarHeight : 0)
    }

    private var expandedCandidateOverlayTopOffset: CGFloat {
        PinyinKeyboardMetrics.expandedCandidateOverlayTopOffset
            + (pinyinState.isQuickFillAddInputVisible ? PinyinKeyboardMetrics.quickFillAddBarHeight : 0)
    }
}

private struct PinyinSpaceTrackpadOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: .systemMaterial)
    }
}

private struct PinyinKeyboardEdgeBlankTapOverlay: View {
    let topInset: CGFloat
    let isUppercaseLocked: Bool
    let insertLetter: (String) -> Void

    private let rowCount: CGFloat = 4
    private let secondLetterRowIndex: CGFloat = 1
    private let sideHitWidthRatio: CGFloat = 0.085
    private let sideHitWidthRange: ClosedRange<CGFloat> = 24...42

    var body: some View {
        GeometryReader { proxy in
            let keyboardTop = topInset
            let keyboardHeight = max(0, proxy.size.height - keyboardTop)
            let rowHeight = keyboardHeight / rowCount
            let hitWidth = min(
                sideHitWidthRange.upperBound,
                max(sideHitWidthRange.lowerBound, proxy.size.width * sideHitWidthRatio)
            )
            let rowTop = keyboardTop + rowHeight * secondLetterRowIndex

            ZStack(alignment: .topLeading) {
                edgeHitArea(letter: isUppercaseLocked ? "A" : "a")
                    .frame(width: hitWidth, height: rowHeight)
                    .offset(x: 0, y: rowTop)

                edgeHitArea(letter: isUppercaseLocked ? "L" : "l")
                    .frame(width: hitWidth, height: rowHeight)
                    .offset(x: proxy.size.width - hitWidth, y: rowTop)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func edgeHitArea(letter: String) -> some View {
        Color.primary.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
                insertLetter(letter)
            }
    }
}

private struct PinyinLanguageSwitchButtonContent: View {
    let isChineseInputEnabled: Bool

    var body: some View {
        Text(isChineseInputEnabled ? "中" : "英")
            .font(.system(size: 16, weight: .semibold))
            .minimumScaleFactor(0.8)
            .lineLimit(1)
    }
}

private struct PinyinPrimaryConfirmButtonContent: View {
    var title = "确认"

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .minimumScaleFactor(0.75)
            .lineLimit(1)
    }
}

private struct PinyinSmartPunctuationButtonContent: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: value == "，" ? 24 : 22, weight: .medium))
            .minimumScaleFactor(0.75)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(x: value == "，" ? 6 : 0, y: value == "，" ? -6 : 0)
            .accessibilityLabel(value)
    }
}

private struct PinyinNumericSymbolicPlaceholderButtonContent: View {
    var body: some View {
        VStack(alignment: .center, spacing: -1) {
            Text("12")
                .frame(width: 20, height: 13, alignment: .center)
            Text("34")
                .frame(width: 20, height: 13, alignment: .center)
        }
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .minimumScaleFactor(0.8)
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityLabel("12 34")
    }
}

private struct PinyinNineGridNumericKeyboard: View {
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let switchToAlphabetic: () -> Void
    let closeNineGrid: () -> Void

    private let keySpacing: CGFloat = 7
    private let bottomRowHeightIncrease: CGFloat = 8
    private let minimumRowHeight: CGFloat = 36

    private struct NineGridRowHeights {
        let standard: CGFloat
        let bottom: CGFloat
    }

    private let numberSymbolKeys: [PinyinNumberSymbolKey] = [
        .init(value: "+"),
        .init(value: "-", title: "−"),
        .init(value: "*", title: "×"),
        .init(value: "/", title: "÷"),
        .init(value: "%"),
        .init(value: "‰"),
        .init(value: "="),
        .init(value: "≠"),
        .init(value: "≈"),
        .init(value: "<"),
        .init(value: ">"),
        .init(value: "≤"),
        .init(value: "≥"),
        .init(value: "±"),
        .init(value: "∞"),
        .init(value: "√"),
        .init(value: "π"),
        .init(value: "°"),
        .init(value: "℃"),
        .init(value: "¥"),
        .init(value: "$"),
        .init(value: "€")
    ]

    private let numberRows: [[PinyinNineGridKey]] = [
        [.text("1"), .text("2"), .text("3")],
        [.text("4"), .text("5"), .text("6")],
        [.text("7"), .text("8"), .text("9")],
        [.control(id: "abc", title: "ABC"), .text("0"), .text(".")]
    ]

    private let functionKeys: [PinyinNineGridKey] = [
        .backspace,
        .control(id: "space", title: "空格"),
        .text("@"),
        .control(id: "send", title: "发送")
    ]

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 12
            let columnSpacing: CGFloat = 7
            let availableWidth = max(0, proxy.size.width - horizontalPadding - columnSpacing * 2)
            let sideColumnWidth = max(48, min(62, availableWidth * 0.18))
            let centerColumnWidth = max(0, availableWidth - sideColumnWidth * 2)
            let rowHeights = verticalRowHeights(for: proxy.size.height - 10)

            HStack(spacing: keySpacing) {
                leftSymbolColumn(rowHeights: rowHeights)
                    .frame(width: sideColumnWidth)

                VStack(spacing: keySpacing) {
                    ForEach(Array(numberRows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: keySpacing) {
                            ForEach(row) { key in
                                keyButton(key)
                            }
                        }
                        .frame(height: index == numberRows.count - 1 ? rowHeights.bottom : rowHeights.standard)
                    }
                }
                .frame(width: centerColumnWidth)

                keyColumn(functionKeys, rowHeights: rowHeights)
                    .frame(width: sideColumnWidth)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color(UIColor.systemGray4))
        }
    }

    private func leftSymbolColumn(rowHeights: NineGridRowHeights) -> some View {
        VStack(spacing: keySpacing) {
            PinyinNumberSymbolScrollColumn(symbols: numberSymbolKeys, insertText: insertText)
                .frame(height: rowHeights.standard * 3 + keySpacing * 2)

            keyButton(.control(id: "back", title: "返回"))
                .frame(height: rowHeights.bottom)
        }
    }

    private func keyColumn(_ keys: [PinyinNineGridKey], rowHeights: NineGridRowHeights) -> some View {
        VStack(spacing: keySpacing) {
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                keyButton(key)
                    .frame(height: index == keys.count - 1 ? rowHeights.bottom : rowHeights.standard)
            }
        }
    }

    private func verticalRowHeights(for availableHeight: CGFloat) -> NineGridRowHeights {
        let spacingTotal = keySpacing * 3
        let contentHeight = max(0, availableHeight - spacingTotal)
        let evenRowHeight = contentHeight / 4
        let desiredBottomHeight = evenRowHeight + bottomRowHeightIncrease

        let bottomHeight: CGFloat
        let standardHeight: CGFloat
        if contentHeight >= minimumRowHeight * 4 + bottomRowHeightIncrease {
            bottomHeight = desiredBottomHeight
            standardHeight = (contentHeight - bottomHeight) / 3
        } else if contentHeight >= minimumRowHeight * 4 {
            standardHeight = minimumRowHeight
            bottomHeight = contentHeight - standardHeight * 3
        } else {
            standardHeight = evenRowHeight
            bottomHeight = evenRowHeight
        }

        return NineGridRowHeights(standard: standardHeight, bottom: bottomHeight)
    }

    private func keyButton(_ key: PinyinNineGridKey) -> some View {
        Button {
            switch key {
            case .text(let value, _):
                insertText(value)
            case .backspace:
                deleteBackward()
            case .returnKey:
                insertText("\n")
            case .control(let id, _):
                switch id {
                case "abc": switchToAlphabetic()
                case "close": closeNineGrid()
                case "back": closeNineGrid()
                case "space": insertText(" ")
                case "send": insertText("\n")
                default: break
                }
            }
        } label: {
            keyLabel(for: key)
        }
        .buttonStyle(PinyinNineGridKeyButtonStyle(role: buttonRole(for: key)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func buttonRole(for key: PinyinNineGridKey) -> PinyinNineGridKeyButtonStyle.Role {
        switch key {
        case .text:
            return .input
        case .backspace:
            return .function
        case .returnKey:
            return .returnKey
        case .control(let id, _):
            return id == "back" ? .returnKey : .function
        }
    }

    private func foregroundColor(for key: PinyinNineGridKey) -> Color {
        switch buttonRole(for: key) {
        case .returnKey:
            return .white
        case .input, .function, .symbolOption:
            return .primary
        }
    }

    private func keyLabel(for key: PinyinNineGridKey) -> some View {
        Group {
            switch key {
            case .text(let value, let title):
                Text(title ?? value)
                    .font(.system(size: 24, weight: .regular))
                    .monospacedDigit()
            case .backspace:
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .regular))
            case .returnKey:
                Image(systemName: "return")
                    .font(.system(size: 20, weight: .regular))
            case .control(_, let title):
                Text(title)
                    .font(.system(size: title.contains("\n") ? 13 : 15, weight: .regular))
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(foregroundColor(for: key))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct PinyinNineGridKeyButtonStyle: ButtonStyle {
    enum Role {
        case input
        case function
        case returnKey
        case symbolOption
    }

    let role: Role

    private var cornerRadius: CGFloat {
        switch role {
        case .symbolOption:
            return 0
        case .input, .function, .returnKey:
            return 7
        }
    }

    private var normalBackground: Color {
        switch role {
        case .input, .symbolOption:
            return Color(.systemBackground)
        case .function:
            return Color(UIColor.systemGray5.withAlphaComponent(0.96))
        case .returnKey:
            return Color(.systemBlue)
        }
    }

    private var pressedBackground: Color {
        switch role {
        case .input, .symbolOption:
            return Color(UIColor.systemGray3)
        case .function:
            return Color(UIColor.systemGray2)
        case .returnKey:
            return Color(UIColor.systemBlue.withAlphaComponent(0.82))
        }
    }

    private var shadowOpacity: Double {
        0
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? pressedBackground : normalBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(role == .symbolOption || role == .returnKey ? 0 : 0.045), lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: 0,
                x: 0,
                y: configuration.isPressed ? 0 : 1.2
            )
            .offset(y: configuration.isPressed ? 1.8 : 0)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct PinyinNumberSymbolScrollColumn: View {
    let symbols: [PinyinNumberSymbolKey]
    let insertText: (String) -> Void

    private let visibleItemCount: CGFloat = 4
    private let dividerHeight: CGFloat = 1 / UIScreen.main.scale

    var body: some View {
        GeometryReader { proxy in
            let visibleDividerCount = max(0, visibleItemCount - 1)
            let itemHeight = max(36, (proxy.size.height - dividerHeight * visibleDividerCount) / visibleItemCount)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(symbols.enumerated()), id: \.element.id) { index, symbol in
                        Button {
                            insertText(symbol.value)
                        } label: {
                            Text(symbol.title)
                                .font(.system(size: 23, weight: .regular))
                                .monospacedDigit()
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: itemHeight, maxHeight: itemHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PinyinNineGridKeyButtonStyle(role: .symbolOption))

                        if index < symbols.count - 1 {
                            Divider()
                                .overlay(Color.primary.opacity(0.045))
                                .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.045), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0), radius: 0, x: 0, y: 0)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct PinyinNumberSymbolKey: Identifiable, Equatable {
    let value: String
    let title: String

    init(value: String, title: String? = nil) {
        self.value = value
        self.title = title ?? value
    }

    var id: String { "number-symbol-\(value)-\(title)" }
}

private enum PinyinNineGridKey: Identifiable, Equatable {
    case text(String, title: String? = nil)
    case backspace
    case returnKey
    case control(id: String, title: String)

    var id: String {
        switch self {
        case .text(let value, let title): return "text-\(value)-\(title ?? value)"
        case .backspace: return "backspace"
        case .returnKey: return "return"
        case .control(let id, _): return "control-\(id)"
        }
    }
}

private struct PinyinCenteredPunctuationButtonContent: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: metrics.fontSize, weight: .regular))
            .minimumScaleFactor(0.75)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(metrics.offset)
            .accessibilityLabel(value)
    }

    private var metrics: PunctuationDisplayMetrics {
        switch value {
        case "。":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: -7))
        case "，":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: -7))
        case "、":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: -6))
        case "；":
            return PunctuationDisplayMetrics(fontSize: 22, offset: CGSize(width: 0, height: -3))
        case "：":
            return PunctuationDisplayMetrics(fontSize: 22, offset: CGSize(width: 0, height: -1))
        case "？", "！":
            return PunctuationDisplayMetrics(fontSize: 22, offset: CGSize(width: 0, height: -1))
        case "％":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "｜":
            return PunctuationDisplayMetrics(fontSize: 22, offset: CGSize(width: 0, height: -0.5))
        case "～":
            return PunctuationDisplayMetrics(fontSize: 22, offset: CGSize(width: 0, height: -1.5))
        case "“":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: 4))
        case "”":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: 4))
        case "‘":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: 4))
        case "’":
            return PunctuationDisplayMetrics(fontSize: 23, offset: CGSize(width: 0, height: 4))
        case "（":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "）":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "【":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "】":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "《", "〈":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        case "》", "〉":
            return PunctuationDisplayMetrics(fontSize: 21, offset: CGSize(width: 0, height: -1))
        default:
            return PunctuationDisplayMetrics(fontSize: 22, offset: .zero)
        }
    }

    private struct PunctuationDisplayMetrics {
        let fontSize: CGFloat
        let offset: CGSize
    }
}

private struct PinyinShiftButtonContent: View {
    let keyboardCase: Keyboard.KeyboardCase

    var body: some View {
        icon
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
    }

    private var icon: Image {
        if let image = bundleImage {
            return Image(uiImage: image)
        }
        return Image(systemName: fallbackSystemName)
    }

    private var bundleImage: UIImage? {
        PinyinKeyboardImageLoader.image(named: imageName)
    }

    private var imageName: String {
        switch keyboardCase {
        case .uppercased:
            return "大写图标"
        case .capsLocked:
            return "大写图标"
        case .lowercased:
            return "小写图标"
        @unknown default:
            return "小写图标"
        }
    }

    private var fallbackSystemName: String {
        switch keyboardCase {
        case .uppercased, .capsLocked:
            return "shift.fill"
        case .lowercased:
            return "shift"
        @unknown default:
            return "shift"
        }
    }
}

private struct PinyinCandidateToolbar: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let insertText: (String) -> Void
    let dismissKeyboard: () -> Void
    let openQuickFillPanel: () -> Void
    let openTranslationPanel: () -> Void
    let openEmojiPanel: () -> Void

    private let candidateBatchSize = 30
    private let candidateStripLeadingAnchorID = "pinyin-candidate-strip-leading-anchor"

    var body: some View {
        VStack(spacing: 0) {
            if pinyinState.isQuickFillAddInputVisible {
                PinyinQuickFillAddBar(pinyinState: pinyinState)
                    .frame(height: PinyinKeyboardMetrics.quickFillAddBarHeight)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                if pinyinState.isCandidatePageVisible {
                    expandedCompositionArea
                } else {
                    candidateInputArea
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: PinyinKeyboardMetrics.candidateToolbarHeight)
            .allowsHitTesting(!pinyinState.isCandidatePageVisible)
        }
        .frame(maxWidth: .infinity)
        .frame(height: toolbarHeight)
        .background(Color.clear)
        .animation(.easeInOut(duration: PinyinKeyboardMetrics.quickFillPanelAnimationDuration), value: pinyinState.isQuickFillAddInputVisible)
    }

    private var toolbarHeight: CGFloat {
        PinyinKeyboardMetrics.candidateToolbarHeight
            + (pinyinState.isQuickFillAddInputVisible ? PinyinKeyboardMetrics.quickFillAddBarHeight : 0)
    }

    private var candidateInputArea: some View {
        VStack(spacing: 7) {
            compositionBar
            migratedCandidateStrip
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var expandedCompositionArea: some View {
        VStack(spacing: 0) {
            compositionBar
                .padding(.horizontal, 4)
                .padding(.top, PinyinKeyboardMetrics.candidateInputTopPadding)
            Spacer(minLength: 0)
        }
    }

    private var compositionBar: some View {
        HStack(spacing: 0) {
            PinyinPlainCompositionText(
                text: compositionBarInputText,
                hasComposition: pinyinState.hasComposition,
                isRimeActive: pinyinState.isUsingRimeEngine
            )
            .frame(maxWidth: .infinity)

            PinyinMascotButton()
        }
        .padding(.horizontal, 10)
        .frame(height: PinyinKeyboardMetrics.compositionBarHeight)
        .background(Color.clear)
    }

    private var compositionBarInputText: String {
        guard pinyinState.hasComposition else { return pinyinState.displayText }
        return pinyinState.rawPinyinText.isEmpty ? pinyinState.displayText : pinyinState.rawPinyinText
    }

    private var shouldShowUtilityIconStrip: Bool {
        !pinyinState.hasComposition
            && pinyinState.candidates.isEmpty
            && !pinyinState.isCandidateRefreshPending
    }

    private var migratedCandidateStrip: some View {
        HStack(spacing: 6) {
            if shouldShowUtilityIconStrip {
                PinyinCandidateUtilityIconStrip(
                    dismissKeyboard: dismissKeyboard,
                    openQuickFillPanel: openQuickFillPanel,
                    openTranslationPanel: openTranslationPanel,
                    openEmojiPanel: openEmojiPanel
                )
            } else {
                GeometryReader { proxy in
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Color.clear
                                    .frame(width: 0, height: 30)
                                    .id(candidateStripLeadingAnchorID)

                                ForEach(Array(pinyinState.candidates.prefix(candidateBatchSize).enumerated()), id: \.element.id) { index, candidate in
                                    candidateButton(candidate, index: index, expanded: false)
                                }

                                if pinyinState.candidates.isEmpty {
                                    Color.clear.frame(width: 1, height: 30)
                                }
                            }
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                            .background(Color.primary.opacity(0.001))
                            .contentShape(Rectangle())
                            .padding(.bottom, 1)
                        }
                        .contentShape(Rectangle())
                        .background(Color.primary.opacity(0.001))
                        .scrollDisabled(pinyinState.candidates.count <= 3)
                        .onChange(of: pinyinState.candidateScrollResetToken) { _ in
                            DispatchQueue.main.async {
                                scrollProxy.scrollTo(candidateStripLeadingAnchorID, anchor: .leading)
                            }
                        }
                    }
                }
                .frame(height: 32)

                if pinyinState.hasComposition {
                    candidateExpandButton
                } else {
                    associationClearButton
                }
            }
        }
        .frame(height: 32)
    }

    private var candidateExpandButton: some View {
        Button {
            guard !pinyinState.candidates.isEmpty,
                  !pinyinState.isCandidateRefreshPending else { return }
            pinyinState.isCandidatePageVisible.toggle()
        } label: {
            Image(systemName: pinyinState.isCandidatePageVisible ? "chevron.up" : "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 32)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: PinyinKeyboardMetrics.candidateExpandHitWidth, height: PinyinKeyboardMetrics.candidateExpandHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pinyinState.candidates.isEmpty ? 0 : 1)
        .allowsHitTesting(!pinyinState.candidates.isEmpty && !pinyinState.isCandidateRefreshPending)
        .accessibilityLabel("展开候选词")
    }

    private var associationClearButton: some View {
        Button {
            guard !pinyinState.candidates.isEmpty,
                  !pinyinState.isCandidateRefreshPending else { return }
            pinyinState.clearAssociationSuggestions()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 32)
                .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: PinyinKeyboardMetrics.candidateExpandHitWidth, height: PinyinKeyboardMetrics.candidateExpandHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pinyinState.candidates.isEmpty ? 0 : 1)
        .allowsHitTesting(!pinyinState.candidates.isEmpty && !pinyinState.isCandidateRefreshPending)
        .accessibilityLabel("清除关联词")
    }

    private func candidateButton(
        _ candidate: KeyboardInputCandidate,
        index: Int,
        expanded: Bool
    ) -> some View {
        PinyinCandidateButton(
            candidate: candidate,
            index: index,
            expanded: expanded,
            pinyinState: pinyinState,
            insertText: insertText
        )
    }
}

private struct PinyinPlainCompositionText: View {
    let text: String
    let hasComposition: Bool
    let isRimeActive: Bool

    private var displayText: String {
        guard hasComposition else { return text }
        return PinyinCompositionFormatter.segmentedDisplayText(from: text)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(displayText)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(hasComposition ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("compositionTextEnd")
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.trailing, 8)
            }
            .onChange(of: displayText) { _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    scrollProxy.scrollTo("compositionTextEnd", anchor: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private enum PinyinCompositionFormatter {
    private static let syllables: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
        "ka", "kai", "kan", "kang", "kao", "ke", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu",
        "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "ta", "tai", "tan", "tang", "tao", "te", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo"
    ]

    static func segmentedDisplayText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if trimmed.contains("'") { return trimmed }

        let normalized = trimmed.replacingOccurrences(of: "ü", with: "v")
        if normalized.contains(where: { $0.isWhitespace }) {
            return normalized
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: "'")
        }

        guard normalized.allSatisfy({ $0.isLetter }) else { return trimmed }
        return segmentASCIILetters(normalized).joined(separator: "'")
    }

    static func segmentASCIILetters(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let characters = Array(lowercased)
        let count = characters.count
        guard count > 0 else { return [] }

        var best: [[String]] = Array(repeating: [], count: count + 1)
        best[count] = []

        if count > 0 {
            for index in stride(from: count - 1, through: 0, by: -1) {
                var chosen: [String]?
                let maxLength = min(6, count - index)
                for length in stride(from: maxLength, through: 1, by: -1) {
                    let syllable = String(characters[index ..< index + length])
                    guard syllables.contains(syllable) else { continue }
                    chosen = [String(characters[index ..< index + length])] + best[index + length]
                    break
                }
                best[index] = chosen ?? [String(characters[index])] + best[index + 1]
            }
        }

        return best[0]
    }
}

private struct PinyinMascotButton: View {
    @State private var animationToken = 0
    @State private var isAnimating = false

    var body: some View {
        Button {
            playAnimation()
        } label: {
            ZStack {
                PinyinHeartBurstView(trigger: animationToken)
                    .frame(width: 72, height: 58)
                    .offset(x: -10, y: -12)
                    .allowsHitTesting(false)

                mascotImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 38)
                    .offset(y: -3)
                    .scaleEffect(isAnimating ? 1.08 : 1)
                    .rotationEffect(.degrees(isAnimating ? -3.5 : 0))
                    .offset(x: isAnimating ? -1 : 0, y: isAnimating ? -5 : 0)
            }
            .frame(width: 56, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cat")
    }

    private var mascotImage: Image {
        if let image = PinyinKeyboardImageLoader.image(named: "猫") {
            return Image(uiImage: image)
        }
        return Image(systemName: "cat")
    }

    private func playAnimation() {
        animationToken += 1
        withAnimation(.easeOut(duration: 0.28)) {
            isAnimating = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            withAnimation(.easeInOut(duration: 0.3)) {
                isAnimating = false
            }
        }
    }
}

private struct PinyinHeartBurstView: View {
    let trigger: Int
    @State private var isExpanded = false

    private let particles: [PinyinHeartParticle] = [
        .init(x: -34, y: -32, rotation: 14, delay: 0, scale: 0.76, size: 13, color: UIColor(red: 1.00, green: 0.35, blue: 0.58, alpha: 1)),
        .init(x: -22, y: -48, rotation: -8, delay: 0.03, scale: 0.88, size: 11, color: UIColor(red: 1.00, green: 0.48, blue: 0.66, alpha: 1)),
        .init(x: -8, y: -58, rotation: 10, delay: 0.055, scale: 0.72, size: 9, color: UIColor(red: 1.00, green: 0.27, blue: 0.44, alpha: 1)),
        .init(x: 8, y: -58, rotation: -12, delay: 0.075, scale: 0.80, size: 10, color: UIColor(red: 0.96, green: 0.25, blue: 0.52, alpha: 1)),
        .init(x: 24, y: -46, rotation: 16, delay: 0.095, scale: 0.92, size: 12, color: UIColor(red: 1.00, green: 0.62, blue: 0.74, alpha: 1)),
        .init(x: 36, y: -30, rotation: -10, delay: 0.12, scale: 0.78, size: 10, color: UIColor(red: 1.00, green: 0.35, blue: 0.58, alpha: 1)),
        .init(x: -38, y: -14, rotation: -18, delay: 0.07, scale: 0.68, size: 8, color: UIColor(red: 1.00, green: 0.48, blue: 0.66, alpha: 1)),
        .init(x: 40, y: -12, rotation: 20, delay: 0.14, scale: 0.70, size: 8, color: UIColor(red: 1.00, green: 0.27, blue: 0.44, alpha: 1)),
        .init(x: -18, y: -26, rotation: 8, delay: 0.11, scale: 0.62, size: 7, color: UIColor(red: 0.96, green: 0.25, blue: 0.52, alpha: 1)),
        .init(x: 18, y: -26, rotation: -8, delay: 0.155, scale: 0.66, size: 7, color: UIColor(red: 1.00, green: 0.62, blue: 0.74, alpha: 1)),
        .init(x: -6, y: -42, rotation: 22, delay: 0.17, scale: 0.58, size: 8, color: UIColor(red: 1.00, green: 0.35, blue: 0.58, alpha: 1)),
        .init(x: 6, y: -42, rotation: -22, delay: 0.195, scale: 0.58, size: 8, color: UIColor(red: 1.00, green: 0.48, blue: 0.66, alpha: 1))
    ]

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                PinyinHeartShape()
                    .fill(Color(particle.color))
                    .frame(width: particle.size, height: particle.size)
                    .rotationEffect(.degrees(isExpanded ? particle.rotation + 45 : 45))
                    .scaleEffect(isExpanded ? particle.scale : 0.35)
                    .opacity(isExpanded ? 0 : (trigger == 0 ? 0 : 1))
                    .offset(x: isExpanded ? particle.x : 0, y: isExpanded ? particle.y : 0)
                    .animation(
                        .easeOut(duration: 0.76).delay(particle.delay),
                        value: isExpanded
                    )
            }
        }
        .onChange(of: trigger) { _ in
            guard trigger > 0 else { return }
            isExpanded = false
            DispatchQueue.main.async {
                isExpanded = true
            }
        }
    }
}

private struct PinyinHeartParticle: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let rotation: CGFloat
    let delay: TimeInterval
    let scale: CGFloat
    let size: CGFloat
    let color: UIColor
}

private struct PinyinHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY - rect.height * 0.08),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY - rect.height * 0.18),
            control2: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.24),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12),
            control2: CGPoint(x: rect.midX - rect.width * 0.24, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.08),
            control1: CGPoint(x: rect.midX + rect.width * 0.24, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.18),
            control2: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY - rect.height * 0.18)
        )
        path.closeSubpath()
        return path
    }
}

private struct PinyinCandidateUtilityIconStrip: View {
    let dismissKeyboard: () -> Void
    let openQuickFillPanel: () -> Void
    let openTranslationPanel: () -> Void
    let openEmojiPanel: () -> Void

    private var items: [PinyinUtilityIconItem] {
        [
            .init(assetName: "icons8-diversity-50", fallbackSystemName: "person.2", accessibilityLabel: "Function", action: nil),
            .init(assetName: "文本", fallbackSystemName: "textformat", accessibilityLabel: "Quick fill", action: openQuickFillPanel),
            .init(assetName: "翻译", fallbackSystemName: "text.translate", accessibilityLabel: "Translate", action: openTranslationPanel),
            .init(assetName: "表情", fallbackSystemName: "face.smiling", accessibilityLabel: "Emoji", action: openEmojiPanel),
            .init(assetName: "icons8-happy-50", fallbackSystemName: "face.smiling", accessibilityLabel: "Emoji", action: nil),
            .init(assetName: "icons8-expand-arrow-50", fallbackSystemName: "chevron.down", accessibilityLabel: "Dismiss keyboard", action: dismissKeyboard)
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(items) { item in
                PinyinUtilityIconButton(item: item)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .top)
    }
}

private struct PinyinTranslationPanel: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState

    var body: some View {
        VStack(spacing: 10) {
            header
            resultArea
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .clipped()
    }

    private var header: some View {
        ZStack {
            Text("翻译")
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 8) {
                Button {
                    pinyinState.setTranslationPanelVisible(false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回键盘")

                Spacer(minLength: 0)

                Text(pinyinState.translationStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusForegroundColor)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(statusBackgroundColor, in: Capsule())
                    .opacity(pinyinState.translationStatusText.isEmpty ? 0 : 1)
            }
        }
        .frame(height: 34)
    }

    private var resultArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(displayText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(resultForegroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
    }

    private var displayText: String {
        if pinyinState.translationText.isEmpty {
            return "正在读取粘贴板并请求翻译..."
        }
        return pinyinState.translationText
    }

    private var resultForegroundColor: Color {
        pinyinState.translationText.isEmpty ? .secondary : .primary
    }

    private var statusForegroundColor: Color {
        switch pinyinState.translationStatusText {
        case "失败", "配置错误", "请求错误":
            return .red
        case "完成":
            return .green
        default:
            return .secondary
        }
    }

    private var statusBackgroundColor: Color {
        statusForegroundColor.opacity(0.12)
    }
}

private struct PinyinEmojiPanel: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let insertText: (String) -> Void
    @State private var selectedCategory: PinyinEmojiCategory = .frequent

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 34, maximum: 54), spacing: 8),
        count: 7
    )
    private let tabBarHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            header

            if availableSections.isEmpty {
                emptyState
            } else {
                emojiGrid
                categoryTabBar
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .clipped()
        .onAppear {
            normalizeSelectedCategory()
        }
        .onChange(of: pinyinState.emojiSections) { _ in
            normalizeSelectedCategory()
        }
    }

    private var availableSections: [PinyinEmojiSection] {
        pinyinState.emojiSections
    }

    private var selectedSection: PinyinEmojiSection? {
        availableSections.first { $0.category == selectedCategory } ?? availableSections.first
    }

    private var selectedItems: [String] {
        selectedSection?.items ?? []
    }

    private var selectedTitle: String {
        selectedSection?.category.title ?? "表情符号"
    }

    private var emojiGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(selectedItems, id: \.self) { item in
                    emojiButton(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var categoryTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableSections) { section in
                    categoryTab(section.category)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: tabBarHeight)
        .background(Color(.systemBackground).opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var header: some View {
        ZStack {
            Text(selectedTitle)
                .font(.system(size: 16, weight: .semibold))

            HStack {
                Button {
                    pinyinState.setEmojiPanelVisible(false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回键盘")

                Spacer(minLength: 0)

                Text("\(selectedItems.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color(.systemBackground), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
    }

    private func categoryTab(_ category: PinyinEmojiCategory) -> some View {
        let isSelected = selectedSection?.category == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Image(systemName: category.systemImageName)
                    .font(.system(size: 15, weight: .semibold))
                if isSelected {
                    Text(category.title)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
            .padding(.horizontal, isSelected ? 10 : 8)
            .frame(height: 32)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "face.smiling")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("未找到表情符号数据")
                .font(.system(size: 15, weight: .semibold))
            Text("请确认 RimeShared/lua/data/emoji.txt 已打包进键盘扩展")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emojiButton(_ item: String) -> some View {
        Button {
            insertText(item)
        } label: {
            Text(item)
                .font(.system(size: emojiFontSize(for: item), weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item)
    }

    private func emojiFontSize(for item: String) -> CGFloat {
        if selectedSection?.category == .currency || selectedSection?.category == .symbols {
            return item.count > 2 ? 15 : 22
        }
        return item.count > 2 ? 16 : 25
    }

    private func normalizeSelectedCategory() {
        guard !availableSections.isEmpty else { return }
        if !availableSections.contains(where: { $0.category == selectedCategory }) {
            selectedCategory = availableSections[0].category
        }
    }
}

private struct PinyinQuickFillPanel: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let insertText: (String) -> Void
    @State private var openedActionItem: String?

    var body: some View {
        VStack(spacing: 10) {
            header

            if pinyinState.quickFillItems.isEmpty {
                quickFillEmptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(pinyinState.quickFillItems, id: \.self) { item in
                            PinyinSwipeableQuickFillItemCard(
                                item: item,
                                isOpen: openedActionItem == item,
                                insertText: {
                                    if openedActionItem == item {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                            openedActionItem = nil
                                        }
                                    } else {
                                        insertText(item)
                                    }
                                },
                                edit: {
                                    openedActionItem = nil
                                    pinyinState.beginEditingQuickFillItem(item)
                                },
                                delete: {
                                    openedActionItem = nil
                                    pinyinState.deleteQuickFillItem(item)
                                },
                                setOpen: { isOpen in
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                        openedActionItem = isOpen ? item : nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .clipped()
    }

    private var header: some View {
        ZStack {
            Text("常用语")
                .font(.system(size: 16, weight: .semibold))

            HStack {
                Button {
                    pinyinState.setQuickFillPanelVisible(false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回键盘")

                Spacer(minLength: 0)

                Button {
                    pinyinState.showQuickFillAddInput()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var quickFillEmptyState: some View {
        GeometryReader { proxy in
            VStack(spacing: 10) {
                emptyStateIcon
                    .frame(width: 29, height: 29)

                Text("暂无常用语")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("点击右上角 + 添加常用语")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(
                width: proxy.size.width * 0.9,
                height: proxy.size.height * 0.9
            )
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateIcon: some View {
        Group {
            if let image = PinyinKeyboardImageLoader.image(named: "快速添加 ") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "plus.message")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

}

private struct PinyinSwipeableQuickFillItemCard: View {
    let item: String
    let isOpen: Bool
    let insertText: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let setOpen: (Bool) -> Void

    @State private var dragOffset: CGFloat = 0

    private let actionWidth: CGFloat = 136
    private let actionButtonWidth: CGFloat = 64
    private let cardCornerRadius: CGFloat = 14
    private let openThreshold: CGFloat = 44

    var body: some View {
        ZStack(alignment: .trailing) {
            if shouldShowActionButtons {
                actionButtons
            }

            itemCard
                .offset(x: cardOffset)
                .highPriorityGesture(dragGesture)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isOpen)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.9), value: dragOffset)
    }

    private var cardOffset: CGFloat {
        min(0, max(-actionWidth, (isOpen ? -actionWidth : 0) + dragOffset))
    }

    private var shouldShowActionButtons: Bool {
        isOpen || dragOffset < 0
    }

    private var itemCard: some View {
        Text(item)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
            .onTapGesture {
            insertText()
            }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            actionButton(
                title: "编辑",
                systemName: "pencil",
                color: Color(red: 0.20, green: 0.48, blue: 0.94),
                action: edit
            )

            actionButton(
                title: "删除",
                systemName: "trash",
                color: Color(red: 1.00, green: 0.23, blue: 0.19),
                action: delete
            )
        }
        .frame(width: actionWidth, alignment: .trailing)
        .background(Color.clear)
    }

    private func actionButton(
        title: String,
        systemName: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: actionButtonWidth)
            .frame(maxHeight: .infinity)
            .background(color)
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let translation = value.translation.width
                if isOpen {
                    dragOffset = min(actionWidth, max(0, translation))
                } else {
                    dragOffset = max(-actionWidth, min(0, translation))
                }
            }
            .onEnded { value in
                let translation = value.translation.width
                let predictedTranslation = value.predictedEndTranslation.width
                let shouldOpen = isOpen
                    ? predictedTranslation > openThreshold ? false : true
                    : predictedTranslation < -openThreshold || translation < -openThreshold
                dragOffset = 0
                setOpen(shouldOpen)
            }
    }
}

private struct PinyinQuickFillAddBar: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState

    var body: some View {
        VStack(spacing: 6) {
            topRow
            inputRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var topRow: some View {
        ZStack {
            // Image(systemName: "plus.circle.fill")
            //     .font(.system(size: 16, weight: .semibold))
            //     .foregroundStyle(Color.accentColor)

            Text("添加常用语")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            // Text("使用下方键盘输入，保存后置顶")
            //     .font(.system(size: 12, weight: .regular))
            //     .foregroundStyle(.secondary)
            //     .lineLimit(1)
            //     .minimumScaleFactor(0.75)

            HStack {
                Spacer(minLength: 0)

                Button {
                    pinyinState.returnToQuickFillPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 24)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            focusedInputField

            Button("保存") {
                pinyinState.saveQuickFillDraft()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 34)
            .background(saveButtonBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .buttonStyle(.plain)
            .disabled(isDraftEmpty)
        }
    }

    private var focusedInputField: some View {
        PinyinQuickFillStableInputField(
            draftPrefixText: draftPrefixText,
            compositionPrefixText: compositionPrefixText,
            compositionSuffixText: compositionSuffixText,
            draftSuffixText: draftSuffixText,
            fullText: activeInputText,
            setDraftCursorOffset: { offset in
                pinyinState.setQuickFillDraftCursorOffset(offset)
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 58)
    }

    private var activeInputText: String {
        draftPrefixText + pinyinState.displayText + draftSuffixText
    }

    private var clampedDraftCursorOffset: Int {
        max(0, min(pinyinState.quickFillDraftCursorOffset, pinyinState.quickFillDraftText.count))
    }

    private var draftPrefixText: String {
        let end = pinyinState.quickFillDraftText.index(
            pinyinState.quickFillDraftText.startIndex,
            offsetBy: clampedDraftCursorOffset
        )
        return String(pinyinState.quickFillDraftText[..<end])
    }

    private var draftSuffixText: String {
        let start = pinyinState.quickFillDraftText.index(
            pinyinState.quickFillDraftText.startIndex,
            offsetBy: clampedDraftCursorOffset
        )
        return String(pinyinState.quickFillDraftText[start...])
    }

    private var clampedCompositionCursorOffset: Int {
        max(0, min(pinyinState.displayCursorOffset, pinyinState.displayText.count))
    }

    private var compositionPrefixText: String {
        guard pinyinState.hasComposition else { return "" }
        let end = pinyinState.displayText.index(
            pinyinState.displayText.startIndex,
            offsetBy: clampedCompositionCursorOffset
        )
        return String(pinyinState.displayText[..<end])
    }

    private var compositionSuffixText: String {
        guard pinyinState.hasComposition else { return "" }
        let start = pinyinState.displayText.index(
            pinyinState.displayText.startIndex,
            offsetBy: clampedCompositionCursorOffset
        )
        return String(pinyinState.displayText[start...])
    }

    private var isDraftEmpty: Bool {
        pinyinState.quickFillDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pinyinState.hasComposition
    }

    private var saveButtonBackground: Color {
        isDraftEmpty ? Color.gray.opacity(0.35) : Color.accentColor
    }

}

private final class OllamaTranslationStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onToken: (String) -> Void
    private let onComplete: (String?) -> Void
    private var lineBuffer = ""
    private var didComplete = false

    init(
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String?) -> Void
    ) {
        self.onToken = onToken
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk
        processBufferedLines(flushRemainder: false)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        processBufferedLines(flushRemainder: true)
        if let error,
           (error as NSError).code != NSURLErrorCancelled {
            complete(error.localizedDescription)
        } else {
            complete(nil)
        }
        session.finishTasksAndInvalidate()
    }

    private func processBufferedLines(flushRemainder: Bool) {
        let separator = CharacterSet.newlines
        var lines = lineBuffer.components(separatedBy: separator)
        if !flushRemainder {
            lineBuffer = lines.popLast() ?? ""
        } else {
            lineBuffer = ""
        }

        for line in lines {
            processLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func processLine(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let error = object["error"] as? String, !error.isEmpty {
            complete(error)
            return
        }

        if let token = object["response"] as? String, !token.isEmpty {
            onToken(token)
        }

        if object["done"] as? Bool == true {
            complete(nil)
        }
    }

    private func complete(_ errorMessage: String?) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(errorMessage)
    }
}

private struct PinyinQuickFillStableInputField: UIViewRepresentable {
    let draftPrefixText: String
    let compositionPrefixText: String
    let compositionSuffixText: String
    let draftSuffixText: String
    let fullText: String
    let setDraftCursorOffset: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(setDraftCursorOffset: setDraftCursorOffset)
    }

    func makeUIView(context: Context) -> StableInputTextView {
        let view = StableInputTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.onSelectionChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.syncDraftCursorOffset(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: StableInputTextView, context: Context) {
        context.coordinator.setDraftCursorOffset = setDraftCursorOffset
        context.coordinator.draftPrefixLength = draftPrefixText.count
        context.coordinator.compositionLength = compositionPrefixText.count + compositionSuffixText.count
        context.coordinator.fullText = fullText

        let cursorActiveOffset = draftPrefixText.count + compositionPrefixText.count
        uiView.update(
            text: fullText,
            cursorCharacterOffset: cursorActiveOffset,
            compositionRange: compositionRange(
                draftPrefixLength: draftPrefixText.count,
                compositionLength: compositionPrefixText.count + compositionSuffixText.count
            )
        )
    }

    private func compositionRange(draftPrefixLength: Int, compositionLength: Int) -> NSRange? {
        guard compositionLength > 0 else { return nil }
        let location = fullText.utf16Offset(forCharacterOffset: draftPrefixLength)
        let end = fullText.utf16Offset(forCharacterOffset: draftPrefixLength + compositionLength)
        return NSRange(location: location, length: max(0, end - location))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var setDraftCursorOffset: (Int) -> Void
        var draftPrefixLength = 0
        var compositionLength = 0
        var fullText = ""

        init(setDraftCursorOffset: @escaping (Int) -> Void) {
            self.setDraftCursorOffset = setDraftCursorOffset
        }

        func syncDraftCursorOffset(from textView: UITextView) {
            let activeUTF16Offset: Int
            if let selectedRange = textView.selectedTextRange {
                activeUTF16Offset = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
            } else {
                activeUTF16Offset = fullText.utf16.count
            }
            let activeOffset = fullText.characterOffset(forUTF16Offset: activeUTF16Offset)

            let draftOffset: Int
            if activeOffset <= draftPrefixLength {
                draftOffset = activeOffset
            } else if activeOffset <= draftPrefixLength + compositionLength {
                // 组合输入期间不允许把草稿光标插入拼音组合串内部，避免候选上屏后位置错乱。
                draftOffset = draftPrefixLength
            } else {
                draftOffset = activeOffset - compositionLength
            }
            setDraftCursorOffset(draftOffset)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // 输入内容统一由自定义键盘状态管理，这里只允许 UITextView 提供多行布局与真实光标定位。
            false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let stableTextView = textView as? StableInputTextView,
               stableTextView.isApplyingSelectionUpdate {
                return
            }
            syncDraftCursorOffset(from: textView)
        }
    }

    final class StableInputTextView: UITextView {
        var onSelectionChanged: (() -> Void)?

        private let horizontalPadding: CGFloat = 10
        private let verticalPadding: CGFloat = 7
        private let counterWidth: CGFloat = 38
        private let inputFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        private let countFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        private let countLabel = UILabel()
        private let placeholderLabel = UILabel()
        private var lastAppliedText = ""
        private var isApplyingUpdate = false
        private var pendingCursorCharacterOffset = 0

        var isApplyingSelectionUpdate: Bool { isApplyingUpdate }

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            setupView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupView()
        }

        private func setupView() {
            backgroundColor = .systemBackground
            layer.cornerRadius = 10
            layer.cornerCurve = .continuous
            layer.borderWidth = 1.2
            layer.borderColor = UIColor.tintColor.withAlphaComponent(0.82).cgColor
            clipsToBounds = true

            font = inputFont
            textColor = .label
            tintColor = .tintColor
            backgroundColor = .systemBackground
            autocorrectionType = .no
            autocapitalizationType = .none
            spellCheckingType = .no
            smartDashesType = .no
            smartQuotesType = .no
            smartInsertDeleteType = .no
            isEditable = true
            isSelectable = true
            isScrollEnabled = true
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            alwaysBounceVertical = false
            keyboardDismissMode = .none
            inputView = UIView(frame: .zero)
            inputAccessoryView = UIView(frame: .zero)
            textContainer.lineFragmentPadding = 0
            textContainerInset = UIEdgeInsets(
                top: verticalPadding,
                left: horizontalPadding,
                bottom: verticalPadding + 10,
                right: horizontalPadding
            )

            placeholderLabel.text = "输入常用语内容"
            placeholderLabel.font = inputFont
            placeholderLabel.textColor = .placeholderText
            placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
            placeholderLabel.isUserInteractionEnabled = false
            addSubview(placeholderLabel)

            countLabel.font = countFont
            countLabel.textColor = .tertiaryLabel
            countLabel.textAlignment = .right
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            countLabel.isUserInteractionEnabled = false
            addSubview(countLabel)

            NSLayoutConstraint.activate([
                countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
                countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                countLabel.widthAnchor.constraint(equalToConstant: counterWidth),

                placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
                placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
                placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8)
            ])
        }

        func update(text: String, cursorCharacterOffset: Int, compositionRange: NSRange?) {
            isApplyingUpdate = true
            pendingCursorCharacterOffset = max(0, min(cursorCharacterOffset, text.count))

            if lastAppliedText != text {
                attributedText = attributedText(for: text, compositionRange: compositionRange)
                lastAppliedText = text
            } else if let compositionRange {
                attributedText = attributedText(for: text, compositionRange: compositionRange)
            }
            countLabel.text = "\(text.count)"
            placeholderLabel.isHidden = !text.isEmpty
            setCursor(characterOffset: pendingCursorCharacterOffset, in: text)
            scrollRangeToVisible(selectedRange)
            isApplyingUpdate = false
        }

        override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            // 不显示系统选区手柄，只保留插入光标，避免用户误以为可以系统编辑/粘贴。
            []
        }

        override func caretRect(for position: UITextPosition) -> CGRect {
            var rect = super.caretRect(for: position)
            rect.size.width = 1.5
            rect.size.height = 18
            rect.origin.y += max(0, (inputFont.lineHeight - rect.height) / 2)
            return rect
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            false
        }

        private func attributedText(for text: String, compositionRange: NSRange?) -> NSAttributedString {
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: inputFont,
                    .foregroundColor: UIColor.label
                ]
            )
            if let compositionRange,
               compositionRange.location >= 0,
               compositionRange.location + compositionRange.length <= attributed.length {
                attributed.addAttributes([
                    .foregroundColor: UIColor.tintColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: compositionRange)
            }
            return attributed
        }

        private func setCursor(characterOffset: Int, in text: String) {
            let utf16Offset = text.utf16Offset(forCharacterOffset: characterOffset)
            selectedRange = NSRange(location: max(0, min(utf16Offset, text.utf16.count)), length: 0)
        }
    }
}

private extension String {
    func utf16Offset(forCharacterOffset characterOffset: Int) -> Int {
        let clampedOffset = max(0, min(characterOffset, count))
        let index = self.index(startIndex, offsetBy: clampedOffset)
        guard let utf16Index = index.samePosition(in: utf16) else { return utf16.count }
        return utf16.distance(from: utf16.startIndex, to: utf16Index)
    }

    func characterOffset(forUTF16Offset utf16Offset: Int) -> Int {
        let clampedOffset = max(0, min(utf16Offset, utf16.count))
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: clampedOffset)
        guard let stringIndex = String.Index(utf16Index, within: self) else {
            return count
        }
        return distance(from: startIndex, to: stringIndex)
    }
}

private struct PinyinUtilityIconItem: Identifiable {
    let id = UUID()
    let assetName: String
    let fallbackSystemName: String
    let accessibilityLabel: String
    let action: (() -> Void)?
}

private struct PinyinUtilityIconButton: View {
    let item: PinyinUtilityIconItem

    var body: some View {
        Button {
            item.action?()
        } label: {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: PinyinKeyboardMetrics.utilityIconPointSize, height: PinyinKeyboardMetrics.utilityIconPointSize)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.action == nil)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var icon: Image {
        if let image = PinyinKeyboardImageLoader.image(named: item.assetName) {
            return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
        }
        return Image(systemName: item.fallbackSystemName)
    }
}

private enum PinyinKeyboardImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(named name: String) -> UIImage? {
        let cacheKey = name as NSString
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let image: UIImage?
        if let url = Bundle(for: KeyboardViewController.self).url(
            forResource: name,
            withExtension: "png",
            subdirectory: "ios-icon"
        ) {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = UIImage(named: name)
        }

        if let image {
            cache.setObject(image, forKey: cacheKey)
        }
        return image
    }
}

private struct PinyinExpandedCandidateOverlay: View {
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let insertText: (String) -> Void

    private let expandedCandidateTopAnchorID = "pinyin-expanded-candidate-top-anchor"

    var body: some View {
        VStack(spacing: 0) {
            collapseHeader

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Color.clear
                        .frame(height: 0)
                        .id(expandedCandidateTopAnchorID)

                    CandidateFlowLayout(spacing: 6) {
                        ForEach(Array(pinyinState.candidates.enumerated()), id: \.element.id) { index, candidate in
                            PinyinCandidateButton(
                                candidate: candidate,
                                index: index,
                                expanded: true,
                                pinyinState: pinyinState,
                                insertText: insertText
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: pinyinState.candidateScrollResetToken) { _ in
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(expandedCandidateTopAnchorID, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .clipped()
    }

    private var collapseHeader: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                pinyinState.isCandidatePageVisible = false
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 32)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: PinyinKeyboardMetrics.candidateExpandHitWidth, height: PinyinKeyboardMetrics.candidateExpandHitHeight)
                    // .background(Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 4)
        .frame(height: PinyinKeyboardMetrics.candidateExpandHitHeight)
        .background(Color(.secondarySystemBackground))
    }
}

private struct PinyinCandidateButton: View {
    let candidate: KeyboardInputCandidate
    let index: Int
    let expanded: Bool
    @ObservedObject var pinyinState: PinyinKeyboardInputState
    let insertText: (String) -> Void

    private var candidateFont: Font {
        .custom("NotoSansCJKsc-Regular", size: 19)
    }

    private var commentText: String? {
        guard let comment = candidate.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else {
            return nil
        }
        return comment
    }

    var body: some View {
        Button {
            guard !pinyinState.isCandidateRefreshPending else { return }
            if let committedText = pinyinState.select(candidate) {
                if pinyinState.isQuickFillAddInputVisible {
                    pinyinState.appendQuickFillDraftText(committedText)
                } else {
                    insertText(committedText)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(candidate.text)
                    .font(candidateFont)
                    .fontWeight(index == 0 ? .semibold : .regular)
                    .foregroundStyle(.primary)

                if let commentText {
                    Text(commentText)
                        .font(.custom("NotoSansCJKsc-Regular", size: expanded ? 14 : 12))
                        .foregroundStyle(.secondary)
                }
            }
                .lineLimit(1)
                .truncationMode(.tail)
            .padding(.horizontal, expanded ? 12 : 9)
            .padding(.vertical, expanded ? PinyinKeyboardMetrics.expandedCandidateVerticalPadding : 2)
            .frame(minWidth: expanded ? 56 : 48, minHeight: expanded ? PinyinKeyboardMetrics.expandedCandidateMinHitHeight : 30)
            .background(expanded ? Color.primary.opacity(0.001) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!pinyinState.isCandidateRefreshPending)
    }
}

private struct PinyinCompositionCursorText: View {
    let text: String
    let cursorOffset: Int
    let hasComposition: Bool

    private let fontSize: CGFloat = 15

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Text(prefixText)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(hasComposition ? .primary : .secondary)
                    .lineLimit(1)

                if hasComposition {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 1.5, height: 18)
                }

                Text(suffixText)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(hasComposition ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    private var clampedCursorOffset: Int {
        max(0, min(cursorOffset, text.count))
    }

    private var prefixText: String {
        let end = text.index(text.startIndex, offsetBy: clampedCursorOffset)
        return String(text[..<end])
    }

    private var suffixText: String {
        let start = text.index(text.startIndex, offsetBy: clampedCursorOffset)
        return String(text[start...])
    }
}

private struct CandidateFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = max(56, proposal.width ?? 320)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(max(size.width, 56), maxWidth)
            let height = max(size.height, 34)
            let candidateSpacing = rowWidth == 0 ? 0 : spacing

            if rowWidth > 0 && rowWidth + candidateSpacing + width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }

            rowWidth += (rowWidth == 0 ? 0 : spacing) + width
            rowHeight = max(rowHeight, height)
        }

        if rowHeight > 0 {
            totalHeight += rowHeight
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = max(56, bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(max(size.width, 56), maxWidth)
            let height = max(size.height, 34)
            let candidateSpacing = x == bounds.minX ? 0 : spacing

            if x > bounds.minX && x + candidateSpacing + width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            } else if x > bounds.minX {
                x += spacing
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width
            rowHeight = max(rowHeight, height)
        }
    }
}
