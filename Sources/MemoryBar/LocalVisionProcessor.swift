import CoreGraphics
import Foundation
import Vision

enum LocalVisionProcessor {
    static func process(_ image: CGImage) throws -> VisionResult {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        textRequest.minimumTextHeight = 0.008

        let classificationRequest = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([textRequest, classificationRequest])

        let recognized = textRequest.results ?? []
        var lines: [String] = []
        var confidences: [Double] = []
        for observation in recognized {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(text)
            confidences.append(Double(candidate.confidence))
        }

        let labels = (classificationRequest.results ?? [])
            .filter { $0.confidence >= 0.12 }
            .prefix(5)
            .map { VisionLabel(name: $0.identifier, confidence: Double($0.confidence)) }
        let averageConfidence = confidences.isEmpty
            ? 0
            : confidences.reduce(0, +) / Double(confidences.count)

        return VisionResult(
            text: lines.joined(separator: "\n"),
            textConfidence: averageConfidence,
            labels: Array(labels)
        )
    }
}
