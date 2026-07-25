import Cocoa
import EventKit
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerProjectFolderChannel(registry: flutterViewController)
    registerCalendarChannel(registry: flutterViewController)

    super.awakeFromNib()
  }
}

/// The `fah/project_folder` method channel: native directory picking via
/// NSOpenPanel plus security-scoped bookmark lifecycle, so a user-selected
/// project folder stays accessible to the sandboxed app across restarts.
private func registerProjectFolderChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/project_folder",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "pickDirectory":
      result(pickDirectoryWithBookmark())
    case "startAccessing":
      let bookmark = call.arguments as? String ?? ""
      result(startAccessing(bookmarkBase64: bookmark))
    case "stopAccessing":
      let bookmark = call.arguments as? String ?? ""
      stopAccessing(bookmarkBase64: bookmark)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Opens an NSOpenPanel for a single directory and returns the chosen path
/// plus a security-scoped bookmark for it, or nil when cancelled.
private func pickDirectoryWithBookmark() -> [String: String]? {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.prompt = "Open"
  panel.message = "Choose a project folder the agent may work in"
  guard panel.runModal() == .OK, let url = panel.url else { return nil }
  guard let bookmark = try? url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil,
  ) else { return nil }
  return [
    "path": url.path,
    "bookmark": bookmark.base64EncodedString(),
  ]
}

/// Resolves a security-scoped bookmark and starts accessing the resource.
/// False when the bookmark is stale or the folder is gone.
private func startAccessing(bookmarkBase64: String) -> Bool {
  guard let data = Data(base64Encoded: bookmarkBase64) else { return false }
  var stale = false
  guard
    let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale,
    ), !stale
  else { return false }
  return url.startAccessingSecurityScopedResource()
}

/// Best-effort stop of a previously started security-scoped access.
private func stopAccessing(bookmarkBase64: String) {
  guard let data = Data(base64Encoded: bookmarkBase64) else { return }
  var stale = false
  guard
    let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale,
    )
  else { return }
  url.stopAccessingSecurityScopedResource()
}

/// Shared store for the `fah/calendar` channel (EventKit wants a long-lived
/// EKEventStore instance).
private let calendarEventStore = EKEventStore()

/// The `fah/calendar` method channel: read-only access to the user's system
/// calendar via EventKit. Methods: `isAvailable`, `requestAccess`, and
/// `events` with `{startMs, endMs}` returning a list of event maps.
private func registerCalendarChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/calendar",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(true)
    case "requestAccess":
      requestCalendarAccess(result: result)
    case "events":
      let args = call.arguments as? [String: Any] ?? [:]
      let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
      let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? 0
      result(calendarEvents(startMs: startMs, endMs: endMs))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Requests full access to events (macOS 14+ API; the legacy requestAccess
/// on older systems). The OS shows its prompt at most once.
private func requestCalendarAccess(result: @escaping FlutterResult) {
  if #available(macOS 14.0, *) {
    calendarEventStore.requestFullAccessToEvents { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  } else {
    calendarEventStore.requestAccess(to: .event) { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }
}

/// Events overlapping [startMs, endMs) as Flutter-friendly maps; empty when
/// access is not granted (the Dart side requests access before calling).
private func calendarEvents(startMs: Int64, endMs: Int64) -> [[String: Any]] {
  let status = EKEventStore.authorizationStatus(for: .event)
  let authorized: Bool
  if #available(macOS 14.0, *) {
    authorized = status == .fullAccess
  } else {
    authorized = status == .authorized
  }
  guard authorized, endMs > startMs else { return [] }
  let start = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
  let end = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000)
  let predicate = calendarEventStore.predicateForEvents(
    withStart: start,
    end: end,
    calendars: nil,
  )
  return calendarEventStore.events(matching: predicate).map { event in
    var map: [String: Any] = [
      "title": event.title ?? "",
      "startMs": Int64(event.startDate.timeIntervalSince1970 * 1000),
      "endMs": Int64(event.endDate.timeIntervalSince1970 * 1000),
      "allDay": event.isAllDay,
    ]
    if let calendar = event.calendar?.title { map["calendar"] = calendar }
    if let location = event.location { map["location"] = location }
    if let notes = event.notes { map["notes"] = notes }
    return map
  }
}
