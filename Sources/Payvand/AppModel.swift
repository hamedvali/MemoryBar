import AppKit
import CoreGraphics
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var isPaused: Bool
    @Published var retainThumbnails: Bool
    @Published var excludedAppsText: String
    @Published private(set) var observationCount = 0
    @Published private(set) var episodeCount = 0
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var mcpError: String?
    @Published private(set) var authorizedClients: [AuthorizedMCPClient] = []
    @Published private(set) var captureFlash = false
    @Published private(set) var showsDockIcon: Bool
    @Published private(set) var pauseShortcutEnabled: Bool
    @Published private(set) var pauseShortcut: HotKeyCombination
    /// Set when the system refuses the combination, usually because another app
    /// already owns it. Surfaced in Settings so a dead shortcut is never silent.
    @Published private(set) var pauseShortcutUnavailable = false

    let startedAt = Date()
    let port: UInt16 = 7_331
    let databaseURL: URL

    private let defaults = UserDefaults.standard
    private var database: MemoryDatabase?
    private var captureService: CaptureService?
    private var httpServer: LocalHTTPServer?
    private var authorization: MCPAuthorizationService?
    private var refreshTimer: Timer?
    private let pauseHotKey = GlobalHotKey()

    var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }
    var screenPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityPermissionGranted: Bool { AccessibilityReader.isTrusted }

    init() {
        let captureDisabledForSmokeTest = ProcessInfo.processInfo.environment["PAYVAND_DISABLE_CAPTURE"] == "1"
        isPaused = captureDisabledForSmokeTest || defaults.bool(forKey: "capture.paused")
        retainThumbnails = defaults.object(forKey: "capture.retainThumbnails") as? Bool ?? true
        excludedAppsText = defaults.string(forKey: "capture.excludedApps") ?? "1Password, Keychain Access"
        showsDockIcon = defaults.bool(forKey: "ui.showDockIcon")
        pauseShortcutEnabled = defaults.object(forKey: "shortcut.enabled") as? Bool ?? true
        pauseShortcut = HotKeyCombination.load(from: defaults)

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        databaseURL = applicationSupport
            .appendingPathComponent("Payvand", isDirectory: true)
            .appendingPathComponent("memory.sqlite3")

        do {
            let database = try MemoryDatabase(url: databaseURL)
            self.database = database
            let capture = CaptureService(database: database) { [weak self] status in
                Task { @MainActor in self?.receive(status) }
            }
            captureService = capture
            do {
                let authorization = try MCPAuthorizationService(
                    storageURL: databaseURL.deletingLastPathComponent().appendingPathComponent("authorization.sqlite3"),
                    port: port
                )
                self.authorization = authorization
                let server = LocalHTTPServer(
                    port: port,
                    handler: MCPProtocolHandler(database: database),
                    authorization: authorization
                )
                try server.start()
                httpServer = server
                refreshAuthorizedClients()
            } catch {
                mcpError = error.localizedDescription
            }
            applyCaptureSettings()
            Task { await capture.start() }
            refreshCounts()
        } catch {
            lastError = error.localizedDescription
        }

        applyPauseShortcut()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCounts()
                self?.refreshAuthorizedClients()
                self?.objectWillChange.send()
            }
        }
    }

    func togglePaused() {
        isPaused.toggle()
        defaults.set(isPaused, forKey: "capture.paused")
        applyCaptureSettings()
    }

    func updatePauseShortcutEnabled(_ value: Bool) {
        pauseShortcutEnabled = value
        defaults.set(value, forKey: "shortcut.enabled")
        applyPauseShortcut()
    }

    func updatePauseShortcut(_ combination: HotKeyCombination) {
        pauseShortcut = combination
        combination.save(to: defaults)
        applyPauseShortcut()
    }

    /// Frees the shortcut while the user records a new one, so the old binding
    /// cannot fire mid-recording. Paired with `resumePauseShortcut()`.
    func suspendPauseShortcut() {
        pauseHotKey.unregister()
    }

    func resumePauseShortcut() {
        applyPauseShortcut()
    }

    func updateShowsDockIcon(_ value: Bool) {
        showsDockIcon = value
        defaults.set(value, forKey: "ui.showDockIcon")
        NSApplication.shared.setActivationPolicy(value ? .regular : .accessory)
    }

    func updateExcludedApps(_ value: String) {
        excludedAppsText = value
        defaults.set(value, forKey: "capture.excludedApps")
        applyCaptureSettings()
    }

    func updateRetainThumbnails(_ value: Bool) {
        retainThumbnails = value
        defaults.set(value, forKey: "capture.retainThumbnails")
        applyCaptureSettings()
    }

    func captureNow() {
        guard let captureService else { return }
        Task { await captureService.captureNow() }
    }

    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        objectWillChange.send()
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityReader.requestPermission()
        objectWillChange.send()
    }

    func copyMCPURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpURL, forType: .string)
    }

    func revokeMCPClient(id: String) {
        do {
            try authorization?.revoke(clientID: id)
            refreshAuthorizedClients()
            mcpError = nil
        } catch {
            mcpError = error.localizedDescription
        }
    }

    func revealMemoryFile() {
        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }

    func deleteAllMemory() {
        do {
            try database?.deleteAllMemory()
            refreshCounts()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func applyPauseShortcut() {
        guard pauseShortcutEnabled else {
            pauseHotKey.unregister()
            pauseShortcutUnavailable = false
            return
        }
        let registered = pauseHotKey.register(pauseShortcut) { [weak self] in
            Task { @MainActor in self?.togglePaused() }
        }
        pauseShortcutUnavailable = !registered
    }

    private func applyCaptureSettings() {
        let exclusions = Set(
            excludedAppsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let settings = CaptureService.Settings(
            isPaused: isPaused,
            excludedApps: exclusions,
            retainThumbnails: retainThumbnails
        )
        if let captureService {
            Task { await captureService.update(settings) }
        }
    }

    private func receive(_ status: CaptureStatus) {
        if let date = status.lastCaptureAt { lastCaptureAt = date }
        lastError = status.lastError
        if status.didStore {
            captureFlash = true
            refreshCounts()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.captureFlash = false
            }
        }
    }

    private func refreshCounts() {
        guard let database else { return }
        let counts = database.counts()
        observationCount = counts.observations
        episodeCount = counts.episodes
    }

    private func refreshAuthorizedClients() {
        authorizedClients = authorization?.authorizedClients() ?? []
    }
}
