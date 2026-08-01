import ActivityKit
import SwiftUI
import WidgetKit

/// The agent-run Live Activity: Dynamic Island (compact/expanded/minimal)
/// plus the lock-screen banner. State comes from the app over
/// `fah/live_activity` (see AppDelegate.swift).
struct FaLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FaLiveActivityAttributes.self) { context in
      // Lock screen / notification-banner presentation.
      HStack(spacing: 10) {
        FaGlyphView(state: context.state)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.attributes.sessionTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(context.state.statusText)
            .font(.footnote.monospaced())
            .lineLimit(1)
        }
        Spacer()
        StatusAccessoryView(state: context.state)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            FaGlyphView(state: context.state)
            Text(context.attributes.sessionTitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          StatusAccessoryView(state: context.state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.state.statusText)
              .font(.caption.monospaced())
              .lineLimit(1)
            Text(subline(for: context.state))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        FaGlyphView(state: context.state)
      } compactTrailing: {
        Text(statusWord(for: context.state))
          .font(.caption2.monospaced())
          .foregroundStyle(context.state.isError ? .red : .secondary)
          .lineLimit(1)
          .frame(maxWidth: 64)
      } minimal: {
        FaGlyphView(state: context.state)
      }
    }
  }

  /// One word for the cramped compact-trailing slot.
  private func statusWord(for state: FaLiveActivityAttributes.ContentState) -> String {
    if state.isError { return "failed" }
    if state.isDone { return "done" }
    return "running"
  }

  /// The expanded-region subline under the live status text.
  private func subline(for state: FaLiveActivityAttributes.ContentState) -> String {
    if state.isError { return "The run hit an error." }
    if state.isDone { return "The run finished." }
    return "Fa is working…"
  }
}

/// The app glyph: a spinner while the run streams, a checkmark when done,
/// an exclamation mark on error.
private struct FaGlyphView: View {
  let state: FaLiveActivityAttributes.ContentState

  var body: some View {
    if state.isError {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    } else if state.isDone {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }
}

/// Trailing accessory for the lock-screen banner / expanded island.
private struct StatusAccessoryView: View {
  let state: FaLiveActivityAttributes.ContentState

  var body: some View {
    if state.isError {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
    } else if state.isDone {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else {
      Image(systemName: "bolt.fill")
        .foregroundStyle(.indigo)
    }
  }
}
