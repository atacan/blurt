import Foundation

extension DictationLog {
  /// Developer Mode's timing-only log, also available in release builds.
  public static var defaultTimingURL: URL { HostIdentity.current.logURL("timings.jsonl") }

  public static var defaultTimingDisplayPath: String {
    (defaultTimingURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  static func appendTiming(
    _ entry: DictationTiming.Entry,
    store: DeveloperModeStore = DeveloperModeStore(), to url: URL = defaultTimingURL
  ) {
    gated(store: store) { _ in appendLine(entry, to: url) }
  }
}

extension DictationSession {
  /// A terminal phase can precede the end of capture/network teardown. The
  /// trace's work count defers its write without holding up the UI or next press.
  func finishTiming(for phase: PipelinePhase) {
    let outcome: DictationTiming.Outcome
    switch phase {
    case .idle: outcome = .empty
    case .failed: outcome = .failed
    case .cancelled: outcome = .cancelled
    case .pasted: outcome = .pasted
    case .noTarget: outcome = .copied
    case .handedBack: outcome = .handedBack
    case .connecting, .recording, .transcribing, .injecting: return
    }
    timing?.finish(outcome: outcome)
    timing = nil
  }
}
