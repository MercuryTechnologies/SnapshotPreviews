import XCTest
@testable import SnapshotPreviewsCore

final class SettleConfigurationTests: XCTestCase {
  func testDefaultsToLegacyImmediateSettle() {
    let config = SettleConfiguration.fromEnvironment([:])
    XCTAssertFalse(config.isAdaptive)
    XCTAssertTrue(config.settlesImmediately)
    XCTAssertEqual(config.minimumDelay, 0)
  }

  func testRenderDelayAloneIsFixedDelayMode() {
    let config = SettleConfiguration.fromEnvironment([SettleConfiguration.minimumDelayKey: "0.15"])
    XCTAssertFalse(config.isAdaptive)
    XCTAssertFalse(config.settlesImmediately)
    XCTAssertEqual(config.minimumDelay, 0.15, accuracy: 0.0001)
  }

  func testSettleTimeoutEnablesAdaptiveMode() {
    let config = SettleConfiguration.fromEnvironment([
      SettleConfiguration.timeoutKey: "0.3",
      SettleConfiguration.stableFramesKey: "3",
    ])
    XCTAssertTrue(config.isAdaptive)
    XCTAssertFalse(config.settlesImmediately)
    XCTAssertEqual(config.timeout, 0.3)
    XCTAssertEqual(config.requiredStableFrames, 3)
  }

  func testInvalidValuesFallBackToDefaults() {
    let config = SettleConfiguration.fromEnvironment([
      SettleConfiguration.minimumDelayKey: "nope",
      SettleConfiguration.timeoutKey: "-1",
      SettleConfiguration.stableFramesKey: "0",
    ])
    XCTAssertEqual(config, SettleConfiguration())
  }
}

final class ExpansionHistoryTests: XCTestCase {
  func testProceedsWhileHeightsAreNew() {
    var history = ExpansionHistory()
    XCTAssertEqual(history.record(visibleHeight: 100), .proceed)
    XCTAssertEqual(history.record(visibleHeight: 300), .proceed)
    XCTAssertEqual(history.record(visibleHeight: 700), .proceed)
    XCTAssertEqual(history.iterations, 3)
  }

  func testDetectsOscillation() {
    var history = ExpansionHistory()
    XCTAssertEqual(history.record(visibleHeight: 100), .proceed)
    XCTAssertEqual(history.record(visibleHeight: 250), .proceed)
    XCTAssertEqual(history.record(visibleHeight: 100.3), .oscillating)
  }

  func testStopsAfterMaxIterations() {
    var history = ExpansionHistory(maxIterations: 3)
    for height in [10, 20, 30] {
      XCTAssertEqual(history.record(visibleHeight: CGFloat(height)), .proceed)
    }
    XCTAssertEqual(history.record(visibleHeight: 40), .exceededIterations)
  }
}

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import UIKit

private struct FakeScrollContent: ContentHeightProviding {
  var contentHeight: CGFloat
  var visibleContentHeight: CGFloat
}

private final class FakeExpander: ScrollExpansionProviding {
  var previousHeight: CGFloat?
  var heightAnchor: NSLayoutConstraint? = NSLayoutConstraint()
  var supportsExpansion = true
  var firstScrollView: ContentHeightProviding?
}

final class ExpansionStepTests: XCTestCase {
  func testGrowsByContentOverflow() {
    let expander = FakeExpander()
    expander.firstScrollView = FakeScrollContent(contentHeight: 900, visibleContentHeight: 400)
    XCTAssertEqual(expander.nextExpansionStep(), .grow(by: 500))
    XCTAssertEqual(expander.previousHeight, 400)
  }

  func testCompletesWhenContentFits() {
    let expander = FakeExpander()
    expander.firstScrollView = FakeScrollContent(contentHeight: 400, visibleContentHeight: 400)
    XCTAssertEqual(expander.nextExpansionStep(), .complete)
  }

  func testCompletesWhenHeightStoppedChanging() {
    let expander = FakeExpander()
    expander.firstScrollView = FakeScrollContent(contentHeight: 900, visibleContentHeight: 400)
    XCTAssertEqual(expander.nextExpansionStep(), .grow(by: 500))
    // Constraint change had no effect (e.g. a half sheet pinned its height).
    XCTAssertEqual(expander.nextExpansionStep(), .complete)
  }

  func testCompletesWithoutHeightAnchorOrScrollView() {
    let expander = FakeExpander()
    expander.firstScrollView = FakeScrollContent(contentHeight: 900, visibleContentHeight: 400)
    expander.heightAnchor = nil
    XCTAssertEqual(expander.nextExpansionStep(), .complete)

    expander.heightAnchor = NSLayoutConstraint()
    expander.firstScrollView = nil
    XCTAssertEqual(expander.nextExpansionStep(), .complete)
  }
}

@MainActor
final class LayoutFingerprintTests: XCTestCase {
  private func makeHierarchy() -> (UIView, UIView, UIScrollView) {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    let child = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 200, height: 300))
    scroll.contentSize = CGSize(width: 200, height: 1000)
    root.addSubview(child)
    root.addSubview(scroll)
    return (root, child, scroll)
  }

  func testUnchangedHierarchyIsStable() {
    let (root, _, _) = makeHierarchy()
    XCTAssertEqual(LayoutFingerprint(view: root), LayoutFingerprint(view: root))
  }

  func testGeometryChangeIsDetected() {
    let (root, child, _) = makeHierarchy()
    let before = LayoutFingerprint(view: root)
    child.frame.origin.x += 1
    XCTAssertNotEqual(before, LayoutFingerprint(view: root))
  }

  func testVisibilityChangeIsDetected() {
    let (root, child, _) = makeHierarchy()
    let before = LayoutFingerprint(view: root)
    child.isHidden = true
    XCTAssertNotEqual(before, LayoutFingerprint(view: root))
  }

  func testScrollContentSizeChangeIsDetected() {
    let (root, _, scroll) = makeHierarchy()
    let before = LayoutFingerprint(view: root)
    scroll.contentSize.height += 40
    XCTAssertNotEqual(before, LayoutFingerprint(view: root))
  }

  func testRedrawnContentsIsDetected() {
    let (root, child, _) = makeHierarchy()
    let before = LayoutFingerprint(view: root)
    child.layer.contents = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage
    XCTAssertNotEqual(before, LayoutFingerprint(view: root))
  }

  func testNonFiniteGeometryDoesNotTrap() {
    // Core Animation rejects NaN bounds when set directly, but SwiftUI can still commit
    // layers with non-finite geometry ("Invalid frame dimension" runtime warning), which
    // trapped `Int(_:)` in the quantizer on CI. The mapping must be total.
    XCTAssertEqual(LayoutFingerprint.quantize(CGFloat.nan), Int.min)
    XCTAssertEqual(LayoutFingerprint.quantize(CGFloat.infinity), Int.max)
    XCTAssertEqual(LayoutFingerprint.quantize(-CGFloat.infinity), Int.min + 1)
    XCTAssertEqual(LayoutFingerprint.quantize(CGFloat.greatestFiniteMagnitude), Int.max)
    XCTAssertEqual(LayoutFingerprint.quantize(-CGFloat.greatestFiniteMagnitude), Int.min + 1)
    XCTAssertEqual(LayoutFingerprint.quantize(12.345), 1235)
    XCTAssertEqual(LayoutFingerprint.quantize(-0.004), 0)
  }

  func testIndefiniteAnimationsAreNotInstability() {
    let (root, child, _) = makeHierarchy()
    let spin = CABasicAnimation(keyPath: "transform.rotation")
    spin.fromValue = 0
    spin.toValue = Double.pi * 2
    spin.duration = 1
    spin.repeatCount = .infinity
    child.layer.add(spin, forKey: "spin")
    XCTAssertFalse(LayoutFingerprint(view: root).isAnimating)

    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = 1
    child.layer.add(fade, forKey: "fade")
    XCTAssertTrue(LayoutFingerprint(view: root).isAnimating)
  }

  func testPersistentMatchAnimationsAreIgnored() {
    let (root, child, _) = makeHierarchy()
    let match = CABasicAnimation(keyPath: "bounds")
    match.duration = 0.25
    child.layer.add(match, forKey: "match-bounds")
    XCTAssertFalse(LayoutFingerprint(view: root).isAnimating)

    child.layer.add(match, forKey: "_UILiquidLensView.punchout.matchPosition")
    XCTAssertFalse(LayoutFingerprint(view: root).isAnimating)

    // The same animation under an ordinary key is a real transition.
    child.layer.add(match, forKey: "bounds")
    XCTAssertTrue(LayoutFingerprint(view: root).isAnimating)
  }

  func testIndefiniteAnimationGroupIsRecognized() {
    let inner = CABasicAnimation(keyPath: "opacity")
    inner.repeatCount = .infinity
    let group = CAAnimationGroup()
    group.animations = [inner]
    XCTAssertTrue(LayoutFingerprint.isIndefinite(group))
    XCTAssertFalse(LayoutFingerprint.isIndefinite(CABasicAnimation(keyPath: "opacity")))
    let repeating = CABasicAnimation(keyPath: "opacity")
    repeating.repeatDuration = .infinity
    XCTAssertTrue(LayoutFingerprint.isIndefinite(repeating))
  }

  func testSubPixelNoiseIsIgnored() {
    let (root, child, _) = makeHierarchy()
    let before = LayoutFingerprint(view: root)
    child.frame.origin.x += 0.001
    XCTAssertEqual(before, LayoutFingerprint(view: root))
  }
}

@MainActor
final class LayoutSettleObserverTests: XCTestCase {
  private var window: UIWindow!
  private var root: UIView!
  private var child: UIView!

  override func setUp() {
    super.setUp()
    window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
    root = UIView(frame: window.bounds)
    child = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
    root.addSubview(child)
    window.addSubview(root)
    window.isHidden = false
  }

  override func tearDown() {
    window.isHidden = true
    window = nil
    super.tearDown()
  }

  private func observe(_ configuration: SettleConfiguration, timeout: TimeInterval = 3) -> SettleOutcome? {
    let settled = expectation(description: "settled")
    var outcome: SettleOutcome?
    let observer = LayoutSettleObserver(view: root, configuration: configuration) {
      outcome = $0
      settled.fulfill()
    }
    observer.start()
    wait(for: [settled], timeout: timeout)
    return outcome
  }

  func testFixedDelayModeReportsFixedDelay() {
    var config = SettleConfiguration()
    config.minimumDelay = 0.02
    XCTAssertEqual(observe(config), .fixedDelay)
  }

  func testStaticViewSettlesWellBeforeTimeout() {
    var config = SettleConfiguration()
    config.timeout = 2
    guard case let .stable(elapsed)? = observe(config) else {
      return XCTFail("expected stable outcome")
    }
    XCTAssertLessThan(elapsed, 0.5)
  }

  func testWaitsForLateHydrationThenSettles() {
    var config = SettleConfiguration()
    config.timeout = 2
    // Simulate a mock load landing a few frames in: keep moving the child until then.
    var remainingMoves = 6
    let mover = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [child] timer in
      child?.frame.origin.x += 5
      remainingMoves -= 1
      if remainingMoves == 0 { timer.invalidate() }
    }
    defer { mover.invalidate() }

    guard case let .stable(elapsed)? = observe(config) else {
      return XCTFail("expected stable outcome")
    }
    XCTAssertEqual(remainingMoves, 0, "should not settle while the layout is still changing")
    XCTAssertGreaterThan(elapsed, 0.05)
  }

  func testContinuouslyChangingViewTimesOut() {
    var config = SettleConfiguration()
    config.timeout = 0.25
    let mover = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [child] _ in
      child?.frame.origin.x += 1
    }
    defer { mover.invalidate() }

    guard case let .timedOut(elapsed)? = observe(config) else {
      return XCTFail("expected timedOut outcome")
    }
    XCTAssertGreaterThanOrEqual(elapsed, 0.25)
    XCTAssertLessThan(elapsed, 1)
  }

  func testCancelSuppressesCallback() {
    var config = SettleConfiguration()
    config.timeout = 0.1
    let notCalled = expectation(description: "not called")
    notCalled.isInverted = true
    let observer = LayoutSettleObserver(view: root, configuration: config) { _ in notCalled.fulfill() }
    observer.start()
    observer.cancel()
    wait(for: [notCalled], timeout: 0.4)
  }
}
#endif
