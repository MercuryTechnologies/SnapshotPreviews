#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import XCTest
import SwiftUI
@testable import SnapshotPreviewsCore

/// Hosts real SwiftUI scroll views through `ExpandingViewController` and checks that the
/// expansion loop ends at the full content height, deterministically.
@MainActor
final class ExpandingViewControllerTests: XCTestCase {
  private var window: UIWindow!

  override func setUp() {
    super.setUp()
    window = UIWindow(frame: UIScreen.main.bounds)
    window.makeKeyAndVisible()
  }

  override func tearDown() {
    window.rootViewController = nil
    window.isHidden = true
    window = nil
    super.tearDown()
  }

  private struct Rows: View {
    let count: Int
    let lazy: Bool
    var body: some View {
      ScrollView {
        if lazy {
          LazyVStack(spacing: 0) { rows }
        } else {
          VStack(spacing: 0) { rows }
        }
      }
    }
    private var rows: some View {
      ForEach(0..<count, id: \.self) { i in
        Text("Row \(i)").frame(height: 50)
      }
    }
  }

  /// Mirrors `View.makeExpandingView`'s container setup so expansion has room to grow.
  private func host(_ controller: ExpandingViewController) {
    let root = UIViewController()
    root.view.bounds = UIScreen.main.bounds
    let container = UIViewController()
    container.view.translatesAutoresizingMaskIntoConstraints = false
    root.view.addSubview(container.view)
    root.addChild(container)
    container.didMove(toParent: root)
    container.view.widthAnchor.constraint(equalToConstant: UIScreen.main.bounds.width).isActive = true
    container.view.heightAnchor.constraint(greaterThanOrEqualToConstant: UIScreen.main.bounds.height).isActive = true
    container.view.centerXAnchor.constraint(equalTo: root.view.centerXAnchor).isActive = true
    container.view.centerYAnchor.constraint(equalTo: root.view.centerYAnchor).isActive = true

    container.view.addSubview(controller.view)
    container.addChild(controller)
    controller.didMove(toParent: container)
    controller.view.centerXAnchor.constraint(equalTo: container.view.centerXAnchor).isActive = true
    controller.view.centerYAnchor.constraint(equalTo: container.view.centerYAnchor).isActive = true
    controller.view.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width).isActive = true
    container.view.heightAnchor.constraint(greaterThanOrEqualTo: controller.view.heightAnchor).isActive = true
    window.rootViewController = root
  }

  /// Renders `view`, waits for expansion to settle, and returns the scroll view's final
  /// (content, visible) heights plus any error the controller reported.
  private func expand<V: View>(_ view: V, configuration: SettleConfiguration) -> (content: CGFloat, visible: CGFloat, error: Error?) {
    let controller = ExpandingViewController(rootView: view, settleConfiguration: configuration)
    controller.setupView(layout: .sizeThatFits)
    let settled = expectation(description: "expansion settled")
    var reported: Error?
    controller.expansionSettled = { _, _, _, _, _, _, _, _, error in
      reported = error
      settled.fulfill()
    }
    host(controller)
    wait(for: [settled], timeout: 9)
    let scrollView = controller.firstScrollView
    return (scrollView?.contentHeight ?? -1, scrollView?.visibleContentHeight ?? -1, reported)
  }

  private var adaptive: SettleConfiguration {
    var config = SettleConfiguration()
    config.timeout = 0.3
    return config
  }

  func testExpandsEagerStackToFullContentHeight() {
    let result = expand(Rows(count: 60, lazy: false), configuration: adaptive)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.content, 3000, accuracy: 1)
    XCTAssertEqual(result.visible, result.content, accuracy: 1)
  }

  func testExpandsLazyStackToFullContentHeightDeterministically() {
    // LazyVStack only materializes rows as the frame grows, so the loop has to keep going
    // until content stops growing. Two passes must land on the same height.
    let first = expand(Rows(count: 120, lazy: true), configuration: adaptive)
    let second = expand(Rows(count: 120, lazy: true), configuration: adaptive)
    XCTAssertNil(first.error)
    XCTAssertNil(second.error)
    XCTAssertEqual(first.content, 6000, accuracy: 1)
    XCTAssertEqual(first.visible, first.content, accuracy: 1)
    XCTAssertEqual(second.visible, first.visible, accuracy: 1)
  }

  func testFixedDelayModeAlsoExpandsFully() {
    var config = SettleConfiguration()
    config.minimumDelay = 0.05
    let result = expand(Rows(count: 60, lazy: false), configuration: config)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.visible, result.content, accuracy: 1)
  }

  func testNonScrollingViewSettlesWithoutExpansion() {
    let result = expand(Text("Hello").frame(width: 200, height: 100), configuration: adaptive)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.content, -1)
  }
}
#endif
