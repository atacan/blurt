import Foundation
import Testing

@testable import BlurtEngine

/// The delete half of the log: `InstallReset` (and `scripts/reset-install.sh`)
/// both exist to return the machine to a preinstall state, and the transcript
/// corpus is the most sensitive thing an install leaves behind — so "removed it"
/// has to mean removed, and "there was nothing to remove" has to read as success
/// rather than as a failed reset.

@Suite("DictationLog.removeStoredLogs")
struct DictationLogRemovalTests {
  private struct LogFiles {
    let dictations: URL
    let errors: URL
    let timings: URL
  }

  private func makeTempLogs() -> LogFiles {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return LogFiles(
      dictations: directory.appendingPathComponent("dictations.jsonl"),
      errors: directory.appendingPathComponent("errors.jsonl"),
      timings: directory.appendingPathComponent("timings.jsonl"))
  }

  @Test("removes transcript, error, and timing logs")
  func removesAllFiles() throws {
    let logs = makeTempLogs()
    defer { try? FileManager.default.removeItem(at: logs.dictations.deletingLastPathComponent()) }
    DictationLog.write(transcript: "hello", to: logs.dictations, now: Date())
    DictationLog.writeError(.apiKeyMissing, to: logs.errors, now: Date())
    try Data("timing\n".utf8).write(to: logs.timings)
    try #require(FileManager.default.fileExists(atPath: logs.dictations.path))
    try #require(FileManager.default.fileExists(atPath: logs.errors.path))

    #expect(DictationLog.removeStoredLogs(dictations: logs.dictations, errors: logs.errors, timings: logs.timings))

    #expect(!FileManager.default.fileExists(atPath: logs.dictations.path))
    #expect(!FileManager.default.fileExists(atPath: logs.errors.path))
    #expect(!FileManager.default.fileExists(atPath: logs.timings.path))
  }

  @Test("an absent log is already in the state being asked for")
  func absentFilesSucceed() {
    let logs = makeTempLogs()
    // Nothing written: the normal case for anyone who never switched developer
    // mode on. Reporting that as a failure would put a "wasn't fully reset"
    // alert in front of every such user.
    #expect(DictationLog.removeStoredLogs(dictations: logs.dictations, errors: logs.errors, timings: logs.timings))
  }

  @Test("removes only empty log directories", arguments: [false, true])
  func removesDirectoryUnlessBystander(keepBystander: Bool) throws {
    let logs = makeTempLogs()
    defer { try? FileManager.default.removeItem(at: logs.dictations.deletingLastPathComponent()) }
    DictationLog.write(transcript: "hello", to: logs.dictations, now: Date())
    let directory = logs.dictations.deletingLastPathComponent()
    // `~/Library/Logs/Blurt` is the app's directory, not this function's: a file
    // Blurt didn't write is not a reset's to delete.
    let bystander = directory.appendingPathComponent("crash.log")
    if keepBystander { try Data("boom".utf8).write(to: bystander) }

    DictationLog.removeStoredLogs(dictations: logs.dictations, errors: logs.errors, timings: logs.timings)

    #expect(FileManager.default.fileExists(atPath: directory.path) == keepBystander)
    #expect(FileManager.default.fileExists(atPath: bystander.path) == keepBystander)
    #expect(!FileManager.default.fileExists(atPath: logs.dictations.path))
  }
}
