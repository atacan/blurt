import Foundation
import Testing

@testable import BlurtEngine

@Suite("First audio buffer timing")
struct DictationFirstBufferTimingTests {
  @Test("buffer duration uses its actual sample rate and later buffers cannot replace it")
  func firstBufferGeometry() throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start, now: { start.advanced(by: .milliseconds(110)) })
    trace.recordFirstBuffer(sampleCount: 960, sampleRateHz: 48_000, callbackAt: start.advanced(by: .milliseconds(105)))
    trace.recordFirstBuffer(sampleCount: 320, sampleRateHz: 16_000, callbackAt: start.advanced(by: .milliseconds(125)))
    trace.finish(outcome: .pasted)
    trace.recordFirstBuffer(sampleCount: 160, sampleRateHz: 16_000, callbackAt: start.advanced(by: .milliseconds(130)))
    let entry = try #require(stored.entries.first)
    let buffer = try #require(entry.firstBuffer)
    #expect(buffer.sampleCount == 960)
    #expect(buffer.sampleRateHz == 48_000)
    #expect(buffer.audioDurationMs == 20)
    #expect(entry.eventsMs["first_audio_callback"] == 105)
    #expect(entry.eventsMs["first_audio_captured"] == 110)
    #expect(entry.durationsMs["first_buffer_processing"] == 5)
  }

  @Test("a buffer delivered before startRunning returns retains a signed interval")
  func callbackBeforeStartReturns() throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start, now: { start.advanced(by: .milliseconds(20)) })
    trace.record(.recorderStartRequested, at: start.advanced(by: .milliseconds(10)))
    trace.recordFirstBuffer(sampleCount: 320, sampleRateHz: 16_000, callbackAt: start.advanced(by: .milliseconds(15)))
    trace.record(.recorderStartReturned, at: start.advanced(by: .milliseconds(30)))
    trace.finish(outcome: .pasted)
    let entry = try #require(stored.entries.first)
    #expect(entry.durationsMs["recorder_start_call"] == 20)
    #expect(entry.durationsMs["start_return_to_first_buffer"] == -15)
    #expect(entry.durationsMs["recorder_bring_up"] == 10)
  }

  @Test("missing format information omits geometry without losing timestamps")
  func missingGeometry() throws {
    let stored = RecordedTimings()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start, now: { start })
    trace.recordFirstBuffer(sampleCount: 320, sampleRateHz: nil, callbackAt: start)
    trace.finish(outcome: .failed)
    let entry = try #require(stored.entries.first)
    #expect(entry.firstBuffer == nil)
    #expect(entry.eventsMs["first_audio_callback"] == 0)
    #expect(entry.eventsMs["first_audio_captured"] == 0)
    #expect(DictationTiming.FirstBuffer(sampleCount: 0, sampleRateHz: 16_000) == nil)
  }

  @Test("invalid rates never produce non-finite JSON values", arguments: [0.0, -1, .infinity, .nan])
  func invalidRates(rate: Double) {
    #expect(DictationTiming.FirstBuffer(sampleCount: 320, sampleRateHz: rate) == nil)
  }
}
