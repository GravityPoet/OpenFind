import Foundation

extension ClipboardHistoryStore {
    private static let currentImageTextRecognitionRevision = 1

    func enqueueMissingImageTextRecognition() {
        guard preferences.imageTextRecognitionEnabled else { return }
        let missing = entries.lazy.filter {
            self.needsImageTextRecognition($0)
        }.map(\.id)
        enqueueImageTextRecognition(ids: missing)
    }

    func enqueueImageTextRecognition(ids: some Sequence<UUID>) {
        guard preferences.imageTextRecognitionEnabled else { return }
        pendingImageTextRecognitionIDs.formUnion(ids)
        guard !isClipboardBackgroundResident,
              imageTextRecognitionTask == nil,
              !pendingImageTextRecognitionIDs.isEmpty else { return }
        let startDelay = imageTextRecognitionStartDelay
        imageTextRecognitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if startDelay > .zero {
                do {
                    try await Task.sleep(for: startDelay)
                } catch {
                    imageTextRecognitionTask = nil
                    return
                }
            }
            var changed = false
            while !Task.isCancelled,
                  let id = pendingImageTextRecognitionIDs.first {
                pendingImageTextRecognitionIDs.remove(id)
                guard let entry = entries.first(where: { $0.id == id }),
                      needsImageTextRecognition(entry),
                      let materialized = try? materializedEntry(for: entry),
                      let data = materialized.imageData else { continue }
                let recognized = await imageTextRecognizer.recognizeText(in: data)
                guard !Task.isCancelled else {
                    pendingImageTextRecognitionIDs.insert(id)
                    break
                }
                changed = applyRecognizedText(recognized, to: id) || changed
            }
            imageTextRecognitionTask = nil
            while changed, isPanelPresented, !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }
            if changed, !Task.isCancelled { persist() }
        }
    }

    func setImageTextRecognitionEnabled(_ enabled: Bool) {
        updatePreferences { $0.imageTextRecognitionEnabled = enabled }
        if enabled {
            enqueueMissingImageTextRecognition()
            return
        }
        imageTextRecognitionTask?.cancel()
        imageTextRecognitionTask = nil
        pendingImageTextRecognitionIDs.removeAll()
        var changed = false
        for index in entries.indices
            where entries[index].recognizedText != nil
                || entries[index].imageTextRecognitionRevision != nil {
            entries[index].recognizedText = nil
            entries[index].imageTextRecognitionRevision = nil
            changed = true
        }
        if changed { persist() }
    }

    func waitForPendingImageTextRecognition() async {
        while let task = imageTextRecognitionTask {
            await task.value
        }
    }

    func pauseImageTextRecognitionForBackground() {
        imageTextRecognitionTask?.cancel()
        imageTextRecognitionTask = nil
    }

    @discardableResult
    private func applyRecognizedText(_ value: String?, to id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty, matchesIgnoredPattern(normalized) {
            entries.remove(at: index)
            removeInvalidSelections()
            selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
            persist()
            return false
        }
        entries[index].recognizedText = normalized ?? ""
        entries[index].imageTextRecognitionRevision =
            Self.currentImageTextRecognitionRevision
        return true
    }

    private func needsImageTextRecognition(_ entry: ClipboardEntry) -> Bool {
        guard entry.kind == .image else { return false }
        if entry.recognizedText == nil { return true }
        return entry.recognizedText?.isEmpty == true
            && (entry.imageTextRecognitionRevision ?? 0)
                < Self.currentImageTextRecognitionRevision
    }
}
