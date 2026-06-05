import Foundation
import CoreImage
import Photos
import PhotosUI
import SwiftUI
import UIKit
import Vision

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: FitnexTab = .home
    @State private var detailScreen: DetailScreen?
    @State private var feedbackMessage: String?
    @ObservedObject private var hostSettings = HostMonitorSettingsStore.shared
    @StateObject private var homeMetrics = HomeMetricsViewModel()
    @StateObject private var diskStatus = DiskStatusViewModel()

    var body: some View {
        ZStack(alignment: .top) {
            FitnexColor.background.ignoresSafeArea()

            currentScreen

            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(FitnexColor.black.opacity(0.88), in: Capsule())
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            FitnexTabBar(
                selected: selectedTab,
                isActivityPresented: detailScreen == .journal,
                selectTab: selectTab,
                openActivity: openActivity
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .animation(.easeInOut(duration: 0.22), value: selectedTab)
        .animation(.easeInOut(duration: 0.22), value: detailScreen)
        .animation(.easeInOut(duration: 0.18), value: feedbackMessage)
        .task {
            await AppLogStore.shared.record(
                category: "system",
                level: "info",
                message: "home initial load",
                metadata: AppLogStore.shared.storageDiagnostics
            )
            async let homeTask: Void = homeMetrics.refresh()
            async let diskTask: Void = diskStatus.loadIfNeeded()
            _ = await (homeTask, diskTask)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await AppLogStore.shared.record(
                    category: "system",
                    level: "info",
                    message: "app became active"
                )
                async let homeTask: Void = homeMetrics.refresh()
                async let diskTask: Void = diskStatus.refresh()
                _ = await (homeTask, diskTask)
            }
        }
        .onChange(of: hostSettings.baseURL) { _ in
            homeMetrics.resetForEndpointChange()
            diskStatus.resetForEndpointChange()
            Task {
                async let homeTask: Void = homeMetrics.refresh()
                async let diskTask: Void = diskStatus.refresh()
                _ = await (homeTask, diskTask)
            }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        if let detailScreen {
            switch detailScreen {
            case .activity:
                ActivityStatusView(
                    back: { self.detailScreen = nil },
                    feedback: feedback
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .disk:
                DiskStatusView(
                    viewModel: diskStatus,
                    back: { self.detailScreen = nil },
                    feedback: feedback
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .journal:
                CutoutCaptureView(
                    back: { self.detailScreen = nil },
                    feedback: feedback
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } else {
            switch selectedTab {
            case .home:
                MinePageView(
                    metrics: homeMetrics,
                    openDisk: { detailScreen = .disk },
                    feedback: feedback
                )
            case .explore:
                MonitorDashboardView(feedback: feedback)
            case .location:
                PlaceholderScreen(
                    title: "Location",
                    subtitle: "Host nodes and network points can surface here.",
                    icon: "location"
                )
            case .settings:
                SettingsView(feedback: feedback)
            }
        }
    }

    private func feedback(_ message: String) {
        feedbackMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if feedbackMessage == message {
                feedbackMessage = nil
            }
        }
    }

    private func selectTab(_ tab: FitnexTab) {
        selectedTab = tab
        detailScreen = nil
    }

    private func openActivity() {
        detailScreen = .journal
    }
}

private enum DetailScreen {
    case activity
    case disk
    case journal
}

private struct IdentifiableString: Identifiable {
    let id: String
    let value: String
    init(value: String) {
        self.id = value
        self.value = value
    }
}

private struct AppVersionInfo {
    let version: String
    let build: String

    static var current: AppVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return AppVersionInfo(version: version, build: build)
    }

    var displayText: String {
        "\(version) (\(build))"
    }
}

private struct KeyboardExtensionDiagnostics {
    struct Item: Identifiable {
        let id: String
        let title: String
        let value: String
        let isExpected: Bool?

        init(_ title: String, _ value: String, isExpected: Bool? = nil) {
            self.id = title
            self.title = title
            self.value = value
            self.isExpected = isExpected
        }
    }

    let status: String
    let items: [Item]

    static let logSource = "keyboard"
    static let logCategory = "keyboardDiagnostic"

    static var current: KeyboardExtensionDiagnostics {
        guard let pluginURL = Bundle.main.builtInPlugInsURL else {
            return KeyboardExtensionDiagnostics(
                status: "未找到 PlugIns 目录",
                items: [
                    Item("App Bundle", Bundle.main.bundleIdentifier ?? "unknown", isExpected: nil)
                ]
            )
        }

        let appExtensions = ((try? FileManager.default.contentsOfDirectory(
            at: pluginURL,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "appex" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let extensionBundle = appExtensions
            .compactMap({ Bundle(url: $0) })
            .first(where: { bundle in
                let info = bundle.infoDictionary ?? [:]
                let extensionInfo = info["NSExtension"] as? [String: Any]
                return extensionInfo?["NSExtensionPointIdentifier"] as? String == "com.apple.keyboard-service"
            }) else {
            return KeyboardExtensionDiagnostics(
                status: "未找到键盘扩展",
                items: [
                    Item("PlugIns", pluginURL.lastPathComponent, isExpected: nil),
                    Item("AppeX Count", "\(appExtensions.count)", isExpected: appExtensions.count > 0)
                ]
            )
        }

        let info = extensionBundle.infoDictionary ?? [:]
        let extensionInfo = info["NSExtension"] as? [String: Any] ?? [:]
        let attributes = extensionInfo["NSExtensionAttributes"] as? [String: Any] ?? [:]
        let isASCIICapable = attributes["IsASCIICapable"] as? Bool
        let requestsOpenAccess = attributes["RequestsOpenAccess"] as? Bool
        let primaryLanguage = attributes["PrimaryLanguage"] as? String ?? "missing"
        let extensionPoint = extensionInfo["NSExtensionPointIdentifier"] as? String ?? "missing"
        let bundleID = extensionBundle.bundleIdentifier ?? "missing"

        return KeyboardExtensionDiagnostics(
            status: isASCIICapable == true ? "搜索输入可用元数据已开启" : "搜索输入元数据异常",
            items: [
                Item("Bundle ID", bundleID, isExpected: bundleID.hasSuffix(".keyboard2")),
                Item("Extension Point", extensionPoint, isExpected: extensionPoint == "com.apple.keyboard-service"),
                Item("Primary Language", primaryLanguage, isExpected: primaryLanguage == "zh-Hans"),
                Item("ASCII Capable", boolText(isASCIICapable), isExpected: isASCIICapable == true),
                Item("Open Access", boolText(requestsOpenAccess), isExpected: requestsOpenAccess == true),
                Item("AppeX", extensionBundle.bundleURL.lastPathComponent, isExpected: nil)
            ]
        )
    }

    private static func boolText(_ value: Bool?) -> String {
        guard let value else { return "missing" }
        return value ? "true" : "false"
    }
}

private struct LogChunk: Identifiable, Hashable {
    let id: String
    let date: Date
    let urls: [URL]

    var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:00"
        return formatter.string(from: date)
    }

    var mergedText: String {
        urls
            .sorted { $0.path < $1.path }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

private struct AppLogEntry: Identifiable, Codable {
    let id: String
    let timestamp: Date
    let source: String
    let category: String
    let level: String
    let message: String
    let method: String
    let url: String
    let requestHeaders: [String: String]
    let requestBody: String
    let statusCode: Int?
    let responseHeaders: [String: String]
    let responseBody: String
    let error: String?
    let durationMS: Int
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case source
        case category
        case level
        case message
        case method
        case url
        case requestHeaders
        case requestBody
        case statusCode
        case responseHeaders
        case responseBody
        case error
        case durationMS
        case metadata
    }

    init(
        id: String,
        timestamp: Date,
        source: String,
        category: String,
        level: String,
        message: String,
        method: String,
        url: String,
        requestHeaders: [String: String],
        requestBody: String,
        statusCode: Int?,
        responseHeaders: [String: String],
        responseBody: String,
        error: String?,
        durationMS: Int,
        metadata: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.category = category
        self.level = level
        self.message = message
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.error = error
        self.durationMS = durationMS
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        let error = try container.decodeIfPresent(String.self, forKey: .error)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "app"
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "http"
        level = try container.decodeIfPresent(String.self, forKey: .level) ?? (error == nil ? "info" : "error")
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? url
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? ""
        self.url = url
        requestHeaders = try container.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        requestBody = try container.decodeIfPresent(String.self, forKey: .requestBody) ?? ""
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        responseHeaders = try container.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:]
        responseBody = try container.decodeIfPresent(String.self, forKey: .responseBody) ?? ""
        self.error = error
        durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    var statusText: String {
        if category != "http" { return level.capitalized }
        if let statusCode { return "HTTP \(statusCode)" }
        if error != nil { return "Failed" }
        return "Completed"
    }
}

private struct LoggedHTTPClient {
    static func data(for request: URLRequest, responseBodyLimit: Int = 32 * 1024) async throws -> (Data, URLResponse) {
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            await AppLogStore.shared.record(
                request: request,
                response: response,
                responseData: data,
                error: nil,
                startedAt: start,
                responseBodyLimit: responseBodyLimit
            )
            return (data, response)
        } catch {
            await AppLogStore.shared.record(
                request: request,
                response: nil,
                responseData: nil,
                error: error,
                startedAt: start,
                responseBodyLimit: responseBodyLimit
            )
            throw error
        }
    }
}

@MainActor
private final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    @Published private(set) var chunks: [LogChunk] = []
    @Published var selectedChunkID: String?
    @Published private(set) var entries: [AppLogEntry] = []
    @Published private(set) var keyboardDiagnosticEntries: [AppLogEntry] = []
    @Published private(set) var latestKeyboardLogURL: URL?

    private let fileManager = FileManager.default
    private let retention: TimeInterval = 3 * 24 * 60 * 60

    private var documentsDirectoryURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }

    private var appGroupLogsDirectoryURL: URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.fitnex")?
            .appendingPathComponent("logs", isDirectory: true)
    }

    private var writeDirectoryURL: URL {
        documentsDirectoryURL
    }

    var storageDiagnostics: [String: String] {
        [
            "writeLocation": "documents",
            "appGroupLogs": appGroupLogsDirectoryURL?.path ?? "missing"
        ]
    }

    var appGroupContainerURL: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.fitnex")
    }

    var appGroupContainerPath: String {
        appGroupContainerURL?.path ?? "missing"
    }

    var appGroupLogsPath: String {
        appGroupLogsDirectoryURL?.path ?? "missing"
    }

    var selectedChunkShareURL: URL? {
        guard let selectedChunkID,
              let chunk = chunks.first(where: { $0.id == selectedChunkID }) else {
            return latestKeyboardLogURL
        }
        if chunk.urls.count == 1 {
            return chunk.urls[0]
        }
        return createMergedShareFile(for: chunk)
    }

    private var readDirectoryURLs: [URL] {
        var urls = [documentsDirectoryURL]
        if let appGroupLogsDirectoryURL {
            urls.append(appGroupLogsDirectoryURL)
        }
        return urls
    }

    private static let chunkFileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter
    }()

    func record(
        request: URLRequest,
        response: URLResponse?,
        responseData: Data?,
        error: Error?,
        startedAt: Date,
        responseBodyLimit: Int = 32 * 1024
    ) {
        cleanupOldLogs()

        let now = Date()
        let entry = AppLogEntry(
            id: UUID().uuidString,
            timestamp: now,
            source: "app",
            category: "http",
            level: error == nil ? "info" : "error",
            message: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: bodyText(request.httpBody, limit: 8 * 1024),
            statusCode: (response as? HTTPURLResponse)?.statusCode,
            responseHeaders: responseHeaders(response),
            responseBody: bodyText(responseData, limit: responseBodyLimit),
            error: error?.localizedDescription,
            durationMS: Int(Date().timeIntervalSince(startedAt) * 1000),
            metadata: [:]
        )

        write(entry)
    }

    func record(
        source: String = "app",
        category: String = "system",
        level: String = "info",
        message: String,
        metadata: [String: String] = [:],
        error: String? = nil
    ) {
        cleanupOldLogs()
        let entry = AppLogEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            source: source,
            category: category,
            level: error == nil ? level : "error",
            message: message,
            method: "",
            url: "",
            requestHeaders: [:],
            requestBody: "",
            statusCode: nil,
            responseHeaders: [:],
            responseBody: "",
            error: error,
            durationMS: 0,
            metadata: metadata
        )

        write(entry)
    }

    private func write(_ entry: AppLogEntry) {
        do {
            try fileManager.createDirectory(at: writeDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            let fileURL = chunkURL(for: entry.timestamp)
            let data = try JSONEncoder().encode(entry)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data([0x0A]))
            handle.closeFile()
            reloadChunks(selectCurrentIfNeeded: false)
        } catch {
            // Logging must never break app data loading.
        }
    }

    func reloadChunks(selectCurrentIfNeeded: Bool = false) {
        cleanupOldLogs()
        var chunksByID: [String: (date: Date, urls: [URL])] = [:]

        for directoryURL in readDirectoryURLs {
            let urls = (try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )) ?? []

            for url in urls where url.pathExtension == "jsonl" {
                let name = url.deletingPathExtension().lastPathComponent
                guard let date = Self.chunkFileFormatter.date(from: name) else { continue }
                var chunk = chunksByID[name] ?? (date: date, urls: [])
                chunk.urls.append(url)
                chunksByID[name] = chunk
            }
        }

        chunks = chunksByID.map { id, value in
            LogChunk(id: id, date: value.date, urls: value.urls)
        }
        .sorted { $0.date > $1.date }

        latestKeyboardLogURL = chunks
            .flatMap(\.urls)
            .filter { $0.path.contains("/Groups/") || $0.path.contains("/Shared/AppGroup/") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first

        if selectedChunkID == nil || selectCurrentIfNeeded {
            let currentID = Self.chunkFileFormatter.string(from: Date())
            selectedChunkID = chunks.first(where: { $0.id == currentID })?.id ?? chunks.first?.id
        }
        loadSelectedEntries()
    }

    private func createMergedShareFile(for chunk: LogChunk) -> URL? {
        let exportDirectoryURL = documentsDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("LogExports", isDirectory: true)
        let fileURL = exportDirectoryURL.appendingPathComponent("Simpanin-\(chunk.id).jsonl")
        do {
            try fileManager.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            try chunk.mergedText.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    func selectChunk(_ chunk: LogChunk) {
        selectedChunkID = chunk.id
        loadSelectedEntries()
    }

    private func loadSelectedEntries() {
        guard let selectedChunkID,
              let chunk = chunks.first(where: { $0.id == selectedChunkID }) else {
            entries = []
            return
        }

        let decodedEntries = chunk.urls
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n") }
            .compactMap { line in
                try? JSONDecoder().decode(AppLogEntry.self, from: Data(line.utf8))
            }
            .sorted { $0.timestamp > $1.timestamp }

        keyboardDiagnosticEntries = decodedEntries.filter { entry in
            entry.source == KeyboardExtensionDiagnostics.logSource
                || entry.category == KeyboardExtensionDiagnostics.logCategory
        }
        entries = decodedEntries.filter { entry in
            entry.source != KeyboardExtensionDiagnostics.logSource
                && entry.category != KeyboardExtensionDiagnostics.logCategory
        }
    }

    private func cleanupOldLogs() {
        let cutoff = Date().addingTimeInterval(-retention)
        for directoryURL in readDirectoryURLs {
            guard let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension == "jsonl" {
                let name = url.deletingPathExtension().lastPathComponent
                guard let date = Self.chunkFileFormatter.date(from: name), date < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func chunkURL(for date: Date) -> URL {
        writeDirectoryURL.appendingPathComponent("\(Self.chunkFileFormatter.string(from: date)).jsonl")
    }

    private func responseHeaders(_ response: URLResponse?) -> [String: String] {
        guard let headers = (response as? HTTPURLResponse)?.allHeaderFields else { return [:] }
        return headers.reduce(into: [String: String]()) { partial, item in
            partial[String(describing: item.key)] = String(describing: item.value)
        }
    }

    private func bodyText(_ data: Data?, limit: Int) -> String {
        guard let data, !data.isEmpty else { return "" }
        let prefix = data.prefix(limit)
        if let text = String(data: prefix, encoding: .utf8) {
            return data.count > limit ? "\(text)\n... truncated \(data.count - limit) bytes" : text
        }
        return "<binary \(data.count) bytes>"
    }
}

private enum FitnexColor {
    static let background = Color.white
    static let black = Color(hex: 0x111111)
    static let orange = Color(hex: 0xFE6F32)
    static let orangeSoft = Color(hex: 0xFFF0E9)
    static let grayText = Color(hex: 0x888888)
    static let lightText = Color(hex: 0xAAAAAA)
    static let border = Color(hex: 0xDDDDDD)
    static let card = Color.white
    static let pale = Color(hex: 0xF7F7F7)
}

private struct MinePageView: View {
    @ObservedObject var metrics: HomeMetricsViewModel
    let openDisk: () -> Void
    let feedback: (String) -> Void
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            mineHeader
                .padding(.horizontal, 25)
                .padding(.top, 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(metrics.snapshotDateText)
                                    .font(.fitnexBody(size: 11, weight: .regular))
                                    .foregroundColor(FitnexColor.grayText)
                                Text(metrics.snapshotTitleText)
                                    .font(.fitnexTitle(size: 15))
                                    .foregroundColor(FitnexColor.black)
                            }
                            Spacer()
                            Button {
                                feedback("Source: \(HomeMetricsViewModel.endpointHost)")
                            } label: {
                                Image(systemName: "ellipsis")
                                    .rotationEffect(.degrees(90))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(FitnexColor.black)
                                    .frame(width: 32, height: 32)
                            }
                        }

                        MetricsStatusStrip(status: metrics.statusText, isLive: metrics.response != nil)
                    }

                    Button(action: openDisk) {
                        ChallengeCard(content: metrics.hostCard)
                    }
                    .buttonStyle(.plain)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 15),
                        GridItem(.flexible(), spacing: 15)
                    ], alignment: .leading, spacing: 15) {
                        MetricCard(content: metrics.cpuCard)
                        MetricCard(content: metrics.memoryCard)
                        MetricCard(content: metrics.uploadCard)
                        MetricCard(content: metrics.downloadCard)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 20)
            }
        }
        .task { await metrics.refresh() }
        .onReceive(refreshTimer) { _ in
            Task {
                await metrics.refresh()
            }
        }
        .onChange(of: metrics.toastMessage) { message in
            guard let message else { return }
            feedback(message)
            metrics.toastMessage = nil
        }
    }

    private var mineHeader: some View {
        HStack(spacing: 12) {
            ProfileAvatar(size: 50)

            Text("Host monitor\nReady for polling?")
                .font(.fitnexTitle(size: 18))
                .foregroundColor(FitnexColor.black)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            SquareIconButton(systemName: "bell", action: { feedback("Notifications") }, dot: true)
        }
    }
}

private struct ActivityStatusView: View {
    let back: () -> Void
    let feedback: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DetailTopBar(title: "Activity Status", back: back, feedback: feedback)
                .padding(.horizontal, 25)
                .padding(.top, 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 15) {
                        ActivityRingCard(title: "Walk", value: "1409", unit: "steps", icon: "figure.walk", progress: 0.63)
                        ActivityRingCard(title: "Sleep", value: "8HR", unit: "20 sec", icon: "moon.fill", progress: 0.52)
                    }
                    .padding(.top, 24)

                    HStack(alignment: .center) {
                        Text("Working Progress")
                            .font(.fitnexTitle(size: 15))
                            .foregroundColor(FitnexColor.black)
                        Spacer()
                        Button {
                            feedback("Weekly filter")
                        } label: {
                            HStack(spacing: 7) {
                                Text("Weekly")
                                    .font(.fitnexBody(size: 11, weight: .regular))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .medium))
                            }
                            .foregroundColor(FitnexColor.orange)
                            .frame(width: 70, height: 25)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(FitnexColor.border, lineWidth: 1)
                            }
                        }
                    }
                    .padding(.top, 30)

                    ProgressChart()
                        .frame(height: 190)
                        .padding(.top, 18)

                    HStack {
                        Text("Latest Workout")
                            .font(.fitnexTitle(size: 15))
                            .foregroundColor(FitnexColor.black)
                        Spacer()
                        Button("See All") {
                            feedback("Workout list")
                        }
                        .font(.fitnexBody(size: 11, weight: .regular))
                        .foregroundColor(FitnexColor.orange)
                    }
                    .padding(.top, 28)

                    VStack(spacing: 15) {
                        WorkoutRow(
                            title: "Full Body",
                            detail: "150 Calories burn | 20 min",
                            symbol: "figure.strengthtraining.traditional"
                        )
                        WorkoutRow(
                            title: "AB Workout",
                            detail: "180 Calories burn | 15 min",
                            symbol: "figure.core.training"
                        )
                    }
                    .padding(.top, 15)
                }
                .padding(.horizontal, 25)
            }
        }
        .background(FitnexColor.background)
    }
}

private struct JournalCaptureView: View {
    let back: () -> Void
    let feedback: (String) -> Void

    @StateObject private var viewModel = JournalGeneratorViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false

    var body: some View {
        VStack(spacing: 0) {
            DetailTopBar(title: "贴纸生成", back: back, feedback: feedback)
                .padding(.horizontal, 25)
                .padding(.top, 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    previewSection

                    HStack(spacing: 14) {
                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showingCamera = true
                            } else {
                                feedback("Camera unavailable")
                            }
                        } label: {
                            JournalActionCard(icon: "camera.viewfinder", title: "拍照", subtitle: "拍一个物品")
                        }
                        .buttonStyle(.plain)

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            JournalActionCard(icon: "photo.on.rectangle", title: "相册", subtitle: "选择图片")
                        }
                        .buttonStyle(.plain)
                    }

                    if viewModel.hasResult {
                        Button {
                            Task { await viewModel.saveResult() }
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(viewModel.isSaving ? "保存中..." : "保存到相册")
                                    .font(.fitnexTitle(size: 14))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(FitnexColor.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSaving)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(Color(hex: 0xE5484D))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }
        }
        .background(FitnexColor.background)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                viewModel.generate(from: image)
            }
        }
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .onChange(of: viewModel.toastMessage) { message in
            guard let message else { return }
            feedback(message)
            viewModel.toastMessage = nil
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        switch viewModel.state {
        case .idle:
            JournalPlaceholderCard()
        case .generating:
            JournalLoadingCard()
        case .completed:
            if let original = viewModel.originalImage, let result = viewModel.resultImage {
                VStack(alignment: .leading, spacing: 12) {
                    Text("生成结果")
                        .font(.fitnexTitle(size: 15))
                        .foregroundColor(FitnexColor.black)

                    StickerPreviewImage(image: result)

                    HStack(spacing: 10) {
                        JournalThumbnail(title: "原图", image: original)
                        JournalThumbnail(title: "贴纸", image: result)
                    }
                }
            } else {
                JournalPlaceholderCard()
            }
        case .failed:
            JournalPlaceholderCard(title: "生成失败", subtitle: "换一张主体更清晰的照片再试")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                viewModel.fail("Image load failed")
                return
            }
            viewModel.generate(from: image)
            selectedPhoto = nil
        } catch {
            viewModel.fail("Image load failed")
        }
    }
}

private struct JournalActionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(FitnexColor.orangeSoft)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(FitnexColor.orange)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.fitnexTitle(size: 14))
                    .foregroundColor(FitnexColor.black)
                Text(subtitle)
                    .font(.fitnexBody(size: 10, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct JournalPlaceholderCard: View {
    var title = "拍照生成透明贴纸"
    var subtitle = "本地识别图中最大的物品，生成粗白边可爱风贴纸"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(FitnexColor.orange)
            Text(title)
                .font(.fitnexTitle(size: 17))
                .foregroundColor(FitnexColor.black)
            Text(subtitle)
                .font(.fitnexBody(size: 12, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct JournalLoadingCard: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(FitnexColor.orange)
            Text("正在识别最大物品...")
                .font(.fitnexTitle(size: 15))
                .foregroundColor(FitnexColor.black)
            Text("使用本地 Vision 和 Core Image 生成透明贴纸")
                .font(.fitnexBody(size: 11, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct StickerPreviewImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .padding(16)
            .background {
                StickerTransparencyBackground()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
    }
}

private struct StickerTransparencyBackground: View {
    private let tileSize: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xF8F8F8)))

            let columns = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            for row in 0...rows {
                for column in 0...columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    context.fill(Path(rect), with: .color(Color(hex: 0xECECEC)))
                }
            }
        }
    }
}

private struct JournalThumbnail: View {
    let title: String
    let image: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.fitnexBody(size: 10, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage) -> Void
        let dismiss: DismissAction

        init(completion: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.completion = completion
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                completion(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private struct CutoutCaptureView: View {
    let back: () -> Void
    let feedback: (String) -> Void

    @StateObject private var viewModel = CutoutGeneratorViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false

    var body: some View {
        VStack(spacing: 0) {
            DetailTopBar(title: "抠图", back: back, feedback: feedback)
                .padding(.horizontal, 25)
                .padding(.top, 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    previewSection

                    HStack(spacing: 14) {
                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showingCamera = true
                            } else {
                                feedback("当前设备不支持拍照")
                            }
                        } label: {
                            JournalActionCard(icon: "camera.viewfinder", title: "拍照", subtitle: "拍一张照片")
                        }
                        .buttonStyle(.plain)

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            JournalActionCard(icon: "photo.on.rectangle", title: "相册", subtitle: "选择图片")
                        }
                        .buttonStyle(.plain)
                    }

                    if viewModel.hasResult {
                        Button {
                            Task { await viewModel.saveResult() }
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(viewModel.isSaving ? "保存中..." : "保存到相册")
                                    .font(.fitnexTitle(size: 14))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(FitnexColor.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSaving)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(Color(hex: 0xE5484D))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }
        }
        .background(FitnexColor.background)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                viewModel.generate(from: image)
            }
        }
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .onChange(of: viewModel.toastMessage) { message in
            guard let message else { return }
            feedback(message)
            viewModel.toastMessage = nil
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        switch viewModel.state {
        case .idle:
            CutoutPlaceholderCard()
        case .generating:
            CutoutLoadingCard()
        case .completed:
            if let original = viewModel.originalImage, let result = viewModel.resultImage {
                VStack(alignment: .leading, spacing: 12) {
                    Text("生成结果")
                        .font(.fitnexTitle(size: 15))
                        .foregroundColor(FitnexColor.black)

                    CutoutPreviewImage(image: result)

                    HStack(spacing: 10) {
                        JournalThumbnail(title: "原图", image: original)
                        JournalThumbnail(title: "抠图", image: result)
                    }
                }
            } else {
                CutoutPlaceholderCard()
            }
        case .failed:
            CutoutPlaceholderCard(title: "抠图失败", subtitle: "换一张主体更清晰的照片再试")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                viewModel.fail("图片加载失败")
                return
            }
            viewModel.generate(from: image)
            selectedPhoto = nil
        } catch {
            viewModel.fail("图片加载失败")
        }
    }
}

private struct CutoutPlaceholderCard: View {
    var title = "拍照生成白底抠图"
    var subtitle = "自动抠出主主体，并生成纯白背景成品"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(FitnexColor.orange)
            Text(title)
                .font(.fitnexTitle(size: 17))
                .foregroundColor(FitnexColor.black)
            Text(subtitle)
                .font(.fitnexBody(size: 12, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct CutoutLoadingCard: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(FitnexColor.orange)
            Text("正在抠出主主体...")
                .font(.fitnexTitle(size: 15))
                .foregroundColor(FitnexColor.black)
            Text("优先使用系统级前景分割，输出纯白背景成品")
                .font(.fitnexBody(size: 11, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct CutoutPreviewImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
    }
}

private struct DiskStatusView: View {
    @ObservedObject var viewModel: DiskStatusViewModel
    let back: () -> Void
    let feedback: (String) -> Void
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    @State private var selectedDiskSerial: IdentifiableString?

    var body: some View {
        VStack(spacing: 0) {
            DetailTopBar(title: "Disk Status", back: back, feedback: feedback)
                .padding(.horizontal, 25)
                .padding(.top, 44)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(viewModel.diskCards) { disk in
                                DiskInfoCard(content: disk) {
                                    guard !disk.serialNumber.isEmpty else { return }
                                    selectedDiskSerial = IdentifiableString(value: disk.serialNumber)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .padding(.top, 24)

                    HStack(alignment: .center) {
                        Text("Working Progress")
                            .font(.fitnexTitle(size: 15))
                            .foregroundColor(FitnexColor.black)
                        Spacer()
                        Text(viewModel.historyWindowLabel)
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(FitnexColor.orange)
                            .frame(width: 90, height: 25)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(FitnexColor.border, lineWidth: 1)
                            }
                    }
                    .padding(.top, 30)

                    if let selectedSummary = viewModel.selectedTemperatureSummary {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Selected Time")
                                    .font(.fitnexTitle(size: 13))
                                    .foregroundColor(FitnexColor.black)
                                Spacer()
                                Text(selectedSummary.timeText)
                                    .font(.fitnexBody(size: 11, weight: .semibold))
                                    .foregroundColor(FitnexColor.orange)
                            }

                            VStack(spacing: 8) {
                                ForEach(selectedSummary.items) { item in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: 7, height: 7)
                                        Text(item.title)
                                            .font(.fitnexBody(size: 10, weight: .regular))
                                            .foregroundColor(FitnexColor.grayText)
                                            .lineLimit(1)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(item.valueText)
                                                .font(.fitnexTitle(size: 12))
                                                .foregroundColor(item.isAvailable ? FitnexColor.black : FitnexColor.lightText)
                                            Text(item.sampleTimeText)
                                                .font(.fitnexBody(size: 8, weight: .regular))
                                                .foregroundColor(FitnexColor.lightText)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(FitnexColor.border, lineWidth: 1)
                        }
                        .padding(.top, 14)
                    }

                    DiskTemperatureChart(
                        content: viewModel.temperatureChart,
                        selectedTime: viewModel.selectedTemperatureTime,
                        selectTime: viewModel.selectTemperatureTime
                    )
                        .frame(height: 190)
                        .padding(.top, 18)

                    HStack {
                        Text("Latest Workout")
                            .font(.fitnexTitle(size: 15))
                            .foregroundColor(FitnexColor.black)
                        Spacer()
                        Text(viewModel.partitionSummary)
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(FitnexColor.orange)
                    }
                    .padding(.top, 28)

                    VStack(spacing: 15) {
                        ForEach(viewModel.partitionRows) { partition in
                            PartitionUsageRow(content: partition)
                        }
                    }
                    .padding(.top, 15)
                }
                .padding(.horizontal, 25)
            }
        }
        .background(FitnexColor.background)
        .sheet(item: $selectedDiskSerial) { wrapper in
            DiskSmartSheet(smart: viewModel.smartDetail, isLoading: viewModel.isLoadingSmart)
                .task {
                    await viewModel.loadSmart(serialNumber: wrapper.value)
                }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await viewModel.refresh()
            }
        }
        .onChange(of: viewModel.toastMessage) { message in
            guard let message else { return }
            feedback(message)
            viewModel.toastMessage = nil
        }
    }
}

private struct DetailTopBar: View {
    let title: String
    let back: () -> Void
    let feedback: (String) -> Void

    var body: some View {
        HStack {
            SquareIconButton(systemName: "chevron.left", action: back)
            Spacer()
            Text(title)
                .font(.fitnexTitle(size: 18))
                .foregroundColor(FitnexColor.black)
            Spacer()
            SquareIconButton(systemName: "bell", action: { feedback("Notifications") }, dot: true)
        }
        .frame(height: 35)
    }
}

private struct MetricsStatusStrip: View {
    let status: String
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(isLive ? FitnexColor.orange : FitnexColor.border)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.fitnexBody(size: 11, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChallengeCard: View {
    let content: HostCardContent

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(FitnexColor.orangeSoft)
                Image(systemName: content.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(FitnexColor.orange)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                if !content.title.isEmpty {
                    Text(content.title)
                        .font(.fitnexBody(size: 10, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
                Text(content.primaryText)
                    .font(.fitnexTitle(size: 16))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(content.secondaryText)
                    .font(.fitnexBody(size: 10, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                    .lineLimit(1)
                if let tertiaryText = content.tertiaryText {
                    Text(tertiaryText)
                        .font(.fitnexBody(size: 10, weight: .regular))
                        .foregroundColor(FitnexColor.lightText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(content.trailingLabel)
                    .font(.fitnexBody(size: 10, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                Text(content.trailingValue)
                    .font(.fitnexTitle(size: 13))
                    .foregroundColor(FitnexColor.orange)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 90)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct MetricCard: View {
    let content: MetricCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(content.title)
                    .font(.fitnexTitle(size: 15))
                    .foregroundColor(FitnexColor.black)
                Spacer()
                SmallCircleIcon(
                    systemName: content.icon,
                    background: content.iconBackground,
                    foreground: content.iconForeground
                )
            }

            Text(content.value)
                .font(.fitnexTitle(size: 15))
                .foregroundColor(FitnexColor.black)
                .padding(.top, 14)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.fitnexBody(size: 9, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                    .padding(.top, 2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            if let progress = content.progress {
                CapacityProgressBar(progress: progress)
                    .frame(height: 10)
                    .padding(.bottom, 6)
            } else if let chart = content.chart {
                MetricSparkline(chart: chart)
                    .frame(height: 52)
            } else {
                switch content.fallbackStyle {
                case .bars:
                    MiniBars()
                        .frame(height: 46)
                case .capsules:
                    StepsBars()
                        .frame(height: 50)
                case .wave:
                    HeartBars()
                        .frame(height: 54)
                case .line:
                    WeightSparkline()
                        .frame(height: 48)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 147, maxHeight: 147)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct CapacityProgressBar: View {
    let progress: CapacityProgressContent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(progress.trackColor)
                Capsule()
                    .fill(progress.fillColor)
                    .frame(width: max(10, geometry.size.width * progress.fraction))
            }
        }
    }
}

private enum FitnexTab {
    case home
    case explore
    case location
    case settings
}

private struct FitnexTabBar: View {
    let selected: FitnexTab
    let isActivityPresented: Bool
    let selectTab: (FitnexTab) -> Void
    let openActivity: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white)
                .frame(height: 68)
                .shadow(color: Color.black.opacity(0.08), radius: 22, y: 8)

            HStack(spacing: 0) {
                tab(.home, "house")
                tab(.explore, "chart.bar.xaxis")
                Spacer(minLength: 62)
                tab(.location, "location")
                tab(.settings, "gearshape")
            }
            .padding(.horizontal, 18)

            Button(action: openActivity) {
                ZStack {
                    Circle()
                        .fill(FitnexColor.orange)
                        .frame(width: 58, height: 58)
                        .shadow(color: FitnexColor.orange.opacity(0.35), radius: 16, y: 8)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .offset(y: -18)
            .scaleEffect(isActivityPresented ? 1.06 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: isActivityPresented)
        }
        .frame(height: 86)
    }

    private func tab(_ tab: FitnexTab, _ icon: String) -> some View {
        let isSelected = selected == tab && !isActivityPresented
        return Button(action: { selectTab(tab) }) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? FitnexColor.orange : FitnexColor.grayText)
                    .scaleEffect(isSelected ? 1.12 : 1)
                    .offset(y: isSelected ? -2 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.66), value: isSelected)
    }
}

private struct PlaceholderScreen: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.fitnexTitle(size: 28))
                        .foregroundColor(FitnexColor.black)
                    Text(subtitle)
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Circle()
                    .fill(FitnexColor.orangeSoft)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
            }
            .padding(.horizontal, 25)
            .padding(.top, 48)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(FitnexColor.card)
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 14) {
                                Image(systemName: icon)
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundColor(FitnexColor.orange)
                                Text("Placeholder")
                                    .font(.fitnexTitle(size: 18))
                                    .foregroundColor(FitnexColor.black)
                                Text("This tab is wired into the new bottom navigation and ready for a real screen.")
                                    .font(.fitnexBody(size: 12, weight: .regular))
                                    .foregroundColor(FitnexColor.grayText)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 220)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(FitnexColor.border, lineWidth: 1)
                        }
                }
                .padding(.horizontal, 25)
                .padding(.top, 22)
            }
        }
        .background(FitnexColor.background)
    }
}

private struct MonitorDashboardView: View {
    let feedback: (String) -> Void
    @StateObject private var viewModel = NezhaMonitorViewModel(settings: .shared)
    @ObservedObject private var settings = NezhaSettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            monitorHeader
                .padding(.horizontal, 25)
                .padding(.top, 48)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !settings.isConfigured {
                        MonitorEmptyConfigCard {
                            feedback("Configure Nezha in Settings")
                        }
                    }

                    MetricsStatusStrip(status: viewModel.statusText, isLive: viewModel.isConnected)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ], spacing: 14) {
                        MonitorOverviewCard(content: viewModel.totalCard)
                        MonitorOverviewCard(content: viewModel.onlineCard)
                        MonitorOverviewCard(content: viewModel.offlineCard)
                        MonitorNetworkCard(content: viewModel.networkCard)
                    }

                    if viewModel.serverRows.isEmpty {
                        MonitorEmptyServerCard(isConfigured: settings.isConfigured)
                    } else {
                        LazyVStack(spacing: 13) {
                            ForEach(viewModel.serverRows) { server in
                                MonitorServerRow(content: server)
                            }
                        }
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
        }
        .background(FitnexColor.background)
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: settings.baseURL) { _ in
            Task { await viewModel.reconnect() }
        }
        .onChange(of: settings.authToken) { _ in
            Task { await viewModel.reconnect() }
        }
        .onChange(of: viewModel.toastMessage) { message in
            guard let message else { return }
            feedback(message)
            viewModel.toastMessage = nil
        }
    }

    private var monitorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("监控列表")
                .font(.fitnexTitle(size: 24))
                .foregroundColor(FitnexColor.black)
            Text(settings.displayHost)
                .font(.fitnexBody(size: 12, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonitorOverviewCard: View {
    let content: MonitorOverviewCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(content.title)
                    .font(.fitnexTitle(size: 13))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(1)
                Spacer()
                Image(systemName: content.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(content.accent)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(content.accent)
                    .frame(width: 7, height: 7)
                Text(content.value)
                    .font(.fitnexTitle(size: 17))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let subtitle = content.subtitle {
                Text(subtitle)
                    .font(.fitnexBody(size: 10, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 86, alignment: .leading)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct MonitorNetworkCard: View {
    let content: MonitorNetworkCardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("网络")
                    .font(.fitnexTitle(size: 13))
                    .foregroundColor(FitnexColor.black)
                Spacer()
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0x3E7BFA))
            }

            Text(content.transferText)
                .font(.fitnexBody(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: 0x8A4DFF))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Label(content.downloadText, systemImage: "arrow.down.circle.fill")
                .font(.fitnexBody(size: 10, weight: .semibold))
                .foregroundColor(FitnexColor.black)
                .lineLimit(1)
            Label(content.uploadText, systemImage: "arrow.up.circle.fill")
                .font(.fitnexBody(size: 10, weight: .semibold))
                .foregroundColor(FitnexColor.black)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 86, alignment: .leading)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct MonitorServerRow: View {
    let content: MonitorServerRowContent

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Circle()
                    .fill(content.isOnline ? Color(hex: 0x14A46A) : Color(hex: 0xD31645))
                    .frame(width: 7, height: 7)
                Circle()
                    .fill(Color(hex: 0xD31645))
                    .frame(width: 7, height: 7)
                Text(content.title)
                    .font(.fitnexTitle(size: 12))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(1)
                Spacer()
                Text(content.countryText)
                    .font(.fitnexBody(size: 11, weight: .semibold))
                    .foregroundColor(FitnexColor.grayText)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                MonitorServerMetric(title: "CPU", value: content.cpuText, progress: content.cpuProgress)
                MonitorServerMetric(title: "内存", value: content.memoryText, progress: content.memoryProgress)
                MonitorServerMetric(title: "存储", value: content.diskText, progress: content.diskProgress)
                MonitorServerMetric(title: "上传", value: content.uploadText, progress: nil)
                MonitorServerMetric(title: "下载", value: content.downloadText, progress: nil)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct MonitorServerMetric: View {
    let title: String
    let value: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.fitnexBody(size: 10, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .lineLimit(1)
            Text(value)
                .font(.fitnexTitle(size: 10))
                .foregroundColor(FitnexColor.black)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(FitnexColor.pale)
                        Capsule()
                            .fill(Color(hex: 0x14A46A))
                            .frame(width: max(3, proxy.size.width * CGFloat(min(max(progress, 0), 1))))
                    }
                }
                .frame(height: 3)
            } else {
                Color.clear.frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonitorEmptyConfigCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(FitnexColor.orangeSoft)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "link")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要配置 Nezha 服务")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    Text("前往 Settings 填写 Base URL 后开始连接")
                        .font(.fitnexBody(size: 10, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
                Spacer()
            }
            .padding(14)
            .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MonitorEmptyServerCard: View {
    let isConfigured: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isConfigured ? "server.rack" : "exclamationmark.triangle")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(FitnexColor.grayText)
            Text(isConfigured ? "暂无服务器数据" : "未配置数据源")
                .font(.fitnexTitle(size: 14))
                .foregroundColor(FitnexColor.black)
            Text(isConfigured ? "等待 WebSocket 返回 Nezha 服务器状态" : "请先在 Settings 配置 Nezha Base URL")
                .font(.fitnexBody(size: 11, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct ActivityRingCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let progress: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.fitnexTitle(size: 11))
                    .foregroundColor(FitnexColor.black)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FitnexColor.lightText)
            }
            .padding(.horizontal, 15)
            .padding(.top, 22)

            Spacer()

            ZStack {
                Circle()
                    .trim(from: 0.08, to: 0.92)
                    .stroke(FitnexColor.pale, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(110))
                Circle()
                    .trim(from: 0.08, to: 0.08 + 0.84 * progress)
                    .stroke(FitnexColor.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(110))
                Circle()
                    .stroke(FitnexColor.pale, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 7]))
                    .frame(width: 68, height: 68)

                VStack(spacing: 1) {
                    Text(value)
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                    Text(unit)
                        .font(.fitnexBody(size: 9, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
            }
            .frame(width: 118, height: 118)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 23)
        }
        .frame(width: 155, height: 180)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct SettingsView: View {
    let feedback: (String) -> Void
    @StateObject private var updateVM = UpdateViewModel()
    @ObservedObject private var logStore = AppLogStore.shared
    @ObservedObject private var hostSettings = HostMonitorSettingsStore.shared
    @ObservedObject private var nezhaSettings = NezhaSettingsStore.shared
    @ObservedObject private var translateSettings = TranslateSettingsStore.shared
    @State private var showingLogs = false
    @State private var showingHostSettings = false
    @State private var showingNezhaSettings = false
    @State private var showingTranslateSettings = false
    @State private var showingKeyboardGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.fitnexTitle(size: 28))
                        .foregroundColor(FitnexColor.black)
                    Text("Updates, app logs and device maintenance.")
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Circle()
                    .fill(FitnexColor.orangeSoft)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "gearshape")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
            }
            .padding(.horizontal, 25)
            .padding(.top, 48)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    settingsSection(title: "配置") {
                        Button {
                            showingHostSettings = true
                        } label: {
                            settingsRow(
                                icon: "desktopcomputer",
                                title: "主机监控",
                                subtitle: hostSettings.displayHost
                            )
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        Button {
                            showingNezhaSettings = true
                        } label: {
                            settingsRow(
                                icon: "server.rack",
                                title: "哪吒配置",
                                trailingText: nezhaSettings.isConfigured ? "已配置" : "未配置",
                                subtitle: nezhaSettings.displayHost
                            )
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        Button {
                            showingTranslateSettings = true
                        } label: {
                            settingsRow(
                                icon: "character.book.closed",
                                title: "翻译配置",
                                trailingText: translateSettings.isConfigured ? "已配置" : "未配置",
                                subtitle: "\(translateSettings.displayHost) · \(translateSettings.model)"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(title: "键盘") {
                        Button {
                            showingKeyboardGuide = true
                        } label: {
                            settingsRow(
                                icon: "keyboard",
                                title: "中文键盘",
                                subtitle: "启用系统键盘扩展并测试拼音输入"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(title: "系统") {
                        Button {
                            logStore.reloadChunks(selectCurrentIfNeeded: true)
                            showingLogs = true
                        } label: {
                            settingsRow(
                                icon: "doc.text.magnifyingglass",
                                title: "日志",
                                subtitle: "\(logStore.chunks.count) hourly slices"
                            )
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        Button {
                            handleUpdateTap()
                        } label: {
                            settingsRow(
                                icon: updateVM.localIPAURL != nil ? "square.and.arrow.down.fill" : "arrow.triangle.2.circlepath",
                                title: buttonTitle,
                                trailingText: AppVersionInfo.current.displayText,
                                subtitle: updateSubtitle,
                                showsProgress: updateVM.isChecking || updateVM.isDownloading
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(updateVM.isChecking || updateVM.isDownloading)
                    }

                    if updateVM.isDownloading || updateVM.errorMessage != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            if updateVM.isDownloading {
                                ProgressView(value: updateVM.downloadProgress)
                                    .tint(FitnexColor.orange)
                                Text("Downloading \(Int(updateVM.downloadProgress * 100))%")
                                    .font(.fitnexBody(size: 11, weight: .regular))
                                    .foregroundColor(FitnexColor.grayText)
                            }

                            if let error = updateVM.errorMessage {
                                Text(error)
                                    .font(.fitnexBody(size: 11, weight: .regular))
                                    .foregroundColor(Color(hex: 0xE5484D))
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 22)
                .padding(.bottom, 120)
            }
        }
        .background(FitnexColor.background)
        .sheet(isPresented: $showingLogs) {
            AppLogSheet(store: logStore)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingHostSettings) {
            HostMonitorSettingsSheet(settings: hostSettings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingNezhaSettings) {
            NezhaSettingsSheet(settings: nezhaSettings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingTranslateSettings) {
            TranslateSettingsSheet(settings: translateSettings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingKeyboardGuide) {
            KeyboardGuideSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            logStore.reloadChunks(selectCurrentIfNeeded: true)
        }
        .onChange(of: updateVM.localIPAURL) { url in
            if url != nil {
                updateVM.installViaTrollStore()
            }
        }
        .onChange(of: updateVM.errorMessage) { msg in
            if let msg { feedback(msg) }
        }
    }

    private func handleUpdateTap() {
        if updateVM.latestRelease?.ipaAsset != nil && updateVM.localIPAURL == nil {
            updateVM.downloadIPA()
        } else if updateVM.localIPAURL != nil {
            updateVM.installViaTrollStore()
        } else {
            Task { await updateVM.checkForUpdate() }
        }
    }

    private var buttonTitle: String {
        if updateVM.isChecking { return "\u{68C0}\u{67E5}\u{4E2D}..." }
        if updateVM.isDownloading { return "\u{4E0B}\u{8F7D}\u{4E2D}..." }
        if updateVM.localIPAURL != nil { return "\u{5B89}\u{88C5}\u{66F4}\u{65B0}" }
        if updateVM.latestRelease?.ipaAsset != nil { return "\u{4E0B}\u{8F7D}\u{66F4}\u{65B0}" }
        return "\u{68C0}\u{67E5}\u{66F4}\u{65B0}"
    }

    private var updateSubtitle: String? {
        if let msg = updateVM.statusMessage {
            return msg
        }
        if let asset = updateVM.latestRelease?.ipaAsset, updateVM.localIPAURL == nil && !updateVM.isDownloading {
            return asset.formattedSize
        }
        return nil
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.fitnexTitle(size: 14))
                .foregroundColor(FitnexColor.grayText)
                .padding(.leading, 18)

            VStack(spacing: 0) {
                content()
            }
            .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color(hex: 0xEEEEEE))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func settingsRow(icon: String, title: String, trailingText: String? = nil, subtitle: String? = nil, showsProgress: Bool = false, showsChevron: Bool = true) -> some View {
        HStack(spacing: 16) {
            ZStack {
                if showsProgress {
                    ProgressView()
                        .scaleEffect(0.82)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundColor(Color(hex: 0x30333A))
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(Color(hex: 0x1F2329))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let trailingText {
                        Text(trailingText)
                            .font(.fitnexBody(size: 11, weight: .semibold))
                            .foregroundColor(FitnexColor.grayText)
                            .lineLimit(1)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.fitnexBody(size: 11, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: 0x8F8F8F))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: subtitle == nil ? 58 : 68)
        .contentShape(Rectangle())
    }
}

/*
private struct LegacySettingsView: View {
    let feedback: (String) -> Void
    @StateObject private var updateVM = UpdateViewModel()
    @ObservedObject private var logStore = AppLogStore.shared
    @ObservedObject private var nezhaSettings = NezhaSettingsStore.shared
    @State private var showingLogs = false
    @State private var showingNezhaSettings = false
    @State private var showingKeyboardGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.fitnexTitle(size: 28))
                        .foregroundColor(FitnexColor.black)
                    Text("Updates, app logs and device maintenance.")
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Circle()
                    .fill(FitnexColor.orangeSoft)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "gearshape")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
            }
            .padding(.horizontal, 25)
            .padding(.top, 48)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        showingNezhaSettings = true
                    } label: {
                        settingsRow(
                            icon: "server.rack",
                            title: "Nezha",
                            trailingText: nezhaSettings.isConfigured ? "Configured" : "Missing",
                            subtitle: nezhaSettings.displayHost
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingKeyboardGuide = true
                    } label: {
                        settingsRow(
                            icon: "keyboard",
                            title: "中文键盘",
                            trailingText: "离线",
                            subtitle: "启用系统键盘扩展并测试拼音输入"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        logStore.reloadChunks(selectCurrentIfNeeded: true)
                        showingLogs = true
                    } label: {
                        settingsRow(
                            icon: "doc.text.magnifyingglass",
                            title: "\u{65E5}\u{5FD7}",
                            subtitle: "\(logStore.chunks.count) hourly slices"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        if updateVM.latestRelease?.ipaAsset != nil && updateVM.localIPAURL == nil {
                            updateVM.downloadIPA()
                        } else if updateVM.localIPAURL != nil {
                            updateVM.installViaTrollStore()
                        } else {
                            Task { await updateVM.checkForUpdate() }
                        }
                    } label: {
                        settingsRow(
                            icon: updateVM.localIPAURL != nil ? "square.and.arrow.down.fill" : "arrow.triangle.2.circlepath",
                            title: buttonTitle,
                            trailingText: AppVersionInfo.current.displayText,
                            subtitle: updateSubtitle,
                            showsProgress: updateVM.isChecking || updateVM.isDownloading
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(updateVM.isChecking || updateVM.isDownloading)

                    if updateVM.isDownloading {
                        VStack(spacing: 8) {
                            ProgressView(value: updateVM.downloadProgress)
                                .tint(FitnexColor.orange)
                            Text("Downloading \(Int(updateVM.downloadProgress * 100))%")
                                .font(.fitnexBody(size: 11, weight: .regular))
                                .foregroundColor(FitnexColor.grayText)
                        }
                        .padding(.horizontal, 15)
                    }

                    if let error = updateVM.errorMessage {
                        Text(error)
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(Color(hex: 0xE5484D))
                            .padding(.horizontal, 15)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 22)
            }
        }
        .background(FitnexColor.background)
        .sheet(isPresented: $showingLogs) {
            AppLogSheet(store: logStore)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingNezhaSettings) {
            NezhaSettingsSheet(settings: nezhaSettings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingKeyboardGuide) {
            KeyboardGuideSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            logStore.reloadChunks(selectCurrentIfNeeded: true)
        }
        .onChange(of: updateVM.localIPAURL) { url in
            if url != nil {
                updateVM.installViaTrollStore()
            }
        }
        .onChange(of: updateVM.errorMessage) { msg in
            if let msg { feedback(msg) }
        }
    }

    private var buttonTitle: String {
        if updateVM.isChecking { return "\u{68C0}\u{67E5}\u{4E2D}..." }
        if updateVM.isDownloading { return "\u{4E0B}\u{8F7D}\u{4E2D}..." }
        if updateVM.localIPAURL != nil { return "\u{5B89}\u{88C5}\u{66F4}\u{65B0}" }
        if updateVM.latestRelease?.ipaAsset != nil { return "\u{4E0B}\u{8F7D}\u{66F4}\u{65B0}" }
        return "\u{68C0}\u{67E5}\u{66F4}\u{65B0}"
    }

    private var updateSubtitle: String? {
        if let msg = updateVM.statusMessage {
            return msg
        }
        if let asset = updateVM.latestRelease?.ipaAsset, updateVM.localIPAURL == nil && !updateVM.isDownloading {
            return asset.formattedSize
        }
        return nil
    }

    private func settingsRow(icon: String, title: String, trailingText: String? = nil, subtitle: String? = nil, showsProgress: Bool = false, showsChevron: Bool = true) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(FitnexColor.orangeSoft)
                .frame(width: 42, height: 42)
                .overlay {
                    if showsProgress {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.fitnexTitle(size: 15))
                        .foregroundColor(FitnexColor.black)
                    if let trailingText {
                        Text(trailingText)
                            .font(.fitnexBody(size: 11, weight: .semibold))
                            .foregroundColor(FitnexColor.grayText)
                            .lineLimit(1)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.fitnexBody(size: 11, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                        .lineLimit(1)
                }
            }

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(FitnexColor.orange)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 72)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

*/

private struct AppLogSheet: View {
    @ObservedObject var store: AppLogStore
    @State private var expandedEntryID: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(FitnexColor.border)
                .frame(width: 42, height: 5)
                .padding(.top, 10)

            HStack {
                Text("Logs")
                    .font(.fitnexTitle(size: 18))
                    .foregroundColor(FitnexColor.black)
                Spacer()
                if let shareURL = store.selectedChunkShareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                            .frame(width: 32, height: 32)
                    }
                }
                Text("\(store.entries.count)")
                    .font(.fitnexBody(size: 12, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.chunks) { chunk in
                        Button {
                            store.selectChunk(chunk)
                            expandedEntryID = nil
                        } label: {
                            Text(chunk.title)
                                .font(.fitnexBody(size: 11, weight: .regular))
                                .foregroundColor(store.selectedChunkID == chunk.id ? .white : FitnexColor.orange)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(
                                    store.selectedChunkID == chunk.id ? FitnexColor.orange : FitnexColor.orangeSoft,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 14)

            if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(FitnexColor.grayText)
                    Text("No logs in this hour")
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(store.entries) { entry in
                            AppLogEntryRow(
                                entry: entry,
                                isExpanded: expandedEntryID == entry.id,
                                toggle: {
                                    expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
                                }
                            )
                        }

            if !store.keyboardDiagnosticEntries.isEmpty {
                Text("键盘相关日志已归类到键盘扩展诊断，可在中文键盘页查看。")
                    .font(.fitnexBody(size: 11, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)
                    .padding(.top, 8)
            }
                    }
                    .padding(20)
                }
            }
        }
        .background(FitnexColor.background)
        .onAppear {
            store.reloadChunks(selectCurrentIfNeeded: true)
        }
    }
}

private struct AppLogEntryRow: View {
    let entry: AppLogEntry
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(entry.badgeText)
                        .font(.fitnexBody(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(FitnexColor.orange, in: Capsule())
                    Text(entry.source.uppercased())
                        .font(.fitnexBody(size: 10, weight: .bold))
                        .foregroundColor(FitnexColor.orange)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(FitnexColor.orangeSoft, in: Capsule())
                    Text(entry.level.uppercased())
                        .font(.fitnexBody(size: 10, weight: .bold))
                        .foregroundColor(entry.levelColor)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(entry.levelColor.opacity(0.12), in: Capsule())
                    Text(entry.statusText)
                        .font(.fitnexBody(size: 11, weight: .regular))
                        .foregroundColor(entry.error == nil ? FitnexColor.grayText : Color(hex: 0xE5484D))
                    Spacer()
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.fitnexBody(size: 10, weight: .regular))
                        .foregroundColor(FitnexColor.lightText)
                    if entry.durationMS > 0 {
                        Text("\(entry.durationMS)ms")
                            .font(.fitnexBody(size: 10, weight: .regular))
                            .foregroundColor(FitnexColor.lightText)
                    }
                }

                Text(entry.displayText)
                    .font(.fitnexBody(size: 11, weight: .regular))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(isExpanded ? nil : 2)

                if isExpanded {
                    if entry.category == "http" {
                        logBlock(title: "\u{8BF7}\u{6C42}\u{4F53}", text: entry.requestBody)
                        logBlock(title: "\u{54CD}\u{5E94}\u{4F53}", text: entry.responseBody)
                    }
                    if !entry.metadata.isEmpty {
                        logBlock(title: "Metadata", text: entry.metadataText)
                    }
                    if let error = entry.error {
                        logBlock(title: "\u{9519}\u{8BEF}", text: error)
                    }
                }
            }
            .padding(12)
            .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func logBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.fitnexBody(size: 10, weight: .bold))
                .foregroundColor(FitnexColor.grayText)
            Text(text.isEmpty ? "<empty>" : text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(FitnexColor.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension AppLogEntry {
    var badgeText: String {
        category == "http" ? method : category.uppercased()
    }

    var displayText: String {
        category == "http" ? url : message
    }

    var levelColor: Color {
        switch level {
        case "error":
            return Color(hex: 0xE5484D)
        case "warning":
            return Color(hex: 0xE5A000)
        case "debug":
            return FitnexColor.grayText
        default:
            return FitnexColor.orange
        }
    }

    var metadataText: String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}

private struct HostMonitorSettingsSheet: View {
    @ObservedObject var settings: HostMonitorSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftBaseURL = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("主机地址")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    TextField(HostMonitorSettingsStore.defaultHost, text: $draftBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("用于主机指标和磁盘状态接口。可以输入 host:port，也可以输入完整 http/https 地址。")
                    .font(.fitnexBody(size: 11, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)

                Spacer()
            }
            .padding(20)
            .background(FitnexColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("主机监控")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.grayText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        settings.save(baseURL: draftBaseURL)
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.orange)
                }
            }
        }
        .onAppear {
            draftBaseURL = settings.baseURL
        }
    }
}

private struct NezhaSettingsSheet: View {
    @ObservedObject var settings: NezhaSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftBaseURL = ""
    @State private var draftToken = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base URL")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    TextField("http://example.com:8008", text: $draftBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Authorization Token")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    SecureField("Optional Bearer token", text: $draftToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("WebSocket will connect to /api/v1/ws/server. Leave token empty when the endpoint is public.")
                    .font(.fitnexBody(size: 11, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)

                Spacer()
            }
            .padding(20)
            .background(FitnexColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Nezha Settings")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.grayText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.save(baseURL: draftBaseURL, authToken: draftToken)
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.orange)
                }
            }
        }
        .onAppear {
            draftBaseURL = settings.baseURL
            draftToken = settings.authToken
        }
    }
}

private struct TranslateSettingsSheet: View {
    @ObservedObject var settings: TranslateSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftBaseURL = ""
    @State private var draftModel = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务地址")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    TextField("http://192.168.2.88:11434", text: $draftBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("模型名称")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)
                    TextField("transgemma4b", text: $draftModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("配置 Ollama 翻译服务的 API 地址和模型名称。")
                    .font(.fitnexBody(size: 11, weight: .regular))
                    .foregroundColor(FitnexColor.grayText)

                Spacer()
            }
            .padding(20)
            .background(FitnexColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("翻译配置")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.grayText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        settings.save(baseURL: draftBaseURL, model: draftModel)
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.orange)
                }
            }
        }
        .onAppear {
            draftBaseURL = settings.baseURL
            draftModel = settings.model
        }
    }
}

private struct KeyboardGuideSheet: View {
    @State private var testText = ""
    @State private var diagnostics = KeyboardExtensionDiagnostics.current
    @StateObject private var logStore = AppLogStore.shared

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("启用步骤")
                            .font(.fitnexTitle(size: 16))
                            .foregroundColor(FitnexColor.black)
                        keyboardStep("1", "打开系统 设置")
                        keyboardStep("2", "进入 通用 > 键盘 > 键盘")
                        keyboardStep("3", "点击 添加新键盘，选择 FITNEX")
                        keyboardStep("4", "开启 允许完全访问，用于同步快速填充配置")
                        keyboardStep("5", "切换到 FITNEX 中文键盘后输入拼音")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("测试输入")
                            .font(.fitnexTitle(size: 16))
                            .foregroundColor(FitnexColor.black)
                        TextEditor(text: $testText)
                            .font(.fitnexBody(size: 14, weight: .regular))
                            .foregroundColor(FitnexColor.black)
                            .frame(minHeight: 120)
                            .padding(10)
                            .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(FitnexColor.border, lineWidth: 1)
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("键盘扩展诊断")
                                .font(.fitnexTitle(size: 16))
                                .foregroundColor(FitnexColor.black)
                            Spacer()
                            Button {
                                diagnostics = KeyboardExtensionDiagnostics.current
                                logStore.reloadChunks(selectCurrentIfNeeded: true)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(FitnexColor.orange)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            Text(diagnostics.status)
                                .font(.fitnexBody(size: 12, weight: .semibold))
                                .foregroundColor(FitnexColor.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)

                            ForEach(diagnostics.items) { item in
                                keyboardDiagnosticRow(item)
                            }
                        }
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(FitnexColor.border, lineWidth: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("键盘日志")
                                .font(.fitnexTitle(size: 16))
                                .foregroundColor(FitnexColor.black)
                            Spacer()
                            if let shareURL = logStore.selectedChunkShareURL {
                                ShareLink(item: shareURL) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(FitnexColor.orange)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            Text("\(logStore.keyboardDiagnosticEntries.count)")
                                .font(.fitnexBody(size: 11, weight: .regular))
                                .foregroundColor(FitnexColor.grayText)
                        }

                        if logStore.keyboardDiagnosticEntries.isEmpty {
                            Text("暂无键盘扩展日志。请先切换到 FITNEX 中文键盘输入，或点击上方刷新。")
                                .font(.fitnexBody(size: 11, weight: .regular))
                                .foregroundColor(FitnexColor.grayText)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(logStore.keyboardDiagnosticEntries.prefix(20)) { entry in
                                    keyboardLogRow(entry)
                                }
                            }
                        }
                    }

                    Text("键盘离线运行，不会访问网络。快速填充配置通过 App Group 共享，需要在系统键盘设置中允许完全访问。拼音候选词库基于 rime-frost（GPL-3.0）转换，来源：https://github.com/gaboolic/rime-frost。")
                        .font(.fitnexBody(size: 11, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
                .padding(20)
            }
            .background(FitnexColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("中文键盘")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
            }
        }
        .onAppear {
            logStore.reloadChunks(selectCurrentIfNeeded: true)
        }
    }

    private func keyboardStep(_ number: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.fitnexTitle(size: 12))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(FitnexColor.orange, in: Circle())
            Text(text)
                .font(.fitnexBody(size: 13, weight: .regular))
                .foregroundColor(FitnexColor.black)
        }
    }

    private func keyboardDiagnosticRow(_ item: KeyboardExtensionDiagnostics.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.title)
                .font(.fitnexBody(size: 11, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
                .frame(width: 104, alignment: .leading)

            Text(item.value)
                .font(.fitnexBody(size: 11, weight: .semibold))
                .foregroundColor(FitnexColor.black)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let isExpected = item.isExpected {
                Image(systemName: isExpected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isExpected ? FitnexColor.orange : Color(hex: 0xE5484D))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func keyboardLogRow(_ entry: AppLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Self.logTimeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(FitnexColor.grayText)
                Text(entry.level.uppercased())
                    .font(.fitnexBody(size: 10, weight: .bold))
                    .foregroundColor(entry.level == "error" ? Color(hex: 0xE5484D) : FitnexColor.orange)
                Spacer()
                if let component = entry.metadata["component"] {
                    Text(component)
                        .font(.fitnexBody(size: 10, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                }
            }

            Text(entry.message)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(FitnexColor.black)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct QuickFillSettingsSheet: View {
    @ObservedObject var store: QuickFillStore
    @State private var draftText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("快速填充项")
                        .font(.fitnexTitle(size: 13))
                        .foregroundColor(FitnexColor.black)

                    if store.items.isEmpty {
                        Text("暂无填充项，添加后可在键盘中快速插入")
                            .font(.fitnexBody(size: 11, weight: .regular))
                            .foregroundColor(FitnexColor.grayText)
                            .padding(.vertical, 12)
                    } else {
                        List {
                            ForEach(store.items) { item in
                                Text(item.text)
                                    .font(.fitnexBody(size: 14, weight: .regular))
                                    .foregroundColor(FitnexColor.black)
                                    .lineLimit(1)
                            }
                            .onDelete { offsets in
                                store.remove(at: offsets)
                            }
                            .onMove { source, destination in
                                store.move(from: source, to: destination)
                            }
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 120)
                    }
                }

                HStack(spacing: 12) {
                    TextField("输入填充文本", text: $draftText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.fitnexBody(size: 13, weight: .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onSubmit {
                            addIfValid()
                        }

                    Button(action: addIfValid) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(FitnexColor.orange)
                    }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()
            }
            .padding(20)
            .background(FitnexColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("快速填充")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(FitnexColor.orange)
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }

    private func addIfValid() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(trimmed)
        draftText = ""
    }
}

private struct DiskInfoCard: View {
    let content: DiskInfoCardContent
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(content.title)
                        .font(.fitnexTitle(size: 11))
                        .foregroundColor(FitnexColor.black)
                        .lineLimit(2)
                    Spacer()
                    SmallCircleIcon(
                        systemName: "internaldrive",
                        background: content.accent.opacity(0.12),
                        foreground: content.accent
                    )
                }
                .padding(.horizontal, 15)
                .padding(.top, 16)

                VStack(spacing: 4) {
                    Text(content.temperatureText)
                        .font(.fitnexTitle(size: 20))
                        .foregroundColor(content.accent)
                    Text(content.capacityText)
                        .font(.fitnexBody(size: 9, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                    Text(content.statusText)
                        .font(.fitnexBody(size: 9, weight: .regular))
                        .foregroundColor(FitnexColor.lightText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .frame(width: 155, height: 150)
            .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(FitnexColor.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DiskSmartSheet: View {
    let smart: DiskSmartResponse?
    let isLoading: Bool

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Loading SMART data...")
                            .font(.fitnexBody(size: 13, weight: .regular))
                            .foregroundColor(FitnexColor.grayText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let smart {
                    smartContent(smart)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(FitnexColor.grayText)
                        Text("SMART data unavailable")
                            .font(.fitnexBody(size: 13, weight: .regular))
                            .foregroundColor(FitnexColor.grayText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(smart?.friendlyName ?? "Disk SMART")
                        .font(.fitnexTitle(size: 16))
                        .foregroundColor(FitnexColor.black)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func smartContent(_ smart: DiskSmartResponse) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                overviewSection(smart)

                if !smart.attributes.isEmpty {
                    Text("SMART Attributes")
                        .font(.fitnexTitle(size: 15))
                        .foregroundColor(FitnexColor.black)
                        .padding(.top, 22)

                    VStack(spacing: 0) {
                        attributeHeader()
                        ForEach(smart.attributes) { attr in
                            attributeRow(attr)
                            if attr.id != smart.attributes.last?.id {
                                Divider()
                                    .background(FitnexColor.pale)
                            }
                        }
                    }
                    .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(FitnexColor.border, lineWidth: 1)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    private func overviewSection(_ smart: DiskSmartResponse) -> some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                smartMetricCard(
                    title: "Health",
                    value: smart.healthStatus,
                    color: smart.isHealthy ? Color(hex: 0x14A46A) : Color(hex: 0xE5484D)
                )
                smartMetricCard(
                    title: "Temperature",
                    value: smart.temperatureCelsius.map { "\($0) C" } ?? "N/A",
                    color: FitnexColor.orange
                )
                smartMetricCard(
                    title: "Power On Hours",
                    value: smart.powerOnHours.map { formatHours($0) } ?? "N/A",
                    color: Color(hex: 0x3E7BFA)
                )
                smartMetricCard(
                    title: "Power Cycles",
                    value: smart.powerCycleCount.map { "\($0)" } ?? "N/A",
                    color: Color(hex: 0x8A4DFF)
                )
            }

            HStack(spacing: 6) {
                if let fw = smart.firmwareVersion, !fw.isEmpty {
                    Text("FW \(fw)")
                }
                if let bus = smart.busType, !bus.isEmpty {
                    Text(bus)
                }
                if let size = smart.sizeBytes {
                    Text(Self.byteFormatter.string(fromByteCount: size))
                }
            }
            .font(.fitnexBody(size: 10, weight: .regular))
            .foregroundColor(FitnexColor.grayText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 14)
        }
    }

    private func smartMetricCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.fitnexBody(size: 10, weight: .regular))
                .foregroundColor(FitnexColor.grayText)
            Text(value)
                .font(.fitnexTitle(size: 15))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FitnexColor.pale, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func attributeHeader() -> some View {
        HStack(spacing: 0) {
            Text("ID")
                .frame(width: 36, alignment: .leading)
            Text("Attribute")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Value")
                .frame(width: 38, alignment: .trailing)
            Text("Worst")
                .frame(width: 38, alignment: .trailing)
            Text("Thresh")
                .frame(width: 42, alignment: .trailing)
            Text("Raw")
                .frame(width: 55, alignment: .trailing)
        }
        .font(.fitnexBody(size: 9, weight: .semibold))
        .foregroundColor(FitnexColor.grayText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FitnexColor.pale)
    }

    private func attributeRow(_ attr: DiskSmartAttribute) -> some View {
        HStack(spacing: 0) {
            Text("\(attr.id)")
                .frame(width: 36, alignment: .leading)
            Text(attr.name)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(attr.value)")
                .frame(width: 38, alignment: .trailing)
            Text("\(attr.worst)")
                .frame(width: 38, alignment: .trailing)
            Text(attr.threshold > 0 ? "\(attr.threshold)" : "-")
                .frame(width: 42, alignment: .trailing)
            Text(attr.rawString.isEmpty ? attr.rawValue : attr.rawString)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 55, alignment: .trailing)
        }
        .font(.fitnexBody(size: 9, weight: .regular))
        .foregroundColor(FitnexColor.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func formatHours(_ hours: Int) -> String {
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        let remain = hours % 24
        if days < 365 {
            return remain > 0 ? "\(days)d \(remain)h" : "\(days)d"
        }
        let years = days / 365
        let remainDays = days % 365
        return remainDays > 0 ? "\(years)y \(remainDays)d" : "\(years)y"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useTB]
        f.countStyle = .binary
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()
}

private struct DiskTemperatureChart: View {
    let content: DiskTemperatureChartContent
    let selectedTime: Date?
    let selectTime: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let chart = chartRect(in: proxy.size)

                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        let chart = chartRect(in: size)
                        let ticks = content.yAxisLabels
                        let rows = max(ticks.count - 1, 1)
                        for row in 0 ... rows {
                            let y = chart.minY + chart.height * CGFloat(row) / CGFloat(rows)
                            var grid = Path()
                            grid.move(to: CGPoint(x: chart.minX, y: y))
                            grid.addLine(to: CGPoint(x: chart.maxX, y: y))
                            context.stroke(grid, with: .color(FitnexColor.pale), lineWidth: 1)
                        }

                        for series in content.series {
                            let points = normalizedPoints(series.points, in: chart)
                            guard let first = points.first else { continue }

                            if points.count == 1 {
                                context.fill(Path(ellipseIn: CGRect(x: first.x - 2.5, y: first.y - 2.5, width: 5, height: 5)), with: .color(series.color))
                                continue
                            }

                            var path = Path()
                            path.move(to: first)
                            if points.count == 2 {
                                path.addLine(to: points[1])
                            } else {
                                path = Path.smoothCurve(through: points)
                            }
                            context.stroke(path, with: .color(series.color), lineWidth: 1.8)
                        }

                        if let selectedTime {
                            let x = xPosition(for: selectedTime, in: chart)
                            var marker = Path()
                            marker.move(to: CGPoint(x: x, y: chart.minY))
                            marker.addLine(to: CGPoint(x: x, y: chart.maxY))
                            context.stroke(marker, with: .color(FitnexColor.orange.opacity(0.75)), lineWidth: 1)

                            for series in content.series {
                                guard let nearest = nearestPoint(in: series.points, to: selectedTime) else { continue }
                                let point = pointPosition(nearest, in: chart)
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(.white))
                                context.stroke(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(series.color), lineWidth: 1.5)
                            }
                        }
                    }

                    VStack {
                        ForEach(content.yAxisLabels, id: \.self) { label in
                            Text(label)
                                .font(.fitnexBody(size: 8, weight: .regular))
                                .foregroundColor(FitnexColor.grayText)
                                .frame(width: 18, alignment: .trailing)
                            if label != content.yAxisLabels.last { Spacer() }
                        }
                    }
                    .frame(height: chart.height)
                    .padding(.top, chart.minY - 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            selectTime(date(at: value.location.x, in: chart))
                        }
                )
            }
            .frame(height: 164)

            HStack {
                ForEach(content.xAxisLabels.indices, id: \.self) { index in
                    Text(content.xAxisLabels[index])
                        .font(.fitnexBody(size: 8, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                    if index < content.xAxisLabels.count - 1 { Spacer() }
                }
            }
            .padding(.leading, 44)
            .padding(.trailing, 6)

            if !content.legend.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(content.legend) { item in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 7, height: 7)
                                Text(item.title)
                                    .font(.fitnexBody(size: 9, weight: .regular))
                                    .foregroundColor(FitnexColor.grayText)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func normalizedPoints(
        _ points: [DiskTemperaturePointValue],
        in rect: CGRect
    ) -> [CGPoint] {
        points.map { pointPosition($0, in: rect) }
    }

    private func pointPosition(_ point: DiskTemperaturePointValue, in rect: CGRect) -> CGPoint {
        let range = content.maxValue - content.minValue
        let normalized = range == 0 ? 0.5 : (point.temperature - content.minValue) / range
        return CGPoint(
            x: xPosition(for: point.sampledAt, in: rect),
            y: rect.maxY - rect.height * CGFloat(normalized)
        )
    }

    private func xPosition(for date: Date, in rect: CGRect) -> CGFloat {
        let total = max(content.endDate.timeIntervalSince(content.startDate), 1)
        let elapsed = min(max(date.timeIntervalSince(content.startDate), 0), total)
        return rect.minX + rect.width * CGFloat(elapsed / total)
    }

    private func date(at x: CGFloat, in rect: CGRect) -> Date {
        let clampedX = min(max(x, rect.minX), rect.maxX)
        let progress = rect.width == 0 ? 0 : Double((clampedX - rect.minX) / rect.width)
        return content.startDate.addingTimeInterval(content.endDate.timeIntervalSince(content.startDate) * progress)
    }

    private func nearestPoint(in points: [DiskTemperaturePointValue], to date: Date) -> DiskTemperaturePointValue? {
        points.min { lhs, rhs in
            abs(lhs.sampledAt.timeIntervalSince(date)) < abs(rhs.sampledAt.timeIntervalSince(date))
        }
    }

    private func chartRect(in size: CGSize) -> CGRect {
        let left: CGFloat = 24
        let right: CGFloat = 8
        let top: CGFloat = 8
        let bottom: CGFloat = 0
        return CGRect(
            x: left,
            y: top,
            width: max(size.width - left - right, 1),
            height: max(size.height - top - bottom, 1)
        )
    }
}

private struct PartitionUsageRow: View {
    let content: PartitionRowContent

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(content.accent.opacity(0.12))
                Image(systemName: "externaldrive")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(content.accent)
            }
            .frame(width: 64, height: 58)

            VStack(alignment: .leading, spacing: 8) {
                Text(content.title)
                    .font(.fitnexTitle(size: 13))
                    .foregroundColor(FitnexColor.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(content.detail)
                    .font(.fitnexBody(size: 9, weight: .regular))
                    .foregroundColor(content.isCritical ? Color(hex: 0xE5484D) : FitnexColor.lightText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                ProgressView(value: content.progress)
                    .tint(content.accent)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(content.percentText)
                .font(.fitnexTitle(size: 12))
                .foregroundColor(content.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .frame(height: 80)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct ProgressChart: View {
    private let points: [CGFloat] = [42, 38, 56, 85, 66, 98, 103, 70, 74, 86, 52, 61]
    private let labels = ["00:00", "06:00", "12:00", "18:00", "24:00"]

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let left: CGFloat = 22
                    let right: CGFloat = 0
                    let top: CGFloat = 6
                    let bottom: CGFloat = 25
                    let chart = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)

                    for row in 0 ... 5 {
                        let y = chart.minY + chart.height * CGFloat(row) / 5
                        var grid = Path()
                        grid.move(to: CGPoint(x: chart.minX, y: y))
                        grid.addLine(to: CGPoint(x: chart.maxX, y: y))
                        context.stroke(grid, with: .color(FitnexColor.pale), lineWidth: 1)
                    }

                    func point(_ index: Int, _ value: CGFloat) -> CGPoint {
                        let x = chart.minX + chart.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = chart.maxY - chart.height * value / 125
                        return CGPoint(x: x, y: y)
                    }

                    let linePoints = points.enumerated().map { point($0, $1) }
                    let line = Path.smoothCurve(through: linePoints)

                    var area = line
                    area.addLine(to: CGPoint(x: chart.maxX, y: chart.maxY))
                    area.addLine(to: CGPoint(x: chart.minX, y: chart.maxY))
                    area.closeSubpath()

                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [FitnexColor.orange.opacity(0.28), FitnexColor.orange.opacity(0.02)]),
                        startPoint: CGPoint(x: chart.midX, y: chart.minY),
                        endPoint: CGPoint(x: chart.midX, y: chart.maxY)
                    ))
                    context.stroke(line, with: .color(FitnexColor.orange), lineWidth: 1.2)

                    let markerX = point(6, points[6]).x
                    var marker = Path()
                    marker.move(to: CGPoint(x: markerX, y: chart.minY))
                    marker.addLine(to: CGPoint(x: markerX, y: chart.maxY))
                    context.stroke(marker, with: .color(FitnexColor.orange.opacity(0.85)), lineWidth: 1)
                    context.fill(Path(ellipseIn: CGRect(x: markerX - 3.5, y: point(6, points[6]).y - 3.5, width: 7, height: 7)), with: .color(.white))
                    context.stroke(Path(ellipseIn: CGRect(x: markerX - 3.5, y: point(6, points[6]).y - 3.5, width: 7, height: 7)), with: .color(FitnexColor.orange), lineWidth: 1.2)
                }

                VStack {
                    ForEach(["125", "100", "75", "50", "25", "0"], id: \.self) { label in
                        Text(label)
                            .font(.fitnexBody(size: 8, weight: .regular))
                            .foregroundColor(FitnexColor.grayText)
                            .frame(width: 16, alignment: .trailing)
                        if label != "0" { Spacer() }
                    }
                }
                .frame(height: 160)
                .padding(.top, 2)
            }

            HStack {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.fitnexBody(size: 8, weight: .regular))
                        .foregroundColor(FitnexColor.grayText)
                    if label != "24:00" { Spacer() }
                }
            }
            .padding(.leading, 42)
            .padding(.trailing, 4)
        }
    }
}

private struct WorkoutRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FitnexColor.orangeSoft)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(FitnexColor.orange)
            }
            .frame(width: 64, height: 58)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.fitnexTitle(size: 13))
                    .foregroundColor(FitnexColor.black)
                Text(detail)
                    .font(.fitnexBody(size: 9, weight: .regular))
                    .foregroundColor(FitnexColor.lightText)
                ProgressView(value: 0.62)
                    .tint(FitnexColor.orange)
                    .frame(width: 180)
            }

            Spacer()

            Circle()
                .fill(FitnexColor.orangeSoft)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FitnexColor.orange)
                }
        }
        .padding(.horizontal, 15)
        .frame(height: 80)
        .background(FitnexColor.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(FitnexColor.border, lineWidth: 1)
        }
    }
}

private struct SquareIconButton: View {
    let systemName: String
    let action: () -> Void
    var dot = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(FitnexColor.border, lineWidth: 1)
                }
                .overlay {
                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FitnexColor.grayText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle()
                            .fill(FitnexColor.orange)
                            .frame(width: 5, height: 5)
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                    }
                }
            .frame(width: 35, height: 35)
        }
        .buttonStyle(.plain)
    }
}

private struct SmallCircleIcon: View {
    let systemName: String
    let background: Color
    let foreground: Color

    var body: some View {
        Circle()
            .fill(background)
            .frame(width: 25, height: 25)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(foreground)
            }
    }
}

private struct ProfileAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(FitnexColor.orangeSoft)
            Circle()
                .fill(Color(hex: 0xF4C7A1))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(y: -size * 0.18)
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(FitnexColor.orange)
                .frame(width: size * 0.56, height: size * 0.3)
                .offset(y: size * 0.16)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct MiniBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach([18, 38, 28, 48, 32], id: \.self) { height in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(height > 34 ? FitnexColor.orange : FitnexColor.orangeSoft)
                    .frame(width: 15, height: CGFloat(height))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct StepsBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach([22, 42, 28, 50, 36, 44, 31], id: \.self) { height in
                Capsule()
                    .fill(height > 40 ? FitnexColor.orange : FitnexColor.orangeSoft)
                    .frame(width: 10, height: CGFloat(height))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct HeartBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach([64, 48, 30, 54, 38, 68], id: \.self) { height in
                Capsule()
                    .fill(height > 50 ? FitnexColor.orange : FitnexColor.orangeSoft)
                    .frame(width: 10, height: CGFloat(height))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct WeightSparkline: View {
    var body: some View {
        Canvas { context, size in
            let values: [CGFloat] = [38, 44, 32, 50, 43, 56, 49]
            let maxValue: CGFloat = 60

            func point(_ index: Int) -> CGPoint {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - size.height * values[index] / maxValue
                return CGPoint(x: x, y: y)
            }

            let curvePoints = values.indices.map { point($0) }
            let path = Path.smoothCurve(through: curvePoints)
            context.stroke(path, with: .color(FitnexColor.orange), lineWidth: 2)
        }
    }
}

private struct MetricSparkline: View {
    let chart: MetricChartContent

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(x: 0, y: 4, width: size.width, height: max(size.height - 8, 1))

            if let secondary = chart.secondary,
               secondary.count > 1 {
                drawLine(
                    secondary,
                    in: frame,
                    color: chart.secondaryColor ?? FitnexColor.lightText,
                    context: &context,
                    lineWidth: 1.5
                )
            }

            if chart.primary.count > 1 {
                if chart.showsArea {
                    drawArea(chart.primary, in: frame, color: chart.primaryColor, context: &context)
                }
                drawLine(chart.primary, in: frame, color: chart.primaryColor, context: &context, lineWidth: 2)
            } else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: frame.minX, y: frame.midY))
                baseline.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                context.stroke(baseline, with: .color(FitnexColor.pale), lineWidth: 1)
            }
        }
    }

    private func drawLine(
        _ values: [Double],
        in frame: CGRect,
        color: Color,
        context: inout GraphicsContext,
        lineWidth: CGFloat
    ) {
        let points = normalizedPoints(values, in: frame)
        guard points.count > 1 else { return }
        let path = Path.smoothCurve(through: points)
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func drawArea(
        _ values: [Double],
        in frame: CGRect,
        color: Color,
        context: inout GraphicsContext
    ) {
        let points = normalizedPoints(values, in: frame)
        guard points.count > 1 else { return }
        var area = Path.smoothCurve(through: points)
        area.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        area.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.24), color.opacity(0.03)]),
                startPoint: CGPoint(x: frame.midX, y: frame.minY),
                endPoint: CGPoint(x: frame.midX, y: frame.maxY)
            )
        )
    }

    private func normalizedPoints(_ values: [Double], in frame: CGRect) -> [CGPoint] {
        guard let minValue = values.min(), let maxValue = values.max() else { return [] }
        let range = maxValue - minValue
        return values.enumerated().map { index, value in
            let x = frame.minX + frame.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
            let normalized = range == 0 ? 0.5 : (value - minValue) / range
            let y = frame.maxY - frame.height * CGFloat(normalized)
            return CGPoint(x: x, y: y)
        }
    }
}

private struct HostCardContent {
    let title: String
    let primaryText: String
    let secondaryText: String
    let tertiaryText: String?
    let trailingLabel: String
    let trailingValue: String
    let icon: String
}

private struct MetricCardContent {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let iconBackground: Color
    let iconForeground: Color
    let chart: MetricChartContent?
    let progress: CapacityProgressContent?
    let fallbackStyle: MetricFallbackStyle
}

private struct MetricChartContent {
    let primary: [Double]
    let secondary: [Double]?
    let primaryColor: Color
    let secondaryColor: Color?
    let showsArea: Bool
}

private enum MetricFallbackStyle {
    case bars
    case capsules
    case wave
    case line
}

private struct CapacityProgressContent {
    let fraction: CGFloat
    let fillColor: Color
    let trackColor: Color
}

private struct NetworkCounterSample {
    let name: String
    let rxBytes: Int64
    let txBytes: Int64
    let timestamp: Date
}

private struct NetworkRateSample {
    let rxBytesPerSecond: Int64
    let txBytesPerSecond: Int64
}

private struct DiskInfoCardContent: Identifiable {
    let id: String
    let serialNumber: String
    let title: String
    let temperatureText: String
    let capacityText: String
    let statusText: String
    let accent: Color
}

private struct DiskTemperaturePointValue {
    let sampledAt: Date
    let temperature: Double
}

private struct DiskTemperatureSeriesContent {
    let id: String
    let title: String
    let color: Color
    let points: [DiskTemperaturePointValue]
}

private struct DiskTemperatureLegendItem: Identifiable {
    let id: String
    let title: String
    let color: Color
}

private struct DiskTemperatureChartContent {
    let series: [DiskTemperatureSeriesContent]
    let legend: [DiskTemperatureLegendItem]
    let minValue: Double
    let maxValue: Double
    let startDate: Date
    let endDate: Date
    let yAxisLabels: [String]
    let xAxisLabels: [String]
}

private struct DiskTemperatureSelectedItem: Identifiable {
    let id: String
    let title: String
    let color: Color
    let valueText: String
    let sampleTimeText: String
    let isAvailable: Bool
}

private struct DiskTemperatureSelectedSummary {
    let timeText: String
    let items: [DiskTemperatureSelectedItem]
}

private struct PartitionRowContent: Identifiable {
    let id: String
    let title: String
    let detail: String
    let percentText: String
    let progress: Double
    let accent: Color
    let isCritical: Bool
}

private enum JournalGenerationState {
    case idle
    case generating
    case completed
    case failed
}

@MainActor
private final class JournalGeneratorViewModel: ObservableObject {
    @Published private(set) var state: JournalGenerationState = .idle
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var resultImage: UIImage?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    var hasResult: Bool {
        resultImage != nil
    }

    func generate(from image: UIImage) {
        originalImage = image
        resultImage = nil
        errorMessage = nil
        state = .generating

        Task {
            do {
                let generated = try await JournalImageProcessor.generate(from: image)
                resultImage = generated
                state = .completed
                toastMessage = "Sticker ready"
            } catch {
                state = .failed
                errorMessage = "Sticker generation failed"
                toastMessage = "Generation failed"
            }
        }
    }

    func saveResult() async {
        guard let resultImage, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            guard let pngData = resultImage.pngData() else {
                throw JournalPhotoSaveError.writeFailed
            }
            try await JournalPhotoSaver.save(pngData)
            toastMessage = "Saved to Photos"
        } catch {
            toastMessage = "Save failed"
            errorMessage = "Unable to save image to Photos"
        }
    }

    func fail(_ message: String) {
        state = .failed
        errorMessage = message
        toastMessage = message
    }
}

private enum JournalImageProcessor {
    static func generate(from image: UIImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let normalized = normalizedImage(image, maxDimension: 1536)
            guard let cgImage = normalized.cgImage,
                  let input = CIImage(image: normalized) else {
                throw JournalImageError.invalidImage
            }

            let extent = input.extent
            let detection = largestObjectDetection(for: cgImage, extent: extent) ?? fallbackDetection(for: cgImage, extent: extent)
            guard let detection else {
                throw JournalImageError.objectNotFound
            }

            let cropRect = paddedRect(around: detection.boundingBox, in: extent, paddingRatio: 0.18)
            let source = stylize(input.cropped(to: cropRect))
            let mask = stickerMask(from: detection.mask, cropRect: cropRect)
            let sticker = stickerComposite(subject: source, mask: mask, extent: cropRect)

            guard let cgOutput = context.createCGImage(sticker, from: cropRect) else {
                throw JournalImageError.renderFailed
            }

            return UIImage(cgImage: cgOutput, scale: normalized.scale, orientation: .up)
        }.value
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private struct SubjectDetection {
        let boundingBox: CGRect
        let mask: CIImage
    }

    private static func normalizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func stylize(_ image: CIImage) -> CIImage {
        var output = image

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(1.14, forKey: kCIInputSaturationKey)
            filter.setValue(0.035, forKey: kCIInputBrightnessKey)
            filter.setValue(1.04, forKey: kCIInputContrastKey)
            output = filter.outputImage ?? output
        }

        if let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(0.18, forKey: kCIInputSharpnessKey)
            output = filter.outputImage ?? output
        }

        return output.cropped(to: image.extent)
    }

    private static func largestObjectDetection(for cgImage: CGImage, extent: CGRect) -> SubjectDetection? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let fullMask = scaledMask(from: observation, extent: extent)
        let allRects: [CGRect] = observation.salientObjects?.map { rect(from: $0.boundingBox, extent: extent) } ?? []
        let largeRects = allRects.filter { $0.width > 4 && $0.height > 4 }
        let largestBox = largeRects.max { ($0.width * $0.height) < ($1.width * $1.height) }
        guard let largestBox else { return nil }

        return SubjectDetection(boundingBox: largestBox, mask: fullMask)
    }

    private static func fallbackDetection(for cgImage: CGImage, extent: CGRect) -> SubjectDetection? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let fullMask = scaledMask(from: observation, extent: extent)
        let allRects: [CGRect] = observation.salientObjects?.map { rect(from: $0.boundingBox, extent: extent) } ?? []
        let largeRects = allRects.filter { $0.width > 4 && $0.height > 4 }
        let fallbackBox = largeRects.max { ($0.width * $0.height) < ($1.width * $1.height) }

        return SubjectDetection(boundingBox: fallbackBox ?? centeredRect(in: extent), mask: fullMask)
    }

    private static func scaledMask(from observation: VNSaliencyImageObservation, extent: CGRect) -> CIImage {
        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let scaleX = extent.width / max(mask.extent.width, 1)
        let scaleY = extent.height / max(mask.extent.height, 1)
        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(scaleX, forKey: kCIInputScaleKey)
            filter.setValue(scaleY / max(scaleX, 0.0001), forKey: "inputAspectRatio")
            if let output = filter.outputImage {
                return output.cropped(to: extent)
            }
        }

        return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: extent)
    }

    private static func stickerMask(from inputMask: CIImage, cropRect: CGRect) -> CIImage {
        var mask = inputMask.cropped(to: cropRect)

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(5.0, forKey: kCIInputContrastKey)
            filter.setValue(0.22, forKey: kCIInputBrightnessKey)
            mask = filter.outputImage?.cropped(to: cropRect) ?? mask
        }

        if let filter = CIFilter(name: "CIColorThreshold") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.34, forKey: "inputThreshold")
            mask = filter.outputImage?.cropped(to: cropRect) ?? mask
        }

        mask = morphologyMaximum(mask, radius: max(min(cropRect.width, cropRect.height) * 0.012, 3))

        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(1.0, forKey: kCIInputRadiusKey)
            mask = filter.outputImage?.cropped(to: cropRect) ?? mask
        }

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(2.2, forKey: kCIInputContrastKey)
            filter.setValue(0.04, forKey: kCIInputBrightnessKey)
            mask = filter.outputImage?.cropped(to: cropRect) ?? mask
        }

        return mask.cropped(to: cropRect)
    }

    private static func stickerComposite(subject: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let transparent = clear(extent: extent)
        let cutout = blend(input: subject, background: transparent, mask: mask)
        let outlineMask = morphologyMaximum(mask, radius: max(min(extent.width, extent.height) * 0.035, 8))
        let shadowMask = blur(morphologyMaximum(mask, radius: max(min(extent.width, extent.height) * 0.028, 7)), radius: 8)
            .transformed(by: CGAffineTransform(translationX: 0, y: -max(extent.height * 0.018, 5)))
            .cropped(to: extent)
        let shadow = blend(
            input: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.12)).cropped(to: extent),
            background: transparent,
            mask: shadowMask
        )
        let outline = blend(
            input: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent),
            background: transparent,
            mask: outlineMask
        )

        return sourceOver(cutout, over: sourceOver(outline, over: shadow)).cropped(to: extent)
    }

    private static func morphologyMaximum(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIMorphologyMaximum") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func blur(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func blend(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func sourceOver(_ input: CIImage, over background: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage?.cropped(to: background.extent) ?? input
    }

    private static func clear(extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
    }

    private static func rect(from normalizedRect: CGRect, extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
    }

    private static func paddedRect(around rect: CGRect, in extent: CGRect, paddingRatio: CGFloat) -> CGRect {
        let padding = max(rect.width, rect.height) * paddingRatio
        return rect.insetBy(dx: -padding, dy: -padding).intersection(extent)
    }

    private static func centeredRect(in extent: CGRect) -> CGRect {
        let side = min(extent.width, extent.height) * 0.78
        return CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        ).intersection(extent)
    }
}

private enum JournalImageError: Error {
    case invalidImage
    case objectNotFound
    case renderFailed
}

private enum JournalPhotoSaver {
    static func save(_ pngData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw JournalPhotoSaveError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "sticker.png"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: pngData, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: JournalPhotoSaveError.writeFailed)
                }
            }
        }
    }
}

private enum JournalPhotoSaveError: Error {
    case notAuthorized
    case writeFailed
}

private enum CutoutGenerationState {
    case idle
    case generating
    case completed
    case failed
}

@MainActor
private final class CutoutGeneratorViewModel: ObservableObject {
    @Published private(set) var state: CutoutGenerationState = .idle
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var resultImage: UIImage?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    var hasResult: Bool {
        resultImage != nil
    }

    func generate(from image: UIImage) {
        originalImage = image
        resultImage = nil
        errorMessage = nil
        state = .generating

        Task {
            do {
                let generated = try await CutoutImageProcessor.generate(from: image)
                resultImage = generated
                state = .completed
                toastMessage = "抠图完成"
            } catch let error as CutoutImageError {
                state = .failed
                switch error {
                case .objectNotFound:
                    errorMessage = "未识别到主主体"
                    toastMessage = "未识别到主主体"
                case .invalidImage, .renderFailed:
                    errorMessage = "抠图失败"
                    toastMessage = "抠图失败"
                }
            } catch {
                state = .failed
                errorMessage = "抠图失败"
                toastMessage = "抠图失败"
            }
        }
    }

    func saveResult() async {
        guard let resultImage, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            guard let pngData = resultImage.pngData() else {
                throw CutoutPhotoSaveError.writeFailed
            }
            try await CutoutPhotoSaver.save(pngData)
            toastMessage = "已保存到相册"
        } catch {
            toastMessage = "保存失败"
            errorMessage = "无法保存到相册"
        }
    }

    func fail(_ message: String) {
        state = .failed
        errorMessage = message
        toastMessage = message
    }
}

private enum CutoutImageProcessor {
    static func generate(from image: UIImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let normalized = normalizedImage(image, maxDimension: 1536)
            guard let cgImage = normalized.cgImage else {
                throw CutoutImageError.invalidImage
            }

            let input = CIImage(cgImage: cgImage)
            let extent = input.extent
            let output: CIImage

            // iOS 17 has system-grade foreground masks. Keep a saliency fallback so
            // the feature still works without raising the app's iOS 16 deployment target.
            if #available(iOS 17.0, *),
               let foregroundCutout = try? foregroundInstanceCutout(for: cgImage, input: input, extent: extent) {
                output = foregroundCutout
            } else if let fallbackCutout = saliencyCutout(for: cgImage, input: input, extent: extent) {
                output = fallbackCutout
            } else {
                throw CutoutImageError.objectNotFound
            }

            guard let cgOutput = context.createCGImage(output, from: extent) else {
                throw CutoutImageError.renderFailed
            }

            return UIImage(cgImage: cgOutput, scale: normalized.scale, orientation: .up)
        }.value
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private struct SubjectDetection {
        let boundingBox: CGRect
        let mask: CIImage
    }

    private static func normalizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    @available(iOS 17.0, *)
    private static func foregroundInstanceCutout(for cgImage: CGImage, input: CIImage, extent: CGRect) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw CutoutImageError.objectNotFound
        }
        guard let primaryInstance = primaryForegroundInstance(in: observation) else {
            throw CutoutImageError.objectNotFound
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: IndexSet(integer: primaryInstance),
            from: handler
        )
        let mask = CIImage(cvPixelBuffer: maskBuffer).cropped(to: extent)
        return cutoutComposite(subject: input, mask: mask, extent: extent)
    }

    private static func saliencyCutout(for cgImage: CGImage, input: CIImage, extent: CGRect) -> CIImage? {
        let detection = largestObjectDetection(for: cgImage, extent: extent) ?? fallbackDetection(for: cgImage, extent: extent)
        guard let detection else { return nil }
        let mask = cutoutMask(from: detection.mask, focusingOn: detection.boundingBox, extent: extent)
        return cutoutComposite(subject: input, mask: mask, extent: extent)
    }

    private static func largestObjectDetection(for cgImage: CGImage, extent: CGRect) -> SubjectDetection? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let fullMask = scaledMask(from: observation, extent: extent)
        let allRects: [CGRect] = observation.salientObjects?.map { rect(from: $0.boundingBox, extent: extent) } ?? []
        let largeRects = allRects.filter { $0.width > 4 && $0.height > 4 }
        guard let largestBox = largeRects.max(by: areaAscending) else { return nil }
        return SubjectDetection(boundingBox: largestBox, mask: fullMask)
    }

    private static func fallbackDetection(for cgImage: CGImage, extent: CGRect) -> SubjectDetection? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let fullMask = scaledMask(from: observation, extent: extent)
        let allRects: [CGRect] = observation.salientObjects?.map { rect(from: $0.boundingBox, extent: extent) } ?? []
        let largeRects = allRects.filter { $0.width > 4 && $0.height > 4 }
        let fallbackBox = largeRects.max(by: areaAscending) ?? centeredRect(in: extent)
        return SubjectDetection(boundingBox: fallbackBox, mask: fullMask)
    }

    private static func scaledMask(from observation: VNSaliencyImageObservation, extent: CGRect) -> CIImage {
        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let scaleX = extent.width / max(mask.extent.width, 1)
        let scaleY = extent.height / max(mask.extent.height, 1)
        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(scaleX, forKey: kCIInputScaleKey)
            filter.setValue(scaleY / max(scaleX, 0.0001), forKey: "inputAspectRatio")
            if let output = filter.outputImage {
                return output.cropped(to: extent)
            }
        }

        return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: extent)
    }

    @available(iOS 17.0, *)
    private static func primaryForegroundInstance(in observation: VNInstanceMaskObservation) -> Int? {
        var largestInstance: Int?
        var largestArea = 0

        for instance in observation.allInstances {
            let area = maskArea(for: IndexSet(integer: instance), using: observation)
            if area > largestArea {
                largestArea = area
                largestInstance = instance
            }
        }

        return largestInstance
    }

    @available(iOS 17.0, *)
    private static func maskArea(for instances: IndexSet, using observation: VNInstanceMaskObservation) -> Int {
        guard let pixelBuffer = try? observation.generateMask(forInstances: instances) else { return 0 }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let usesPlanes = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        let plane = 0
        let width = usesPlanes ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = usesPlanes ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = usesPlanes ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = usesPlanes ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) : CVPixelBufferGetBaseAddress(pixelBuffer)

        guard let baseAddress else { return 0 }

        var area = 0
        for rowIndex in 0..<height {
            let row = baseAddress
                .advanced(by: rowIndex * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for columnIndex in 0..<width where row[columnIndex] > 0 {
                area += 1
            }
        }

        return area
    }

    private static func cutoutMask(from inputMask: CIImage, focusingOn boundingBox: CGRect, extent: CGRect) -> CIImage {
        let focusRect = boundingBox.intersection(extent)
        let croppedMask = inputMask.cropped(to: focusRect.isNull ? extent : focusRect)
        var mask = sourceOver(croppedMask, over: clear(extent: extent)).cropped(to: extent)

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(5.0, forKey: kCIInputContrastKey)
            filter.setValue(0.18, forKey: kCIInputBrightnessKey)
            mask = filter.outputImage?.cropped(to: extent) ?? mask
        }

        if let filter = CIFilter(name: "CIColorThreshold") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.4, forKey: "inputThreshold")
            mask = filter.outputImage?.cropped(to: extent) ?? mask
        }

        mask = morphologyMaximum(mask, radius: max(min(extent.width, extent.height) * 0.004, 2))

        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(1.2, forKey: kCIInputRadiusKey)
            mask = filter.outputImage?.cropped(to: extent) ?? mask
        }

        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(mask, forKey: kCIInputImageKey)
            filter.setValue(0.0, forKey: kCIInputSaturationKey)
            filter.setValue(2.4, forKey: kCIInputContrastKey)
            filter.setValue(0.02, forKey: kCIInputBrightnessKey)
            mask = filter.outputImage?.cropped(to: extent) ?? mask
        }

        return mask.cropped(to: extent)
    }

    private static func cutoutComposite(subject: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        blend(input: subject, background: whiteBackground(extent: extent), mask: mask).cropped(to: extent)
    }

    private static func morphologyMaximum(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIMorphologyMaximum") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func blend(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func sourceOver(_ input: CIImage, over background: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage?.cropped(to: background.extent) ?? input
    }

    private static func clear(extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
    }

    private static func whiteBackground(extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
    }

    private static func rect(from normalizedRect: CGRect, extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
    }

    private static func centeredRect(in extent: CGRect) -> CGRect {
        let side = min(extent.width, extent.height) * 0.78
        return CGRect(
            x: extent.midX - side / 2,
            y: extent.midY - side / 2,
            width: side,
            height: side
        ).intersection(extent)
    }

    private static func areaAscending(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        (lhs.width * lhs.height) < (rhs.width * rhs.height)
    }
}

private enum CutoutImageError: Error {
    case invalidImage
    case objectNotFound
    case renderFailed
}

private enum CutoutPhotoSaver {
    static func save(_ pngData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CutoutPhotoSaveError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "cutout.png"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: pngData, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CutoutPhotoSaveError.writeFailed)
                }
            }
        }
    }
}

private enum CutoutPhotoSaveError: Error {
    case notAuthorized
    case writeFailed
}

private enum MonitorServerFilter: CaseIterable, Hashable {
    case all
    case online
    case offline

    var icon: String {
        switch self {
        case .all: return "server.rack"
        case .online: return "checkmark.circle.fill"
        case .offline: return "pause.circle.fill"
        }
    }
}

private struct MonitorOverviewCardContent {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let accent: Color
}

private struct MonitorNetworkCardContent {
    let transferText: String
    let downloadText: String
    let uploadText: String
}

private struct MonitorServerRowContent: Identifiable {
    let id: Int
    let title: String
    let countryText: String
    let isOnline: Bool
    let cpuText: String
    let cpuProgress: Double?
    let memoryText: String
    let memoryProgress: Double?
    let diskText: String
    let diskProgress: Double?
    let uploadText: String
    let downloadText: String
}

@MainActor
private final class HostMonitorSettingsStore: ObservableObject {
    static let shared = HostMonitorSettingsStore()
    static let defaultHost = "192.168.2.202:12225"
    private static let defaultIPAddress = "192.168.2.202"
    static let defaultBaseURL = "http://192.168.2.202:12225"

    @Published private(set) var baseURL: String

    private let defaults = UserDefaults.standard
    private let baseURLKey = "hostMonitor.baseURL"

    private init() {
        let stored = defaults.string(forKey: baseURLKey) ?? ""
        baseURL = Self.normalizedHTTPBaseURL(stored, fallback: Self.defaultBaseURL)
    }

    var displayHost: String {
        Self.displayHost(for: baseURL)
    }

    var endpointIPAddress: String {
        URL(string: baseURL)?.host ?? Self.defaultIPAddress
    }

    func endpointURL(path: String) -> URL {
        endpointURL(baseURL: baseURL, path: path)
    }

    func endpointURL(baseURL: String, path: String) -> URL {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(baseURL)/\(trimmedPath)") ?? URL(string: "\(Self.defaultBaseURL)/\(trimmedPath)")!
    }

    func save(baseURL: String) {
        let normalizedBaseURL = Self.normalizedHTTPBaseURL(baseURL, fallback: Self.defaultBaseURL)
        self.baseURL = normalizedBaseURL
        defaults.set(normalizedBaseURL, forKey: baseURLKey)
    }

    private static func normalizedHTTPBaseURL(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)?.host == nil ? fallback : trimmed
        }
        let normalized = "http://\(trimmed)"
        return URL(string: normalized)?.host == nil ? fallback : normalized
    }

    private static func displayHost(for baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host else { return Self.defaultHost }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

@MainActor
private final class NezhaSettingsStore: ObservableObject {
    static let shared = NezhaSettingsStore()
    private static let defaultBaseURL = "http://nz.geff.top"

    @Published private(set) var baseURL: String
    @Published private(set) var authToken: String

    private let defaults = UserDefaults.standard
    private let baseURLKey = "nezha.baseURL"
    private let authTokenKey = "nezha.authToken"

    private init() {
        baseURL = Self.normalizedHTTPBaseURL(defaults.string(forKey: baseURLKey) ?? "")
        authToken = defaults.string(forKey: authTokenKey) ?? ""
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayHost: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Nezha service not configured" }
        return URL(string: Self.normalizedHTTPBaseURL(trimmed))?.host ?? trimmed
    }

    func save(baseURL: String, authToken: String) {
        let normalizedBaseURL = Self.normalizedHTTPBaseURL(baseURL)
        let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = normalizedBaseURL
        self.authToken = trimmedToken
        defaults.set(normalizedBaseURL, forKey: baseURLKey)
        defaults.set(trimmedToken, forKey: authTokenKey)
    }

    private static func normalizedHTTPBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return Self.defaultBaseURL }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)?.host == nil ? Self.defaultBaseURL : trimmed
        }
        if trimmed.hasPrefix("ws://") {
            let normalized = "http://" + String(trimmed.dropFirst(5))
            return URL(string: normalized)?.host == nil ? Self.defaultBaseURL : normalized
        }
        if trimmed.hasPrefix("wss://") {
            let normalized = "https://" + String(trimmed.dropFirst(6))
            return URL(string: normalized)?.host == nil ? Self.defaultBaseURL : normalized
        }
        let normalized = "http://\(trimmed)"
        return URL(string: normalized)?.host == nil ? Self.defaultBaseURL : normalized
    }
}

@MainActor
private final class TranslateSettingsStore: ObservableObject {
    static let shared = TranslateSettingsStore()
    private static let defaultBaseURL = "http://192.168.2.88:11434"
    private static let defaultModel = "transgemma4b"

    @Published private(set) var baseURL: String
    @Published private(set) var model: String

    private let defaults = UserDefaults(suiteName: "group.com.local.fitnex") ?? .standard
    private let legacyDefaults = UserDefaults.standard
    private let baseURLKey = "translate.baseURL"
    private let modelKey = "translate.model"

    private init() {
        baseURL = defaults.string(forKey: baseURLKey) ?? legacyDefaults.string(forKey: baseURLKey) ?? Self.defaultBaseURL
        model = defaults.string(forKey: modelKey) ?? legacyDefaults.string(forKey: modelKey) ?? Self.defaultModel
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayHost: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "翻译服务未配置" }
        return URL(string: trimmed)?.host ?? trimmed
    }

    func save(baseURL: String, model: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmedURL.isEmpty ? Self.defaultBaseURL : trimmedURL
        self.model = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
        defaults.set(self.baseURL, forKey: baseURLKey)
        defaults.set(self.model, forKey: modelKey)
        defaults.synchronize()
        legacyDefaults.set(self.baseURL, forKey: baseURLKey)
        legacyDefaults.set(self.model, forKey: modelKey)
    }
}

private struct QuickFillItem: Identifiable, Equatable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

private final class QuickFillStore: ObservableObject {
    static let shared = QuickFillStore()

    @Published private(set) var items: [QuickFillItem]

    private let defaults: UserDefaults?
    private let itemsKey = "quickFill.items"

    private init() {
        defaults = UserDefaults(suiteName: "group.com.local.fitnex")
        items = (defaults?.stringArray(forKey: itemsKey) ?? []).map { QuickFillItem(text: $0) }
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(QuickFillItem(text: trimmed))
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        defaults?.set(items.map(\.text), forKey: itemsKey)
        defaults?.synchronize()
    }

    static var sharedItems: [String] {
        guard let defaults = UserDefaults(suiteName: "group.com.local.fitnex") else { return [] }
        return defaults.stringArray(forKey: "quickFill.items") ?? []
    }
}

@MainActor
private final class NezhaMonitorViewModel: ObservableObject {
    @Published private(set) var servers: [NezhaStreamServer] = []
    @Published private(set) var connectionState: NezhaConnectionState = .notConfigured
    @Published private(set) var lastUpdated: Date?
    @Published var selectedFilter: MonitorServerFilter = .all
    @Published var sortDescending = true
    @Published var toastMessage: String?

    private let settings: NezhaSettingsStore
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var hasShownFailure = false
    private var isActive = false

    init(settings: NezhaSettingsStore) {
        self.settings = settings
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var statusText: String {
        switch connectionState {
        case .notConfigured:
            return "Configure Nezha in Settings"
        case .connecting:
            return "Connecting to \(settings.displayHost)"
        case .connected:
            if let lastUpdated {
                return "Updated \(Self.timeFormatter.string(from: lastUpdated))"
            }
            return "Connected"
        case .disconnected:
            return "Disconnected, retrying"
        case .failed(let message):
            return message
        }
    }

    var totalCard: MonitorOverviewCardContent {
        MonitorOverviewCardContent(
            title: "服务器总数",
            value: "\(servers.count)",
            subtitle: nil,
            icon: "server.rack",
            accent: Color(hex: 0x3E7BFA)
        )
    }

    var onlineCard: MonitorOverviewCardContent {
        MonitorOverviewCardContent(
            title: "在线服务器",
            value: "\(servers.filter { isOnline($0) }.count)",
            subtitle: nil,
            icon: "checkmark.circle.fill",
            accent: Color(hex: 0x14A46A)
        )
    }

    var offlineCard: MonitorOverviewCardContent {
        MonitorOverviewCardContent(
            title: "离线服务器",
            value: "\(servers.filter { !isOnline($0) }.count)",
            subtitle: nil,
            icon: "xmark.circle.fill",
            accent: Color(hex: 0xE5484D)
        )
    }

    var networkCard: MonitorNetworkCardContent {
        let down = servers.reduce(Int64(0)) { $0 + ($1.state?.netInSpeed ?? 0) }
        let up = servers.reduce(Int64(0)) { $0 + ($1.state?.netOutSpeed ?? 0) }
        let downTransfer = servers.reduce(Int64(0)) { $0 + ($1.state?.netInTransfer ?? 0) }
        let upTransfer = servers.reduce(Int64(0)) { $0 + ($1.state?.netOutTransfer ?? 0) }
        return MonitorNetworkCardContent(
            transferText: "↓\(bytes(downTransfer)) ↑\(bytes(upTransfer))",
            downloadText: rate(down),
            uploadText: rate(up)
        )
    }

    var serverRows: [MonitorServerRowContent] {
        filteredServers.map { server in
            let cpu = server.state?.cpu
            let memoryProgress = fraction(used: server.state?.memUsed, total: server.host?.memTotal)
            let diskProgress = fraction(used: server.state?.diskUsed, total: server.host?.diskTotal)
            return MonitorServerRowContent(
                id: server.id,
                title: server.name.isEmpty ? "Server \(server.id)" : server.name,
                countryText: server.countryCode?.uppercased() ?? "",
                isOnline: isOnline(server),
                cpuText: cpu.map { percent($0) } ?? "--",
                cpuProgress: cpu.map { min(max($0 / 100, 0), 1) },
                memoryText: memoryProgress.map { percent($0 * 100) } ?? "--",
                memoryProgress: memoryProgress,
                diskText: diskProgress.map { percent($0 * 100) } ?? "--",
                diskProgress: diskProgress,
                uploadText: rate(server.state?.netOutSpeed ?? 0),
                downloadText: rate(server.state?.netInSpeed ?? 0)
            )
        }
    }

    func start() async {
        isActive = true
        stopSocketOnly()
        await connect()
    }

    func stop() {
        isActive = false
        reconnectTask?.cancel()
        receiveTask?.cancel()
        socketTask?.cancel(with: .goingAway, reason: nil)
        reconnectTask = nil
        receiveTask = nil
        socketTask = nil
    }

    func reconnect() async {
        stopSocketOnly()
        await connect()
    }

    func toggleSort() {
        sortDescending.toggle()
    }

    private var filteredServers: [NezhaStreamServer] {
        let filtered = servers.filter { server in
            switch selectedFilter {
            case .all:
                return true
            case .online:
                return isOnline(server)
            case .offline:
                return !isOnline(server)
            }
        }

        return filtered.sorted { lhs, rhs in
            if lhs.displayIndex != rhs.displayIndex {
                return sortDescending ? lhs.displayIndex > rhs.displayIndex : lhs.displayIndex < rhs.displayIndex
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func connect() async {
        guard isActive else { return }
        guard let url = webSocketURL() else {
            connectionState = .notConfigured
            servers = []
            return
        }

        connectionState = .connecting
        var request = URLRequest(url: url)
        if !settings.authToken.isEmpty {
            request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        socketTask = task
        task.resume()
        connectionState = .connected
        hasShownFailure = false

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handlePayload(Data(text.utf8))
                case .data(let data):
                    handlePayload(data)
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                connectionState = .disconnected
                scheduleReconnect()
                return
            }
        }
    }

    private func handlePayload(_ data: Data) {
        let decoder = JSONDecoder()
        do {
            if let stream = try? decoder.decode(NezhaStreamServerData.self, from: data) {
                servers = stream.servers
            } else if let streamServers = try? decoder.decode([NezhaStreamServer].self, from: data) {
                servers = streamServers
            } else {
                let wrapped = try decoder.decode(NezhaCommonResponse<NezhaStreamServerData>.self, from: data)
                servers = wrapped.data?.servers ?? []
            }
            lastUpdated = Date()
            connectionState = .connected
        } catch {
            if !hasShownFailure {
                toastMessage = "Nezha payload decode failed"
                hasShownFailure = true
            }
        }
    }

    private func scheduleReconnect() {
        guard isActive, settings.isConfigured else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.connect()
        }
    }

    private func stopSocketOnly() {
        reconnectTask?.cancel()
        receiveTask?.cancel()
        socketTask?.cancel(with: .goingAway, reason: nil)
        reconnectTask = nil
        receiveTask = nil
        socketTask = nil
    }

    private func webSocketURL() -> URL? {
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        let suffix = base.hasSuffix("/api/v1") ? "/ws/server" : "/api/v1/ws/server"
        guard var components = URLComponents(string: base + suffix) else { return nil }
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }
        return components.url
    }

    private func isOnline(_ server: NezhaStreamServer) -> Bool {
        server.state != nil
    }

    private func fraction(used: Int64?, total: Int64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private func rate(_ value: Int64) -> String {
        let bytes = Double(max(value, 0))
        if bytes == 0 { return "0B/s" }
        if bytes < 1024 { return String(format: "%.0fB/s", bytes) }
        let units = ["KiB/s", "MiB/s", "GiB/s", "TiB/s"]
        var scaled = bytes / 1024
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return String(format: "%.2f%@", scaled, units[index])
    }

    private func bytes(_ value: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

private enum NezhaConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case disconnected
    case failed(String)
}

@MainActor
private final class DiskStatusViewModel: ObservableObject {
    @Published private(set) var disks: PhysicalDisksResponse?
    @Published private(set) var partitions: PartitionsResponse?
    @Published private(set) var history: DiskTemperatureHistoryResponse?
    @Published private(set) var smartDetail: DiskSmartResponse?
    @Published private(set) var isLoadingSmart = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var selectedTemperatureTime: Date?
    @Published var toastMessage: String?
    private let settings = HostMonitorSettingsStore.shared
    private var didShowRefreshError = false

    var diskCards: [DiskInfoCardContent] {
        if let disks {
            let palette = diskPalette
            return disks.physicalDisks.enumerated().map { index, disk in
                let accent = palette[index % palette.count]
                let temperatureText: String
                if let temperature = disk.temperatureCelsius {
                    temperatureText = "\(temperature) C"
                } else {
                    temperatureText = "Unavailable"
                }
                return DiskInfoCardContent(
                    id: disk.deviceId,
                    serialNumber: disk.serialNumber,
                    title: disk.friendlyName,
                    temperatureText: temperatureText,
                    capacityText: bytes(disk.sizeBytes),
                    statusText: "\(disk.healthStatus) | \(disk.operationalStatus)",
                    accent: accent
                )
            }
        }

        if !hasLoadedOnce {
            let palette = diskPalette
            return [
                DiskInfoCardContent(
                    id: "loading-0",
                    serialNumber: "",
                    title: "Loading disk",
                    temperatureText: "--",
                    capacityText: "Fetching capacity",
                    statusText: "Waiting for device state",
                    accent: palette[0]
                ),
                DiskInfoCardContent(
                    id: "loading-1",
                    serialNumber: "",
                    title: "Loading disk",
                    temperatureText: "--",
                    capacityText: "Fetching capacity",
                    statusText: "Waiting for device state",
                    accent: palette[1 % palette.count]
                )
            ]
        }

        let palette = diskPalette
        return [
            DiskInfoCardContent(
                id: "unavailable",
                serialNumber: "",
                title: "Disk unavailable",
                temperatureText: "--",
                capacityText: "No recent disk data",
                statusText: "Keep last good snapshot until the host responds",
                accent: palette[0]
            )
        ]
    }

    var historyWindowLabel: String {
        hasLoadedOnce ? "Last 24h" : "Loading"
    }

    var partitionSummary: String {
        if let partitions {
            return "\(partitions.items.count) partitions"
        }
        return hasLoadedOnce ? "Unavailable" : "Loading..."
    }

    var partitionRows: [PartitionRowContent] {
        if let partitions {
            return partitions.items.map { partition -> PartitionRowContent in
                let isCritical = partition.usedPercent > 90
                let accent = isCritical ? Color(hex: 0xE5484D) : FitnexColor.orange
                return PartitionRowContent(
                    id: partition.path,
                    title: "\(partition.path) \(partition.fstype)",
                    detail: "\(bytes(partition.usedBytes)) / \(bytes(partition.totalBytes))",
                    percentText: percent(partition.usedPercent),
                    progress: min(max(partition.usedPercent / 100, 0), 1),
                    accent: accent,
                    isCritical: isCritical
                )
            }
        }

        if !hasLoadedOnce {
            return [
                PartitionRowContent(
                    id: "loading-partition-0",
                    title: "Loading partition",
                    detail: "Fetching capacity",
                    percentText: "--",
                    progress: 0.35,
                    accent: FitnexColor.orange,
                    isCritical: false
                ),
                PartitionRowContent(
                    id: "loading-partition-1",
                    title: "Loading partition",
                    detail: "Fetching capacity",
                    percentText: "--",
                    progress: 0.55,
                    accent: FitnexColor.orange,
                    isCritical: false
                )
            ]
        }

        let rows = [PartitionRowContent(
            id: "unavailable-partition",
            title: "Partitions unavailable",
            detail: "No recent capacity snapshot",
            percentText: "--",
            progress: 0,
            accent: FitnexColor.orange,
            isCritical: false
        )]
        return rows
    }

    var temperatureChart: DiskTemperatureChartContent {
        let palette = diskPalette
        let historyItems = history?.items ?? []

        func historyPoints(from item: DiskTemperatureHistoryResponse.DiskTemperatureHistoryItem?) -> [DiskTemperaturePointValue] {
            guard let item else { return [] }
            return item.points.compactMap { point -> DiskTemperaturePointValue? in
                guard let value = point.temperatureCelsius,
                      let sampledAt = parseTimestamp(point.sampledAt) else { return nil }
                return DiskTemperaturePointValue(sampledAt: sampledAt, temperature: Double(value))
            }.sorted { $0.sampledAt < $1.sampledAt }
        }

        func appendCurrentPointIfNeeded(
            to points: [DiskTemperaturePointValue],
            disk: PhysicalDisksResponse.PhysicalDisk,
            snapshotTimestamp: String?
        ) -> [DiskTemperaturePointValue] {
            guard points.count < 2, let temperature = disk.temperatureCelsius else { return points }
            let sampledAt = parseTimestamp(disk.temperatureUpdatedAt ?? "")
                ?? parseTimestamp(snapshotTimestamp ?? "")
                ?? Date()
            let currentPoint = DiskTemperaturePointValue(sampledAt: sampledAt, temperature: Double(temperature))
            var merged = points.filter { abs($0.sampledAt.timeIntervalSince(sampledAt)) > 1 }
            merged.append(currentPoint)
            return merged.sorted { $0.sampledAt < $1.sampledAt }
        }

        var usedHistoryItemIds = Set<String>()
        var series: [DiskTemperatureSeriesContent] = []

        if let disks {
            series = disks.physicalDisks.enumerated().map { index, disk in
                let historyItem = historyItems.first { item in
                    item.deviceId == disk.deviceId || item.serialNumber == disk.serialNumber
                }
                if let historyItem {
                    usedHistoryItemIds.insert(historyItem.deviceId)
                }
                let points = appendCurrentPointIfNeeded(
                    to: historyPoints(from: historyItem),
                    disk: disk,
                    snapshotTimestamp: disks.timestamp
                )
                return DiskTemperatureSeriesContent(
                    id: disk.deviceId,
                    title: disk.friendlyName,
                    color: palette[index % palette.count],
                    points: points
                )
            }
        }

        let extraHistorySeries = historyItems.enumerated().compactMap { index, item -> DiskTemperatureSeriesContent? in
            guard !usedHistoryItemIds.contains(item.deviceId) else { return nil }
            let points = historyPoints(from: item)
            guard !points.isEmpty || disks == nil else { return nil }
            return DiskTemperatureSeriesContent(
                id: item.deviceId,
                title: item.friendlyName,
                color: palette[index % palette.count],
                points: points
            )
        }
        series.append(contentsOf: extraHistorySeries)

        let values = series.flatMap { $0.points.map(\.temperature) }
        let minValue = floor((values.min() ?? 30) - 1)
        let maxValue = ceil((values.max() ?? 50) + 1)
        let step = max((maxValue - minValue) / 5, 1)
        let yAxisLabels = stride(from: maxValue, through: minValue, by: -step).map { "\(Int($0))" }
        let allDates = series.flatMap { $0.points.map(\.sampledAt) }
        let fallbackEnd = allDates.max() ?? Date()
        let endDate = parseTimestamp(history?.to ?? "") ?? fallbackEnd
        var startDate = parseTimestamp(history?.from ?? "") ?? allDates.min() ?? endDate.addingTimeInterval(-24 * 60 * 60)
        if startDate >= endDate {
            startDate = endDate.addingTimeInterval(-24 * 60 * 60)
        }

        return DiskTemperatureChartContent(
            series: series,
            legend: series.map { DiskTemperatureLegendItem(id: $0.id, title: $0.title, color: $0.color) },
            minValue: minValue,
            maxValue: maxValue,
            startDate: startDate,
            endDate: endDate,
            yAxisLabels: yAxisLabels.isEmpty ? ["50", "40", "30"] : yAxisLabels,
            xAxisLabels: timeAxisLabels(from: startDate, to: endDate)
        )
    }

    var selectedTemperatureSummary: DiskTemperatureSelectedSummary? {
        let chart = temperatureChart
        guard !chart.series.isEmpty else { return nil }
        let selectedTime = selectedTemperatureTime ?? latestTemperatureSampleTime(in: chart.series) ?? chart.endDate
        let items = chart.series.map { series -> DiskTemperatureSelectedItem in
            let nearest = nearestPoint(in: series.points, to: selectedTime)
            let availablePoint: DiskTemperaturePointValue?
            if let nearest, abs(nearest.sampledAt.timeIntervalSince(selectedTime)) <= 45 * 60 {
                availablePoint = nearest
            } else {
                availablePoint = nil
            }
            return DiskTemperatureSelectedItem(
                id: series.id,
                title: series.title,
                color: series.color,
                valueText: availablePoint.map { "\(Int($0.temperature.rounded())) C" } ?? "Unavailable",
                sampleTimeText: availablePoint.map { Self.selectedTimeFormatter.string(from: $0.sampledAt) } ?? "--",
                isAvailable: availablePoint != nil
            )
        }
        return DiskTemperatureSelectedSummary(
            timeText: Self.selectedDateFormatter.string(from: selectedTime),
            items: items
        )
    }

    func selectTemperatureTime(_ date: Date) {
        selectedTemperatureTime = date
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce, !isRefreshing else { return }
        await refresh()
    }

    func resetForEndpointChange() {
        disks = nil
        partitions = nil
        history = nil
        smartDetail = nil
        isRefreshing = false
        isLoadingSmart = false
        selectedTemperatureTime = nil
        hasLoadedOnce = false
        didShowRefreshError = false
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestBaseURL = settings.baseURL
        let from = Date().addingTimeInterval(-24 * 60 * 60)
        let historyURL = makeHistoryURL(baseURL: requestBaseURL, from: from, to: Date(), limit: 2000)
        var hadSuccess = false

        do {
            let response = try await fetch(PhysicalDisksResponse.self, from: settings.endpointURL(baseURL: requestBaseURL, path: "api/public/system/disks"))
            guard requestBaseURL == settings.baseURL else { return }
            disks = response
            hadSuccess = true
        } catch {
        }

        do {
            let response = try await fetch(PartitionsResponse.self, from: settings.endpointURL(baseURL: requestBaseURL, path: "api/public/system/partitions"))
            guard requestBaseURL == settings.baseURL else { return }
            partitions = response
            hadSuccess = true
        } catch {
        }

        do {
            let response = try await fetch(DiskTemperatureHistoryResponse.self, from: historyURL)
            guard requestBaseURL == settings.baseURL else { return }
            history = response
            normalizeSelectedTemperatureTime()
            hadSuccess = true
        } catch {
        }

        if hadSuccess {
            hasLoadedOnce = true
            didShowRefreshError = false
        } else if !hasLoadedOnce {
            toastMessage = "Disk status unavailable"
        } else if !didShowRefreshError {
            toastMessage = "Disk refresh failed"
            didShowRefreshError = true
        }
    }

    func loadSmart(serialNumber: String) async {
        guard !isLoadingSmart else { return }
        isLoadingSmart = true
        smartDetail = nil
        defer { isLoadingSmart = false }

        let requestBaseURL = settings.baseURL
        let encoded = serialNumber.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serialNumber
        let url = settings.endpointURL(baseURL: requestBaseURL, path: "api/public/system/disks/smart/\(encoded)")

        do {
            let response = try await fetch(DiskSmartResponse.self, from: url)
            guard requestBaseURL == settings.baseURL else { return }
            smartDetail = response
        } catch {
            smartDetail = nil
            toastMessage = "SMART data unavailable"
        }
    }

    private func makeHistoryURL(baseURL: String, from: Date, to: Date, limit: Int) -> URL {
        var components = URLComponents(url: settings.endpointURL(baseURL: baseURL, path: "api/public/system/disk-temperatures/history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: Self.historyDateFormatter.string(from: from)),
            URLQueryItem(name: "to", value: Self.historyDateFormatter.string(from: to)),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        return components.url!
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await LoggedHTTPClient.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func bytes(_ value: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: value)
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func normalizeSelectedTemperatureTime() {
        guard selectedTemperatureTime == nil,
              let latest = latestTemperatureSampleTime(in: temperatureChart.series) else { return }
        selectedTemperatureTime = latest
    }

    private func latestTemperatureSampleTime(in series: [DiskTemperatureSeriesContent]) -> Date? {
        series.flatMap { $0.points.map(\.sampledAt) }.max()
    }

    private func nearestPoint(in points: [DiskTemperaturePointValue], to date: Date) -> DiskTemperaturePointValue? {
        points.min { lhs, rhs in
            abs(lhs.sampledAt.timeIntervalSince(date)) < abs(rhs.sampledAt.timeIntervalSince(date))
        }
    }

    private func timeAxisLabels(from startDate: Date, to endDate: Date) -> [String] {
        let interval = endDate.timeIntervalSince(startDate)
        return (0 ... 4).map { index in
            let date = startDate.addingTimeInterval(interval * Double(index) / 4)
            return Self.axisTimeFormatter.string(from: date)
        }
    }

    private func parseTimestamp(_ value: String) -> Date? {
        Self.fractionalFormatter.date(from: value) ?? Self.basicFormatter.date(from: value)
    }

    private let diskPalette: [Color] = [
        Color(hex: 0xFE6F32),
        Color(hex: 0x3E7BFA),
        Color(hex: 0x14A46A),
        Color(hex: 0x8A4DFF),
        Color(hex: 0xF59E0B),
        Color(hex: 0xEC4899),
    ]

    private static let historyDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let axisTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let selectedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let selectedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

@MainActor
private final class HomeMetricsViewModel: ObservableObject {
    static var endpointHost: String {
        HostMonitorSettingsStore.shared.displayHost
    }

    private static let historyLimit = 20

    @Published private(set) var response: SystemMetricsResponse?
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var isRefreshing = false
    @Published var toastMessage: String?

    private let settings = HostMonitorSettingsStore.shared
    private var didShowRefreshError = false
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var networkRxHistory: [Double] = []
    private var networkTxHistory: [Double] = []
    private var latestNetworkRate: NetworkRateSample?
    private var previousNetworkCounter: NetworkCounterSample?

    var snapshotDateText: String {
        guard let response, let date = parseTimestamp(response.timestamp) else {
            return Self.dateFormatter.string(from: Date())
        }
        return Self.dateFormatter.string(from: date)
    }

    var snapshotTitleText: String {
        hasLoadedOnce ? "System Metrics Overview" : "Connecting to host"
    }

    var statusText: String {
        if isInitialLoading {
            return "Loading metrics from \(settings.displayHost)"
        }
        if isRefreshing, let response, let date = parseTimestamp(response.timestamp) {
            return "Refreshing | last update \(Self.timeFormatter.string(from: date))"
        }
        if let response, let date = parseTimestamp(response.timestamp) {
            return "Updated \(Self.timeFormatter.string(from: date))"
        }
        return "Waiting for reachable host"
    }

    var hostCard: HostCardContent {
        guard let host = response?.host else {
            return HostCardContent(
                title: "",
                primaryText: isInitialLoading ? "Connecting..." : "Host unavailable",
                secondaryText: isInitialLoading ? "Reading public system metrics" : "Check the DownGo host and local network",
                tertiaryText: isInitialLoading ? "IP \(settings.endpointIPAddress)" : "IP unavailable",
                trailingLabel: "Endpoint",
                trailingValue: "HTTP",
                icon: "desktopcomputer"
            )
        }

        return HostCardContent(
            title: "",
            primaryText: host.hostname,
            secondaryText: "\(host.platform) | \(host.os)",
            tertiaryText: "IP \(settings.endpointIPAddress)",
            trailingLabel: "Uptime",
            trailingValue: formatDuration(host.uptimeSeconds),
            icon: "desktopcomputer"
        )
    }

    var cpuCard: MetricCardContent {
        guard let cpu = response?.cpu else {
            return placeholderCard(
                title: "CPU",
                icon: "cpu",
                iconBackground: Color(hex: 0xFFF0E9),
                iconForeground: Color(hex: 0xFE6F32),
                fallbackStyle: .bars
            )
        }
        return MetricCardContent(
            title: "CPU",
            value: percent(cpu.usagePercent),
            subtitle: "\(cpu.logicalCores)L / \(cpu.physicalCores)P cores",
            icon: "cpu",
            iconBackground: Color(hex: 0xFFF0E9),
            iconForeground: Color(hex: 0xFE6F32),
            chart: MetricChartContent(
                primary: cpuHistory,
                secondary: nil,
                primaryColor: Color(hex: 0xFE6F32),
                secondaryColor: nil,
                showsArea: true
            ),
            progress: nil,
            fallbackStyle: .bars
        )
    }

    var memoryCard: MetricCardContent {
        guard let memory = response?.memory else {
            return placeholderCard(
                title: "Memory",
                icon: "memorychip",
                iconBackground: Color(hex: 0xEAF2FF),
                iconForeground: Color(hex: 0x3E7BFA),
                fallbackStyle: .line
            )
        }
        return MetricCardContent(
            title: "Memory",
            value: "\(bytes(memory.usedBytes)) / \(bytes(memory.totalBytes))",
            subtitle: "\(percent(memory.usedPercent)) used",
            icon: "memorychip",
            iconBackground: Color(hex: 0xEAF2FF),
            iconForeground: Color(hex: 0x3E7BFA),
            chart: MetricChartContent(
                primary: memoryHistory,
                secondary: nil,
                primaryColor: Color(hex: 0x3E7BFA),
                secondaryColor: nil,
                showsArea: true
            ),
            progress: nil,
            fallbackStyle: .line
        )
    }

    var uploadCard: MetricCardContent {
        guard selectedNetworkInterface != nil else {
            return placeholderCard(
                title: "Upload",
                icon: "arrow.up",
                iconBackground: Color(hex: 0xE8FFF5),
                iconForeground: Color(hex: 0x14A46A),
                fallbackStyle: .capsules
            )
        }

        let latestTx = latestNetworkRate?.txBytesPerSecond ?? 0

        return MetricCardContent(
            title: "Upload",
            value: rate(latestTx),
            subtitle: "Live upload",
            icon: "arrow.up",
            iconBackground: Color(hex: 0xE8FFF5),
            iconForeground: Color(hex: 0x14A46A),
            chart: MetricChartContent(
                primary: networkTxHistory,
                secondary: nil,
                primaryColor: Color(hex: 0x14A46A),
                secondaryColor: nil,
                showsArea: false
            ),
            progress: nil,
            fallbackStyle: .capsules
        )
    }

    var downloadCard: MetricCardContent {
        guard selectedNetworkInterface != nil else {
            return placeholderCard(
                title: "Download",
                icon: "arrow.down",
                iconBackground: Color(hex: 0xEAF2FF),
                iconForeground: Color(hex: 0x3E7BFA),
                fallbackStyle: .line
            )
        }

        let latestRx = latestNetworkRate?.rxBytesPerSecond ?? 0

        return MetricCardContent(
            title: "Download",
            value: rate(latestRx),
            subtitle: "Live download",
            icon: "arrow.down",
            iconBackground: Color(hex: 0xEAF2FF),
            iconForeground: Color(hex: 0x3E7BFA),
            chart: MetricChartContent(
                primary: networkRxHistory,
                secondary: nil,
                primaryColor: Color(hex: 0x3E7BFA),
                secondaryColor: nil,
                showsArea: false
            ),
            progress: nil,
            fallbackStyle: .line
        )
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce, !isRefreshing else { return }
        await refresh()
    }

    func resetForEndpointChange() {
        response = nil
        isRefreshing = false
        hasLoadedOnce = false
        didShowRefreshError = false
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        networkRxHistory.removeAll()
        networkTxHistory.removeAll()
        latestNetworkRate = nil
        previousNetworkCounter = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestBaseURL = settings.baseURL
        do {
            let decoded = try await fetch(SystemMetricsResponse.self, from: settings.endpointURL(baseURL: requestBaseURL, path: "api/public/system/metrics"))
            guard requestBaseURL == settings.baseURL else { return }
            response = decoded
            hasLoadedOnce = true
            recordSample(decoded)

            didShowRefreshError = false
        } catch {
            if !hasLoadedOnce {
                toastMessage = "Metrics host unavailable"
            } else if !didShowRefreshError {
                toastMessage = "Metrics refresh failed"
            }
            didShowRefreshError = true
        }
    }

    private var selectedNetworkInterface: SystemMetricsResponse.NetworkInterface? {
        guard let interfaces = response?.network.interfaces else { return nil }

        if let matched = interfaces.first(where: { interface in
            interface.ipAddresses.contains(where: { $0.address == settings.endpointIPAddress })
        }) {
            return matched
        }

        return interfaces.first(where: { interface in
            interface.isUp && !(interface.flags.contains("loopback"))
        })
    }

    private func recordSample(_ metrics: SystemMetricsResponse) {
        append(&cpuHistory, value: metrics.cpu.usagePercent)
        append(&memoryHistory, value: Double(metrics.memory.usedPercent))

        guard let interface = matchingInterface(in: metrics.network.interfaces) else {
            latestNetworkRate = nil
            previousNetworkCounter = nil
            return
        }

        let now = Date()
        let currentCounter = NetworkCounterSample(
            name: interface.name,
            rxBytes: interface.bytesRecv,
            txBytes: interface.bytesSent,
            timestamp: now
        )

        if let previous = previousNetworkCounter,
           previous.name != currentCounter.name {
            networkRxHistory.removeAll()
            networkTxHistory.removeAll()
            latestNetworkRate = nil
        }

        if let previous = previousNetworkCounter,
           previous.name == currentCounter.name {
            let interval = max(now.timeIntervalSince(previous.timestamp), 1)
            let rxDelta = max(Double(currentCounter.rxBytes - previous.rxBytes), 0)
            let txDelta = max(Double(currentCounter.txBytes - previous.txBytes), 0)
            let rate = NetworkRateSample(
                rxBytesPerSecond: Int64(rxDelta / interval),
                txBytesPerSecond: Int64(txDelta / interval)
            )
            latestNetworkRate = rate
            append(&networkRxHistory, value: Double(rate.rxBytesPerSecond))
            append(&networkTxHistory, value: Double(rate.txBytesPerSecond))
        }

        previousNetworkCounter = currentCounter
    }

    private func matchingInterface(in interfaces: [SystemMetricsResponse.NetworkInterface]) -> SystemMetricsResponse.NetworkInterface? {
        if let matched = interfaces.first(where: { interface in
            interface.ipAddresses.contains(where: { $0.address == settings.endpointIPAddress })
        }) {
            return matched
        }

        return interfaces.first(where: { interface in
            interface.isUp && !(interface.flags.contains("loopback"))
        })
    }

    private func append(_ series: inout [Double], value: Double) {
        series.append(value)
        if series.count > Self.historyLimit {
            series.removeFirst(series.count - Self.historyLimit)
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, urlResponse) = try await LoggedHTTPClient.data(for: request)
        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func placeholderCard(
        title: String,
        icon: String,
        iconBackground: Color,
        iconForeground: Color,
        fallbackStyle: MetricFallbackStyle,
        progress: CapacityProgressContent? = nil
    ) -> MetricCardContent {
        MetricCardContent(
            title: title,
            value: isInitialLoading ? "Loading..." : "Unavailable",
            subtitle: isInitialLoading ? "Waiting for host" : "No fresh metrics",
            icon: icon,
            iconBackground: iconBackground,
            iconForeground: iconForeground,
            chart: nil,
            progress: progress,
            fallbackStyle: fallbackStyle
        )
    }

    private var isInitialLoading: Bool {
        !hasLoadedOnce && isRefreshing
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func percent(_ value: Int) -> String {
        "\(value)%"
    }

    private func bytes(_ value: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: value)
    }

    private func rate(_ value: Int64) -> String {
        let bytes = Double(max(value, 0))
        if bytes == 0 {
            return "0B/s"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.2fK/s", bytes / 1024)
        }
        let units = ["M/s", "G/s", "T/s"]
        var scaled = bytes / 1024 / 1024
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return String(format: "%.2f%@", scaled, units[index])
    }

    private func formatDuration(_ seconds: Int) -> String {
        guard let formatted = Self.durationFormatter.string(from: TimeInterval(seconds)) else {
            return "\(seconds)s"
        }
        return formatted
    }

    private func parseTimestamp(_ value: String) -> Date? {
        Self.fractionalFormatter.date(from: value) ?? Self.basicFormatter.date(from: value)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

private struct SystemMetricsResponse: Decodable {
    let timestamp: String
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let network: NetworkMetrics
    let host: HostMetrics
    let process: ProcessMetrics

    struct CPUMetrics: Decodable {
        let usagePercent: Double
        let logicalCores: Int
        let physicalCores: Int
        let modelName: String
    }

    struct MemoryMetrics: Decodable {
        let totalBytes: Int64
        let usedBytes: Int64
        let availableBytes: Int64
        let usedPercent: Int
    }

    struct NetworkMetrics: Decodable {
        let interfaces: [NetworkInterface]
    }

    struct NetworkInterface: Decodable {
        let name: String
        let hardwareAddr: String
        let mtu: Int
        let flags: [String]
        let isUp: Bool
        let ipAddresses: [IPAddress]
        let bytesSent: Int64
        let bytesRecv: Int64
        let packetsSent: Int64
        let packetsRecv: Int64
    }

    struct IPAddress: Decodable {
        let address: String
        let family: String
        let cidr: String
    }

    struct HostMetrics: Decodable {
        let hostname: String
        let os: String
        let platform: String
        let uptimeSeconds: Int
    }

    struct ProcessMetrics: Decodable {
        let pid: Int
        let uptimeSeconds: Int
        let goroutines: Int
        let allocBytes: Int64
        let sysBytes: Int64
    }
}

private struct NezhaCommonResponse<T: Decodable>: Decodable {
    let success: Bool?
    let error: String?
    let data: T?
}

private struct NezhaStreamServerData: Decodable {
    let servers: [NezhaStreamServer]
}

private struct NezhaStreamServer: Decodable, Identifiable {
    let id: Int
    let name: String
    let countryCode: String?
    let displayIndex: Int
    let host: NezhaHost?
    let state: NezhaHostState?
    let lastActive: String?
    let publicNote: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, state
        case countryCode = "country_code"
        case displayIndex = "display_index"
        case lastActive = "last_active"
        case publicNote = "public_note"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        displayIndex = try c.decodeIfPresent(Int.self, forKey: .displayIndex) ?? 0
        host = try c.decodeIfPresent(NezhaHost.self, forKey: .host)
        state = try c.decodeIfPresent(NezhaHostState.self, forKey: .state)
        lastActive = try c.decodeIfPresent(String.self, forKey: .lastActive)
        publicNote = try c.decodeIfPresent(String.self, forKey: .publicNote)
    }
}

private struct NezhaHost: Decodable {
    let arch: String?
    let bootTime: Int64?
    let cpu: [String]
    let diskTotal: Int64?
    let gpu: [String]
    let memTotal: Int64?
    let platform: String?
    let platformVersion: String?
    let swapTotal: Int64?
    let version: String?
    let virtualization: String?

    private enum CodingKeys: String, CodingKey {
        case arch, cpu, gpu, platform, version, virtualization
        case bootTime = "boot_time"
        case diskTotal = "disk_total"
        case memTotal = "mem_total"
        case platformVersion = "platform_version"
        case swapTotal = "swap_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arch = try c.decodeIfPresent(String.self, forKey: .arch)
        bootTime = try c.decodeIfPresent(Int64.self, forKey: .bootTime)
        cpu = try c.decodeIfPresent([String].self, forKey: .cpu) ?? []
        diskTotal = try c.decodeIfPresent(Int64.self, forKey: .diskTotal)
        gpu = try c.decodeIfPresent([String].self, forKey: .gpu) ?? []
        memTotal = try c.decodeIfPresent(Int64.self, forKey: .memTotal)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try c.decodeIfPresent(String.self, forKey: .platformVersion)
        swapTotal = try c.decodeIfPresent(Int64.self, forKey: .swapTotal)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        virtualization = try c.decodeIfPresent(String.self, forKey: .virtualization)
    }
}

private struct NezhaHostState: Decodable {
    let cpu: Double?
    let diskUsed: Int64?
    let gpu: [Double]
    let load1: Double?
    let load5: Double?
    let load15: Double?
    let memUsed: Int64?
    let netInSpeed: Int64?
    let netInTransfer: Int64?
    let netOutSpeed: Int64?
    let netOutTransfer: Int64?
    let processCount: Int?
    let swapUsed: Int64?
    let tcpConnCount: Int?

    private enum CodingKeys: String, CodingKey {
        case cpu, gpu
        case diskUsed = "disk_used"
        case load1 = "load_1"
        case load5 = "load_5"
        case load15 = "load_15"
        case memUsed = "mem_used"
        case netInSpeed = "net_in_speed"
        case netInTransfer = "net_in_transfer"
        case netOutSpeed = "net_out_speed"
        case netOutTransfer = "net_out_transfer"
        case processCount = "process_count"
        case swapUsed = "swap_used"
        case tcpConnCount = "tcp_conn_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try c.decodeIfPresent(Double.self, forKey: .cpu)
        diskUsed = try c.decodeIfPresent(Int64.self, forKey: .diskUsed)
        gpu = try c.decodeIfPresent([Double].self, forKey: .gpu) ?? []
        load1 = try c.decodeIfPresent(Double.self, forKey: .load1)
        load5 = try c.decodeIfPresent(Double.self, forKey: .load5)
        load15 = try c.decodeIfPresent(Double.self, forKey: .load15)
        memUsed = try c.decodeIfPresent(Int64.self, forKey: .memUsed)
        netInSpeed = try c.decodeIfPresent(Int64.self, forKey: .netInSpeed)
        netInTransfer = try c.decodeIfPresent(Int64.self, forKey: .netInTransfer)
        netOutSpeed = try c.decodeIfPresent(Int64.self, forKey: .netOutSpeed)
        netOutTransfer = try c.decodeIfPresent(Int64.self, forKey: .netOutTransfer)
        processCount = try c.decodeIfPresent(Int.self, forKey: .processCount)
        swapUsed = try c.decodeIfPresent(Int64.self, forKey: .swapUsed)
        tcpConnCount = try c.decodeIfPresent(Int.self, forKey: .tcpConnCount)
    }
}

private struct PhysicalDisksResponse: Decodable {
    let timestamp: String
    let physicalDisks: [PhysicalDisk]

    struct PhysicalDisk: Decodable {
        let deviceId: String
        let friendlyName: String
        let serialNumber: String
        let mediaType: String
        let busType: String
        let healthStatus: String
        let operationalStatus: String
        let sizeBytes: Int64
        let temperatureCelsius: Int?
        let temperatureUpdatedAt: String?
        let temperatureError: String?
    }
}

private struct DiskTemperatureHistoryResponse: Decodable {
    let from: String
    let to: String
    let items: [DiskTemperatureHistoryItem]

    struct DiskTemperatureHistoryItem: Decodable {
        let deviceId: String
        let friendlyName: String
        let serialNumber: String
        let mediaType: String
        let points: [Point]
    }

    struct Point: Decodable {
        let sampledAt: String
        let temperatureCelsius: Int?
        let temperatureError: String?
    }
}

private struct DiskSmartResponse: Decodable {
    let deviceId: String
    let friendlyName: String
    let serialNumber: String
    let firmwareVersion: String?
    let mediaType: String
    let busType: String?
    let healthStatus: String
    let sizeBytes: Int64?
    let temperatureCelsius: Int?
    let powerOnHours: Int?
    let powerCycleCount: Int?
    let attributes: [DiskSmartAttribute]

    var isHealthy: Bool {
        ["AVAILABLE", "PASSED", "HEALTHY", "OK"].contains(healthStatus.uppercased())
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        friendlyName = try c.decode(String.self, forKey: .friendlyName)
        serialNumber = try c.decode(String.self, forKey: .serialNumber)
        firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        busType = try c.decodeIfPresent(String.self, forKey: .busType)
        healthStatus = try c.decodeIfPresent(String.self, forKey: .healthStatus) ?? "Available"
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        temperatureCelsius = try c.decodeIfPresent(Int.self, forKey: .temperatureCelsius)
        powerOnHours = try c.decodeIfPresent(Int.self, forKey: .powerOnHours)
        powerCycleCount = try c.decodeIfPresent(Int.self, forKey: .powerCycleCount)
        attributes = try c.decodeIfPresent([DiskSmartAttribute].self, forKey: .attributes) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, friendlyName, serialNumber, firmwareVersion, mediaType, busType
        case healthStatus, sizeBytes, temperatureCelsius, powerOnHours, powerCycleCount, attributes
    }
}

private struct DiskSmartAttribute: Decodable, Identifiable {
    let id: Int
    let name: String
    let value: Int
    let worst: Int
    let threshold: Int
    let rawValue: String
    let rawString: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(Int.self, forKey: .value)
        worst = try c.decodeIfPresent(Int.self, forKey: .worst) ?? 0
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? 0
        rawValue = try c.decodeIfPresent(String.self, forKey: .rawValue) ?? ""
        rawString = try c.decodeIfPresent(String.self, forKey: .rawString) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, worst, threshold, rawValue, rawString
    }
}

private struct PartitionsResponse: Decodable {
    let timestamp: String
    let items: [PartitionItem]

    struct PartitionItem: Decodable {
        let path: String
        let fstype: String
        let totalBytes: Int64
        let usedBytes: Int64
        let freeBytes: Int64
        let usedPercent: Double
    }
}

private extension Font {
    static func fitnexTitle(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func fitnexBody(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }

    var ipaAsset: GitHubReleaseAsset? {
        assets.first { $0.name.hasSuffix(".ipa") }
    }

}

private struct GitHubReleaseAsset: Decodable {
    let id: Int
    let name: String
    let size: Int
    let url: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case id, name, size, url
        case browserDownloadURL = "browser_download_url"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

@MainActor
private final class UpdateViewModel: ObservableObject {
    @Published var latestRelease: GitHubRelease?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var localIPAURL: URL?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    var documentController: UIDocumentInteractionController?

    private var downloadDelegateRef: DownloadProgressDelegate?

    private static let repoAPI = "https://api.github.com/repos/ge-fei-fan/I-aTool-ios/releases/latest"

    func checkForUpdate() async {
        isChecking = true
        errorMessage = nil
        latestRelease = nil
        statusMessage = nil

        do {
            let url = URL(string: Self.repoAPI)!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await LoggedHTTPClient.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "UpdateError", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "GitHub API error"
                ])
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if release.ipaAsset != nil {
                latestRelease = release
                statusMessage = "\u{6700}\u{65B0} \(release.tagName)"
            } else {
                errorMessage = "No IPA in latest release"
            }
        } catch {
            errorMessage = "Check failed: \(error.localizedDescription)"
        }

        isChecking = false
    }

    func downloadIPA() {
        guard let asset = latestRelease?.ipaAsset else { return }
        isDownloading = true
        downloadProgress = 0
        localIPAURL = nil
        errorMessage = nil

        guard let url = URL(string: asset.url) else {
            isDownloading = false
            errorMessage = "Invalid download URL"
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let delegate = DownloadProgressDelegate()
        delegate.viewModel = self
        delegate.request = request
        delegate.startedAt = Date()
        downloadDelegateRef = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: request).resume()
    }

    func installViaTrollStore() {
        guard let url = localIPAURL else { return }
        let docController = UIDocumentInteractionController(url: url)
        docController.uti = "com.apple.itunes.ipa"
        docController.name = url.lastPathComponent
        documentController = docController
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        docController.presentOpenInMenu(from: sourceRect, in: top.view, animated: true)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    @MainActor weak var viewModel: UpdateViewModel?
    var request: URLRequest?
    var startedAt = Date()
    private var didRecordCompletion = false

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let dest = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aTool_update.ipa")

        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "UpdateError", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Download failed: HTTP \(http.statusCode)"
                ])
            }
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: location, to: dest)
            guard let handle = try? FileHandle(forReadingFrom: dest),
                  let data = try? handle.read(upToCount: 2),
                  data.count >= 2 && data[0] == 0x50 && data[1] == 0x4B else {
                try? fm.removeItem(at: dest)
                throw NSError(domain: "UpdateError", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Not a valid IPA file"
                ])
            }
            try? handle.close()
            let attributes = try? fm.attributesOfItem(atPath: dest.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            recordDownload(
                response: downloadTask.response,
                error: nil,
                summary: "Downloaded \(size) bytes to \(dest.lastPathComponent)"
            )
            Task { @MainActor [weak self] in
                self?.viewModel?.isDownloading = false
                self?.viewModel?.localIPAURL = dest
            }
        } catch {
            recordDownload(
                response: downloadTask.response,
                error: error,
                summary: "Download failed before a valid IPA was saved"
            )
            Task { @MainActor [weak self] in
                self?.viewModel?.isDownloading = false
                self?.viewModel?.errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        recordDownload(
            response: task.response,
            error: error,
            summary: "Download task failed"
        )
        Task { @MainActor [weak self] in
            self?.viewModel?.isDownloading = false
            self?.viewModel?.errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor [weak self] in
            self?.viewModel?.downloadProgress = progress
        }
    }

    private func recordDownload(response: URLResponse?, error: Error?, summary: String) {
        guard !didRecordCompletion, let request else { return }
        didRecordCompletion = true
        let data = Data(summary.utf8)
        Task { @MainActor in
            AppLogStore.shared.record(
                request: request,
                response: response,
                responseData: data,
                error: error,
                startedAt: startedAt,
                responseBodyLimit: 2 * 1024
            )
        }
    }
}

private extension Path {
    static func smoothCurve(through points: [CGPoint]) -> Path {
        guard points.count > 1 else {
            if let p = points.first { return Path(ellipseIn: CGRect(x: p.x - 0.5, y: p.y - 0.5, width: 1, height: 1)) }
            return Path()
        }
        var path = Path()
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 0 ..< points.count - 1 {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : p2
            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }
}
