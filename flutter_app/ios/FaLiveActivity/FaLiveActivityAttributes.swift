import ActivityKit
import Foundation

/// The Live Activity model for an agent run. Shared by BOTH the Runner app
/// target (which starts/updates/ends activities over the
/// `fah/live_activity` channel) and the FaLiveActivity widget extension
/// (which renders them) — keep it in both target memberships.
@available(iOS 16.1, *)
struct FaLiveActivityAttributes: ActivityAttributes {
  /// Dynamic state, pushed by the app on every status change.
  public struct ContentState: Codable, Hashable {
    /// The current status line (e.g. "[bash] …", "writing…", "done").
    var statusText: String
    /// True when the run failed (renders in red, with an error glyph).
    var isError: Bool
    /// True once the run finished (the activity lingers briefly, then the
    /// app ends it).
    var isDone: Bool
  }

  /// Static content: the session title, fixed when the activity starts.
  var sessionTitle: String
}
