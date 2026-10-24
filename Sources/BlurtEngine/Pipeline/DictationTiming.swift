import Foundation
import Synchronization

/// One utterance's monotonic timeline. Callbacks only update memory; the final
/// snapshot is handed to the developer log after all tracked work has settled.
final class DictationTiming: Sendable {
  @TaskLocal static var current: DictationTiming?

  enum Event: String, Sendable {
    case startShortcut = "start_shortcut"
    case captureRequested = "capture_requested"
    case recorderStartRequested = "recorder_start_requested"
    case firstAudioCaptured = "first_audio_captured"
    case recordingReady = "recording_ready"
    case httpRequestStarted = "http_request_started"
    case stopShortcut = "stop_shortcut"
    case captureStopRequested = "capture_stop_requested"
    case recordingStopped = "recording_stopped"
    case responseReceived = "response_received"
    case jsonDecodeStarted = "json_decode_started"
    case jsonDecodeCompleted = "json_decode_completed"
  }

  enum Outcome: String, Codable, Sendable {
    case empty, failed, cancelled, pasted, copied, handedBack, abandoned
  }

  struct Entry: Codable, Sendable {
    let id: UUID
    let ts: String
    let outcome: Outcome
    let eventsMs: [String: Double]
    let durationsMs: [String: Double]

    enum CodingKeys: String, CodingKey {
      case id, ts, outcome
      case eventsMs = "events_ms"
      case durationsMs = "durations_ms"
    }
  }

  private struct State {
    var events: [String: Double] = [:]
    var pendingWork = 0
    var outcome: Outcome?
    var written = false
  }

  private let id = UUID()
  private let start: ContinuousClock.Instant
  private let timestamp: String
  private let now: @Sendable () -> ContinuousClock.Instant
  private let write: @Sendable (Entry) -> Void
  private let state = Mutex(State())

  init(
    startedAt: ContinuousClock.Instant? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    date: Date = Date(), write: @escaping @Sendable (Entry) -> Void
  ) {
    let observed = now()
    let start = startedAt ?? observed
    self.start = start
    self.now = now
    self.write = write
    // The command may have queued behind mic bring-up: keep the wall-clock
    // anchor at the original event, just like the monotonic offsets.
    timestamp = date.addingTimeInterval(-start.duration(to: observed).milliseconds / 1000)
      .formatted(DictationLog.timestampFormat)
    if startedAt != nil { record(.startShortcut, at: start) }
  }

  func record(_ event: Event, at instant: ContinuousClock.Instant? = nil) {
    let offset = start.duration(to: instant ?? now()).milliseconds
    state.withLock {
      guard !$0.written, $0.events[event.rawValue] == nil else { return }
      $0.events[event.rawValue] = offset
    }
  }

  /// Retain before spawning work, so a fast cancellation cannot finalize before
  /// the new task even gets its first turn. Each owner releases in a defer.
  func beginWork() {
    state.withLock { $0.pendingWork += 1 }
  }

  func endWork() {
    let entry = state.withLock {
      $0.pendingWork -= 1
      return takeEntryIfSettled(&$0)
    }
    if let entry { write(entry) }
  }

  func finish(outcome: Outcome) {
    let entry = state.withLock {
      if $0.outcome == nil { $0.outcome = outcome }
      return takeEntryIfSettled(&$0)
    }
    if let entry { write(entry) }
  }

  private func takeEntryIfSettled(_ state: inout State) -> Entry? {
    guard let outcome = state.outcome, state.pendingWork == 0, !state.written else { return nil }
    state.written = true
    return Entry(
      id: id, ts: timestamp, outcome: outcome,
      eventsMs: state.events, durationsMs: Self.durations(events: state.events))
  }

  private static func durations(events: [String: Double]) -> [String: Double] {
    let intervals: [String: (Event, Event)] = [
      "startup": (.startShortcut, .firstAudioCaptured),
      "recorder_bring_up": (.recorderStartRequested, .firstAudioCaptured),
      "first_buffer_to_ready": (.firstAudioCaptured, .recordingReady),
      "capture_to_request": (.firstAudioCaptured, .httpRequestStarted),
      "stop": (.stopShortcut, .recordingStopped),
      "stop_to_response": (.recordingStopped, .responseReceived),
      "json_decode": (.jsonDecodeStarted, .jsonDecodeCompleted),
      "stop_to_decoded_result": (.stopShortcut, .jsonDecodeCompleted),
    ]
    var result: [String: Double] = [:]
    for (name, (from, to)) in intervals {
      if let start = events[from.rawValue], let end = events[to.rawValue] {
        result[name] = end - start
      }
    }
    return result
  }
}
