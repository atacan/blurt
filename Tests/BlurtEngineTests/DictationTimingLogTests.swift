import Foundation
import Testing

@testable import BlurtEngine

@Suite("Dictation timing log")
struct DictationTimingLogTests {
  @Test("Developer Mode gates timing writes and the shared queue writes valid JSONL")
  func gatedAppend() throws {
    let defaults = freshDefaults()
    let store = DeveloperModeStore(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("timings.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = RecordedTimings()
    stored.trace().finish(outcome: .empty)
    let entry = try #require(stored.entries.first)
    DictationLog.appendTiming(entry, store: store, to: url)
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    DictationLog.appendTiming(entry, store: store, to: url)
    DictationLog.queue.sync {}
    let data = try Data(contentsOf: url)
    #expect(data.last == 0x0A)
    let decoded = try JSONDecoder().decode(DictationTiming.Entry.self, from: data)
    #expect(decoded.id == entry.id)
    #expect(decoded.eventsMs.isEmpty)
    #expect(decoded.outcome == .empty)
    #expect(DictationLog.defaultTimingDisplayPath.hasSuffix("Library/Logs/Blurt/timings.jsonl"))
  }
}
