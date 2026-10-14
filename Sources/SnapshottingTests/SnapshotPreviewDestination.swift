import Foundation

struct SnapshotPreviewDestination {
  static func currentDeviceName(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    simulatorDeviceName(environment: environment) ?? environment["SIMULATOR_MODEL_IDENTIFIER"]
  }

  /// The simulator's device name, reporting parallel-testing clones ("Clone 1 of iPhone 16")
  /// as the device they were cloned from so metadata and device filters match serial runs.
  static func simulatorDeviceName(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    guard let name = environment["SIMULATOR_DEVICE_NAME"] else {
      return nil
    }
    guard let match = name.range(of: #"^Clone [0-9]+ of "#, options: .regularExpression) else {
      return name
    }
    return String(name[match.upperBound...])
  }
}
