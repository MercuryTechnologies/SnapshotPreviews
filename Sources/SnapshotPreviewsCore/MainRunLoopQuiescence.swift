//
//  MainRunLoopQuiescence.swift
//
//
//  Created by Kyle Bashour on 10/14/26.
//

import Foundation

/// Calls back once the preview's Swift concurrency work has finished: the main run loop has gone
/// to sleep `quietIterations` times in a row without running a task job in between. Gives up after
/// `limit`, for previews that never stop working.
///
/// Every task job is moved to the main executor (see `TaskJobCounter`), so when the main run loop
/// is about to sleep with no jobs since the last time, no task can be running elsewhere. The
/// observer runs after SwiftUI's update and Core Animation's commit, so any state a job changed
/// has been rendered, and any `.task` that rendering started has been counted.
final class MainRunLoopQuiescence {
  private var observer: CFRunLoopObserver?
  private var lastJobCount = TaskJobCounter.count
  private var quietIterations = 0

  /// Set by `EMERGE_SNAPSHOT_SETTLE_ON_TASKS`.
  static let isEnabled = ProcessInfo.processInfo.environment["EMERGE_SNAPSHOT_SETTLE_ON_TASKS"] == "1"

  /// Runs the task jobs queued so far, such as loads a view model starts in its initializer, so
  /// they finish before the first render as they would have on the global executor.
  static func drainQueuedJobs() {
    guard isEnabled else { return }
    TaskJobCounter.install()
    var quietPasses = 0
    while quietPasses < 2 {
      let jobCount = TaskJobCounter.count
      CFRunLoopRunInMode(.defaultMode, 0, false)
      quietPasses = TaskJobCounter.count == jobCount ? quietPasses + 1 : 0
    }
  }

  static func wait(quietIterations: Int, limit: TimeInterval, completion: @escaping () -> Void) {
    TaskJobCounter.install()
    let quiescence = MainRunLoopQuiescence()
    quiescence.start(quietIterations: quietIterations, limit: limit) {
      // Keep the instance alive until it finishes.
      _ = quiescence
      completion()
    }
  }

  private func start(quietIterations required: Int, limit: TimeInterval, completion: @escaping () -> Void) {
    var finished = false
    let finish = { [weak self] in
      guard !finished else { return }
      finished = true
      if let observer = self?.observer {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      }
      completion()
    }

    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
      guard let self else { return }
      let jobCount = TaskJobCounter.count
      quietIterations = jobCount == lastJobCount ? quietIterations + 1 : 0
      lastJobCount = jobCount
      if quietIterations >= required {
        // Finish outside the observer callout.
        DispatchQueue.main.async(execute: finish)
      }
    }
    self.observer = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

    DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: finish)
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
