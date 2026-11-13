import Foundation
import Testing

/// Keep a missing cache/download from turning the CI parity job into a green skipped suite.
@Test
func ciRequiresBothPinnedParityCheckpoints() throws {
    guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
    _ = try RealtimeReference.shared.get()
    _ = try OfflineReference.shared.get()
}
