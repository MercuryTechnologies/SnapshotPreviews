//
//  MainRunLoopQuiescence.swift
//
//
//  Created by Kyle Bashour on 10/14/26.
//

import Foundation
#if canImport(UIKit) && !os(visionOS) && !os(watchOS) && !os(tvOS)
import UIKit

/// Calls back once the preview's Swift concurrency work has finished and what it changed is on
/// screen: `quietFrames` display frames in a row have gone by without running a task job. Gives
/// up after `limit`, for previews that never stop working.
///
/// Every task job is moved to the main executor (see `TaskJobCounter`), so no task can be running
/// elsewhere unseen. Counting frames rather than run loop turns matters because UIKit and SwiftUI
/// apply state changes once per frame: an `@Published` value set in `onAppear` only shows up in
/// the next frame's update, which also starts any `.task` the new content adds.
final class MainRunLoopQuiescence: NSObject {
  private var displayLink: CADisplayLink?
  private var lastJobCount = TaskJobCounter.count
  private var quietFrames = 0
  private let requiredQuietFrames: Int
  private var completion: (() -> Void)?

  /// Set by `EMERGE_SNAPSHOT_SETTLE_ON_TASKS`.
  static let isEnabled = ProcessInfo.processInfo.environment["EMERGE_SNAPSHOT_SETTLE_ON_TASKS"] == "1"

  /// Runs the task jobs queued so far, such as loads a view model starts in its initializer, so
  /// they finish before the first render as they would have on the global executor.
  static func drainQueuedJobs() {
    guard isEnabled else { return }
    TaskJobCounter.install()
    var quietPasses = 0
    var passes = 0
    while quietPasses < 2 {
      let jobCount = TaskJobCounter.count
      CFRunLoopRunInMode(.defaultMode, 0, false)
      passes += 1
      quietPasses = TaskJobCounter.count == jobCount ? quietPasses + 1 : 0
    }
    SnapshotTiming.record { $0.drainPasses = passes }
  }

  static func wait(quietFrames: Int, limit: TimeInterval, completion: @escaping () -> Void) {
    TaskJobCounter.install()
    // The display link retains the instance until it finishes.
    let quiescence = MainRunLoopQuiescence(quietFrames: quietFrames, completion: completion)
    let displayLink = CADisplayLink(target: quiescence, selector: #selector(frame))
    quiescence.displayLink = displayLink
    displayLink.add(to: .main, forMode: .common)

    DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak quiescence] in
      guard let quiescence, quiescence.completion != nil else { return }
      SnapshotTiming.record { $0.settleHitLimit = true }
      NSLog("SnapshotPreviews: settled at the %.2fs limit before its work finished", limit)
      quiescence.finish()
    }
  }

  private init(quietFrames: Int, completion: @escaping () -> Void) {
    requiredQuietFrames = quietFrames
    self.completion = completion
  }

  @objc private func frame() {
    let jobCount = TaskJobCounter.count
    if let displayLink {
      let time = SnapshotTiming.now()
      let jobsChanged = jobCount != lastJobCount
      SnapshotTiming.record {
        $0.settleFrames.append(SnapshotTiming.Frame(
          t: SnapshotTiming.ms(time),
          timestamp: SnapshotTiming.ms(displayLink.timestamp),
          targetTimestamp: SnapshotTiming.ms(displayLink.targetTimestamp),
          duration: displayLink.duration * 1000,
          jobsChanged: jobsChanged))
      }
    }
    quietFrames = jobCount == lastJobCount ? quietFrames + 1 : 0
    lastJobCount = jobCount
    if quietFrames >= requiredQuietFrames {
      finish()
    }
  }

  private func finish() {
    displayLink?.invalidate()
    displayLink = nil
    guard let completion else { return }
    SnapshotTiming.record {
      $0.settleFinish = SnapshotTiming.ms()
      if $0.settleHitLimit == nil {
        $0.settleHitLimit = false
      }
    }
    self.completion = nil
    // Finish outside the display link callout.
    DispatchQueue.main.async(execute: completion)
  }
}

/// Counts Swift concurrency jobs run on the main executor, and moves jobs bound for the global
/// executor there too so they are counted and can't run unseen on another thread. This is the
/// same hook swift-concurrency-extras' `withMainSerialExecutor` uses.
enum TaskJobCounter {
  fileprivate typealias Original = @convention(thin) (UnownedJob) -> Void
  fileprivate typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

  private static let lock = NSLock()
  private static var _count = 0
  private static var installed = false

  static var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return _count
  }

  fileprivate static func increment() {
    lock.lock()
    _count += 1
    lock.unlock()
  }

  static func install() {
    guard !installed else { return }
    installed = true
    guard let handle = dlopen(nil, 0),
          let globalHook = dlsym(handle, "swift_task_enqueueGlobal_hook"),
          let mainHook = dlsym(handle, "swift_task_enqueueMainExecutor_hook") else {
      return
    }
    globalHook.assumingMemoryBound(to: Hook?.self).pointee = enqueueOnMain
    mainHook.assumingMemoryBound(to: Hook?.self).pointee = countAndEnqueue
  }
}

private func enqueueOnMain(_ job: UnownedJob, _ original: TaskJobCounter.Original) {
  MainActor.shared.enqueue(job)
}

private func countAndEnqueue(_ job: UnownedJob, _ original: TaskJobCounter.Original) {
  TaskJobCounter.increment()
  original(job)
}
#endif
