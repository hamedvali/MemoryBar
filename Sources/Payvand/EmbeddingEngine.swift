import Foundation
import NaturalLanguage

final class EmbeddingEngine: @unchecked Sendable {
    static let shared = EmbeddingEngine()
    private let dimensions = 256

    func vector(for text: String) -> [Float] {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        if let model = NLEmbedding.sentenceEmbedding(for: language),
           let values = model.vector(for: String(text.prefix(8_000))) {
            return normalize(values.map(Float.init))
        }
        return hashedVector(for: text)
    }

    func data(for text: String) -> Data {
        vector(for: text).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func vector(from data: Data) -> [Float] {
        data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return 0 }
        return Double(dot / (sqrt(left) * sqrt(right)))
    }

    private func hashedVector(for text: String) -> [Float] {
        var result = Array(repeating: Float(0), count: dimensions)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in word.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            let index = Int(hash % UInt64(dimensions))
            result[index] += (hash & 1 == 0) ? 1 : -1
        }
        return normalize(result)
    }

    private func normalize(_ values: [Float]) -> [Float] {
        let magnitude = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return values }
        return values.map { $0 / magnitude }
    }
}
