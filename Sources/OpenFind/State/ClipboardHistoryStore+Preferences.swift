import Foundation

extension ClipboardHistoryStore {
    func setRetentionPeriod(
        _ period: ClipboardRetentionPeriod,
        referenceDate: Date = Date()
    ) {
        updatePreferences { $0.retentionPeriod = period }
        if trimToLimits(referenceDate: referenceDate) {
            selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
            persist()
        }
    }

    func setItemLimitMegabytes(_ megabytes: Int) {
        updatePreferences { $0.itemLimitBytes = megabytes * 1_024 * 1_024 }
    }

    func setIgnoredBundleIdentifiers(_ identifiers: Set<String>) {
        updatePreferences { $0.ignoredBundleIdentifiers = identifiers }
    }

    func setAllowedBundleIdentifiers(_ identifiers: Set<String>) {
        updatePreferences { $0.allowedBundleIdentifiers = identifiers }
    }

    func setPasteWithoutFormatting(_ enabled: Bool) {
        updatePreferences { $0.pasteWithoutFormatting = enabled }
    }

    func setClearHistoryOnQuit(_ enabled: Bool) {
        updatePreferences { $0.clearHistoryOnQuit = enabled }
    }

    func setClearSystemClipboardOnQuit(_ enabled: Bool) {
        updatePreferences { $0.clearSystemClipboardOnQuit = enabled }
    }

    func setFuzzySearchEnabled(_ enabled: Bool) {
        updatePreferences { $0.searchMode = enabled ? .fuzzy : .exact }
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
    }

    func setSearchMode(_ mode: ClipboardSearchMode) {
        updatePreferences { $0.searchMode = mode }
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
    }

    func setSortMode(_ mode: ClipboardSortMode) {
        let selectedID = selectedEntry?.id
        updatePreferences { $0.sortMode = mode }
        restoreSelection(id: selectedID)
    }

    func setPinsPosition(_ position: ClipboardPinsPosition) {
        let selectedID = selectedEntry?.id
        updatePreferences { $0.pinsPosition = position }
        restoreSelection(id: selectedID)
    }

    func setStorageCategory(_ category: ClipboardStorageCategory, enabled: Bool) {
        updatePreferences {
            if enabled {
                $0.enabledStorageCategories.insert(category)
            } else {
                $0.enabledStorageCategories.remove(category)
            }
        }
    }

    func setCaptureOnlyFromAllowedApplications(_ enabled: Bool) {
        updatePreferences { $0.captureOnlyFromAllowedApplications = enabled }
    }

    func setIgnoredPasteboardTypes(_ types: Set<String>) {
        updatePreferences { $0.ignoredPasteboardTypes = types }
    }

    func resetIgnoredPasteboardTypes() {
        setIgnoredPasteboardTypes(ClipboardPreferences.defaultIgnoredPasteboardTypes)
    }

    func setIgnoredTextPatterns(_ patterns: [String]) {
        updatePreferences { $0.ignoredTextPatterns = patterns }
    }

    func setCapturePaused(_ paused: Bool) {
        updatePreferences {
            $0.capturePaused = paused
            if !paused { $0.ignoreOnlyNextCapture = false }
        }
    }

    func ignoreNextCapture() {
        updatePreferences {
            $0.capturePaused = true
            $0.ignoreOnlyNextCapture = true
        }
    }

    func setClipboardCheckInterval(_ interval: TimeInterval) {
        updatePreferences { $0.clipboardCheckInterval = interval }
    }

    func setSnippetExpansionEnabled(_ enabled: Bool) {
        updatePreferences { $0.snippetExpansionEnabled = enabled }
    }

    func setQuickMergeEnabled(_ enabled: Bool) {
        updatePreferences { $0.quickMergeEnabled = enabled }
    }

    func setQuickMergeSeparator(_ separator: ClipboardQuickMergeSeparator) {
        updatePreferences { $0.quickMergeSeparator = separator }
    }

    func setQuickMergeCustomSeparator(_ separator: String) {
        updatePreferences { $0.quickMergeCustomSeparator = separator }
    }

    func setPreference<Value>(
        _ keyPath: WritableKeyPath<ClipboardPreferences, Value>,
        to value: Value
    ) {
        updatePreferences { $0[keyPath: keyPath] = value }
    }

    func updatePreferences(_ update: (inout ClipboardPreferences) -> Void) {
        var next = preferences
        update(&next)
        preferences = next.normalized()
        ClipboardPreferencesPersistence.save(preferences, to: defaults)
    }
}
