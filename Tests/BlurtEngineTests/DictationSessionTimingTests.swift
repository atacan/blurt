import Foundation
import Testing

@testable import BlurtEngine

@Suite("Dictation session timing", .timeLimit(.minutes(1)))
struct DictationSessionTimingTests {
  @Test("task-local timing crosses capture and HTTP tasks, separating readiness and tail linger")
  func completeTimeline() async throws {
    let stored = RecordedTimings()
    let clock = TestClock()
    let start = ContinuousClock.now
    let transport = FakeHTTPTransport { request in
      if request.httpMethod == "POST" { clock.advance(by: .milliseconds(50)) }
      return (200, json(["text": "hello"]))
    }
    let session = makeSession(
      transcriber: makeTranscriber(apiKey: "k", transport: transport), mic: TimedMic(clock: clock),
      seams: stored.seams(now: { start.advanced(by: clock.now.offset) }))
    await session.press(at: start)
    await session.release(at: start.advanced(by: clock.now.offset))
    await session.awaitPipeline()
    let entry = try #require(stored.entries.first)
    #expect(entry.eventsMs.count == 12)
    #expect(entry.durationsMs["startup"] == 100)
    #expect(entry.durationsMs["first_buffer_to_ready"] == 30)
    #expect(entry.durationsMs["stop"] == 220)
    #expect(entry.durationsMs["stop_to_response"] == 50)
    #expect(entry.durationsMs["stop_to_decoded_result"] == 270)
  }

  @Test("submitted stop time survives a queued microphone startup")
  func queuedStopDuringStartup() async throws {
    let stored = RecordedTimings()
    let clock = TestClock()
    let start = ContinuousClock.now
    let mic = GatedStartMic()
    let session = makeSession(
      transcriber: StubTranscriber(mode: .transcript("hello")), mic: mic,
      seams: stored.seams(now: { start.advanced(by: clock.now.offset) }))
    session.submit(.press, at: start)
    await mic.waitUntilStartEntered()
    clock.advance(by: .milliseconds(50))
    session.submit(.release, at: start.advanced(by: .milliseconds(50)))
    clock.advance(by: .milliseconds(500))
    await mic.allowStartToFinish()
    await stored.waitForEntries(1)
    let entry = try #require(stored.entries.first)
    #expect(entry.outcome == .pasted)
    #expect(entry.eventsMs["start_shortcut"] == 0)
    #expect(entry.eventsMs["stop_shortcut"] == 50)
    #expect(entry.eventsMs["capture_stop_requested"] == 550)
    #expect(await mic.stopCalls == 1)
  }

  @Test("cancellation during stop waits for teardown before writing its partial timeline")
  func cancelledStopSettlesBeforeWrite() async throws {
    let stored = RecordedTimings()
    let mic = GatedStopMic()
    let session = makeSession(
      transcriber: StubTranscriber(mode: .transcript("discarded")), mic: mic, seams: stored.seams())
    await session.press(at: .now)
    let released = Task { await session.release(at: .now) }
    await mic.waitUntilStopEntered()
    await session.cancel()
    #expect(stored.entries.isEmpty)
    await mic.allowStopToFinish()
    await released.value
    await stored.waitForEntries(1)
    let entry = try #require(stored.entries.first)
    #expect(entry.outcome == .cancelled)
    #expect(entry.eventsMs["capture_stop_requested"] != nil)
    #expect(entry.eventsMs["json_decode_completed"] == nil)
  }

  @Test("startup failures, short recordings and hand-back success each get one record")
  func partialAndConsecutiveRuns() async throws {
    let stored = RecordedTimings()
    let mic = StubMicCapture()
    let session = makeSession(
      transcriber: StubTranscriber(mode: .transcript("hello")), mic: mic, seams: stored.seams())
    await mic.setStartError(URLError(.cannotOpenFile))
    await session.press(at: .now)
    await mic.setStartError(nil)
    await mic.setPCM(Data())
    await session.dictate()
    await mic.setPCM(StubPCM.aboveMinimum)
    await session.dictate(handingBack: true)
    await stored.waitForEntries(3)
    let entries = stored.entries
    #expect(entries.map(\.outcome) == [.failed, .empty, .handedBack])
    #expect(Set(entries.map(\.id)).count == 3)
    #expect(entries.first?.eventsMs["capture_requested"] != nil)
    #expect(entries.first?.eventsMs["capture_stop_requested"] == nil)
  }

  @Test("readiness refusal and cancel during startup retain partial timelines")
  func refusedAndCancelledStartup() async throws {
    let stored = RecordedTimings()
    let refused = makeSession(
      transcriber: StubTranscriber(mode: .transcript("unused")), readinessCheck: { .apiKeyMissing },
      seams: stored.seams())
    await refused.press(at: .now)
    let mic = GatedStartMic()
    await mic.setThrowsIfCancelled(true)
    let cancelled = makeSession(
      transcriber: StubTranscriber(mode: .transcript("unused")), mic: mic, seams: stored.seams())
    let pressed = Task { await cancelled.press(at: .now) }
    await mic.waitUntilStartEntered()
    await cancelled.cancel()
    #expect(stored.entries.count == 1)
    await mic.allowStartToFinish()
    await pressed.value
    #expect(stored.entries.map(\.outcome) == [.failed, .cancelled])
    #expect(stored.entries.first?.eventsMs["capture_requested"] == nil)
  }
}

/// Controlled audio producer for testing task-local propagation and delayed
/// readiness/stop boundaries without opening a real device or sleeping.
private actor TimedMic: MicCaptureProtocol {
  let clock: TestClock
  private var timing: DictationTiming?
  private var feed: AsyncStream<Data>.Continuation?

  init(clock: TestClock) { self.clock = clock }

  func start() async throws -> AsyncStream<Data> {
    timing = DictationTiming.current
    timing?.record(.recorderStartRequested)
    clock.advance(by: .milliseconds(100))
    timing?.record(.firstAudioCaptured)
    clock.advance(by: .milliseconds(30))
    timing?.record(.recordingReady)
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    feed = continuation
    continuation.yield(StubPCM.aboveMinimum)
    return stream
  }

  func stop() async throws -> Int {
    clock.advance(by: .milliseconds(220))
    timing?.record(.recordingStopped)
    feed?.finish()
    return StubPCM.aboveMinimum.count
  }
}
