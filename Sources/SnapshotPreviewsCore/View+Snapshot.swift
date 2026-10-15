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
        SnapshotTiming.record { $0.captureStart = SnapshotTiming.ms() }
        if let a11yWrapper, let accessibilityEnabled, accessibilityEnabled, !async {
          let a11yView = a11yWrapper(controller, window, layout)
          let result = Self.takeSnapshot(layout: .sizeThatFits, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: a11yView)
          a11yView.removeFromSuperview()
          completion(SnapshotResult(image: result.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext, groupOverride: groupOverride, canvasTheme: canvasTheme))
        } else {
          let imageResult = Self.takeSnapshot(layout: layout, renderingMode: renderingMode, window: window, rootVC: containerVC, targetView: controller.view, heightChangedSinceSettle: controller.heightChangedSinceSettle)
          completion(SnapshotResult(image: imageResult.mapError { $0 }, precision: precision, accessibilityEnabled: accessibilityEnabled, colorScheme: _colorScheme, appStoreSnapshot: appStoreSnapshot, tags: tags, additionalContext: additionalContext, groupOverride: groupOverride, canvasTheme: canvasTheme))
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

  private static func takeSnapshot(
    layout: PreviewLayout,
    renderingMode: EmergeRenderingMode?,
    window: UIWindow,
    rootVC: UIViewController,
    targetView: UIView,
    heightChangedSinceSettle: Bool? = nil,
    maxSize: Double = 1_000_000,
    maxTotalPixels: Double = 40_000_000) -> Result<UIImage, RenderingError>
  {
    if renderingMode == EmergeRenderingMode.window {
      let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
      let renderStart = SnapshotTiming.now()
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

    // The settle wait ended on quiet display frames, so the screen is normally current and forcing
    // another screen update only costs time. Force one if the height changed since, or a layout is
    // pending. Checked before the commit below, which would run that layout but not render it.
    // Unknown (`nil`, e.g. a view the accessibility wrapper just added) always forces one.
    let layoutViews: [UIView?] = [targetView, rootVC.view, window.rootViewController?.view, window]
    let needsLayout = layoutViews.contains { $0?.layer.needsLayout() == true }
    let afterScreenUpdates = heightChangedSinceSettle != false || needsLayout
    SnapshotTiming.record {
      $0.heightChanged = heightChangedSinceSettle
      $0.needsLayout = needsLayout
    }

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
#endif
