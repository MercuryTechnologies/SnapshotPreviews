//
//  ScrollExpansion.swift
//
//
//  Created by Noah Martin on 8/22/24.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

protocol ContentHeightProviding {
  var contentHeight: CGFloat { get }

  var visibleContentHeight: CGFloat { get }
}

protocol FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? { get }
}

#if !os(watchOS)
protocol ScrollExpansionProviding: AnyObject, FirstScrollViewProviding {
  var previousHeight: CGFloat? { get set }
  var heightAnchor: NSLayoutConstraint? { get }
  var supportsExpansion: Bool { get }
}

/// One step of the scroll-view expansion loop.
enum ExpansionStep: Equatable {
  /// The scroll view's content fits (or can't be made to fit); capture as-is.
  case complete
  /// Grow the height constraint by this many points and lay out again.
  case grow(by: CGFloat)
}

extension ScrollExpansionProviding {
  /// Decides the next expansion step without applying it, so callers can choose to apply the
  /// height change synchronously (AppKit) or on the next run-loop turn (UIKit).
  func nextExpansionStep() -> ExpansionStep {
    // If heightAnchor isn't set, this was a fixed size and we don't expand the scroll view
    guard heightAnchor != nil else {
      return .complete
    }

    guard let scrollView = firstScrollView, supportsExpansion else {
      return .complete
    }

    let diff = Int(scrollView.contentHeight - scrollView.visibleContentHeight)
    guard abs(diff) > 0, previousHeight != nil || diff > 0 else {
      return .complete
    }

    if let previousHeight {
      // Check if expansion isn't working and we should give up.
      // Could happen if the view is constrained to not grow, such as a half sheet
      guard abs(previousHeight - scrollView.visibleContentHeight) >= 1 else {
        return .complete
      }
    }
    previousHeight = scrollView.visibleContentHeight
    return .grow(by: CGFloat(diff))
  }

  /// Applies `nextExpansionStep()` synchronously. Used by AppKit, where the layout pass is
  /// not re-entered from inside `layout()`.
  func updateHeight(_ complete: (() -> Void)) {
    switch nextExpansionStep() {
    case .complete:
      complete()
    case let .grow(diff):
      heightAnchor?.constant += diff
    }
  }
}
#endif

#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
extension UIScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    contentSize.height
  }

  var visibleContentHeight: CGFloat {
    frame.height - (adjustedContentInset.top + adjustedContentInset.bottom)
  }
}

extension UIView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      // Don’t expand UITextView, it can cause flakes
      guard !(subview is UITextView) else {
        continue
      }

      subviews.append(contentsOf: subview.subviews)
      if let scrollView = subview as? UIScrollView {
        return scrollView
      }
    }
    return nil
  }
}

extension UIViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view?.firstScrollView
  }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension NSScrollView: ContentHeightProviding {

  var contentHeight: CGFloat {
    documentView?.frame.size.height ?? 0
  }

  var visibleContentHeight: CGFloat {
    frame.height - (contentInsets.top + contentInsets.bottom)
  }
}

extension NSView: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    var subviews = subviews
    while !subviews.isEmpty {
      let subview = subviews.removeFirst()
      if let scrollView = subview as? NSScrollView {
        // Don’t expand NSTextView, it can cause flakes
        guard !(scrollView.documentView is NSTextView) else {
          continue
        }

        return scrollView
      }
      subviews.append(contentsOf: subview.subviews)
    }
    return nil
  }
}

extension NSViewController: FirstScrollViewProviding {
  var firstScrollView: ContentHeightProviding? {
    view.firstScrollView
  }
}
#endif
