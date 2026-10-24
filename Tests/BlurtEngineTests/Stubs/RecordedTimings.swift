import Foundation
import Synchronization

@testable import BlurtEngine

/// In-memory timing sink: session and transport tests never write real logs.
final class RecordedTimings: Sendable {
  private let stored = Mutex<[DictationTiming.Entry]>([])

  var entries: [DictationTiming.Entry] { stored.withLock { $0 } }

  func record(_ entry: DictationTiming.Entry) {
    stored.withLock { $0.append(entry) }
  }

  func trace(
    at start: ContinuousClock.Instant? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, date: Date = Date()
  ) -> DictationTiming {
    DictationTiming(startedAt: start, now: now, date: date) { self.record($0) }
  }

  func seams(
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
  ) -> DictationSession.Seams {
    var seams = testSeams()
    seams.makeTiming = { self.trace(at: $0, now: now) }
    return seams
  }

  func waitForEntries(_ count: Int) async {
    while entries.count < count { await Task.yield() }
  }
}
