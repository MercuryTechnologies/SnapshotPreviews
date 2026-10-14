//
//  PreviewBaseTest.swift
//
//
//  Created by Noah Martin on 8/9/24.
//

import Foundation
import XCTest

struct DiscoveredPreview {
  let typeName: String
  let displayName: String?
  let devices: [String]
  let orientations: [String]
  let numberOfPreviews: Int
}

struct DiscoveredPreviewAndIndex {
  let preview: DiscoveredPreview
  let index: Int
}

/// One slice of the discovered previews. Xcode's parallel testing distributes work by test
/// class, so splitting previews across several subclasses lets them run on simulator clones.
public struct SnapshotShard {
  public let index: Int
  public let count: Int

  public init(index: Int, count: Int) {
    precondition(count > 0 && (0..<count).contains(index), "Invalid shard \(index) of \(count)")
    self.index = index
    self.count = count
  }

  func contains(testIndex: Int) -> Bool {
    testIndex % count == index
  }
}

// Every class rebuilds this same list during discovery and test selectors index into it, so
// shard subclasses running in one process all resolve to the right previews.
var previews: [DiscoveredPreviewAndIndex] = []

@objc(EMGPreviewBaseTest)
open class PreviewBaseTest: XCTestCase {

  /// Returns the slice of previews this class should test, or nil to test all of them.
  open class func snapshotShard() -> SnapshotShard? {
    nil
  }

  static var signatureCreator: NSObject?

  @objc
  static func swizzle(_ signatureCreator: NSObject) {
    self.signatureCreator = signatureCreator
    let originalSelector = NSSelectorFromString("testInvocations")
    let swizzledSelector = #selector(swizzled_testInvocations)
    let originalMethod = class_getClassMethod(XCTestCase.self, originalSelector)
    let swizzledMethod = class_getClassMethod(PreviewBaseTest.self, swizzledSelector)
    guard let originalMethod, let swizzledMethod else {
      print("Method not found")
      return
    }

    let swizzledImp = method_getImplementation(swizzledMethod)
    let currentClass: AnyClass = object_getClass(PreviewBaseTest.self)!
    class_addMethod(currentClass, originalSelector, swizzledImp, method_getTypeEncoding(originalMethod))
  }

  @objc @MainActor
  static func swizzled_testInvocations() -> [AnyObject] {
    let className = NSStringFromClass(self)
    // Only support running this test if it’s a subclass outside of the SnapshottingTests module
    if className == "EMGPreviewBaseTest" || className.hasPrefix("SnapshottingTests.") {
      return []
    }

    let dynamicTestSelectors = addMethods().sorted()
    var invocations: [AnyObject] = []
    guard let signatureCreator else {
      return invocations
    }
    for testName in dynamicTestSelectors {
      let invocation = signatureCreator.perform(NSSelectorFromString("create:"), with: testName).takeRetainedValue() as! NSObject
      invocations.append(invocation)
    }
    return invocations
  }

    @MainActor
    class func addMethods() -> [String] {
      var dynamicTestSelectors: [String] = []
      let discoveredPreviews = discoverPreviews()
      previews = []
      var i = 0

      let currentDeviceName = SnapshotPreviewDestination.currentDeviceName()
      let shard = snapshotShard()

      for discoveredPreview in discoveredPreviews {
        let typeName = discoveredPreview.typeName
        let displayName = discoveredPreview.displayName ?? typeName
        let count = discoveredPreview.numberOfPreviews

        for j in 0..<count {
          if !SnapshotPreviewDeviceFilter.shouldInclude(
            discoveredPreview: discoveredPreview,
            index: j,
            currentDestinationDeviceName: currentDeviceName
          ) {
            continue
          }

          let preview = DiscoveredPreviewAndIndex(preview: discoveredPreview, index: j)
          previews.append(preview)

          if let shard, !shard.contains(testIndex: i) {
            i += 1
            continue
          }

          let orientation = discoveredPreview.orientations[j]
          let testSelectorName = "\(orientation)-\(displayName)-\(j)-\(i)"
          dynamicTestSelectors.append(testSelectorName)

          let sel = NSSelectorFromString(testSelectorName)
          let rawPtr = unsafeBitCast(dynamicTestMethod, to: UnsafeRawPointer.self)
          let success = class_addMethod(self, sel, OpaquePointer(rawPtr), "v@:")
          if !success {
            print("Error adding method \(testSelectorName)")
          }
          i += 1
        }
      }

      return dynamicTestSelectors
    }

    @MainActor
    func testPreview(_ preview: DiscoveredPreviewAndIndex) {
      print("This should be implemented by a subclass")
    }

    @MainActor
    class func discoverPreviews() -> [DiscoveredPreview] {
      print("This should be implemented by a subclass")
      return []
    }
}

@MainActor
private let dynamicTestMethod: @convention(c) (AnyObject, Selector) -> Void = { (self, _cmd) in
    let selectorName = NSStringFromSelector(_cmd)
    let testNumber = selectorName.components(separatedBy: "-").last ?? "0"
    let index = Int(testNumber) ?? 0
    let preview = previews[index]
    if let selfAsBase = self as? PreviewBaseTest {
        selfAsBase.testPreview(preview)
    }
}
