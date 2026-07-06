import Foundation
@preconcurrency import Vision
import CoreGraphics

// MARK: - OCREngine
// Uses Apple Vision (VNRecognizeTextRequest) to extract text from a CGImage.
// Runs on a background thread, returns structured OCR result.

struct OCRResult {
    let fullText: String           // All recognized text joined
    let lines: [String]            // Individual text lines
    let confidence: Float          // Average confidence 0–1
}

final class OCREngine {
    static let shared = OCREngine()
    private init() {}

    func recognize(image: CGImage) async -> OCRResult {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: OCRResult(fullText: "", lines: [], confidence: 0))
                    return
                }

                var lines: [String] = []
                var totalConf: Float = 0

                for obs in observations {
                    if let top = obs.topCandidates(1).first {
                        lines.append(top.string)
                        totalConf += top.confidence
                    }
                }

                let avgConf = observations.isEmpty ? 0 : totalConf / Float(observations.count)
                let fullText = lines.joined(separator: "\n")

                continuation.resume(returning: OCRResult(
                    fullText: fullText,
                    lines: lines,
                    confidence: avgConf
                ))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    // If perform() throws, the completion handler never fires — resume
                    // here so the awaiting analysis pipeline can never hang forever.
                    continuation.resume(returning: OCRResult(fullText: "", lines: [], confidence: 0))
                }
            }
        }
    }
}
