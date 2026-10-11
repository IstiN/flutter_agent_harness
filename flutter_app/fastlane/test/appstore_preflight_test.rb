# frozen_string_literal: true

# Issue #239 AC3 — release-appstore.yml pre-flight matrix. Plain ruby, no
# gems (runs on the CI runner's stock ruby and anywhere else):
#
#   ruby flutter_app/fastlane/test/appstore_preflight_test.rb
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

require_relative "../appstore_preflight"

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  # AC3 — confirm mismatch → fail decision with a named reason (the lane
  # surfaces it via UI.user_error!); nothing mutated either way.
  d = AppstorePreflight.decide(version: "1.2.3", confirm: "1.2.4", app_store_version: nil, builds: [])
  raise "FAIL: confirm mismatch must fail first, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("CONFIRM MISMATCH") && d["reason"].include?("1.2.4")
  ok("confirm mismatch → named fail decision, nothing mutated")
  d = AppstorePreflight.decide(version: "1.2.3", confirm: "1.2.3", app_store_version: nil, builds: [])
  raise "FAIL: matching confirm must fall through to version check, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("store-metadata.yml")
  ok("matching confirm passes through")

  # AC3 — version missing from ASC → fail before mutation
  d = AppstorePreflight.decide(version: "9.9.9", confirm: "9.9.9", app_store_version: nil, builds: [])
  raise "FAIL: version missing must fail, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("9.9.9") && d["reason"].include?("store-metadata.yml")
  ok("version missing → fail before mutation, points at store-metadata.yml")

  # gh-1519 — the remediation must name the CREATING step: store-metadata's
  # app_store lane creates the version when absent (before gh-1519 the
  # message implied store-metadata already did it — a dead-end remediation)
  d = AppstorePreflight.decide(version: "9.9.9", confirm: "9.9.9", app_store_version: nil, builds: [])
  raise "FAIL: remediation must name the creating step, got #{d['reason'].inspect}" \
    unless d["reason"].include?("creates the version when absent")
  ok("remediation names the creating step (store-metadata app_store lane, gh-1519)")

  # AC3 — build still processing → fail with an ETA hint
  d = AppstorePreflight.decide(
    version: "1.2.3",
    confirm: "1.2.3",
    app_store_version: { "state" => "PREPARE_FOR_SUBMISSION" },
    builds: [{ "number" => "7", "state" => "PROCESSING" }]
  )
  raise "FAIL: processing must fail with ETA hint, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("still processing") && d["reason"].include?("~15 minutes")
  ok("build still processing → fail with ETA hint, nothing submitted")

  # AC3 — already submitted → green no-op (idempotent re-run, E2)
  %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE READY_FOR_SALE ACCEPTED].each do |state|
    d = AppstorePreflight.decide(
      version: "1.2.3",
      confirm: "1.2.3",
      app_store_version: { "state" => state },
      builds: [{ "number" => "7", "state" => "VALID" }]
    )
    raise "FAIL: #{state} must be a noop, got #{d.inspect}" unless d["action"] == "noop" && d["reason"].include?(state)
  end
  ok("in-flight/submitted states → green no-op notice")

  # Happy path — the latest PROCESSED build wins; processing builds are ignored
  d = AppstorePreflight.decide(
    version: "1.2.3",
    confirm: "1.2.3",
    app_store_version: { "state" => "PREPARE_FOR_SUBMISSION" },
    builds: [
      { "number" => "5", "state" => "VALID" },
      { "number" => "9", "state" => "PROCESSING" },
      { "number" => "7", "state" => "VALID" }
    ]
  )
  raise "FAIL: must submit build 7, got #{d.inspect}" unless d["action"] == "submit" && d["build_number"] == "7"
  ok("submit targets the latest PROCESSED build (7), skipping still-processing 9")

  # No builds at all → fail before mutation
  d = AppstorePreflight.decide(version: "1.2.3", confirm: "1.2.3", app_store_version: { "state" => "PREPARE_FOR_SUBMISSION" }, builds: [])
  raise "FAIL: no builds must fail, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("No TestFlight build")
  ok("no builds for the version → fail before mutation")

  # Rejected versions stay resubmittable (NOT in SUBMITTED_STATES)
  d = AppstorePreflight.decide(
    version: "1.2.3",
    confirm: "1.2.3",
    app_store_version: { "state" => "REJECTED" },
    builds: [{ "number" => "7", "state" => "VALID" }]
  )
  raise "FAIL: REJECTED must be submittable, got #{d.inspect}" unless d["action"] == "submit"
  ok("REJECTED state stays resubmittable")

  # gh-1519 rework (review thread, PR #1520): the pre-flight's bounded
  # read-side retry must cover BOTH failure arms — a nil find (read lag)
  # AND a raised call (transient ASC error, the macOS preflight probe's
  # failure class). log/sleep_fn are injected so this matrix runs with
  # no fastlane and no real sleeps.
  logs = []
  slept = []
  log = ->(msg) { logs << msg }
  no_sleep = ->(secs) { slept << secs }

  # Arm 1 — nil find (read lag): retries until the version becomes visible.
  calls = 0
  found = AppstorePreflight.with_visibility_retries(attempts: 3, delay: 20, log: log, sleep_fn: no_sleep) do
    calls += 1
    calls < 3 ? nil : "1.2.3"
  end
  raise "FAIL: nil-find arm must retry to visibility, got #{found.inspect} in #{calls} calls" unless found == "1.2.3" && calls == 3
  raise "FAIL: must sleep between retries, got #{slept.inspect}" unless slept == [20, 20]
  ok("nil find (read lag) → retries until visible (3 × call, 2 × sleep)")

  # Arm 2 — raised call (transient ASC error): retried, not instant-fail.
  calls = 0
  logs.clear
  slept.clear
  found = AppstorePreflight.with_visibility_retries(attempts: 3, delay: 20, log: log, sleep_fn: no_sleep) do
    calls += 1
    raise "Server error got 500" if calls == 1
    "1.2.3"
  end
  raise "FAIL: raised arm must retry to visibility, got #{found.inspect} in #{calls} calls" unless found == "1.2.3" && calls == 2
  raise "FAIL: the raise must be logged, got #{logs.inspect}" unless logs.any? { |m| m.include?("raised") && m.include?("attempt 1/3") }
  ok("raised call (transient ASC 500) → retried, not instant-fail")

  # Arm 2 boundary — a raise on the FINAL attempt propagates (a
  # persistent API error is not a visibility miss).
  calls = 0
  begin
    AppstorePreflight.with_visibility_retries(attempts: 3, delay: 20, log: log, sleep_fn: no_sleep) do
      calls += 1
      raise "persistent outage" if calls == 3
      nil
    end
    raise "FAIL: final-attempt raise must propagate"
  rescue RuntimeError => e
    raise "FAIL: must be the original error, got #{e.message.inspect}" unless e.message == "persistent outage"
  end
  raise "FAIL: must have attempted exactly 3 times, got #{calls}" unless calls == 3
  ok("raise on the final attempt propagates the original error")

  # Exhaustion — never visible: bounded attempts, final 'still not
  # visible' message (the genuine dead-end the pre-flight must report).
  calls = 0
  logs.clear
  slept.clear
  found = AppstorePreflight.with_visibility_retries(attempts: 3, delay: 20, log: log, sleep_fn: no_sleep) do
    calls += 1
    nil
  end
  raise "FAIL: exhaustion must return nil, got #{found.inspect}" unless found.nil?
  raise "FAIL: must stop at the attempt bound, got #{calls}" unless calls == 3
  raise "FAIL: exhaustion must be logged, got #{logs.inspect}" unless logs.last.to_s.include?("still not visible after 3 attempts")
  ok("never visible → nil after 3 attempts with a final exhaustion log")

  # Fast path — visible on the first read: no sleeps, no noise.
  calls = 0
  logs.clear
  slept.clear
  found = AppstorePreflight.with_visibility_retries(attempts: 3, delay: 20, log: log, sleep_fn: no_sleep) do
    calls += 1
    "1.2.3"
  end
  raise "FAIL: fast path must return immediately, got #{found.inspect} in #{calls} calls" unless found == "1.2.3" && calls == 1
  raise "FAIL: fast path must not sleep or log" unless slept.empty? && logs.empty?
  ok("visible on first read → immediate, no sleeps, no logs")

  puts "appstore_preflight: #{$checks} checks OK"
end
