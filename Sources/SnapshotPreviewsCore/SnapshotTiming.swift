//
//  SnapshotTiming.swift
//
//
//  Created by Kyle Bashour on 10/15/26.
//

import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import UIKit
#endif

/// Temporary instrumentation: records per-phase timings of each snapshot and appends one JSON
/// line per shot to the file at `EMERGE_SNAPSHOT_TIMING_LOG`. Does nothing when that is unset.
/// Every call happens on the main thread.
public enum SnapshotTiming {
  struct Frame: Encodable {
    /// When the callback ran, ms since shot start.
    var t: Double
    /// `CADisplayLink.timestamp`, ms since shot start.
    var timestamp: Double
    /// `CADisplayLink.targetTimestamp`, ms since shot start.
    var targetTimestamp: Double
    /// `CADisplayLink.duration`, ms.
    var duration: Double
    var jobsChanged: Bool
  }

  struct Shot: Encodable {
    var kind = "shot"
    var pid = Int(ProcessInfo.processInfo.processIdentifier)
    var testName: String
    var typeName: String
    var previewName: String?
    var previewIndex: Int

    /// `TaskJobCounter.count` at the end of the previous shot in this process, at the start of this
    /// one (after XCTest's `setUp`), and around this shot's drain.
    var jobsAtPreviousTestEnd: Int?
    var jobsAtTestStart: Int?
    var jobsAtDrainStart: Int?
    var jobsAtDrainEnd: Int?

    var performRenderStart: Double?
    var previewViewEnd: Double?
    var drainEnd: Double?
    var drainPasses: Int?
    var makeExpandingViewEnd: Double?
    var settleWaitStart: Double?
    var settleFrames: [Frame] = []
    var settleFinish: Double?
    var settleHitLimit: Bool?
    var settleEnd: Double?
    var layoutPassesBeforeSettle = 0
    var heightPasses: [Double] = []
    var runCallback: Double?
    var runCallbackError: Bool?
    var captureStart: Double?
    var renderImageStart: Double?
    var renderImageEnd: Double?
    var renderImageMs: Double?
    var renderPath: String?
    var drawHierarchySucceeded: Bool?
    var afterScreenUpdates: Bool?
    /// Why capture laid out and waited for display frames first: the height constraint changed
    /// after `settle()`, or a layout was pending at the start of capture.
    var heightChanged: Bool?
    var needsLayout: Bool?
    /// Which of `target`, `root`, `windowRoot` and `window` had a layout pending.
    var needsLayoutViews: [String]?
    /// Display frames waited after laying out, before drawing (0 or 2).
    var captureWaitFrames: Int?
    /// Whether a layout was pending again after that wait.
    var needsLayoutAfterWait: Bool?
    /// From the start of the capture block to just before `renderer.image`.
    var captureWaitMs: Double?
    /// Whether `settle()` re-measuring changed the height constraint the settle wait rendered with.
    var settleRemeasureChangedHeight: Bool?
    var retriedWithScreenUpdates: Bool?
    var imageSize: [Double]?
    var completion: Double?
    var testPreviewEnd: Double?
  }

  struct ProcessLine: Encodable {
    var kind = "process"
    var pid = Int(ProcessInfo.processInfo.processIdentifier)
    var maximumFramesPerSecond: Int
    var scale: Double
    var bounds: [Double]
    var simulatorDeviceName: String?
    var simulatorUDID: String?
    var settleOnTasks: String?
    var renderDelay: String?
  }

  private static let fileDescriptor: Int32? = {
    guard let path = ProcessInfo.processInfo.environment["EMERGE_SNAPSHOT_TIMING_LOG"], !path.isEmpty else {
      return nil
    }
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd < 0 {
      NSLog("SnapshotTiming: could not open %@ (errno %d)", path, errno)
      return nil
    }
    return fd
  }()

  private static var wroteProcessLine = false
  private static var start: Double = 0
  private static var current: Shot?
  private static var previousTestEndJobs: Int?

  static func now() -> Double {
    #if canImport(QuartzCore)
    return CACurrentMediaTime()
    #else
    return ProcessInfo.processInfo.systemUptime
    #endif
  }

  /// Milliseconds since the shot started, for a time on the `now()` clock.
  static func ms(_ time: Double) -> Double {
    ((time - start) * 1_000_000).rounded() / 1000
  }

  static func ms() -> Double {
    ms(now())
  }

  private static var taskJobCount: Int? {
    #if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
    return TaskJobCounter.count
    #else
    return nil
    #endif
  }

  static func record(_ update: (inout Shot) -> Void) {
    guard current != nil else { return }
    update(&current!)
  }

  @MainActor
  public static func beginShot(testName: String, typeName: String, previewName: String?, previewIndex: Int) {
    guard fileDescriptor != nil else { return }
    writeProcessLineIfNeeded()
    #if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
    // Count jobs from the first shot on, not just from its drain. Only when settling on tasks, since
    // installing also moves global executor jobs to the main thread.
    if MainRunLoopQuiescence.isEnabled {
      TaskJobCounter.install()
    }
    #endif
    start = now()
    current = Shot(testName: testName, typeName: typeName, previewName: previewName, previewIndex: previewIndex)
    current?.jobsAtPreviousTestEnd = previousTestEndJobs
    current?.jobsAtTestStart = taskJobCount
  }

  public static func recordCompletion() {
    record { $0.completion = ms() }
  }

  public static func endShot() {
    guard var shot = current else { return }
    shot.testPreviewEnd = ms()
    previousTestEndJobs = taskJobCount
    current = nil
    write(shot)
  }

  @MainActor
  private static func writeProcessLineIfNeeded() {
    guard !wroteProcessLine else { return }
    wroteProcessLine = true
    #if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
    let environment = ProcessInfo.processInfo.environment
    let screen = UIScreen.main
    let process = ProcessLine(
      maximumFramesPerSecond: screen.maximumFramesPerSecond,
      scale: Double(screen.scale),
      bounds: [Double(screen.bounds.width), Double(screen.bounds.height)],
      simulatorDeviceName: environment["SIMULATOR_DEVICE_NAME"],
      simulatorUDID: environment["SIMULATOR_UDID"],
      settleOnTasks: environment["EMERGE_SNAPSHOT_SETTLE_ON_TASKS"],
      renderDelay: environment["EMERGE_SNAPSHOT_RENDER_DELAY"])
    write(process)
    #endif
  }

  private static func write<T: Encodable>(_ value: T) {
    guard let fd = fileDescriptor else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(value) else { return }
    data.append(0x0A)
    // One write per line, so lines from processes sharing the file don't interleave.
    data.withUnsafeBytes { buffer in
      _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
    }
  }
}
