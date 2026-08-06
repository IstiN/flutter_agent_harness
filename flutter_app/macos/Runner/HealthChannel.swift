import FlutterMacOS
import HealthKit

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
/// data (macOS 14+ read-only access to HealthKit data). Methods: `isAvailable`,
/// `requestAccess`, and `summary` with {days} answering {steps,
/// restingHeartRate, sleepHours} — each a list of {date, value} day entries.
func registerHealthChannel(messenger: FlutterBinaryMessenger) {
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
      if #available(macOS 13.0, *) {
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
/// NOT named `homeManager`: HMHomeManagerDelegate's members
/// (`homeManager(_:didAdd:…)`) shadow a global with that name inside the
/// delegate class — Swift then fails with "cannot find in scope".
