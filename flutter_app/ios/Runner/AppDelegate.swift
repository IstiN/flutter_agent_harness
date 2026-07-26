import AVFoundation
import Contacts
import EventKit
import Flutter
import HealthKit
import HomeKit
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerCalendarChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerContactsChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerHealthChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerHomeChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerICloudChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerKeychainChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerMicChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerNotifyChannel(messenger: engineBridge.applicationRegistrar.messenger())
    registerVideoChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// The `fah/icloud` method channel: iCloud Drive ubiquity container access
/// for the session/apps sync. `containerUrl` → the absolute path of the
/// container's Documents directory, or nil when iCloud is unavailable (not
/// signed in, or the iCloud capability/container id missing from the
/// provisioning profile). `syncStatus` → {available, containerUrl?}. The
/// file copy itself happens Dart-side once the container URL is known.
private func registerICloudChannel(messenger: FlutterBinaryMessenger) {
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

/// The `fah/keychain` method channel: app-scoped Keychain storage for API
/// keys (service `fa.app`). Methods: `isAvailable`, `readAll` (every entry
/// as a name→value map), `set` {name, value}, and `delete` {name}. Values
/// never leave the device (AfterFirstUnlockThisDeviceOnly — no iCloud
/// backup of secrets).
private func registerKeychainChannel(messenger: FlutterBinaryMessenger) {
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
  // Keep this identical to the macOS implementation: list attributes first
  // and fetch each value with a single-item data query. The combined
  // kSecReturnData + kSecMatchLimitAll query fails with errSecParam on
  // macOS, and the two-step form works on both platforms.
  var query = keychainQuery()
  query[kSecReturnAttributes as String] = true
  query[kSecMatchLimit as String] = kSecMatchLimitAll
  var item: CFTypeRef?
  guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
    let entries = item as? [[String: Any]]
  else { return [:] }
  var out: [String: String] = [:]
  for entry in entries {
    guard let account = entry[kSecAttrAccount as String] as? String else { continue }
    var dataQuery = keychainQuery(account)
    dataQuery[kSecReturnData as String] = true
    dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var data: CFTypeRef?
    if SecItemCopyMatching(dataQuery as CFDictionary, &data) == errSecSuccess,
      let bytes = data as? Data,
      let value = String(data: bytes, encoding: .utf8)
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

/// Shared store for the `fah/calendar` channel (EventKit wants a long-lived
/// EKEventStore instance).
private let calendarEventStore = EKEventStore()

/// The `fah/calendar` method channel: access to the user's system calendar
/// via EventKit. Methods: `isAvailable`, `requestAccess`, `events` with
/// {startMs, endMs} returning a list of event maps, `calendars` listing the
/// event calendars, plus the write methods `createEvent` / `updateEvent` /
/// `deleteEvent` (recurrence, alarms, url, span supported).
private func registerCalendarChannel(messenger: FlutterBinaryMessenger) {
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
    case "calendars":
      result(calendarCalendars())
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

/// Requests full access to events (iOS 17+ API; the legacy requestAccess on
/// older systems). The OS shows its prompt at most once.
private func requestCalendarAccess(result: @escaping FlutterResult) {
  if #available(iOS 17.0, *) {
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
  if #available(iOS 17.0, *) {
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
    if let url = event.url { map["url"] = url.absoluteString }
    if let alarms = event.alarms, !alarms.isEmpty {
      // Minutes BEFORE the start (relativeOffset is negative seconds).
      map["alarms"] = alarms.map { Int((-$0.relativeOffset) / 60) }
    }
    if let rule = event.recurrenceRules?.first {
      map["recurrence"] = calendarRecurrenceSummary(rule)
    }
    return map
  }
}

/// The event calendars as Flutter-friendly maps ({title, source, writable});
/// empty when access is not granted.
private func calendarCalendars() -> [[String: Any]] {
  guard calendarWriteAccessGranted() else { return [] }
  return calendarEventStore.calendars(for: .event).map { calendar in
    [
      "title": calendar.title,
      "source": calendar.source.title,
      "writable": calendar.allowsContentModifications,
    ]
  }
}

/// Compact recurrence summary for the `events` map: {frequency, interval,
/// daysOfWeek?, daysOfMonth?, untilMs?|count?} — the Dart side renders it.
private func calendarRecurrenceSummary(_ rule: EKRecurrenceRule) -> [String: Any] {
  var summary: [String: Any] = ["interval": max(1, rule.interval)]
  switch rule.frequency {
  case .daily: summary["frequency"] = "daily"
  case .weekly: summary["frequency"] = "weekly"
  case .monthly: summary["frequency"] = "monthly"
  case .yearly: summary["frequency"] = "yearly"
  @unknown default: summary["frequency"] = "daily"
  }
  if let days = rule.daysOfTheWeek, !days.isEmpty {
    summary["daysOfWeek"] = days.map { calendarWeekdayCode($0.dayOfTheWeek) }
  }
  if let days = rule.daysOfTheMonth, !days.isEmpty {
    summary["daysOfMonth"] = days.map { $0.intValue }
  }
  if let end = rule.recurrenceEnd {
    if let date = end.endDate {
      summary["untilMs"] = Int64(date.timeIntervalSince1970 * 1000)
    } else if end.occurrenceCount > 0 {
      summary["count"] = end.occurrenceCount
    }
  }
  return summary
}

/// Two-letter weekday code (`MO`..`SU`) matching the Dart-side convention.
private func calendarWeekdayCode(_ weekday: EKWeekday) -> String {
  switch weekday {
  case .monday: return "MO"
  case .tuesday: return "TU"
  case .wednesday: return "WE"
  case .thursday: return "TH"
  case .friday: return "FR"
  case .saturday: return "SA"
  case .sunday: return "SU"
  @unknown default: return "MO"
  }
}

/// Whether the store may write events — the same full-access check the
/// read path applies (iOS 17+ API; legacy status on older systems).
private func calendarWriteAccessGranted() -> Bool {
  let status = EKEventStore.authorizationStatus(for: .event)
  if #available(iOS 17.0, *) {
    return status == .fullAccess
  }
  return status == .authorized
}

/// Applies the shared write fields ({title, startMs, endMs, allDay,
/// calendar, location, notes, url, alarms, recurrence|removeRecurrence}) to
/// [event]; only present keys are applied. A present alarms list REPLACES
/// the alarms ([] clears them); a present recurrence map replaces the rule
/// and removeRecurrence=true drops it.
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
  if let urlString = args["url"] as? String {
    event.url = urlString.isEmpty ? nil : URL(string: urlString)
  }
  if let minutes = args["alarms"] as? [NSNumber] {
    event.alarms = minutes.map { EKAlarm(relativeOffset: -$0.doubleValue * 60) }
  }
  if let recurrence = args["recurrence"] as? [String: Any] {
    if let rule = calendarRecurrenceRule(args: recurrence) {
      event.recurrenceRules = [rule]
    }
  } else if args["removeRecurrence"] as? Bool == true {
    event.recurrenceRules = nil
  }
  if let name = args["calendar"] as? String,
    let match = calendarEventStore.calendars(for: .event)
      .first(where: { $0.title == name })
  {
    event.calendar = match
  }
}

/// Builds an EKRecurrenceRule from {frequency, interval?, daysOfWeek?,
/// daysOfMonth?, untilMs?|count?}; nil when the frequency is unknown (the
/// Dart side validates the combinations before they get here).
private func calendarRecurrenceRule(args: [String: Any]) -> EKRecurrenceRule? {
  let frequency: EKRecurrenceFrequency
  switch args["frequency"] as? String {
  case "daily": frequency = .daily
  case "weekly": frequency = .weekly
  case "monthly": frequency = .monthly
  case "yearly": frequency = .yearly
  default: return nil
  }
  let interval = max(1, (args["interval"] as? NSNumber)?.intValue ?? 1)
  var daysOfWeek: [EKRecurrenceDayOfWeek]? = nil
  if let codes = args["daysOfWeek"] as? [String], !codes.isEmpty {
    daysOfWeek = codes.compactMap { code -> EKRecurrenceDayOfWeek? in
      switch code {
      case "MO": return EKRecurrenceDayOfWeek(.monday)
      case "TU": return EKRecurrenceDayOfWeek(.tuesday)
      case "WE": return EKRecurrenceDayOfWeek(.wednesday)
      case "TH": return EKRecurrenceDayOfWeek(.thursday)
      case "FR": return EKRecurrenceDayOfWeek(.friday)
      case "SA": return EKRecurrenceDayOfWeek(.saturday)
      case "SU": return EKRecurrenceDayOfWeek(.sunday)
      default: return nil
      }
    }
  }
  let daysOfMonth = (args["daysOfMonth"] as? [NSNumber])?.filter {
    $0.intValue >= 1 && $0.intValue <= 31
  }
  var end: EKRecurrenceEnd? = nil
  if let untilMs = (args["untilMs"] as? NSNumber)?.int64Value {
    end = EKRecurrenceEnd(
      end: Date(timeIntervalSince1970: TimeInterval(untilMs) / 1000),
    )
  } else if let count = (args["count"] as? NSNumber)?.intValue, count > 0 {
    end = EKRecurrenceEnd(occurrenceCount: count)
  }
  return EKRecurrenceRule(
    recurrenceWith: frequency,
    interval: interval,
    daysOfTheWeek: daysOfWeek,
    daysOfTheMonth: daysOfMonth,
    monthsOfTheYear: nil,
    weeksOfTheYear: nil,
    daysOfTheYear: nil,
    setPositions: nil,
    end: end,
  )
}

/// Creates an event from {title, startMs, endMs, allDay?, calendar?,
/// location?, notes?, url?, alarms?, recurrence?} and returns the new event
/// id (or a FlutterError).
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
  let span: EKSpan = (args["span"] as? String) == "future" ? .futureEvents : .thisEvent
  do {
    try calendarEventStore.save(event, span: span, commit: true)
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
/// args["span"] "future" also removes the later occurrences of a recurring
/// event (default: only this one).
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
    let span: EKSpan = (args["span"] as? String) == "future" ? .futureEvents : .thisEvent
    try calendarEventStore.remove(event, span: span, commit: true)
    return true
  } catch {
    return FlutterError(
      code: "delete_failed",
      message: error.localizedDescription,
      details: nil,
    )
  }
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
private func registerContactsChannel(messenger: FlutterBinaryMessenger) {
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
      result(contactsSearch(
        query: args["query"] as? String ?? "",
        limit: args["limit"] as? Int ?? 200,
        offset: args["offset"] as? Int ?? 0,
      ))
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

/// Whether the store may read contacts (iOS 18's limited access counts —
/// the selected contacts can be read and new ones created).
private func contactsAccessGranted() -> Bool {
  let status = CNContactStore.authorizationStatus(for: .contacts)
  if #available(iOS 18.0, *) {
    return status == .authorized || status == .limited
  }
  return status == .authorized
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
private func contactsSearch(
  query: String,
  limit: Int,
  offset: Int,
) -> [[String: Any]] {
  guard contactsAccessGranted() else { return [] }
  var matches: [[String: Any]] = []
  let digits = String(query.filter { $0.isNumber })
  do {
    if query.isEmpty {
      // Full address book, paged — the dedup/cleanup workflow needs it.
      let request = CNContactFetchRequest(keysToFetch: contactKeys)
      var index = 0
      try contactStore.enumerateContacts(with: request) { contact, stop in
        if index >= offset {
          matches.append(contactMap(contact))
          if matches.count >= limit { stop.pointee = true }
        }
        index += 1
      }
    } else if digits.count >= 3 {
      // Digit queries match names AND phone-number digits (dedup by number).
      let request = CNContactFetchRequest(keysToFetch: contactKeys)
      try contactStore.enumerateContacts(with: request) { contact, stop in
        let nameMatch =
          contact.givenName.localizedCaseInsensitiveContains(query)
          || contact.familyName.localizedCaseInsensitiveContains(query)
        let phoneMatch = contact.phoneNumbers.contains {
          String($0.value.stringValue.filter { $0.isNumber }).contains(digits)
        }
        if nameMatch || phoneMatch {
          matches.append(contactMap(contact))
          if matches.count >= limit { stop.pointee = true }
        }
      }
    } else {
      let predicate = CNContact.predicateForContacts(matchingName: query)
      matches = try contactStore.unifiedContacts(
        matching: predicate,
        keysToFetch: contactKeys,
      ).dropFirst(offset).prefix(limit).map(contactMap)
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
/// is malformed (the open itself completes asynchronously).
private func contactsOpenUrl(_ urlString: String) -> Any {
  guard let url = URL(string: urlString) else {
    return FlutterError(
      code: "bad_url",
      message: "Cannot parse URL: \(urlString)",
      details: nil,
    )
  }
  guard UIApplication.shared.canOpenURL(url) else {
    return FlutterError(
      code: "no_handler",
      message:
        "No app on this device can open \(url.scheme ?? urlString) links "
        + "(the Phone/Messages app is unavailable — e.g. on the Simulator)",
      details: nil,
    )
  }
  UIApplication.shared.open(url, options: [:]) { _ in }
  return true
}

/// Shared store for the `fah/health` channel (HKHealthStore is meant to be
/// long-lived).
private let healthStore = HKHealthStore()

/// The types the `summary` method reads: daily step counts, resting heart
/// rate, and sleep analysis. Read-only — the app never writes samples.
private let healthReadTypes: Set<HKObjectType> = [
  HKQuantityType(.stepCount),
  HKQuantityType(.restingHeartRate),
  HKCategoryType(.sleepAnalysis),
]

/// Day labels for the `summary` entries ("yyyy-MM-dd", local calendar).
private let healthDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

/// The `fah/health` method channel: read-only access to the user's HealthKit
/// data (iOS only — there is no HealthKit on macOS). Methods: `isAvailable`,
/// `requestAccess`, and `summary` with {days} answering {steps,
/// restingHeartRate, sleepHours} — each a list of {date, value} day entries.
private func registerHealthChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(
    name: "fah/health",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "requestAccess":
      healthStore.requestAuthorization(toShare: [], read: healthReadTypes) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "summary":
      let args = call.arguments as? [String: Any] ?? [:]
      let days = (args["days"] as? NSNumber)?.intValue ?? 7
      healthSummary(days: days, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// An empty summary map in the channel's result shape.
private func healthEmptySummary() -> [String: Any] {
  [
    "steps": [[String: Any]](),
    "restingHeartRate": [[String: Any]](),
    "sleepHours": [[String: Any]](),
  ]
}

/// Daily summaries for the last [days] days (clamped to 1–31): cumulative
/// step counts, average resting heart rate, and asleep hours per night.
/// Runs the three HealthKit queries in parallel and answers once; days
/// without data are omitted from each series.
private func healthSummary(days: Int, result: @escaping FlutterResult) {
  guard HKHealthStore.isHealthDataAvailable() else {
    result(healthEmptySummary())
    return
  }
  let span = min(max(days, 1), 31)
  let calendar = Calendar.current
  let today = calendar.startOfDay(for: Date())
  guard let start = calendar.date(byAdding: .day, value: -(span - 1), to: today) else {
    result(healthEmptySummary())
    return
  }
  let end = Date()
  let group = DispatchGroup()
  var steps: [[String: Any]] = []
  var resting: [[String: Any]] = []
  var sleep: [[String: Any]] = []

  group.enter()
  healthQuantitySeries(
    type: HKQuantityType(.stepCount),
    unit: .count(),
    options: .cumulativeSum,
    start: start,
    end: end,
  ) { entries in
    steps = entries
    group.leave()
  }

  group.enter()
  healthQuantitySeries(
    type: HKQuantityType(.restingHeartRate),
    unit: HKUnit.count().unitDivided(by: .minute()),
    options: .discreteAverage,
    start: start,
    end: end,
  ) { entries in
    resting = entries
    group.leave()
  }

  group.enter()
  healthSleepSeries(start: start) { entries in
    sleep = entries
    group.leave()
  }

  group.notify(queue: .main) {
    result([
      "steps": steps,
      "restingHeartRate": resting,
      "sleepHours": sleep,
    ])
  }
}

/// Per-day statistics for one quantity type as {date, value} entries; days
/// without samples are omitted. Steps come out as whole counts, resting
/// heart rate as whole bpm.
private func healthQuantitySeries(
  type: HKQuantityType,
  unit: HKUnit,
  options: HKStatisticsOptions,
  start: Date,
  end: Date,
  completion: @escaping ([[String: Any]]) -> Void,
) {
  var interval = DateComponents()
  interval.day = 1
  let query = HKStatisticsCollectionQuery(
    quantityType: type,
    quantitySamplePredicate: nil,
    options: options,
    anchorDate: start,
    intervalComponents: interval,
  )
  query.initialResultsHandler = { _, collection, _ in
    var entries: [[String: Any]] = []
    collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
      let quantity =
        options == .cumulativeSum ? statistics.sumQuantity() : statistics.averageQuantity()
      guard let quantity = quantity else { return }
      entries.append([
        "date": healthDayFormatter.string(from: statistics.startDate),
        "value": quantity.doubleValue(for: unit).rounded(),
      ])
    }
    completion(entries)
  }
  healthStore.execute(query)
}

/// Asleep hours per night as {date, value} entries (one decimal). A night is
/// attributed to the day it ends on — technically the calendar day after
/// (sample end − 12 h). Days without asleep samples are omitted.
private func healthSleepSeries(
  start: Date,
  completion: @escaping ([[String: Any]]) -> Void,
) {
  let calendar = Calendar.current
  // Include the previous evening — the night ending on the first window day
  // starts before midnight.
  let rangeStart = calendar.date(byAdding: .hour, value: -12, to: start) ?? start
  let predicate = HKQuery.predicateForSamples(
    withStart: rangeStart,
    end: nil,
    options: .strictEndDate,
  )
  let query = HKSampleQuery(
    sampleType: HKCategoryType(.sleepAnalysis),
    predicate: predicate,
    limit: HKObjectQueryNoLimit,
    sortDescriptors: nil,
  ) { _, samples, _ in
    var secondsByDay: [String: Double] = [:]
    for case let sample as HKCategorySample in samples ?? [] {
      guard sample.value != HKCategoryValueSleepAnalysis.awake.rawValue else {
        continue
      }
      if #available(iOS 16.0, *) {
        guard sample.value != HKCategoryValueSleepAnalysis.inBed.rawValue else {
          continue
        }
      }
      let shifted = sample.endDate.addingTimeInterval(-12 * 3600)
      guard
        let morning = calendar.date(
          byAdding: .day,
          value: 1,
          to: calendar.startOfDay(for: shifted),
        )
      else { continue }
      let key = healthDayFormatter.string(from: morning)
      secondsByDay[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
    }
    let earliest = healthDayFormatter.string(from: start)
    let latest = healthDayFormatter.string(from: Date())
    let entries =
      secondsByDay
      .filter { $0.key >= earliest && $0.key <= latest }
      .map { ["date": $0.key, "value": ($0.value / 3600 * 10).rounded() / 10] as [String: Any] }
      .sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
    completion(entries)
  }
  healthStore.execute(query)
}


/// Shared manager for the `fah/home` channel (HMHomeManager is meant to be
/// long-lived; creating it is also what triggers the OS home-data prompt).
private let homeManager = HMHomeManager()

/// Delegate for the `fah/home` channel: homes load asynchronously after the
/// user answers the access prompt, so pending Flutter results wait here for
/// `homeManagerDidUpdateHomes` — and a deny, which reports `.determined`
/// without `.authorized` and may never deliver a homes update, is caught by
/// polling the authorization status.
private final class HomeChannelDelegate: NSObject, HMHomeManagerDelegate {
  /// `requestAccess` results waiting for the prompt answer.
  var pendingResults: [FlutterResult] = []
  /// Closures waiting for the first homes load: with access granted long
  /// ago `requestAccess` answers immediately while `homeManager.homes` is
  /// still empty, so the first list call waits here (answered with what we
  /// have after [homesWaitTimeout]).
  var homesWaiters: [() -> Void] = []
  /// Remaining half-second polls while waiting for the prompt answer.
  private var accessPollsLeft = 0

  /// How long a read call waits for the first homes load before answering
  /// with what we have (usually an empty list).
  let homesWaitTimeout: TimeInterval = 5

  func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
    NSLog(
      "[fah/home] homeManagerDidUpdateHomes: \(manager.homes.count) home(s), "
        + "authorizationStatus=\(manager.authorizationStatus.rawValue)",
    )
    answerAccessResults()
    flushHomesWaiters()
  }

  /// Adds [result] to the pending `requestAccess` answers and polls for the
  /// prompt outcome — without the poll a deny would hang the Flutter side
  /// forever (no homes update fires).
  func waitForAccessAnswer(result: @escaping FlutterResult) {
    pendingResults.append(result)
    accessPollsLeft = 240 // two minutes of half-second polls
    pollAccessAnswer()
  }

  /// Runs [work] once the homes have loaded, or after [homesWaitTimeout]
  /// with whatever is there (the delegate's homes update flushes early).
  func whenHomesLoaded(_ work: @escaping () -> Void) {
    let first = homesWaiters.isEmpty
    homesWaiters.append(work)
    guard first else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + homesWaitTimeout) { [self] in
      if !homesWaiters.isEmpty {
        NSLog(
          "[fah/home] homes wait timed out — answering with "
            + "\(homeManager.homes.count) home(s)",
        )
      }
      flushHomesWaiters()
    }
  }

  private func flushHomesWaiters() {
    let waiters = homesWaiters
    homesWaiters = []
    for waiter in waiters {
      DispatchQueue.main.async(execute: waiter)
    }
  }

  private func pollAccessAnswer() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
      guard !pendingResults.isEmpty else { return }
      if homeManager.authorizationStatus.contains(.determined) {
        // The prompt was answered — granted or denied, answer either way.
        answerAccessResults()
        return
      }
      accessPollsLeft -= 1
      if accessPollsLeft <= 0 {
        NSLog("[fah/home] requestAccess timed out waiting for the prompt")
        let results = pendingResults
        pendingResults = []
        for result in results {
          result(false)
        }
        return
      }
      pollAccessAnswer()
    }
  }

  private func answerAccessResults() {
    let results = pendingResults
    pendingResults = []
    for result in results {
      DispatchQueue.main.async { result(homeAccessGranted()) }
    }
  }
}

private let homeChannelDelegate = HomeChannelDelegate()

/// Whether the user granted home-data access. `.determined` only means the
/// prompt was answered — access itself is the `.authorized` flag.
private func homeAccessGranted() -> Bool {
  homeManager.authorizationStatus.contains(.authorized)
}

/// The `fah/home` method channel: HomeKit home control (iOS only — there is
/// no HomeKit framework on macOS). Methods: `isAvailable`, `requestAccess`,
/// `listHomes` → [{id, name, primary, roomCount, accessoryCount}],
/// `listRooms` {homeId?} → [{id, name, homeName, accessoryCount}],
/// `listAccessories` {homeId?, roomId?} → [{id, name, room, homeName,
/// category, reachable, isOn?, brightness?, targetTemperature?, services:
/// [{type, name, characteristics: [{type, value?, readable, writable}]}]}],
/// `readAccessory` {id} → one accessory map with freshly-read values,
/// `writeCharacteristic` {id, type, value} writing ANY writable
/// characteristic by its HomeKit type string, `listScenes` {homeId?} →
/// [{id, name, homeName, actionCount, executing}], `executeScene` {id}, and
/// the convenience writes `setPower` {id, on}, `setBrightness` {id, value},
/// `setTargetTemperature` {id, celsius}. NSHomeKitUsageDescription is
/// declared in Info.plist.
private func registerHomeChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(
    name: "fah/home",
    binaryMessenger: messenger,
  )
  homeManager.delegate = homeChannelDelegate
  channel.setMethodCallHandler { call, result in
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      NSLog(
        "[fah/home] isAvailable: "
          + "authorizationStatus=\(homeManager.authorizationStatus.rawValue)",
      )
      result(true)
    case "requestAccess":
      homeRequestAccess(result: result)
    case "listHomes":
      homeRunWhenHomesReady { result(homeListHomes()) }
    case "listRooms":
      homeRunWhenHomesReady {
        result(homeListRooms(homeId: args["homeId"] as? String))
      }
    case "listAccessories":
      homeRunWhenHomesReady {
        homeListAccessories(
          homeId: args["homeId"] as? String,
          roomId: args["roomId"] as? String,
          result: result,
        )
      }
    case "readAccessory":
      homeRunWhenHomesReady {
        homeReadAccessory(id: args["id"] as? String ?? "", result: result)
      }
    case "writeCharacteristic":
      guard
        let type = args["type"] as? String,
        !type.isEmpty,
        let value = args["value"]
      else {
        result(
          FlutterError(
            code: "bad_args",
            message: "type and value are required",
            details: nil,
          ),
        )
        return
      }
      homeRunWhenHomesReady {
        homeWriteCharacteristic(
          id: args["id"] as? String ?? "",
          type: type,
          value: value,
          result: result,
        )
      }
    case "listScenes":
      homeRunWhenHomesReady {
        result(homeListScenes(homeId: args["homeId"] as? String))
      }
    case "executeScene":
      homeRunWhenHomesReady {
        homeExecuteScene(id: args["id"] as? String ?? "", result: result)
      }
    case "setPower":
      homeRunWhenHomesReady {
        homeWriteCharacteristic(
          id: args["id"] as? String ?? "",
          type: HMCharacteristicTypePowerState,
          value: args["on"] as? Bool ?? false,
          result: result,
        )
      }
    case "setBrightness":
      let value = (args["value"] as? NSNumber)?.intValue ?? -1
      guard (0...100).contains(value) else {
        result(
          FlutterError(
            code: "bad_args",
            message: "value must be between 0 and 100",
            details: nil,
          ),
        )
        return
      }
      homeRunWhenHomesReady {
        homeWriteCharacteristic(
          id: args["id"] as? String ?? "",
          type: HMCharacteristicTypeBrightness,
          value: value,
          result: result,
        )
      }
    case "setTargetTemperature":
      guard let celsius = (args["celsius"] as? NSNumber)?.doubleValue else {
        result(
          FlutterError(
            code: "bad_args",
            message: "celsius is required",
            details: nil,
          ),
        )
        return
      }
      homeRunWhenHomesReady {
        homeWriteCharacteristic(
          id: args["id"] as? String ?? "",
          type: HMCharacteristicTypeTargetTemperature,
          value: celsius,
          result: result,
        )
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Answers a `requestAccess` call. HomeKit has no explicit request API:
/// touching `homes` on the manager is what makes the OS show its prompt
/// (once), and the homes arrive via the delegate afterwards.
private func homeRequestAccess(result: @escaping FlutterResult) {
  NSLog(
    "[fah/home] requestAccess: "
      + "authorizationStatus=\(homeManager.authorizationStatus.rawValue)",
  )
  if homeAccessGranted() {
    result(true)
    return
  }
  let status = homeManager.authorizationStatus
  if status.contains(.determined) {
    // The prompt was already answered (and denied or restricted).
    result(false)
    return
  }
  _ = homeManager.homes // triggers the OS prompt on first access
  homeChannelDelegate.waitForAccessAnswer(result: result)
}

/// Runs [work] once the homes have loaded. HMHomeManager delivers the homes
/// asynchronously, so with access granted long ago (requestAccess answers
/// immediately) the first read call would otherwise see `homes == []` —
/// wait for the first `homeManagerDidUpdateHomes` instead (the delegate
/// answers with what we have after a timeout).
private func homeRunWhenHomesReady(_ work: @escaping () -> Void) {
  if homeAccessGranted(), homeManager.homes.isEmpty {
    NSLog("[fah/home] access granted but homes not loaded yet — waiting")
    homeChannelDelegate.whenHomesLoaded(work)
  } else {
    work()
  }
}

/// The homes matching [homeId] (all of them when nil).
private func homeHomes(homeId: String?) -> [HMHome] {
  guard let homeId else { return homeManager.homes }
  return homeManager.homes.filter { $0.uniqueIdentifier.uuidString == homeId }
}

/// Answers `listHomes`: one map per home. Empty when access is not granted.
private func homeListHomes() -> [[String: Any]] {
  guard homeAccessGranted() else { return [] }
  NSLog("[fah/home] listHomes: \(homeManager.homes.count) home(s)")
  return homeManager.homes.map { home in
    [
      "id": home.uniqueIdentifier.uuidString,
      "name": home.name,
      "primary": home.isPrimary,
      "roomCount": home.rooms.count,
      "accessoryCount": home.accessories.count,
    ]
  }
}

/// Answers `listRooms`: one map per room across the matching homes. Empty
/// when access is not granted.
private func homeListRooms(homeId: String?) -> [[String: Any]] {
  guard homeAccessGranted() else { return [] }
  var out: [[String: Any]] = []
  for home in homeHomes(homeId: homeId) {
    for room in home.rooms {
      out.append([
        "id": room.uniqueIdentifier.uuidString,
        "name": room.name,
        "homeName": home.name,
        "accessoryCount": room.accessories.count,
      ])
    }
  }
  NSLog("[fah/home] listRooms: \(out.count) room(s)")
  return out
}

/// Answers `listScenes`: one map per action set across the matching homes.
/// Empty when access is not granted.
private func homeListScenes(homeId: String?) -> [[String: Any]] {
  guard homeAccessGranted() else { return [] }
  var out: [[String: Any]] = []
  for home in homeHomes(homeId: homeId) {
    for actionSet in home.actionSets {
      out.append([
        "id": actionSet.uniqueIdentifier.uuidString,
        "name": actionSet.name,
        "homeName": home.name,
        "actionCount": actionSet.actions.count,
        "executing": actionSet.isExecuting,
      ])
    }
  }
  NSLog("[fah/home] listScenes: \(out.count) scene(s)")
  return out
}

/// Answers `executeScene`: runs the action set with [id]; true or a
/// FlutterError (denied / not_found / execute_failed).
private func homeExecuteScene(id: String, result: @escaping FlutterResult) {
  guard homeAccessGranted() else {
    result(
      FlutterError(
        code: "denied",
        message: "home access was not granted",
        details: nil,
      ),
    )
    return
  }
  for home in homeManager.homes {
    guard
      let actionSet = home.actionSets.first(where: {
        $0.uniqueIdentifier.uuidString == id
      })
    else { continue }
    home.executeActionSet(actionSet) { error in
      DispatchQueue.main.async {
        if let error {
          NSLog(
            "[fah/home] executeActionSet \(actionSet.name) failed: "
              + error.localizedDescription,
          )
          result(
            FlutterError(
              code: "execute_failed",
              message: error.localizedDescription,
              details: nil,
            ),
          )
        } else {
          NSLog("[fah/home] executeActionSet \(actionSet.name): ok")
          result(true)
        }
      }
    }
    return
  }
  result(
    FlutterError(
      code: "not_found",
      message: "no scene with this id",
      details: nil,
    ),
  )
}

/// One accessory as a Flutter-friendly map with the static fields only —
/// [homeFullAccessoryMap] adds the state conveniences and the services
/// breakdown from the (possibly just-refreshed) characteristic values.
private func homeAccessoryMap(
  _ accessory: HMAccessory,
  room: String,
  homeName: String,
) -> [String: Any] {
  [
    "id": accessory.uniqueIdentifier.uuidString,
    "name": accessory.name,
    "room": room,
    "homeName": homeName,
    "category": homeCategory(accessory),
    "reachable": accessory.isReachable,
  ]
}

/// The category label the Dart side switches on: one of lightbulb / switch /
/// outlet / thermostat, or the raw HomeKit category type otherwise.
private func homeCategory(_ accessory: HMAccessory) -> String {
  switch accessory.category.categoryType {
  case HMAccessoryCategoryTypeLightbulb:
    return "lightbulb"
  case HMAccessoryCategoryTypeSwitch:
    return "switch"
  case HMAccessoryCategoryTypeOutlet:
    return "outlet"
  case HMAccessoryCategoryTypeThermostat:
    return "thermostat"
  default:
    return accessory.category.categoryType
  }
}

/// Finds the first characteristic of [type] across the accessory's services.
private func homeCharacteristic(
  _ accessory: HMAccessory,
  type: String,
) -> HMCharacteristic? {
  for service in accessory.services {
    for characteristic in service.characteristics
    where characteristic.characteristicType == type {
      return characteristic
    }
  }
  return nil
}

/// All accessories across the matching homes and rooms (including the room
/// for the entire home) as (accessory, map) pairs. Empty when access is not
/// granted (the Dart side requests access before calling).
private func homeAllAccessories(
  homeId: String? = nil,
  roomId: String? = nil,
) -> [(HMAccessory, [String: Any])] {
  guard homeAccessGranted() else { return [] }
  var out: [(HMAccessory, [String: Any])] = []
  let homes = homeHomes(homeId: homeId)
  for home in homes {
    var rooms = home.rooms
    rooms.append(home.roomForEntireHome())
    for room in rooms {
      if let roomId, room.uniqueIdentifier.uuidString != roomId { continue }
      for accessory in room.accessories {
        out.append((accessory, homeAccessoryMap(accessory, room: room.name, homeName: home.name)))
      }
    }
    NSLog(
      "[fah/home] home \"\(home.name)\": \(home.accessories.count) "
        + "accessory(ies), \(home.rooms.count) room(s)",
    )
  }
  NSLog(
    "[fah/home] accessories: \(out.count) across \(homes.count) home(s)",
  )
  return out
}

/// One service with its characteristics as a Flutter-friendly map.
/// Characteristic values are included when [includeValues] (reachable
/// accessories only) and channel-safe (Bool/Number/String).
private func homeServiceMap(
  _ service: HMService,
  includeValues: Bool,
) -> [String: Any] {
  [
    "type": service.serviceType,
    "name": service.name,
    "characteristics": service.characteristics.map { characteristic in
      var map: [String: Any] = [
        "type": characteristic.characteristicType,
        "readable": characteristic.properties.contains(
          HMCharacteristicPropertyReadable,
        ),
        "writable": characteristic.properties.contains(
          HMCharacteristicPropertyWritable,
        ),
      ]
      if includeValues, let value = homeFlutterValue(characteristic.value) {
        map["value"] = value
      }
      return map
    },
  ]
}

/// Converts a characteristic value to a channel-safe type (Number/String —
/// boolean NSNumbers cross the standard codec as Dart bools); anything else
/// is dropped (the map then omits `value`).
private func homeFlutterValue(_ value: Any?) -> Any? {
  if let number = value as? NSNumber { return number }
  if let string = value as? String { return string }
  return nil
}

/// The full accessory map: the static fields, the flat isOn / brightness /
/// targetTemperature conveniences (read from the current characteristic
/// values), and the whole `services` breakdown.
private func homeFullAccessoryMap(
  _ accessory: HMAccessory,
  room: String,
  homeName: String,
) -> [String: Any] {
  var map = homeAccessoryMap(accessory, room: room, homeName: homeName)
  if let characteristic = homeCharacteristic(
    accessory,
    type: HMCharacteristicTypePowerState,
  ), let number = characteristic.value as? NSNumber {
    map["isOn"] = number.boolValue
  }
  if let characteristic = homeCharacteristic(
    accessory,
    type: HMCharacteristicTypeBrightness,
  ), let number = characteristic.value as? NSNumber {
    map["brightness"] = number
  }
  if let characteristic = homeCharacteristic(
    accessory,
    type: HMCharacteristicTypeTargetTemperature,
  ), let number = characteristic.value as? NSNumber {
    map["targetTemperature"] = number
  }
  map["services"] = accessory.services.map {
    homeServiceMap($0, includeValues: accessory.isReachable)
  }
  return map
}

/// Every readable characteristic of [accessory].
private func homeReadableCharacteristics(
  _ accessory: HMAccessory,
) -> [HMCharacteristic] {
  accessory.services.flatMap { service in
    service.characteristics.filter {
      $0.properties.contains(HMCharacteristicPropertyReadable)
    }
  }
}

/// Answers `listAccessories`: collects every accessory, then reads every
/// readable characteristic of the reachable ones in parallel (the maps are
/// built from the refreshed values once the reads land). Empty when access
/// is not granted.
private func homeListAccessories(
  homeId: String?,
  roomId: String?,
  result: @escaping FlutterResult,
) {
  let entries = homeAllAccessories(homeId: homeId, roomId: roomId)
  guard !entries.isEmpty else {
    result([[String: Any]]())
    return
  }
  let group = DispatchGroup()
  for (accessory, _) in entries {
    guard accessory.isReachable else { continue }
    for characteristic in homeReadableCharacteristics(accessory) {
      group.enter()
      characteristic.readValue { error in
        if let error {
          NSLog(
            "[fah/home] readValue \(characteristic.characteristicType) on "
              + "\(accessory.name) failed: \(error.localizedDescription)",
          )
        }
        group.leave()
      }
    }
  }
  group.notify(queue: .main) {
    result(
      entries.map { entry in
        homeFullAccessoryMap(
          entry.0,
          room: entry.1["room"] as? String ?? "",
          homeName: entry.1["homeName"] as? String ?? "",
        )
      },
    )
  }
}

/// Answers `readAccessory`: re-reads every readable characteristic of the
/// accessory with [id] and answers its full map with fresh values, or a
/// FlutterError (denied / not_found).
private func homeReadAccessory(id: String, result: @escaping FlutterResult) {
  guard homeAccessGranted() else {
    result(
      FlutterError(
        code: "denied",
        message: "home access was not granted",
        details: nil,
      ),
    )
    return
  }
  guard
    let (accessory, map) = homeAllAccessories()
      .first(where: { $0.0.uniqueIdentifier.uuidString == id })
  else {
    result(
      FlutterError(
        code: "not_found",
        message: "no accessory with this id",
        details: nil,
      ),
    )
    return
  }
  let group = DispatchGroup()
  if accessory.isReachable {
    for characteristic in homeReadableCharacteristics(accessory) {
      group.enter()
      characteristic.readValue { error in
        if let error {
          NSLog(
            "[fah/home] readValue \(characteristic.characteristicType) on "
              + "\(accessory.name) failed: \(error.localizedDescription)",
          )
        }
        group.leave()
      }
    }
  }
  group.notify(queue: .main) {
    result(
      homeFullAccessoryMap(
        accessory,
        room: map["room"] as? String ?? "",
        homeName: map["homeName"] as? String ?? "",
      ),
    )
  }
}

/// Writes [value] to the characteristic [type] of the accessory with [id];
/// answers true or a FlutterError (denied / not_found / unsupported /
/// write_failed).
private func homeWriteCharacteristic(
  id: String,
  type: String,
  value: Any,
  result: @escaping FlutterResult,
) {
  guard homeAccessGranted() else {
    result(
      FlutterError(
        code: "denied",
        message: "home access was not granted",
        details: nil,
      ),
    )
    return
  }
  guard
    let accessory = homeAllAccessories()
      .first(where: { $0.0.uniqueIdentifier.uuidString == id })?.0
  else {
    result(
      FlutterError(
        code: "not_found",
        message: "no accessory with this id",
        details: nil,
      ),
    )
    return
  }
  guard let characteristic = homeCharacteristic(accessory, type: type) else {
    result(
      FlutterError(
        code: "unsupported",
        message: "this accessory has no such characteristic",
        details: nil,
      ),
    )
    return
  }
  characteristic.writeValue(value) { error in
    DispatchQueue.main.async {
      if let error = error {
        NSLog(
          "[fah/home] writeValue \(type) on \(accessory.name) failed: "
            + error.localizedDescription,
        )
        result(
          FlutterError(
            code: "write_failed",
            message: error.localizedDescription,
            details: nil,
          ),
        )
      } else {
        result(true)
      }
    }
  }
}

/// The `fah/mic` method channel: microphone capture to a temporary .m4a
/// file (AVAudioRecorder, AAC 44.1 kHz mono, auto-stop at 120 s — no
/// streaming). Methods: `isAvailable`, `requestAccess`, `startRecording`,
/// and `stopRecording` → {path, durationMs, sampleRate}. The usage string
/// (NSMicrophoneUsageDescription) lives in Info.plist.
private func registerMicChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(
    name: "fah/mic",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "isAvailable":
      result(true)
    case "requestAccess":
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async { result(granted) }
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
  let session = AVAudioSession.sharedInstance()
  do {
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)
  } catch {
    return FlutterError(
      code: "audio_session",
      message: error.localizedDescription,
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
      try? session.setActive(false)
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
    try? session.setActive(false)
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
  try? AVAudioSession.sharedInstance().setActive(false)
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
private func registerVideoChannel(messenger: FlutterBinaryMessenger) {
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
      guard let image = try? generator.copyCGImage(at: time, actualTime: nil),
        let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
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
/// Shows banners for notifications delivered while the app is in the
/// foreground — iOS/macOS suppress them by default, which made scheduled
/// reminders look like they never fired.
private final class FaNotificationDelegate: NSObject,
  UNUserNotificationCenterDelegate
{
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .badge])
  }
}

private let faNotificationDelegate = FaNotificationDelegate()

/// UNUserNotificationCenter — no remote pushes, no background modes.
/// Methods: `requestAccess`, `schedule` {title, body, id?, delaySeconds?}
/// answering the scheduled id (immediate when delaySeconds is absent/zero,
/// otherwise a one-shot UNTimeIntervalNotificationTrigger — no repeats),
/// `cancel` {id}, and `cancelAll`.
private func registerNotifyChannel(messenger: FlutterBinaryMessenger) {
  UNUserNotificationCenter.current().delegate = faNotificationDelegate
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
