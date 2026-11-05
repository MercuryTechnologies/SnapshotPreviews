import Foundation
import SwiftUI
@testable import SnapshotPreviewsCore
@testable import SnapshottingTests
import XCTest

@MainActor
final class AllSnapshotImageNamesTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AllSnapshotImageNamesTests-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  func testCurrentDestinationDeviceNamePrefersSimulatorDeviceName() {
    let deviceName = SnapshotPreviewDestination.currentDeviceName(
      environment: [
        "SIMULATOR_DEVICE_NAME": "iPhone 15",
        "SIMULATOR_MODEL_IDENTIFIER": "iPhone16,1",
      ]
    )

    XCTAssertEqual(deviceName, "iPhone 15")
  }

  func testCurrentDestinationDeviceNameStripsParallelTestingClonePrefix() {
    let deviceName = SnapshotPreviewDestination.currentDeviceName(
      environment: ["SIMULATOR_DEVICE_NAME": "Clone 12 of iPhone 15"]
    )

    XCTAssertEqual(deviceName, "iPhone 15")
  }

  func testShardsCoverEveryPositionContiguouslyAndInOrder() {
    for total in [0, 1, 5, 867] {
      let ranges = (0..<4).map { SnapshotShard(index: $0, count: 4).positions(total: total) }

      XCTAssertEqual(ranges.first?.lowerBound, 0)
      XCTAssertEqual(ranges.last?.upperBound, total)
      for (previous, next) in zip(ranges, ranges.dropFirst()) {
        XCTAssertEqual(previous.upperBound, next.lowerBound)
      }
    }
  }

  func testCurrentDestinationDeviceNameFallsBackToSimulatorModelIdentifier() {
    let deviceName = SnapshotPreviewDestination.currentDeviceName(
      environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone16,1"]
    )

    XCTAssertEqual(deviceName, "iPhone16,1")
  }

  func testDiscoveredPreviewDeviceFilterIncludesUndeclaredAndMatchingDevices() {
    let preview = DiscoveredPreview(
      typeName: "Module.TestView_Previews",
      displayName: "Test View",
      devices: ["", "iPhone 15", "iPhone 14"],
      orientations: ["portrait", "portrait", "portrait"],
      numberOfPreviews: 3
    )

    XCTAssertTrue(
      SnapshotPreviewDeviceFilter.shouldInclude(
        discoveredPreview: preview,
        index: 0,
        currentDestinationDeviceName: "iPhone 15"
      )
    )
    XCTAssertTrue(
      SnapshotPreviewDeviceFilter.shouldInclude(
        discoveredPreview: preview,
        index: 1,
        currentDestinationDeviceName: "iPhone 15"
      )
    )
    XCTAssertFalse(
      SnapshotPreviewDeviceFilter.shouldInclude(
        discoveredPreview: preview,
        index: 2,
        currentDestinationDeviceName: "iPhone 15"
      )
    )
  }

  func testWriterReplacesStaleOutputWithSortedDeduplicatedNames() throws {
    let outputURL = tempDir.appendingPathComponent("all-image-names.txt")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try "stale.png\n".write(to: outputURL, atomically: true, encoding: .utf8)

    let writer = try XCTUnwrap(
      AllSnapshotImageNamesWriter.createFromEnvironment(
        environment: [AllSnapshotImageNamesWriter.envKey: outputURL.path]
      )
    )

    writer.write(imageNames: ["Beta.png", "Alpha.png", "Beta.png"])

    XCTAssertEqual(try readAllSnapshotImageNamesFile(at: outputURL), "Alpha.png\nBeta.png\n")
  }

  func testWriterWritesEmptyFileWhenThereAreNoImageNames() throws {
    let outputURL = tempDir.appendingPathComponent("all-image-names.txt")
    let writer = AllSnapshotImageNamesWriter(outputURL: outputURL)

    writer.write(imageNames: [])

    XCTAssertEqual(try readAllSnapshotImageNamesFile(at: outputURL), "")
  }

  func testLogicalImageNamesAreSanitizedPngNamesAndPreserveDuplicateOrdinalsAfterDeviceFiltering() {
    let previewType = PreviewType(
      typeName: "TestModule.AllSnapshotImageNamesTestProvider",
      previewProvider: AllSnapshotImageNamesTestProvider.self
    )
    let resolver = SnapshotTest.FileNameResolver(previews: [previewType])

    let imageNames = SnapshotTest.logicalImageNames(
      previews: [previewType],
      fileNameResolver: resolver,
      environment: ["SIMULATOR_DEVICE_NAME": "iPhone 14"]
    )

    XCTAssertEqual(
      imageNames,
      [
        "All_Snapshot_Image_Names_Test_Provider_Duplicate_1.png",
        "All_Snapshot_Image_Names_Test_Provider_Other.png",
      ]
    )
  }

  func testLogicalImageNamesUsePreviewTypeDeviceWhenDestinationMatches() {
    let previewType = PreviewType(
      typeName: "TestModule.AllSnapshotImageNamesTestProvider",
      previewProvider: AllSnapshotImageNamesTestProvider.self
    )
    let resolver = SnapshotTest.FileNameResolver(previews: [previewType])

    let imageNames = SnapshotTest.logicalImageNames(
      previews: [previewType],
      fileNameResolver: resolver,
      environment: ["SIMULATOR_DEVICE_NAME": "iPhone 15"]
    )

    XCTAssertEqual(
      imageNames,
      [
        "All_Snapshot_Image_Names_Test_Provider_Duplicate_1.png",
        "All_Snapshot_Image_Names_Test_Provider_Duplicate_2.png",
        "All_Snapshot_Image_Names_Test_Provider_Other.png",
      ]
    )
  }

  private func readAllSnapshotImageNamesFile(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }
}

private struct AllSnapshotImageNamesTestProvider: PreviewProvider {
  static var previews: some View {
    Group {
      Text("One")
        .previewDisplayName("Duplicate")
      Text("Two")
        .previewDisplayName("Duplicate")
        .previewDevice("iPhone 15")
      Text("Three")
        .previewDisplayName("Other")
    }
  }
}

final class UnnamedPreviewMacroNameTests: XCTestCase {
  private let fileID = "MyApp/LoginView.swift"

  private func macro(line: Int, named name: String? = nil) -> PreviewType {
    let previews = name == nil ? UnnamedPreviewProvider._allPreviews : NamedPreviewProvider._allPreviews
    return PreviewType(
      typeName: "$s5MyApp9LoginViewV13Preview_\(line)fMf_15PreviewRegistryMc",
      fileID: fileID,
      line: line,
      previews: previews.map { Preview(preview: $0, type: UnnamedPreviewProvider.self) }
    )
  }

  private func imageNames(_ previews: [PreviewType]) -> [String] {
    let resolver = SnapshotTest.FileNameResolver(previews: previews)
    return SnapshotTest.logicalImageNames(previews: previews, fileNameResolver: resolver, environment: [:])
  }

  func testUnnamedMacrosAreNamedByOrderInFile() {
    XCTAssertEqual(
      imageNames([macro(line: 120), macro(line: 80), macro(line: 100, named: "Check")]),
      [
        "MyApp_LoginView.swift_Preview_2.png",
        "MyApp_LoginView.swift_Preview.png",
        "MyApp_LoginView.swift_Check.png",
      ]
    )
  }

  func testMovingUnnamedMacroKeepsItsName() {
    XCTAssertEqual(imageNames([macro(line: 403)]), imageNames([macro(line: 409)]))
  }

  func testResolverExposesDisplayNameForUnnamedMacro() {
    let preview = macro(line: 12)
    let resolver = SnapshotTest.FileNameResolver(previews: [preview])
    XCTAssertEqual(resolver.displayName(typeName: preview.typeName, previewIndex: 0), "Preview")
  }
}

private struct UnnamedPreviewProvider: PreviewProvider {
  static var previews: some View {
    Text("Unnamed")
  }
}

private struct NamedPreviewProvider: PreviewProvider {
  static var previews: some View {
    Text("Named")
      .previewDisplayName("Check")
  }
}
