import Foundation
import Vision

protocol ClipboardImageTextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async -> String?
}

struct VisionClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    func recognizeText(in imageData: Data) async -> String? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                guard !Task.isCancelled else { return nil }
                if let text = recognizedText(in: imageData, level: .fast) {
                    return text
                }
                guard !Task.isCancelled else { return nil }
                return recognizedText(in: imageData, level: .accurate)
            }
        }.value
    }

    private func recognizedText(
        in imageData: Data,
        level: VNRequestTextRecognitionLevel
    ) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        guard !Task.isCancelled else { return nil }
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: "\n").prefix(20_000))
    }
}
