//
//  View+Snapshot.swift
//  FindPreviews
//
//  Created by Noah Martin on 12/22/22.
//

import CoreFoundation

public enum RenderingError: Error {
  case failedRendering(CGSize)
  case maxSize(CGSize)
  case expandingViewTimeout(CGSize)
  case orientationChangeTimeout
}

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import Foundation
import SwiftUI
import UIKit
import SnapshotSharedModels

private var _colorScheme: ColorScheme? = nil

extension View {
  public func makeExpandingView(layout: PreviewLayout, window: UIWindow) -> ExpandingViewController {
    UIView.setAnimationsEnabled(false)
    var wrappedView: any View = self.transaction { transaction in
      transaction.disablesAnimations = true
    }
    _colorScheme = nil
    wrappedView = PreferredColorSchemeWrapper {
      AnyView(wrappedView)
    } colorSchemeUpdater: { scheme in
      _colorScheme = scheme
    }
    let controller = ExpandingViewController(rootView: wrappedView)
    controller.setupView(layout: layout)

    let windowRootVC = Self.setupRootVC(subVC: controller)
    window.rootViewController = windowRootVC
    return controller
  }

  public func snapshot(
    layout: PreviewLayout,
    controller: ExpandingViewController,
    window: UIWindow,
    async: Bool,
    a11yWrapper: ((UIViewController, UIWindow, PreviewLayout) -> UIView)? = nil,
    completion: @escaping (SnapshotResult) -> Void)
  {
    controller.expansionSettled = { [weak controller, weak window] renderingMode, precision, accessibilityEnabled, appStoreSnapshot, tags, additionalContext, groupOverride, canvasTheme, error in
      guard let controller, let window, let containerVC = controller.parent else {
        return
      }

      if let error {
        DispatchQueue.main.async {
          completion(SnapshotResult(image: .failure(error), precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext, groupOverride: groupOverride, canvasTheme: canvasTheme))
        }
        return
      }

      // The EMERGE_SNAPSHOT_RENDER_DELAY settle delay is applied by
      // ExpandingViewController before the view is measured and expanded, so by the
      // time expansion settles the content is final — capture immediately.
      let delay: TimeInterval = async ? 2 : 0
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let captureBlockStart = SnapshotTiming.now()
        SnapshotTiming.record { $0.captureStart = SnapshotTiming.ms(captureBlockStart) }
        if let a11yWrapper, let accessibilityEnabled, accessibilityEnabled, !async {
          let a11yView = a11yWrapper(controller, window, layout)
          let result = Self.takeSnapshot(layout: .sizeThatFits, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: a11yView, afterScreenUpdates: true, captureBlockStart: captureBlockStart)
          a11yView.removeFromSuperview()
          completion(SnapshotResult(image: result.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext, groupOverride: groupOverride, canvasTheme: canvasTheme))
        } else {
          Self.prepareForCapture(
            renderingMode: renderingMode,
            window: window,
            rootVC: containerVC,
            targetView: controller.view,
            heightChangedSinceSettle: controller.heightChangedSinceSettle)
          {
            let imageResult = Self.takeSnapshot(layout: layout, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: controller.view, afterScreenUpdates: false, captureBlockStart: captureBlockStart)
            completion(SnapshotResult(image: imageResult.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext, groupOverride: groupOverride, canvasTheme: canvasTheme))
          }
        }
      }
    }
  }

  private static func setupRootVC(subVC: UIViewController) -> UIViewController {
    let windowRootVC = UIViewController()
    windowRootVC.view.bounds = UIScreen.main.bounds
    windowRootVC.view.backgroundColor = .clear

    let containerVC = UIViewController()
    containerVC.view.backgroundColor = .clear
    containerVC.view.translatesAutoresizingMaskIntoConstraints = false
    windowRootVC.view.addSubview(containerVC.view)
    windowRootVC.addChild(containerVC)
    containerVC.didMove(toParent: windowRootVC)
    containerVC.view.widthAnchor.constraint(equalToConstant: UIScreen.main.bounds.width).isActive = true
    containerVC.view.heightAnchor.constraint(greaterThanOrEqualToConstant: UIScreen.main.bounds.height).isActive = true
    containerVC.view.centerXAnchor.constraint(equalTo: windowRootVC.view.centerXAnchor).isActive = true
    containerVC.view.centerYAnchor.constraint(equalTo: windowRootVC.view.centerYAnchor).isActive = true

    containerVC.view.addSubview(subVC.view)
    containerVC.addChild(subVC)
    subVC.didMove(toParent: containerVC)

    subVC.view.centerXAnchor.constraint(equalTo: containerVC.view.centerXAnchor).isActive = true
    subVC.view.centerYAnchor.constraint(equalTo: containerVC.view.centerYAnchor).isActive = true
    subVC.view.widthAnchor.constraint(lessThanOrEqualToConstant: UIScreen.main.bounds.width).isActive = true
    containerVC.view.heightAnchor.constraint(greaterThanOrEqualTo: subVC.view.heightAnchor, multiplier: 1).isActive = true

    return windowRootVC
  }

  /// Gets the screen current enough to capture with `drawHierarchy(afterScreenUpdates: false)`,
  /// then calls `capture` once.
  ///
  /// The settle wait ended on quiet display frames, so the screen is normally current already. If
  /// the height changed since `settle()` or a layout is pending, lay out now and wait two display
  /// frames for that layout to reach the screen, rather than forcing a screen update in the draw.
  /// Modes that never draw the hierarchy without a screen update capture right away.
  private static func prepareForCapture(
    renderingMode: EmergeRenderingMode?,
    window: UIWindow,
    rootVC: UIViewController,
    targetView: UIView,
    heightChangedSinceSettle: Bool,
    capture: @escaping () -> Void)
  {
    let layoutViews: [(name: String, view: UIView?)] = [
      ("target", targetView),
      ("root", rootVC.view),
      ("windowRoot", window.rootViewController?.view),
      ("window", window),
    ]
    let needsLayoutViews = layoutViews.filter { $0.view?.layer.needsLayout() == true }.map { $0.name }
    let needsLayout = !needsLayoutViews.isEmpty
    let drawsScreenState = renderingMode != EmergeRenderingMode.window && renderingMode != EmergeRenderingMode.coreAnimation
    let waitFrames = drawsScreenState && (heightChangedSinceSettle || needsLayout) ? 2 : 0
    SnapshotTiming.record {
      $0.heightChanged = heightChangedSinceSettle
      $0.needsLayout = needsLayout
      $0.needsLayoutViews = needsLayoutViews
      $0.captureWaitFrames = waitFrames
    }
    guard waitFrames > 0 else {
      capture()
      return
    }
    window.layoutIfNeeded()
    DisplayFrameWait.wait(frames: waitFrames) {
      SnapshotTiming.record {
        $0.needsLayoutAfterWait = layoutViews.contains { entry in entry.view?.layer.needsLayout() == true }
      }
      capture()
    }
  }

  private static func takeSnapshot(
    layout: PreviewLayout,
    renderingMode: EmergeRenderingMode?,
    window: UIWindow,
    rootVC: UIViewController,
    targetView: UIView,
    afterScreenUpdates: Bool,
    captureBlockStart: Double,
    maxSize: Double = 1_000_000,
    maxTotalPixels: Double = 40_000_000) -> Result<UIImage, RenderingError>
  {
    if renderingMode == EmergeRenderingMode.window {
      let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
      let renderStart = SnapshotTiming.now()
      SnapshotTiming.record { $0.captureWaitMs = (renderStart - captureBlockStart) * 1000 }
      let screenshot = renderer.image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let renderEnd = SnapshotTiming.now()
      SnapshotTiming.record {
        $0.renderImageStart = SnapshotTiming.ms(renderStart)
        $0.renderImageEnd = SnapshotTiming.ms(renderEnd)
        $0.renderImageMs = (renderEnd - renderStart) * 1000
        $0.renderPath = "window.drawHierarchy"
        $0.imageSize = [Double(window.bounds.width), Double(window.bounds.height)]
      }
      return .success(screenshot)
    }

    let view = targetView
    let drawCode: (CGContext) -> Void

    CATransaction.commit()

    let targetSize: CGSize
    var success = false
    switch layout {
    case .fixed(width: let width, height: let height):
      targetSize = CGSize(width: width, height: height)
      drawCode = { ctx in
        success = view.render(size: targetSize, mode: renderingMode, context: ctx, afterScreenUpdates: afterScreenUpdates)
      }
    case .sizeThatFits:
      targetSize = view.bounds.size
      drawCode = { ctx in
        success = view.render(size: targetSize, mode: renderingMode, context: ctx, afterScreenUpdates: afterScreenUpdates)
      }
    case .device:
      fallthrough
    default:
      let viewSize = view.bounds.size

      targetSize = CGSize(width: UIScreen.main.bounds.size.width, height: max(viewSize.height, UIScreen.main.bounds.size.height))
      drawCode = { ctx in
        success = rootVC.view.render(size: targetSize, mode: renderingMode, context: ctx, afterScreenUpdates: afterScreenUpdates)
      }
    }
    let scale = Double(UIScreen.main.scale)
    let totalPixels = Double(targetSize.width) * scale * Double(targetSize.height) * scale
    if targetSize.height > maxSize || targetSize.width > maxSize || totalPixels > maxTotalPixels {
      return .failure(RenderingError.maxSize(targetSize))
    }
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderStart = SnapshotTiming.now()
    SnapshotTiming.record { $0.captureWaitMs = (renderStart - captureBlockStart) * 1000 }
    let image = renderer.image { context in
      drawCode(context.cgContext)
    }
    let renderEnd = SnapshotTiming.now()
    SnapshotTiming.record {
      $0.renderImageStart = SnapshotTiming.ms(renderStart)
      $0.renderImageEnd = SnapshotTiming.ms(renderEnd)
      $0.renderImageMs = (renderEnd - renderStart) * 1000
      $0.imageSize = [Double(targetSize.width), Double(targetSize.height)]
    }
    if !success {
      return .failure(RenderingError.failedRendering(targetSize))
    }
    return .success(image)
  }
}

extension CGSize {
  var requiresCoreAnimationSnapshot: Bool {
    height >= UIScreen.main.bounds.size.height * 2
  }
}

extension UIView {
  func render(size: CGSize, mode: EmergeRenderingMode?, context: CGContext, afterScreenUpdates: Bool = true) -> Bool {
    switch mode {
    case .coreAnimation:
      SnapshotTiming.record { $0.renderPath = "layer.render" }
      layer.layerForSnapshot.render(in: context)
      return true
    case .uiView:
      return drawHierarchyForSnapshot(size: size, context: context, afterScreenUpdates: afterScreenUpdates)
    case .window, .none:
      if !size.requiresCoreAnimationSnapshot {
        return drawHierarchyForSnapshot(size: size, context: context, afterScreenUpdates: afterScreenUpdates)
      } else {
        SnapshotTiming.record { $0.renderPath = "layer.render" }
        layer.layerForSnapshot.render(in: context)
        return true
      }
    }
  }

  private func drawHierarchyForSnapshot(size: CGSize, context: CGContext, afterScreenUpdates: Bool) -> Bool {
    SnapshotTiming.record {
      $0.renderPath = "drawHierarchy"
      $0.afterScreenUpdates = afterScreenUpdates
    }
    let rect = CGRect(origin: .zero, size: size)
    var drew = drawHierarchy(in: rect, afterScreenUpdates: afterScreenUpdates)
    if !drew && !afterScreenUpdates {
      // The draw without a screen update failed. Clear anything it drew and retry with one, so a
      // failure never becomes a blank or partial image.
      context.clear(rect)
      drew = drawHierarchy(in: rect, afterScreenUpdates: true)
      SnapshotTiming.record { $0.retriedWithScreenUpdates = true }
    }
    SnapshotTiming.record { $0.drawHierarchySucceeded = drew }
    return drew
  }
}

extension CALayer {

  var layerForSnapshot: Self {
    guard !hasMapView else {
      return self
    }

    return presentation() ?? self
  }

  var hasMapView: Bool {
    if type(of: self).description() == "VKMapView" {
      return true
    }
    for s in sublayers ?? [] {
      if s.hasMapView {
        return true
      }
    }
    return false
  }
}

/// Calls back on the main queue after `frames` display link callbacks, or after `limit` if the
/// display link doesn't fire, whichever comes first.
private final class DisplayFrameWait: NSObject {
  private var displayLink: CADisplayLink?
  private var remainingFrames: Int
  private var completion: (() -> Void)?

  static func wait(frames: Int, limit: TimeInterval = 1, completion: @escaping () -> Void) {
    // The display link retains the instance until it finishes.
    let waiter = DisplayFrameWait(frames: frames, completion: completion)
    let displayLink = CADisplayLink(target: waiter, selector: #selector(frame))
    waiter.displayLink = displayLink
    displayLink.add(to: .main, forMode: .common)

    DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak waiter] in
      guard let waiter, waiter.completion != nil else { return }
      NSLog("SnapshotPreviews: display link didn't fire %ld frames within %.2fs before capture", frames, limit)
      waiter.finish()
    }
  }

  private init(frames: Int, completion: @escaping () -> Void) {
    remainingFrames = frames
    self.completion = completion
  }

  @objc private func frame() {
    remainingFrames -= 1
    if remainingFrames <= 0 {
      finish()
    }
  }

  private func finish() {
    displayLink?.invalidate()
    displayLink = nil
    guard let completion else { return }
    self.completion = nil
    // Finish outside the display link callout.
    DispatchQueue.main.async(execute: completion)
  }
}
#endif
