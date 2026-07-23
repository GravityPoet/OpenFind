import Foundation
import Vision

protocol ClipboardImageTextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async -> String?
}

struct VisionClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    func recognizeText(in imageData: Data) async -> String? {
        await Task.detached(priority: .background) {
            autoreleasepool {
                guard !Task.isCancelled else { return nil }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
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
        }.value
    }
}
