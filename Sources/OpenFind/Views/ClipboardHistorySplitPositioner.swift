import AppKit
import SwiftUI

/// Applies the initial split position after SwiftUI has materialized its
/// underlying NSSplitView. HSplitView otherwise distributes the available
/// width evenly and ignores unequal ideal widths.
struct ClipboardHistorySplitPositioner: NSViewRepresentable {
    let preferredPreviewWidth: CGFloat

    func makeNSView(context: Context) -> PositionerView {
        PositionerView(preferredPreviewWidth: preferredPreviewWidth)
    }

    func updateNSView(_ nsView: PositionerView, context: Context) {
        nsView.applyInitialPositionIfPossible()
    }

    @MainActor
    final class PositionerView: NSView {
        private let initialPreferredPreviewWidth: CGFloat
        private var didApplyInitialPosition = false
        private var retryScheduled = false
        private var retryCount = 0
        private var stabilizationPassesRemaining = 0
        private var stabilizationScheduled = false

        init(preferredPreviewWidth: CGFloat) {
            initialPreferredPreviewWidth = preferredPreviewWidth
            super.init(frame: .zero)
            isHidden = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyInitialPositionIfPossible()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyInitialPositionIfPossible()
        }

        func applyInitialPositionIfPossible() {
            guard !didApplyInitialPosition, window != nil else { return }
            guard enclosingSplitView != nil else {
                scheduleRetry()
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                guard !strongSelf.didApplyInitialPosition,
                      let splitView = strongSelf.enclosingSplitView,
                      splitView.subviews.count >= 2 else {
                    strongSelf.scheduleRetry()
                    return
                }

                splitView.setPosition(
                    strongSelf.requestedHistoryWidth(for: splitView),
                    ofDividerAt: 0
                )
                strongSelf.didApplyInitialPosition = true
                strongSelf.stabilizationPassesRemaining = 8
                strongSelf.scheduleStabilization()
            }
        }

        private func scheduleStabilization() {
            guard stabilizationPassesRemaining > 0,
                  !stabilizationScheduled,
                  window != nil else { return }
            stabilizationScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self else { return }
                self.stabilizationScheduled = false
                self.stabilizePositionIfNeeded()
            }
        }

        private func stabilizePositionIfNeeded() {
            guard stabilizationPassesRemaining > 0, window != nil else { return }
            stabilizationPassesRemaining -= 1
            guard let splitView = enclosingSplitView,
                  splitView.subviews.count >= 2 else {
                scheduleStabilization()
                return
            }
            guard !splitView.inLiveResize, NSEvent.pressedMouseButtons == 0 else {
                stabilizationPassesRemaining = 0
                return
            }

            let historyWidth = requestedHistoryWidth(for: splitView)
            if abs(splitView.subviews[0].frame.width - historyWidth) >= 0.5 {
                splitView.setPosition(historyWidth, ofDividerAt: 0)
            }
            scheduleStabilization()
        }

        private func requestedHistoryWidth(for splitView: NSSplitView) -> CGFloat {
            let storedPreviewWidth = abs(
                initialPreferredPreviewWidth
                    - ClipboardHistoryPanelGeometryMigration.previousBalancedPreviewWidth
            ) < 1
                ? ClipboardHistoryPanelMetrics.previewIdealWidth
                : initialPreferredPreviewWidth
            let previewWidth = min(
                max(
                    max(
                        storedPreviewWidth,
                        ClipboardHistoryPanelMetrics.previewIdealWidth
                    ),
                    ClipboardHistoryPanelMetrics.previewMinimumWidth
                ),
                ClipboardHistoryPanelMetrics.previewMaximumIdealWidth
            )
            let requestedHistoryWidth = splitView.bounds.width
                - splitView.dividerThickness
                - previewWidth
            return min(
                max(
                    requestedHistoryWidth,
                    ClipboardHistoryPanelMetrics.historyMinimumWidth
                ),
                ClipboardHistoryPanelMetrics.historyMaximumWidth
            )
        }

        private func scheduleRetry() {
            guard !retryScheduled, retryCount < 40, window != nil else { return }
            retryScheduled = true
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.applyInitialPositionIfPossible()
            }
        }

        private var enclosingSplitView: NSSplitView? {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView { return splitView }
                ancestor = view.superview
            }
            return nil
        }
    }
}
