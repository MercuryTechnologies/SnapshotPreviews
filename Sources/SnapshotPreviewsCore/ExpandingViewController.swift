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

  private let HeightExpansionTimeLimitInSeconds: UInt64 = 30

  /// Optional settle delay before the view is measured and expanded. Lets deferred
  /// main-queue work — SwiftUI `.task` modifiers, async data fetches — hydrate the
  /// view first, so sizing and capture see the final content instead of racing it.
  private let settleDelay = ProcessInfo.processInfo
    .environment["EMERGE_SNAPSHOT_RENDER_DELAY"]
    .flatMap(Double.init) ?? 0

  private var didSettle = false
  private var settleScheduled = false
  private var layout: PreviewLayout = .sizeThatFits

  private var didCall = false
  var previousHeight: CGFloat?

  var heightAnchor: NSLayoutConstraint?
  private var widthAnchor: NSLayoutConstraint?

  private var startTime: UInt64?
  private var timer: Timer?

  public var expansionSettled: ((EmergeRenderingMode?, Float?, Bool?, Bool?, [String: String], [String: SnapshotMetadataValue], SnapshotGroup?, SnapshotCanvasTheme?, Error?) -> Void)? {
    didSet {
      didCall = false
      didSettle = settleDelay <= 0
      settleScheduled = false
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

    // Wait out the settle delay before measuring: re-apply the layout constraints so
    // the fitting size reflects the hydrated content, then let expansion run to
    // completion and capture immediately on settle.
    guard didSettle else {
      scheduleSettleIfNeeded()
      return
    }

    updateHeight {
      runCallback()
    }
  }

  private func scheduleSettleIfNeeded() {
    guard !settleScheduled else { return }
    settleScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
      guard let self, expansionSettled != nil, !didCall else { return }
      didSettle = true
      setupView(layout: layout)
      view.setNeedsLayout()
      updateScrollViewHeight()
    }
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
          let timeoutError = RenderingError.expandingViewTimeout(CGSize(width: UIScreen.main.bounds.size.width,
                                                                        height: firstScrollView?.visibleContentHeight ?? -1))
          NSLog("ExpandingViewController: Expanding Scroll View timed out. Current height is \(firstScrollView?.visibleContentHeight ?? -1)")
          runCallback(timeoutError)
      }
  }

  func stopAndResetTimer() {
      timer?.invalidate()
      timer = nil
      startTime = nil
  }

}
#endif
