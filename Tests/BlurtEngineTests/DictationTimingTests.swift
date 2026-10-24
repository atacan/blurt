import Foundation
import Testing

@testable import BlurtEngine

@Suite("Dictation timing trace", .timeLimit(.minutes(1)))
struct DictationTimingTests {
  @Test("one clock yields event offsets and the complete latency breakdown")
  func timelineArithmetic() throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start, now: { start }, date: Date(timeIntervalSince1970: 1000))
    let events: [(DictationTiming.Event, Int)] = [
      (.captureRequested, 5), (.recorderStartRequested, 10), (.firstAudioCaptured, 110),
      (.recordingReady, 140), (.httpRequestStarted, 160), (.stopShortcut, 1000),
      (.captureStopRequested, 1010), (.recordingStopped, 1230), (.responseReceived, 1500),
      (.jsonDecodeStarted, 1510), (.jsonDecodeCompleted, 1512),
    ]
    for (event, ms) in events { trace.record(event, at: start.advanced(by: .milliseconds(ms))) }
    trace.finish(outcome: .pasted)
    let entry = try #require(stored.entries.first)
    #expect(entry.eventsMs.count == 12)
    #expect(entry.eventsMs["start_shortcut"] == 0)
    #expect(entry.eventsMs["json_decode_completed"] == 1512)
    #expect(
      entry.durationsMs == [
        "startup": 110, "recorder_bring_up": 100, "first_buffer_to_ready": 30,
        "capture_to_request": 50, "stop": 230, "stop_to_response": 270,
        "json_decode": 2, "stop_to_decoded_result": 512,
      ])
    let encoded = try DictationLog.makeEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["id", "ts", "outcome", "events_ms", "durations_ms"])
    #expect(entry.ts == Date(timeIntervalSince1970: 1000).formatted(DictationLog.timestampFormat))
  }

  @Test("wall-clock anchor includes command queue delay and event offsets use the injected clock")
  func clockAndQueueDelay() throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let clock = TestClock()
    clock.advance(by: .milliseconds(250))
    let trace = stored.trace(
      at: start, now: { start.advanced(by: clock.now.offset) }, date: Date(timeIntervalSince1970: 1000))
    trace.record(.captureRequested)
    clock.advance(by: .milliseconds(100))
    trace.record(.firstAudioCaptured)
    trace.finish(outcome: .empty)
    let entry = try #require(stored.entries.first)
    #expect(entry.eventsMs["capture_requested"] == 250)
    #expect(entry.durationsMs["startup"] == 350)
    #expect(entry.ts == Date(timeIntervalSince1970: 999.75).formatted(DictationLog.timestampFormat))
  }

  @Test("concurrent callbacks keep the first event and write exactly once")
  func concurrentCallbacks() async throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start)
    trace.beginWork()
    trace.record(.firstAudioCaptured, at: start.advanced(by: .milliseconds(10)))
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          trace.record(.firstAudioCaptured)
          trace.finish(outcome: .cancelled)
        }
      }
    }
    #expect(stored.entries.isEmpty)
    trace.record(.recordingStopped, at: start.advanced(by: .milliseconds(30)))
    trace.endWork()
    trace.finish(outcome: .failed)
    trace.record(.jsonDecodeCompleted)
    #expect(stored.entries.count == 1)
    let entry = try #require(stored.entries.first)
    #expect(entry.outcome == .cancelled)
    #expect(entry.eventsMs["first_audio_captured"] == 10)
    #expect(entry.eventsMs["recording_stopped"] == 30)
    #expect(entry.eventsMs["json_decode_completed"] == nil)
    #expect(entry.durationsMs == ["startup": 10])
  }

  @Test("direct callers omit shortcut events and traces do not share callbacks")
  func independentPartialTraces() throws {
    let stored = RecordedTimings()
    let first = stored.trace()
    first.beginWork()
    first.finish(outcome: .cancelled)
    let second = stored.trace()
    second.record(.captureRequested)
    second.finish(outcome: .empty)
    first.record(.recordingStopped)
    first.endWork()
    let entries = stored.entries
    #expect(entries.count == 2)
    let newer = try #require(entries.first)
    let older = try #require(entries.last)
    #expect(newer.id != older.id)
    #expect(newer.eventsMs["recording_stopped"] == nil)
    #expect(older.eventsMs["capture_requested"] == nil)
    #expect(older.eventsMs["recording_stopped"] != nil)
    #expect(newer.eventsMs["start_shortcut"] == nil)
    #expect(newer.eventsMs["stop_shortcut"] == nil)
  }
}
