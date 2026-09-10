import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

actor CaptureService {
    struct Settings: Sendable {
        var isPaused = false
        var excludedApps: Set<String> = []
        var retainThumbnails = true
        var pollInterval: TimeInterval = 2
        var fallbackInterval: TimeInterval = 10
        var changeThreshold = 0.07
    }

    private let database: MemoryDatabase
    private let onStatus: @Sendable (CaptureStatus) -> Void
    private var settings = Settings()
    private var loopTask: Task<Void, Never>?
    private var previousFingerprint: [UInt8]?
    private var lastStoredAt = Date.distantPast

    init(database: MemoryDatabase, onStatus: @escaping @Sendable (CaptureStatus) -> Void) {
        self.database = database
        self.onStatus = onStatus
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureTick()
                let interval = await self?.settings.pollInterval ?? 2
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func update(_ newSettings: Settings) {
        settings = newSettings
    }

    func captureNow() {
        Task { await captureTick(force: true) }
    }

    private func captureTick(force: Bool = false) async {
        guard !settings.isPaused else { return }
        guard CGPreflightScreenCaptureAccess() else {
            onStatus(CaptureStatus(
                lastCaptureAt: nil,
                lastError: "Screen Recording is not active for this build. Enable Payvand in System Settings, then quit and reopen Payvand.",
                didStore: false
            ))
            return
        }
        let context = AccessibilityReader.focusedWindow()
        guard !isExcluded(context) else { return }

        do {
            let image = try await captureDisplay()
            let fingerprint = makeFingerprint(image)
            let changeScore = difference(previousFingerprint, fingerprint)
            let fallbackDue = Date().timeIntervalSince(lastStoredAt) >= settings.fallbackInterval
            previousFingerprint = fingerprint
            guard force || fallbackDue || changeScore >= settings.changeThreshold else {
                onStatus(CaptureStatus(lastCaptureAt: Date(), lastError: nil, didStore: false))
                return
            }

            let vision = try LocalVisionProcessor.process(image)
            let exactText = TextIntelligence.normalizedText(parts: [
                context.windowTitle,
                context.documentURL,
                context.focusedRole,
                context.focusedValue,
                context.selectedText,
                vision.text
            ])
            let metadataConfidence = context.windowTitle == "Untitled" ? 0.35 : 0.9
            let confidence = min(1, vision.textConfidence * 0.75 + metadataConfidence * 0.25)
            let evidence = Evidence(
                source: "screen-capture",
                accessibilityTrusted: AccessibilityReader.isTrusted,
                fallbackCapture: fallbackDue && changeScore < settings.changeThreshold,
                app: context.appName,
                bundleIdentifier: context.bundleIdentifier,
                windowTitle: context.windowTitle,
                documentURL: context.documentURL,
                focusedRole: context.focusedRole,
                visionLabels: vision.labels,
                ocrConfidence: vision.textConfidence,
                changeScore: changeScore
            )
            let draft = ObservationDraft(
                context: context,
                exactText: exactText,
                visionLabels: vision.labels,
                confidence: confidence,
                changeScore: changeScore,
                thumbnailJPEG: settings.retainThumbnails ? thumbnailJPEG(image) : nil,
                evidenceJSON: JSONCoding.string(evidence)
            )
            _ = try database.ingest(draft)
            lastStoredAt = draft.capturedAt
            onStatus(CaptureStatus(lastCaptureAt: draft.capturedAt, lastError: nil, didStore: true))
        } catch {
            onStatus(CaptureStatus(lastCaptureAt: nil, lastError: error.localizedDescription, didStore: false))
        }
    }

    private func isExcluded(_ context: WindowContext) -> Bool {
        let app = context.appName.lowercased()
        let bundle = context.bundleIdentifier.lowercased()
        if bundle == "com.localfirst.payvand" || app == "payvand" { return true }
        return settings.excludedApps.contains { value in
            let needle = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !needle.isEmpty && (app == needle || bundle == needle || app.contains(needle))
        }
    }

    private func captureDisplay() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1_600.0 / Double(max(display.width, 1)))
        configuration.width = max(640, Int(Double(display.width) * scale))
        configuration.height = max(360, Int(Double(display.height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func makeFingerprint(_ image: CGImage) -> [UInt8] {
        let width = 32
        let height = 18
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        bytes.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func difference(_ previous: [UInt8]?, _ current: [UInt8]) -> Double {
        guard let previous, previous.count == current.count else { return 1 }
        let total = zip(previous, current).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(total) / Double(current.count * 255)
    }

    private func thumbnailJPEG(_ image: CGImage) -> Data? {
        let width = min(640, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(1, image.width))))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        let source = NSBitmapImageRep(cgImage: thumbnail)
        return source.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }
}

private struct Evidence: Codable {
    var source: String
    var accessibilityTrusted: Bool
    var fallbackCapture: Bool
    var app: String
    var bundleIdentifier: String
    var windowTitle: String
    var documentURL: String?
    var focusedRole: String?
    var visionLabels: [VisionLabel]
    var ocrConfidence: Double
    var changeScore: Double
}

private enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        "No display is available for capture."
    }
}
