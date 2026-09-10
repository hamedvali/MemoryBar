import Foundation

struct WindowContext: Sendable {
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var documentURL: String?
    var focusedRole: String?
    var focusedValue: String?
    var selectedText: String?

    static let unknown = WindowContext(
        appName: "Unknown",
        bundleIdentifier: "unknown",
        windowTitle: "Untitled"
    )
}

struct VisionLabel: Codable, Equatable, Sendable {
    var name: String
    var confidence: Double
}

struct VisionResult: Sendable {
    var text: String
    var textConfidence: Double
    var labels: [VisionLabel]
}

struct ObservationDraft: Sendable {
    var id = UUID().uuidString
    var capturedAt = Date()
    var context: WindowContext
    var exactText: String
    var visionLabels: [VisionLabel]
    var confidence: Double
    var changeScore: Double
    var thumbnailJPEG: Data?
    var evidenceJSON: String
}

struct EpisodeRecord: Codable, Equatable, Sendable {
    var id: String
    var startAt: Date
    var endAt: Date
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var project: String?
    var summary: String
    var exactText: String
    var confidence: Double
    var people: [String]
    var actions: [String]
    var observationCount: Int
}

struct MemorySearchResult: Codable, Equatable, Sendable {
    var episode: EpisodeRecord
    var score: Double
}

struct ObservationEvidence: Codable, Equatable, Sendable {
    var id: String
    var capturedAt: Date
    var appName: String
    var bundleIdentifier: String
    var windowTitle: String
    var documentURL: String?
    var exactText: String
    var confidence: Double
    var changeScore: Double
    var evidenceJSON: String
    var hasThumbnail: Bool
}

struct EpisodeDetail: Codable, Equatable, Sendable {
    var episode: EpisodeRecord
    var evidence: [ObservationEvidence]
}

struct ActionRecord: Codable, Equatable, Sendable {
    var id: String
    var episodeID: String
    var text: String
    var detectedAt: Date
    var status: String
}

struct DaySummary: Codable, Equatable, Sendable {
    var date: String
    var episodeCount: Int
    var activeMinutes: Int
    var topApplications: [String: Int]
    var highlights: [String]
    var openActions: [ActionRecord]
}

struct CaptureStatus: Sendable {
    var lastCaptureAt: Date?
    var lastError: String?
    var didStore: Bool
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func string<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
