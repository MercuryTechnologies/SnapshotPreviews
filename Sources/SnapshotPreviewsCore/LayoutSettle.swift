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
  private(set) var hash = 0
  /// True when any layer in the tree has an in-flight, finite Core Animation animation.
  /// Indefinitely repeating animations (spinners, pulses) never end, so waiting on them
  /// would only ever hit the ceiling; they are ignored and captured mid-cycle as before.
  private(set) var isAnimating = false

  /// Diagnostics for `EMERGE_SNAPSHOT_SETTLE_DEBUG`: a description of each layer that is
  /// animating, so a preview that keeps hitting the ceiling can be traced to its source.
  private(set) var animatingLayerDescriptions: [String] = []
  /// Per-layer hashes in visit order, used to describe what changed between two frames.
  private var layerHashes: [Int] = []
  private var layerDescriptions: [String] = []

  static var isDebugEnabled = ProcessInfo.processInfo.environment["EMERGE_SNAPSHOT_SETTLE_DEBUG"] != nil

  static func == (lhs: LayoutFingerprint, rhs: LayoutFingerprint) -> Bool {
    lhs.hash == rhs.hash && lhs.isAnimating == rhs.isAnimating
  }

  @MainActor
  init(view: UIView) {
    var hasher = Hasher()
    var animating = false
    visit(layer: view.layer, depth: 0, hasher: &hasher, animating: &animating)
    hash = hasher.finalize()
    isAnimating = animating
  }

  /// Describes the first layers whose hash differs from `previous`, for debug logging.
  func describeChanges(since previous: LayoutFingerprint, limit: Int = 5) -> [String] {
    guard Self.isDebugEnabled else { return [] }
    if layerHashes.count != previous.layerHashes.count {
      return ["layer count changed \(previous.layerHashes.count) → \(layerHashes.count)"]
    }
    var changes: [String] = []
    for (index, (old, new)) in zip(previous.layerHashes, layerHashes).enumerated() where old != new {
      changes.append(layerDescriptions[index])
      if changes.count == limit { break }
    }
    return changes
  }

  @MainActor
  private mutating func visit(layer: CALayer, depth: Int, hasher: inout Hasher, animating: inout Bool) {
    var layerHasher = Hasher()
    layerHasher.combine(Self.quantize(layer.bounds))
    layerHasher.combine(Self.quantize(layer.position))
    layerHasher.combine(layer.isHidden)
    layerHasher.combine(Self.quantize(CGFloat(layer.opacity)))
    // `contents` is replaced whenever a drawn layer (text, images, shapes) redraws, which is how
    // same-size content changes such as skeleton → data are detected.
    if let contents = layer.contents {
      layerHasher.combine(ObjectIdentifier(contents as AnyObject))
    }
    if let scrollView = layer.delegate as? UIScrollView {
      layerHasher.combine(Self.quantize(scrollView.contentSize))
      layerHasher.combine(Self.quantize(scrollView.contentOffset))
    }
    let layerHash = layerHasher.finalize()
    hasher.combine(layerHash)

    if Self.hasFiniteAnimation(layer) {
      animating = true
      if Self.isDebugEnabled {
        animatingLayerDescriptions.append(Self.describe(layer, depth: depth) + " keys=\(layer.animationKeys() ?? [])")
      }
    }
    if Self.isDebugEnabled {
      layerHashes.append(layerHash)
      layerDescriptions.append(Self.describe(layer, depth: depth))
    }
    for sublayer in layer.sublayers ?? [] {
      visit(layer: sublayer, depth: depth + 1, hasher: &hasher, animating: &animating)
    }
  }

  /// Liquid Glass keeps geometry-tracking animations attached for as long as a layer exists:
  /// `match-bounds`, `match-position`, `match-mesh` … on `UISDFElementView` element layers,
  /// and `_UILiquidLensView.punchout.matchPosition` on lens punch-outs. They never describe
  /// an in-flight transition, and a screen with one glass button would otherwise never settle.
  static func isPersistentTrackingAnimationKey(_ key: String) -> Bool {
    key.lowercased().contains("match")
  }

  @MainActor
  static func hasFiniteAnimation(_ layer: CALayer) -> Bool {
    guard let keys = layer.animationKeys(), !keys.isEmpty else { return false }
    return keys.contains { key in
      guard !isPersistentTrackingAnimationKey(key) else { return false }
      guard let animation = layer.animation(forKey: key) else { return false }
      return !isIndefinite(animation)
    }
  }

  static func isIndefinite(_ animation: CAAnimation) -> Bool {
    if animation.repeatCount == .infinity || animation.repeatDuration == .infinity {
      return true
    }
    if let group = animation as? CAAnimationGroup {
      return group.animations?.contains(where: isIndefinite) ?? false
    }
    return false
  }

  @MainActor
  private static func describe(_ layer: CALayer, depth: Int) -> String {
    let owner = (layer.delegate as? UIView).map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
    let bounds = layer.bounds
    return "\(String(repeating: "  ", count: depth))\(owner) \(Int(bounds.width))x\(Int(bounds.height))"
  }

  /// Quantize to 1/100 pt so float noise between identical layouts doesn't read as a change.
  /// Layers can carry NaN or infinite geometry (SwiftUI warns "Invalid frame dimension" but
  /// still commits them), and `Int(_:)` traps on those, so map them to sentinels instead.
  static func quantize(_ value: CGFloat) -> Int {
    guard value.isFinite else {
      if value.isNaN { return Int.min }
      return value > 0 ? Int.max : Int.min + 1
    }
    let scaled = (value * 100).rounded()
    guard abs(scaled) < CGFloat(Int.max / 2) else {
      return scaled > 0 ? Int.max : Int.min + 1
    }
    return Int(scaled)
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
  private var observedFrames = 0
  private var isCancelled = false

  /// Extra time past `timeout` that the belt-and-braces fallback waits, so a view whose first
  /// frame alone outlasts the ceiling still gets the minimum number of stability checks.
  static let fallbackGrace: TimeInterval = 0.5

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
    DispatchQueue.main.asyncAfter(deadline: .now() + remaining + Self.fallbackGrace) { [weak self] in
      guard let self, !isCancelled, displayLink != nil else { return }
      finish(.timedOut(elapsed: CACurrentMediaTime() - startTime))
    }
  }

  @objc private func tick() {
    guard !isCancelled, let timeout = configuration.timeout else { return }
    let elapsed = CACurrentMediaTime() - startTime
    let fingerprint = LayoutFingerprint(view: view)
    observedFrames += 1

    if !fingerprint.isAnimating, fingerprint == lastFingerprint {
      consecutiveStableFrames += 1
    } else {
      consecutiveStableFrames = 1
    }
    previousFingerprintForDebug = lastFingerprint
    lastFingerprint = fingerprint

    if consecutiveStableFrames >= configuration.requiredStableFrames {
      finish(.stable(elapsed: elapsed))
    } else if elapsed >= timeout, observedFrames >= configuration.requiredStableFrames {
      // A slow first layout can push the first tick past the ceiling; always look at the
      // minimum number of frames before declaring the view unstable.
      if LayoutFingerprint.isDebugEnabled {
        logInstability(fingerprint)
      }
      finish(.timedOut(elapsed: elapsed))
    }
  }

  private var previousFingerprintForDebug: LayoutFingerprint?

  private func logInstability(_ fingerprint: LayoutFingerprint) {
    var lines = ["LayoutSettleObserver: timed out; last frame was unstable because:"]
    if fingerprint.isAnimating {
      lines.append("  animating layers:")
      lines.append(contentsOf: fingerprint.animatingLayerDescriptions.prefix(5).map { "    " + $0 })
    }
    if let previous = previousFingerprintForDebug {
      let changes = fingerprint.describeChanges(since: previous)
      if !changes.isEmpty {
        lines.append("  changed layers:")
        lines.append(contentsOf: changes.map { "    " + $0 })
      }
    }
    NSLog("%@", lines.joined(separator: "\n"))
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
