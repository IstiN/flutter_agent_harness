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
    registerKeychainChannel(registry: flutterViewController)

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

/// The `fah/calendar` method channel: access to the user's system calendar
/// via EventKit. Methods: `isAvailable`, `requestAccess`, `events` with
/// {startMs, endMs} returning a list of event maps, plus the write methods
/// `createEvent` / `updateEvent` / `deleteEvent`.
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
    case "createEvent":
      let args = call.arguments as? [String: Any] ?? [:]
      result(calendarCreateEvent(args: args))
    case "updateEvent":
      let args = call.arguments as? [String: Any] ?? [:]
      result(calendarUpdateEvent(args: args))
    case "deleteEvent":
      let args = call.arguments as? [String: Any] ?? [:]
      result(calendarDeleteEvent(args: args))
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
      "id": event.eventIdentifier ?? "",
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

/// Whether the store may write events — the same full-access check the
/// read path applies (macOS 14+ API; legacy status on older systems).
private func calendarWriteAccessGranted() -> Bool {
  let status = EKEventStore.authorizationStatus(for: .event)
  if #available(macOS 14.0, *) {
    return status == .fullAccess
  }
  return status == .authorized
}

/// Applies the shared write fields ({title, startMs, endMs, allDay,
/// calendar, location, notes}) to [event]; only present keys are applied.
private func calendarApplyWriteFields(args: [String: Any], to event: EKEvent) {
  if let title = args["title"] as? String { event.title = title }
  if let startMs = (args["startMs"] as? NSNumber)?.int64Value {
    event.startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
  }
  if let endMs = (args["endMs"] as? NSNumber)?.int64Value {
    event.endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000)
  }
  if let allDay = args["allDay"] as? Bool { event.isAllDay = allDay }
  if let location = args["location"] as? String { event.location = location }
  if let notes = args["notes"] as? String { event.notes = notes }
  if let name = args["calendar"] as? String,
    let match = calendarEventStore.calendars(for: .event)
      .first(where: { $0.title == name })
  {
    event.calendar = match
  }
}

/// Creates an event from {title, startMs, endMs, allDay?, calendar?,
/// location?, notes?} and returns the new event id (or a FlutterError).
private func calendarCreateEvent(args: [String: Any]) -> Any {
  guard calendarWriteAccessGranted() else {
    return FlutterError(
      code: "denied",
      message: "calendar access was not granted",
      details: nil,
    )
  }
  guard let title = args["title"] as? String, !title.isEmpty else {
    return FlutterError(
      code: "bad_args",
      message: "title is required",
      details: nil,
    )
  }
  let event = EKEvent(eventStore: calendarEventStore)
  calendarApplyWriteFields(args: args, to: event)
  if event.startDate == nil {
    event.startDate = Date()
  }
  if event.endDate == nil {
    event.endDate = event.startDate.addingTimeInterval(3600)
  }
  if event.calendar == nil {
    event.calendar = calendarEventStore.defaultCalendarForNewEvents
  }
  do {
    try calendarEventStore.save(event, span: .thisEvent, commit: true)
    return event.eventIdentifier ?? ""
  } catch {
    return FlutterError(
      code: "save_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// Updates the event with args["id"]; returns true or a FlutterError.
private func calendarUpdateEvent(args: [String: Any]) -> Any {
  guard calendarWriteAccessGranted() else {
    return FlutterError(
      code: "denied",
      message: "calendar access was not granted",
      details: nil,
    )
  }
  guard let id = args["id"] as? String,
    let event = calendarEventStore.event(withIdentifier: id)
  else {
    return FlutterError(
      code: "not_found",
      message: "no event with this id",
      details: nil,
    )
  }
  calendarApplyWriteFields(args: args, to: event)
  do {
    try calendarEventStore.save(event, span: .thisEvent, commit: true)
    return true
  } catch {
    return FlutterError(
      code: "save_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// Deletes the event with args["id"]; returns true or a FlutterError.
private func calendarDeleteEvent(args: [String: Any]) -> Any {
  guard calendarWriteAccessGranted() else {
    return FlutterError(
      code: "denied",
      message: "calendar access was not granted",
      details: nil,
    )
  }
  guard let id = args["id"] as? String,
    let event = calendarEventStore.event(withIdentifier: id)
  else {
    return FlutterError(
      code: "not_found",
      message: "no event with this id",
      details: nil,
    )
  }
  do {
    try calendarEventStore.remove(event, span: .thisEvent, commit: true)
    return true
  } catch {
    return FlutterError(
      code: "delete_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// The `fah/keychain` method channel: app-scoped Keychain storage for API
/// keys (service `fa.app`). Methods: `isAvailable`, `readAll` (every entry
/// as a name→value map), `set` {name, value}, and `delete` {name}. Values
/// never leave the device (AfterFirstUnlockThisDeviceOnly — no iCloud
/// backup of secrets). Works inside the app sandbox for app-private items.
private func registerKeychainChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/keychain",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(true)
    case "readAll":
      result(keychainReadAll())
    case "set":
      let args = call.arguments as? [String: Any] ?? [:]
      result(
        keychainSet(
          name: args["name"] as? String ?? "",
          value: args["value"] as? String ?? "",
        ),
      )
    case "delete":
      let args = call.arguments as? [String: Any] ?? [:]
      result(keychainDelete(name: args["name"] as? String ?? ""))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private let keychainService = "fa.app"

private func keychainQuery(_ name: String? = nil) -> [String: Any] {
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: keychainService,
  ]
  if let name = name { query[kSecAttrAccount as String] = name }
  return query
}

private func keychainReadAll() -> [String: String] {
  var query = keychainQuery()
  query[kSecReturnAttributes as String] = true
  query[kSecReturnData as String] = true
  query[kSecMatchLimit as String] = kSecMatchLimitAll
  var item: CFTypeRef?
  guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
    let entries = item as? [[String: Any]]
  else { return [:] }
  var out: [String: String] = [:]
  for entry in entries {
    if let account = entry[kSecAttrAccount as String] as? String,
      let data = entry[kSecValueData as String] as? Data,
      let value = String(data: data, encoding: .utf8)
    {
      out[account] = value
    }
  }
  return out
}

private func keychainSet(name: String, value: String) -> Bool {
  guard !name.isEmpty, let data = value.data(using: .utf8) else { return false }
  let query = keychainQuery(name)
  let attrs: [String: Any] = [
    kSecValueData as String: data,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
  ]
  let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
  if status == errSecItemNotFound {
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }
  return status == errSecSuccess
}

private func keychainDelete(name: String) -> Bool {
  let status = SecItemDelete(keychainQuery(name) as CFDictionary)
  return status == errSecSuccess || status == errSecItemNotFound
}
