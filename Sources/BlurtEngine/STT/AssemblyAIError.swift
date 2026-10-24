import Foundation

/// Errors specific to the AssemblyAI transport. These get wrapped in
/// `BlurtError.sttFailed` before reaching the UI.
enum AssemblyAIError: Error, LocalizedError {
  case http(status: Int, message: String?)
  case malformedResponse
  /// The recording ended below `SyncSTTLimits.minPCMBytes`, so the body was
  /// never closed — a belt on top of `DictationSession.performRelease`'s own
  /// guard rather than the only thing between a stray tap and a request billed
  /// for transcribing nothing. `awaitUpload` maps it to the same quiet `.idle`
  /// that guard produces, so whichever layer notices first the user sees the
  /// same nothing; the description below is a backstop, not a message anyone is
  /// expected to read.
  case audioTooShort

  var errorDescription: String? {
    switch self {
    case .http(let status, let message):
      if let message { return "AssemblyAI error \(status): \(message)" }
      return "AssemblyAI error \(status)"
    case .malformedResponse:
      return "Unexpected response from AssemblyAI."
    case .audioTooShort:
      return "That recording was too short to transcribe."
    }
  }
}
