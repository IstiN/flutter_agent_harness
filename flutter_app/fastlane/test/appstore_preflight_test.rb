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

  # AC3 — confirm mismatch aborts (fat-finger guard)
  begin
    AppstorePreflight.validate_confirm!(version: "1.2.3", confirm: "1.2.4")
    raise "FAIL: confirm mismatch must raise"
  rescue RuntimeError => e
    raise "FAIL: wrong message: #{e.message}" unless e.message.include?("CONFIRM MISMATCH") && e.message.include?("1.2.4")
  end
  ok("confirm mismatch aborts with a named error, nothing mutated")
  AppstorePreflight.validate_confirm!(version: "1.2.3", confirm: "1.2.3")
  ok("matching confirm passes")

  # AC3 — version missing from ASC → fail before mutation
  d = AppstorePreflight.decide(version: "9.9.9", app_store_version: nil, builds: [])
  raise "FAIL: version missing must fail, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("9.9.9") && d["reason"].include?("store-metadata.yml")
  ok("version missing → fail before mutation, points at store-metadata.yml")

  # AC3 — build still processing → fail with an ETA hint
  d = AppstorePreflight.decide(
    version: "1.2.3",
    app_store_version: { "state" => "PREPARE_FOR_SUBMISSION" },
    builds: [{ "number" => "7", "state" => "PROCESSING" }]
  )
  raise "FAIL: processing must fail with ETA hint, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("still processing") && d["reason"].include?("~15 minutes")
  ok("build still processing → fail with ETA hint, nothing submitted")

  # AC3 — already submitted → green no-op (idempotent re-run, E2)
  %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE READY_FOR_SALE ACCEPTED].each do |state|
    d = AppstorePreflight.decide(
      version: "1.2.3",
      app_store_version: { "state" => state },
      builds: [{ "number" => "7", "state" => "VALID" }]
    )
    raise "FAIL: #{state} must be a noop, got #{d.inspect}" unless d["action"] == "noop" && d["reason"].include?(state)
  end
  ok("in-flight/submitted states → green no-op notice")

  # Happy path — the latest PROCESSED build wins; processing builds are ignored
  d = AppstorePreflight.decide(
    version: "1.2.3",
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
  d = AppstorePreflight.decide(version: "1.2.3", app_store_version: { "state" => "PREPARE_FOR_SUBMISSION" }, builds: [])
  raise "FAIL: no builds must fail, got #{d.inspect}" unless d["action"] == "fail" && d["reason"].include?("No TestFlight build")
  ok("no builds for the version → fail before mutation")

  # Rejected versions stay resubmittable (NOT in SUBMITTED_STATES)
  d = AppstorePreflight.decide(
    version: "1.2.3",
    app_store_version: { "state" => "REJECTED" },
    builds: [{ "number" => "7", "state" => "VALID" }]
  )
  raise "FAIL: REJECTED must be submittable, got #{d.inspect}" unless d["action"] == "submit"
  ok("REJECTED state stays resubmittable")

  puts "appstore_preflight: #{$checks} checks OK"
end
