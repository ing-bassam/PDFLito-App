import Vision

/// On-device text recognition (Apple Vision). Nothing is uploaded.
enum TextRecognizer {
    static func recognize(_ image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, box: observation.boundingBox, confidence: candidate.confidence,
                                  words: words(in: candidate),
                                  bottomLeft: TextPoint(observation.bottomLeft),
                                  bottomRight: TextPoint(observation.bottomRight),
                                  topLeft: TextPoint(observation.topLeft))
        }
    }

    /// Every word with its own position, so the text layer of the PDF sits exactly on the print.
    /// Returns an empty list when Vision cannot place the words individually.
    private static func words(in candidate: VNRecognizedText) -> [RecognizedWord] {
        let string = candidate.string
        var words: [RecognizedWord] = []
        var index = string.startIndex
        while index < string.endIndex {
            guard !string[index].isWhitespace else {
                index = string.index(after: index)
                continue
            }
            var end = index
            while end < string.endIndex, !string[end].isWhitespace {
                end = string.index(after: end)
            }
            guard let box = try? candidate.boundingBox(for: index..<end) else { return [] }
            words.append(RecognizedWord(text: String(string[index..<end]),
                                        bottomLeft: TextPoint(box.bottomLeft),
                                        bottomRight: TextPoint(box.bottomRight),
                                        topLeft: TextPoint(box.topLeft)))
            index = end
        }
        return words
    }
}

private extension TextPoint {
    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }
}
