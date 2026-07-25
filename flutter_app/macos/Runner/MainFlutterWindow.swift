import AVFoundation
import Cocoa
import Contacts
import EventKit
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame

    // Modern unified titlebar (macOS 14+, see the traffic-lights skill):
    // the native traffic lights float over Flutter content — no solid
    // title-bar band, no duplicated text title (it stays for Dock/Mission
    // Control only), and the window background matches the app's dark
    // palette (#070A10) so the seam is invisible without making the
    // Flutter scaffold transparent.
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    styleMask.insert(.fullSizeContentView)
    if #available(macOS 11.0, *) {
      toolbarStyle = .unifiedCompact
    }
    toolbar = NSToolbar(identifier: "FaToolbar")
    toolbar?.showsBaselineSeparator = false
    isMovableByWindowBackground = true
    backgroundColor = NSColor(
      calibratedRed: 7.0 / 255.0,
      green: 10.0 / 255.0,
      blue: 16.0 / 255.0,
      alpha: 1.0,
    )

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerProjectFolderChannel(registry: flutterViewController)
    registerCalendarChannel(registry: flutterViewController)
    registerContactsChannel(registry: flutterViewController)
    registerHealthChannel(registry: flutterViewController)
    registerHomeChannel(registry: flutterViewController)
    registerICloudChannel(registry: flutterViewController)
    registerKeychainChannel(registry: flutterViewController)
    registerMicChannel(registry: flutterViewController)
    registerNotifyChannel(registry: flutterViewController)
    registerVideoChannel(registry: flutterViewController)

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

/// The `fah/icloud` method channel: iCloud Drive ubiquity container access
/// for the session/apps sync. `containerUrl` → the absolute path of the
/// container's Documents directory, or nil when iCloud is unavailable (not
/// signed in, or the iCloud capability/container id missing from the
/// provisioning profile). `syncStatus` → {available, containerUrl?}. The
/// file copy itself happens Dart-side once the container URL is known.
private func registerICloudChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/icloud",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "containerUrl":
      iCloudContainerDocumentsPath { path in result(path) }
    case "syncStatus":
      iCloudContainerDocumentsPath { path in
        result(["available": path != nil, "containerUrl": path as Any])
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Resolves the ubiquity container's Documents directory, answering on the
/// main thread. The lookup can block on first call, so it runs off the main
/// thread. Nil when the iCloud capability or a signed-in account is missing.
private func iCloudContainerDocumentsPath(completion: @escaping (String?) -> Void) {
  DispatchQueue.global(qos: .userInitiated).async {
    let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)
    let path = url?.appendingPathComponent("Documents").path
    DispatchQueue.main.async { completion(path) }
  }
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

/// Shared store for the `fah/contacts` channel (CNContactStore wants a
/// long-lived instance).
private let contactStore = CNContactStore()

/// The keys every contacts fetch shares. CNContactNoteKey is deliberately
/// absent — reading notes requires Apple's notes entitlement; writing a
/// note on a mutable contact works without it.
private let contactKeys: [CNKeyDescriptor] = [
  CNContactIdentifierKey as CNKeyDescriptor,
  CNContactGivenNameKey as CNKeyDescriptor,
  CNContactFamilyNameKey as CNKeyDescriptor,
  CNContactPhoneNumbersKey as CNKeyDescriptor,
  CNContactEmailAddressesKey as CNKeyDescriptor,
]

/// The `fah/contacts` method channel: access to the user's system contacts
/// via Contacts.framework. Methods: `isAvailable`, `requestAccess`,
/// `searchContacts` with {query} returning a list of contact maps
/// ({id, name, phones, emails}), the write methods `createContact` /
/// `updateContact` / `deleteContact`, and `openUrl` ({url}) which opens
/// `tel:`/`sms:` URLs for the call/SMS flows.
private func registerContactsChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/contacts",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(true)
    case "requestAccess":
      contactStore.requestAccess(for: .contacts) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "searchContacts":
      let args = call.arguments as? [String: Any] ?? [:]
      result(contactsSearch(query: args["query"] as? String ?? ""))
    case "createContact":
      let args = call.arguments as? [String: Any] ?? [:]
      result(contactsCreate(args: args))
    case "updateContact":
      let args = call.arguments as? [String: Any] ?? [:]
      result(contactsUpdate(args: args))
    case "deleteContact":
      let args = call.arguments as? [String: Any] ?? [:]
      result(contactsDelete(args: args))
    case "openUrl":
      let args = call.arguments as? [String: Any] ?? [:]
      result(contactsOpenUrl(args["url"] as? String ?? ""))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Whether the store may read contacts.
private func contactsAccessGranted() -> Bool {
  CNContactStore.authorizationStatus(for: .contacts) == .authorized
}

/// One contact as a Flutter-friendly map: {id, name, phones[], emails[]}.
private func contactMap(_ contact: CNContact) -> [String: Any] {
  let name = "\(contact.givenName) \(contact.familyName)"
    .trimmingCharacters(in: .whitespaces)
  return [
    "id": contact.identifier,
    "name": name.isEmpty ? "(no name)" : name,
    "phones": contact.phoneNumbers.map { $0.value.stringValue },
    "emails": contact.emailAddresses.map { $0.value as String },
  ]
}

/// Name matches as Flutter-friendly maps (capped at 50); an empty query
/// lists the first contacts. Empty when access is not granted (the Dart
/// side requests access before calling).
private func contactsSearch(query: String) -> [[String: Any]] {
  guard contactsAccessGranted() else { return [] }
  var matches: [[String: Any]] = []
  do {
    if query.isEmpty {
      let request = CNContactFetchRequest(keysToFetch: contactKeys)
      try contactStore.enumerateContacts(with: request) { contact, stop in
        matches.append(contactMap(contact))
        if matches.count >= 50 { stop.pointee = true }
      }
    } else {
      let predicate = CNContact.predicateForContacts(matchingName: query)
      matches = try contactStore.unifiedContacts(
        matching: predicate,
        keysToFetch: contactKeys,
      ).prefix(50).map(contactMap)
    }
  } catch {
    return []
  }
  return matches
}

private func contactsDeniedError() -> FlutterError {
  FlutterError(
    code: "denied",
    message: "contacts access was not granted",
    details: nil,
  )
}

/// Splits a full name into given/family parts (last word is the family).
private func contactsApplyName(_ name: String, to contact: CNMutableContact) {
  let parts = name.split(separator: " ").map(String.init)
  if parts.count > 1 {
    contact.givenName = parts.dropLast().joined(separator: " ")
    contact.familyName = parts.last ?? ""
  } else {
    contact.givenName = name
    contact.familyName = ""
  }
}

/// Applies the shared write fields ({name, phones, emails, note}) to
/// [contact]; only present keys are applied, and a present phones/emails
/// list REPLACES the existing entries.
private func contactsApplyWriteFields(
  args: [String: Any],
  to contact: CNMutableContact,
) {
  if let name = args["name"] as? String { contactsApplyName(name, to: contact) }
  if let phones = args["phones"] as? [String] {
    contact.phoneNumbers = phones.map {
      CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
    }
  }
  if let emails = args["emails"] as? [String] {
    contact.emailAddresses = emails.map {
      CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
    }
  }
  if let note = args["note"] as? String { contact.note = note }
}

/// Creates a contact from {name, phones?, emails?, note?} and returns the
/// new contact id (or a FlutterError).
private func contactsCreate(args: [String: Any]) -> Any {
  guard contactsAccessGranted() else { return contactsDeniedError() }
  guard let name = args["name"] as? String, !name.isEmpty else {
    return FlutterError(
      code: "bad_args",
      message: "name is required",
      details: nil,
    )
  }
  let contact = CNMutableContact()
  contactsApplyWriteFields(args: args, to: contact)
  let request = CNSaveRequest()
  request.add(contact, toContainerWithIdentifier: nil)
  do {
    try contactStore.execute(request)
    return contact.identifier
  } catch {
    return FlutterError(
      code: "save_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// Updates the contact with args["id"]; returns true or a FlutterError.
private func contactsUpdate(args: [String: Any]) -> Any {
  guard contactsAccessGranted() else { return contactsDeniedError() }
  guard let id = args["id"] as? String,
    let existing = try? contactStore.unifiedContact(
      withIdentifier: id,
      keysToFetch: contactKeys,
    ),
    let contact = existing.mutableCopy() as? CNMutableContact
  else {
    return FlutterError(
      code: "not_found",
      message: "no contact with this id",
      details: nil,
    )
  }
  contactsApplyWriteFields(args: args, to: contact)
  let request = CNSaveRequest()
  request.update(contact)
  do {
    try contactStore.execute(request)
    return true
  } catch {
    return FlutterError(
      code: "save_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// Deletes the contact with args["id"]; returns true or a FlutterError.
private func contactsDelete(args: [String: Any]) -> Any {
  guard contactsAccessGranted() else { return contactsDeniedError() }
  guard let id = args["id"] as? String,
    let existing = try? contactStore.unifiedContact(
      withIdentifier: id,
      keysToFetch: contactKeys,
    ),
    let contact = existing.mutableCopy() as? CNMutableContact
  else {
    return FlutterError(
      code: "not_found",
      message: "no contact with this id",
      details: nil,
    )
  }
  let request = CNSaveRequest()
  request.delete(contact)
  do {
    try contactStore.execute(request)
    return true
  } catch {
    return FlutterError(
      code: "delete_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

/// Opens a `tel:`/`sms:` URL with the system handler; false when the URL
/// is malformed or the system refuses it.
private func contactsOpenUrl(_ urlString: String) -> Bool {
  guard let url = URL(string: urlString) else { return false }
  return NSWorkspace.shared.open(url)
}

/// The `fah/health` method channel: HealthKit does not exist on macOS, so
/// the channel is registered but honestly reports every call as
/// unsupported. The Dart side (`healthPlatformSupported`) already gates
/// health to iOS and never gets here in practice.
private func registerHealthChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/health",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable", "requestAccess":
      result(false)
    case "summary":
      result(
        FlutterError(
          code: "unsupported",
          message: "HealthKit is not available on macOS",
          details: nil,
        ),
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The `fah/home` method channel: there is no HomeKit framework on macOS, so
/// the channel is registered but honestly reports every call as unsupported.
/// The Dart side (`homePlatformSupported`) already gates home control to iOS
/// and never gets here in practice.
private func registerHomeChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/home",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable", "requestAccess":
      result(false)
    case "listAccessories", "setPower", "setBrightness", "setTargetTemperature":
      result(
        FlutterError(
          code: "unsupported",
          message: "HomeKit is not available on macOS",
          details: nil,
        ),
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The `fah/mic` method channel: microphone capture to a temporary .m4a
/// file (AVAudioRecorder, AAC 44.1 kHz mono, auto-stop at 120 s — no
/// streaming). Methods: `isAvailable`, `requestAccess`, `startRecording`,
/// and `stopRecording` → {path, durationMs, sampleRate}. Needs the
/// `com.apple.security.device.audio-input` entitlement (sandbox) and the
/// NSMicrophoneUsageDescription Info.plist string.
private func registerMicChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/mic",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(true)
    case "requestAccess":
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:
        result(true)
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async { result(granted) }
        }
      default:
        result(false)
      }
    case "startRecording":
      result(micStartRecording())
    case "stopRecording":
      result(micStopRecording())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private var micRecorder: AVAudioRecorder?
private var micStartedAt: Date?

/// Longest single take in seconds — the recorder auto-stops there.
private let micMaxRecordSeconds: TimeInterval = 120

private func micStartRecording() -> Any {
  guard micRecorder == nil else {
    return FlutterError(
      code: "busy",
      message: "a recording is already in progress",
      details: nil,
    )
  }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("fah-mic-\(UUID().uuidString).m4a")
  let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 44100,
    AVNumberOfChannelsKey: 1,
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
  ]
  do {
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    guard recorder.record(forDuration: micMaxRecordSeconds) else {
      return FlutterError(
        code: "record_failed",
        message: "the microphone could not start (permission denied?)",
        details: nil,
      )
    }
    micRecorder = recorder
    micStartedAt = Date()
    return true
  } catch {
    return FlutterError(
      code: "record_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
}

private func micStopRecording() -> Any {
  guard let recorder = micRecorder else {
    return FlutterError(
      code: "not_recording",
      message: "no recording is in progress",
      details: nil,
    )
  }
  recorder.stop()
  let durationMs = Int(((micStartedAt.map { Date().timeIntervalSince($0) }) ?? 0) * 1000)
  micRecorder = nil
  micStartedAt = nil
  return [
    "path": recorder.url.path,
    "durationMs": durationMs,
    "sampleRate": 44100,
  ]
}

/// The `fah/video` method channel: video frame extraction via
/// AVAssetImageGenerator for the `read_video` tool / JS bridge.
/// `extractFrames` {path, count} → [{bytes (jpeg, base64), positionMs}]
/// sampled at the centers of `count` equal timeline slices (exact times,
/// ±0.5 s tolerance). An unreadable/unseekable asset answers an empty list;
/// individual frame failures are skipped (the Dart side treats an empty
/// list as "not a readable video").
private func registerVideoChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/video",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "extractFrames":
      let args = call.arguments as? [String: Any] ?? [:]
      let path = args["path"] as? String ?? ""
      let count = (args["count"] as? NSNumber)?.intValue ?? 6
      extractVideoFrames(path: path, count: count) { frames in
        result(frames)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private func extractVideoFrames(
  path: String,
  count: Int,
  completion: @escaping ([[String: Any]]) -> Void,
) {
  DispatchQueue.global(qos: .userInitiated).async {
    guard FileManager.default.fileExists(atPath: path) else {
      completion([])
      return
    }
    let asset = AVAsset(url: URL(fileURLWithPath: path))
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      completion([])
      return
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    // Cap the frame size: each jpeg rides the vision request as base64.
    generator.maximumSize = CGSize(width: 768, height: 768)
    let n = max(1, min(count, 12))
    var frames: [[String: Any]] = []
    for index in 0..<n {
      // Center of each equal slice — avoids the often-black first frame.
      let position = durationSeconds * (Double(index) + 0.5) / Double(n)
      let time = CMTime(seconds: position, preferredTimescale: 600)
      guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
        continue
      }
      let bitmap = NSBitmapImageRep(cgImage: image)
      guard
        let data = bitmap.representation(
          using: .jpeg,
          properties: [.compressionFactor: 0.8],
        )
      else { continue }
      frames.append([
        "bytes": data.base64EncodedString(),
        "positionMs": Int((position * 1000).rounded()),
      ])
    }
    completion(frames)
  }
}

/// The `fah/notify` method channel: LOCAL user notifications via
/// UNUserNotificationCenter — no remote pushes, no background modes.
/// Methods: `requestAccess`, `schedule` {title, body, id?, delaySeconds?}
/// answering the scheduled id (immediate when delaySeconds is absent/zero,
/// otherwise a one-shot UNTimeIntervalNotificationTrigger — no repeats),
/// `cancel` {id}, and `cancelAll`. UserNotifications works inside the app
/// sandbox — no entitlement is needed (unlike calendar/contacts/mic).
private func registerNotifyChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/notify",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "requestAccess":
      // The OS shows its prompt at most once; later calls return the stored
      // decision without prompting again.
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge],
      ) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "schedule":
      let args = call.arguments as? [String: Any] ?? [:]
      notifySchedule(args: args, result: result)
    case "cancel":
      let args = call.arguments as? [String: Any] ?? [:]
      notifyCancel(id: args["id"] as? String ?? "")
      result(true)
    case "cancelAll":
      let center = UNUserNotificationCenter.current()
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Adds a local notification request and answers its id (or a FlutterError).
/// A nil trigger delivers immediately; a positive delaySeconds schedules a
/// one-shot time-interval trigger.
private func notifySchedule(args: [String: Any], result: @escaping FlutterResult) {
  guard let title = args["title"] as? String, !title.isEmpty else {
    result(
      FlutterError(
        code: "bad_args",
        message: "title is required",
        details: nil,
      ),
    )
    return
  }
  let id = (args["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
  let content = UNMutableNotificationContent()
  content.title = title
  if let body = args["body"] as? String, !body.isEmpty { content.body = body }
  content.sound = .default
  let delay = (args["delaySeconds"] as? NSNumber)?.doubleValue ?? 0
  let trigger =
    delay > 0
    ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
    : nil
  let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
  UNUserNotificationCenter.current().add(request) { error in
    DispatchQueue.main.async {
      if let error = error {
        result(
          FlutterError(
            code: "schedule_failed",
            message: error.localizedDescription,
            details: nil,
          ),
        )
      } else {
        result(id)
      }
    }
  }
}

/// Cancels a scheduled (and already-delivered) notification by id.
private func notifyCancel(id: String) {
  guard !id.isEmpty else { return }
  let center = UNUserNotificationCenter.current()
  center.removePendingNotificationRequests(withIdentifiers: [id])
  center.removeDeliveredNotifications(withIdentifiers: [id])
}
