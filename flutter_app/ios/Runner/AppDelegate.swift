import Contacts
import EventKit
import Flutter
import HealthKit
import UIKit

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
    registerKeychainChannel(messenger: engineBridge.applicationRegistrar.messenger())
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

/// Shared store for the `fah/calendar` channel (EventKit wants a long-lived
/// EKEventStore instance).
private let calendarEventStore = EKEventStore()

/// The `fah/calendar` method channel: access to the user's system calendar
/// via EventKit. Methods: `isAvailable`, `requestAccess`, `events` with
/// {startMs, endMs} returning a list of event maps, plus the write methods
/// `createEvent` / `updateEvent` / `deleteEvent`.
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
    return map
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
/// is malformed (the open itself completes asynchronously).
private func contactsOpenUrl(_ urlString: String) -> Bool {
  guard let url = URL(string: urlString) else { return false }
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
