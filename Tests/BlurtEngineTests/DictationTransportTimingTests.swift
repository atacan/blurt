import Foundation
import Testing

@testable import BlurtEngine

@Suite("Dictation transport timing", .timeLimit(.minutes(1)))
struct DictationTransportTimingTests {
  @Test("the complete response precedes successful JSON decoding")
  func responseThenDecode() async throws {
    let stored = RecordedTimings()
    let clock = TestClock()
    let start = ContinuousClock.now
    let trace = stored.trace(at: start, now: { start.advanced(by: clock.now.offset) })
    let transport = FakeHTTPTransport { _ in
      clock.advance(by: .milliseconds(100))
      return (200, json(["text": "hello"]))
    }
    let text = try await DictationTiming.$current.withValue(trace) {
      try await collectTranscript(makeTranscriber(apiKey: "k", transport: transport))
    }
    trace.finish(outcome: .pasted)
    let entry = try #require(stored.entries.first)
    #expect(text == "hello")
    #expect(entry.eventsMs["http_request_started"] == 0)
    #expect(entry.eventsMs["response_received"] == 100)
    #expect(entry.eventsMs["json_decode_started"] == 100)
    #expect(entry.eventsMs["json_decode_completed"] == 100)
  }

  @Test("HTTP and malformed JSON failures omit stages they did not complete", arguments: [200, 500])
  func failedResponses(status: Int) async throws {
    let transcriber = makeTranscriber(
      apiKey: "k", transport: FakeHTTPTransport { _ in (status, Data("invalid JSON".utf8)) })
    let entry = try await failedEntry(transcriber)
    #expect(entry.eventsMs["http_request_started"] != nil)
    #expect(entry.eventsMs["response_received"] != nil)
    #expect((entry.eventsMs["json_decode_started"] != nil) == (status == 200))
    #expect(entry.eventsMs["json_decode_completed"] == nil)
    #expect(entry.durationsMs["json_decode"] == nil)
  }

  @Test("network failure has no response or decode timestamps")
  func noResponse() async throws {
    let transcriber = makeTranscriber(
      apiKey: "k", transport: FakeHTTPTransport.failing(with: URLError(.notConnectedToInternet)))
    let entry = try await failedEntry(transcriber)
    #expect(Set(entry.eventsMs.keys) == ["http_request_started"])
  }

  private func failedEntry(_ transcriber: AssemblyAITranscriber) async throws -> DictationTiming.Entry {
    let stored = RecordedTimings()
    let trace = stored.trace()
    await #expect(throws: (any Error).self) {
      try await DictationTiming.$current.withValue(trace) { try await collectTranscript(transcriber) }
    }
    trace.finish(outcome: .failed)
    return try #require(stored.entries.first)
  }
}
