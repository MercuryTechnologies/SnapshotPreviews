//
//  LayoutSettle.swift
//
//  Adaptive "is the preview done rendering?" detection used by ExpandingViewController
//  before a preview is measured, expanded and captured.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// How long to wait for a preview to finish hydrating before it is measured and captured.
///
/// Two modes:
/// - **Fixed delay** (`timeout == nil`): wait `minimumDelay` and proceed. This is the legacy
///   `EMERGE_SNAPSHOT_RENDER_DELAY` behavior.
/// - **Adaptive** (`timeout != nil`): wait `minimumDelay`, let the main queue drain
///   `mainQueueTurns` times so `.task` modifiers and mock responses can land, then proceed as
///   soon as the layer tree has been identical for `requiredStableFrames` consecutive frames,
///   or when `timeout` elapses, whichever comes first.
struct SettleConfiguration: Equatable {
  static let minimumDelayKey = "EMERGE_SNAPSHOT_RENDER_DELAY"
  static let timeoutKey = "EMERGE_SNAPSHOT_SETTLE_TIMEOUT"
  static let stableFramesKey = "EMERGE_SNAPSHOT_SETTLE_STABLE_FRAMES"

  var minimumDelay: TimeInterval = 0
  var timeout: TimeInterval?
  var requiredStableFrames: Int = 2
  var mainQueueTurns: Int = 3

  var isAdaptive: Bool { timeout != nil }

  /// True when there is nothing to wait for at all, so the controller can settle synchronously.
  var settlesImmediately: Bool { !isAdaptive && minimumDelay <= 0 }

  static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SettleConfiguration {
    var config = SettleConfiguration()
    if let delay = environment[minimumDelayKey].flatMap(Double.init), delay > 0 {
      config.minimumDelay = delay
    }
    if let timeout = environment[timeoutKey].flatMap(Double.init), timeout > 0 {
      config.timeout = timeout
    }
    if let frames = environment[stableFramesKey].flatMap(Int.init), frames >= 1 {
      config.requiredStableFrames = frames
    }
    return config
  }
}

enum SettleOutcome: Equatable {
  /// The fixed delay elapsed (legacy mode).
  case fixedDelay
  /// The layer tree was stable for the required number of frames.
  case stable(elapsed: TimeInterval)
  /// The layer tree never stabilized before the timeout. The capture proceeds anyway.
  case timedOut(elapsed: TimeInterval)
}

/// Tracks scroll-view expansion so a view whose content grows with its frame, or oscillates
/// between heights, cannot keep the expansion loop running forever.
struct ExpansionHistory: Equatable {
  static let defaultMaxIterations = 50

  private(set) var iterations = 0
  private var visitedHeights: [CGFloat] = []
  let maxIterations: Int

  init(maxIterations: Int = ExpansionHistory.defaultMaxIterations) {
    self.maxIterations = maxIterations
  }

  enum Verdict: Equatable {
    case proceed
    /// The same visible height was already visited, so the layout is oscillating.
    case oscillating
    /// More steps than any convergent layout should need.
    case exceededIterations
  }

  /// Records one expansion step at `visibleHeight` and reports whether the loop should keep going.
  mutating func record(visibleHeight: CGFloat) -> Verdict {
    iterations += 1
    if iterations > maxIterations {
      return .exceededIterations
    }
    let rounded = visibleHeight.rounded()
    if visitedHeights.contains(rounded) {
      return .oscillating
    }
    visitedHeights.append(rounded)
    return .proceed
  }
}

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)

/// A cheap digest of everything in a layer tree that affects what gets captured: geometry,
/// visibility, redrawn contents, and scroll-view content sizes. Two equal fingerprints taken
/// on consecutive frames mean the preview has stopped changing.
struct LayoutFingerprint: Equatable {
  let hash: Int
  /// True when any layer in the tree has an in-flight Core Animation animation.
  let isAnimating: Bool

  @MainActor
  init(view: UIView) {
    var hasher = Hasher()
    var animating = false
    Self.visit(layer: view.layer, hasher: &hasher, animating: &animating)
    hash = hasher.finalize()
    isAnimating = animating
  }

  @MainActor
  private static func visit(layer: CALayer, hasher: inout Hasher, animating: inout Bool) {
    hasher.combine(quantize(layer.bounds))
    hasher.combine(quantize(layer.position))
    hasher.combine(layer.isHidden)
    hasher.combine(quantize(CGFloat(layer.opacity)))
    // `contents` is replaced whenever a drawn layer (text, images, shapes) redraws, which is how
    // same-size content changes such as skeleton → data are detected.
    if let contents = layer.contents {
      hasher.combine(ObjectIdentifier(contents as AnyObject))
    }
    if let scrollView = layer.delegate as? UIScrollView {
      hasher.combine(quantize(scrollView.contentSize))
      hasher.combine(quantize(scrollView.contentOffset))
    }
    if let keys = layer.animationKeys(), !keys.isEmpty {
      animating = true
    }
    for sublayer in layer.sublayers ?? [] {
      visit(layer: sublayer, hasher: &hasher, animating: &animating)
    }
  }

  /// Quantize to 1/100 pt so float noise between identical layouts doesn't read as a change.
  private static func quantize(_ value: CGFloat) -> Int {
    Int((value * 100).rounded())
  }

  private static func quantize(_ point: CGPoint) -> [Int] {
    [quantize(point.x), quantize(point.y)]
  }

  private static func quantize(_ size: CGSize) -> [Int] {
    [quantize(size.width), quantize(size.height)]
  }

  private static func quantize(_ rect: CGRect) -> [Int] {
    quantize(rect.origin) + quantize(rect.size)
  }
}

/// Waits for a hosted preview to settle according to a `SettleConfiguration`, then calls
/// `onSettled` exactly once on the main thread. `cancel()` prevents the callback.
@MainActor
final class LayoutSettleObserver {
  private let view: UIView
  private let configuration: SettleConfiguration
  private var onSettled: ((SettleOutcome) -> Void)?

  private var displayLink: CADisplayLink?
  private var startTime: CFTimeInterval = 0
  private var lastFingerprint: LayoutFingerprint?
  private var consecutiveStableFrames = 0
  private var isCancelled = false

  init(view: UIView, configuration: SettleConfiguration, onSettled: @escaping (SettleOutcome) -> Void) {
    self.view = view
    self.configuration = configuration
    self.onSettled = onSettled
  }

  func start() {
    startTime = CACurrentMediaTime()
    let afterMinimumDelay: () -> Void = { [weak self] in
      guard let self, !isCancelled else { return }
      if configuration.isAdaptive {
        drainMainQueue(turns: configuration.mainQueueTurns) { [weak self] in
          self?.beginObservingFrames()
        }
      } else {
        finish(.fixedDelay)
      }
    }
    if configuration.minimumDelay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + configuration.minimumDelay, execute: afterMinimumDelay)
    } else {
      afterMinimumDelay()
    }
  }

  func cancel() {
    isCancelled = true
    onSettled = nil
    stopDisplayLink()
  }

  private func drainMainQueue(turns: Int, then completion: @escaping () -> Void) {
    guard turns > 0 else {
      completion()
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, !isCancelled else { return }
      drainMainQueue(turns: turns - 1, then: completion)
    }
  }

  private func beginObservingFrames() {
    guard !isCancelled, let timeout = configuration.timeout else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    displayLink = link

    // Belt and braces: if the display link never fires (no screen, paused run loop), the
    // timeout still wins so the lane can't stall here.
    let remaining = max(0, timeout - (CACurrentMediaTime() - startTime))
    DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.1) { [weak self] in
      guard let self, !isCancelled, displayLink != nil else { return }
      finish(.timedOut(elapsed: CACurrentMediaTime() - startTime))
    }
  }

  @objc private func tick() {
    guard !isCancelled, let timeout = configuration.timeout else { return }
    let elapsed = CACurrentMediaTime() - startTime
    let fingerprint = LayoutFingerprint(view: view)

    if !fingerprint.isAnimating, fingerprint == lastFingerprint {
      consecutiveStableFrames += 1
    } else {
      consecutiveStableFrames = 1
    }
    lastFingerprint = fingerprint

    if consecutiveStableFrames >= configuration.requiredStableFrames {
      finish(.stable(elapsed: elapsed))
    } else if elapsed >= timeout {
      finish(.timedOut(elapsed: elapsed))
    }
  }

  private func finish(_ outcome: SettleOutcome) {
    stopDisplayLink()
    guard let onSettled else { return }
    self.onSettled = nil
    onSettled(outcome)
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }
}

#endif
