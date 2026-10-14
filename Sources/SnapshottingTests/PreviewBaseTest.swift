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

/// One slice of the discovered previews, for running them across several processes or machines.
///
/// Rendering a preview can leave process-wide state that later previews pick up, so each shard
/// takes a contiguous run of the tests in execution order. That way every preview follows the same
/// previews it would in a single serial run, except the first test of each shard.
public struct SnapshotShard {
  public let index: Int
  public let count: Int

  public init(index: Int, count: Int) {
    precondition(count > 0 && (0..<count).contains(index), "Invalid shard \(index) of \(count)")
    self.index = index
    self.count = count
  }

  /// Positions this shard covers among `total` tests sorted in execution order.
  func positions(total: Int) -> Range<Int> {
    (total * index / count)..<(total * (index + 1) / count)
  }
}

// Every class rebuilds this same list during discovery and test selectors index into it, so
// shard subclasses running in one process all resolve to the right previews.
var previews: [DiscoveredPreviewAndIndex] = []

// The test selector of every discovered preview, including ones other shards test, keyed by
// `previewKey(typeName:index:)`. Selectors sort in execution order.
var testSelectorNames: [String: String] = [:]

func previewKey(typeName: String, index: Int) -> String {
  "\(typeName)#\(index)"
}

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
      let discoveredPreviews = discoverPreviews()
      previews = []
      testSelectorNames = [:]
      var i = 0

      let currentDeviceName = SnapshotPreviewDestination.currentDeviceName()

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

          let orientation = discoveredPreview.orientations[j]
          testSelectorNames[previewKey(typeName: typeName, index: j)] = "\(orientation)-\(displayName)-\(j)-\(i)"
          previews.append(DiscoveredPreviewAndIndex(preview: discoveredPreview, index: j))
          i += 1
        }
      }

      var dynamicTestSelectors = testSelectorNames.values.sorted()
      if let shard = snapshotShard() {
        dynamicTestSelectors = Array(dynamicTestSelectors[shard.positions(total: dynamicTestSelectors.count)])
      }

      for testSelectorName in dynamicTestSelectors {
        let sel = NSSelectorFromString(testSelectorName)
        let rawPtr = unsafeBitCast(dynamicTestMethod, to: UnsafeRawPointer.self)
        let success = class_addMethod(self, sel, OpaquePointer(rawPtr), "v@:")
        if !success {
          print("Error adding method \(testSelectorName)")
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
