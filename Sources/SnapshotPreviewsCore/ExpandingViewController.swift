//
//  ExpandingViewController.swift
//  TestAppSwiftUI
//
//  Created by Noah Martin on 6/30/23.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI
import SnapshotSharedModels

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)

public final class ExpandingViewController: UIHostingController<EmergeModifierView>, ScrollExpansionProviding {

  var supportsExpansion: Bool {
    rootView.supportsExpansion
  }

  /// Must stay below the 10s the SnapshotTest harness waits for a render, otherwise a slow
  /// expansion surfaces as "Did not render" instead of this descriptive error.
  private let HeightExpansionTimeLimitInSeconds: UInt64 = 8

  /// How to wait for deferred main-queue work — SwiftUI `.task` modifiers, async data
  /// fetches — to hydrate the view before it is measured and captured. See `SettleConfiguration`.
  private let settleConfiguration = SettleConfiguration.fromEnvironment()

  private var didSettle = false
  private var settleObserver: LayoutSettleObserver?
  private var layout: PreviewLayout = .sizeThatFits

  private var didCall = false
  var previousHeight: CGFloat?
  private var expansionHistory = ExpansionHistory()
  private var isExpansionStepPending = false

  var heightAnchor: NSLayoutConstraint?
  private var widthAnchor: NSLayoutConstraint?

  private var startTime: UInt64?
  private var timer: Timer?

  public var expansionSettled: ((EmergeRenderingMode?, Float?, Bool?, Bool?, [String: String], [String: SnapshotMetadataValue], SnapshotGroup?, SnapshotCanvasTheme?, Error?) -> Void)? {
    didSet {
      didCall = false
      didSettle = settleConfiguration.settlesImmediately
      settleObserver?.cancel()
      settleObserver = nil
      expansionHistory = ExpansionHistory()
      isExpansionStepPending = false
    }
  }

  init<Content: View>(rootView: Content) {
    super.init(rootView: EmergeModifierView(wrapped: rootView))

    if #available(iOS 16, *) {
      sizingOptions = .intrinsicContentSize
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
  }

  @MainActor required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func removeConstraints() {
    heightAnchor?.isActive = false
    widthAnchor?.isActive = false
    heightAnchor = nil
    widthAnchor = nil
    previousHeight = nil
  }

  public func setupView(layout: PreviewLayout) {
    self.layout = layout
    removeConstraints()
    switch layout {
    case let .fixed(width: width, height: height):
      widthAnchor = view.widthAnchor.constraint(equalToConstant: width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(equalToConstant: height)
      heightAnchor?.isActive = true
    default:
      let fittingSize = sizeThatFits(in: UIScreen.main.bounds.size)
      widthAnchor = view.widthAnchor.constraint(greaterThanOrEqualToConstant: fittingSize.width)
      widthAnchor?.isActive = true
      heightAnchor = view.heightAnchor.constraint(greaterThanOrEqualToConstant: fittingSize.height)
      heightAnchor?.isActive = true
    }
  }

  private func runCallback(_ error: Error? = nil) {
    guard !didCall else { return }

    didCall = true
    settleObserver?.cancel()
    settleObserver = nil
    expansionSettled?(rootView.emergeRenderingMode, rootView.precision, rootView.accessibilityEnabled, rootView.appStoreSnapshot, rootView.tags, rootView.additionalContext, rootView.groupOverride, rootView.canvasTheme, error)
    stopAndResetTimer()
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateScrollViewHeight()
  }

  public func updateScrollViewHeight() {
    // Timeout limit
    if timer == nil && heightAnchor != nil && supportsExpansion && firstScrollView != nil {
      startTimer()
    }

    guard expansionSettled != nil else {
      runCallback()
      return
    }

    // Wait for the view to settle before measuring: re-apply the layout constraints so
    // the fitting size reflects the hydrated content, then let expansion run to
    // completion and capture immediately on settle.
    guard didSettle else {
      scheduleSettleIfNeeded()
      return
    }

    // A height change is already queued; this layout pass is the one it will trigger.
    guard !isExpansionStepPending else { return }

    switch nextExpansionStep() {
    case .complete:
      runCallback()
    case let .grow(diff):
      applyExpansionStep(diff)
    }
  }

  /// Applies a height change on the next run-loop turn rather than inside the current layout
  /// pass. Mutating the constraint synchronously re-enters `viewDidLayoutSubviews` within the
  /// same Core Animation commit, so a layout that never converges starves the run loop and no
  /// timer — ours or XCTest's — can ever fire. Yielding per step keeps the loop interruptible,
  /// and `ExpansionHistory` bounds it outright.
  private func applyExpansionStep(_ diff: CGFloat) {
    let visibleHeight = firstScrollView?.visibleContentHeight ?? -1
    switch expansionHistory.record(visibleHeight: visibleHeight) {
    case .proceed:
      break
    case .oscillating:
      NSLog("ExpandingViewController: scroll view height is oscillating at \(visibleHeight); capturing as-is")
      runCallback()
      return
    case .exceededIterations:
      NSLog("ExpandingViewController: scroll view expansion did not converge after \(expansionHistory.iterations) steps")
      runCallback(expansionTimeoutError())
      return
    }

    isExpansionStepPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isExpansionStepPending = false
      guard expansionSettled != nil, !didCall, let heightAnchor else { return }
      heightAnchor.constant += diff
      view.setNeedsLayout()
    }
  }

  private func scheduleSettleIfNeeded() {
    guard settleObserver == nil else { return }
    let observer = LayoutSettleObserver(view: view, configuration: settleConfiguration) { [weak self] outcome in
      guard let self, expansionSettled != nil, !didCall else { return }
      if case let .timedOut(elapsed) = outcome {
        NSLog("ExpandingViewController: layout did not settle within \(elapsed)s; capturing as-is")
      }
      didSettle = true
      setupView(layout: layout)
      view.setNeedsLayout()
      updateScrollViewHeight()
    }
    settleObserver = observer
    observer.start()
  }

  private func expansionTimeoutError() -> RenderingError {
    .expandingViewTimeout(CGSize(width: UIScreen.main.bounds.size.width,
                                 height: firstScrollView?.visibleContentHeight ?? -1))
  }

//  MARK: - Timer

  func startTimer() {
      guard timer == nil else {
        print("Timer already exists")
        return
      }
      startTime = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
          guard let self,
                let start = startTime,
                clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start >= (HeightExpansionTimeLimitInSeconds * 1_000_000_000) else {
              return
          }
          NSLog("ExpandingViewController: Expanding Scroll View timed out. Current height is \(firstScrollView?.visibleContentHeight ?? -1)")
          runCallback(expansionTimeoutError())
      }
  }

  func stopAndResetTimer() {
      timer?.invalidate()
      timer = nil
      startTime = nil
  }

}
#endif
