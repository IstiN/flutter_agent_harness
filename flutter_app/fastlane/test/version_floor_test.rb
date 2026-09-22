# frozen_string_literal: true

# Issue #798 AC1/AC2/E2 — the TestFlight version-floor pre-check matrix.
# Plain ruby, no gems (runs on the CI runner's stock ruby and anywhere
# else):
#
#   ruby flutter_app/fastlane/test/version_floor_test.rb
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

require_relative "../version_floor"

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  def approved(version, state = "READY_FOR_SALE")
    { "state" => state, "version" => version }
  end

  # AC1 — stamped below the approved floor → named abort, zero build minutes
  d = VersionFloor.decide(stamped: "1.0.100", approved: [approved("1.0.452")])
  raise "FAIL: below-floor must abort, got #{d.inspect}" unless d["action"] == "abort" && d["floor"] == "1.0.452" && d["reason"].include?("stamped 1.0.100 ≤ approved 1.0.452") && d["reason"].include?("gh-785")
  ok("AC1: stamped 1.0.100 ≤ approved 1.0.452 → named abort")

  # AC1 as it happened in #785 — the 0.1.x train under an approved 1.0.0
  d = VersionFloor.decide(stamped: "0.1.452", approved: [approved("1.0.0")])
  raise "FAIL: #785 shape must abort, got #{d.inspect}" unless d["action"] == "abort" && d["reason"].include?("0.1.452 ≤ approved 1.0.0")
  ok("AC1: the #785 shape (0.1.452 vs approved 1.0.0) aborts")

  # AC2 — stamped above the floor → pass
  d = VersionFloor.decide(stamped: "1.0.453", approved: [approved("1.0.452")])
  raise "FAIL: above-floor must pass, got #{d.inspect}" unless d["action"] == "pass" && d["reason"].include?("stamped 1.0.453 > approved 1.0.452")
  ok("AC2: stamped 1.0.453 > approved 1.0.452 → pass")

  # Equal version is NOT above the floor (90062 is a strict monotonicity)
  d = VersionFloor.decide(stamped: "1.0.452", approved: [approved("1.0.452")])
  raise "FAIL: equal must abort, got #{d.inspect}" unless d["action"] == "abort"
  ok("equal stamped == approved → abort (strict monotonicity)")

  # E2 — first-ever release: no approved versions → floor 0.0.0, passes
  d = VersionFloor.decide(stamped: "1.0.1", approved: [])
  raise "FAIL: empty approved must pass with floor 0.0.0, got #{d.inspect}" unless d["action"] == "pass" && d["floor"] == "0.0.0"
  ok("E2: no approved versions → floor 0.0.0, trivially passes")

  # E2 marker stays meaningful — the floor is surfaced either way
  d = VersionFloor.decide(stamped: "1.0.1", approved: [approved("0.9.9", "REJECTED")])
  raise "FAIL: rejected versions must not raise the floor, got #{d.inspect}" unless d["action"] == "pass" && d["floor"] == "0.0.0"
  ok("REJECTED versions never raise the floor")

  # Only genuinely approved states raise the floor: a TestFlight-only
  # version (no App Store entry) or one still in review does not block.
  d = VersionFloor.decide(
    stamped: "1.0.5",
    approved: [
      approved("1.0.4", "READY_FOR_SALE"),
      approved("1.0.9", "WAITING_FOR_REVIEW"),
      approved("1.0.8", "IN_REVIEW"),
      { "state" => "READY_FOR_SALE", "version" => "not-a-version" }
    ]
  )
  raise "FAIL: in-review entries must not raise the floor, got #{d.inspect}" unless d["action"] == "pass" && d["floor"] == "1.0.4"
  ok("floor = max of APPROVED states only; in-review (1.0.9/1.0.8)/garbage entries ignored")

  # All three approved states count (ACCEPTED and pending-dev-release are
  # Apple-approved already — 90062 compares against approved, not live)
  d = VersionFloor.decide(
    stamped: "1.0.9",
    approved: [approved("1.0.8", "ACCEPTED"), approved("1.0.7", "PENDING_DEVELOPER_RELEASE")]
  )
  raise "FAIL: ACCEPTED must raise the floor, got #{d.inspect}" unless d["action"] == "pass" && d["floor"] == "1.0.8"
  ok("ACCEPTED/PENDING_DEVELOPER_RELEASE count as approved")

  # Numeric comparison, not string: 1.0.9 < 1.0.10
  d = VersionFloor.decide(stamped: "1.0.9", approved: [approved("1.0.10")])
  raise "FAIL: numeric compare broken, got #{d.inspect}" unless d["action"] == "abort" && d["floor"] == "1.0.10"
  ok("numeric compare: 1.0.9 ≤ 1.0.10 aborts")

  # Garbage stamp aborts named instead of comparing wrong
  d = VersionFloor.decide(stamped: "auto", approved: [approved("1.0.0")])
  raise "FAIL: garbage stamp must abort named, got #{d.inspect}" unless d["action"] == "abort" && d["reason"].include?("not a comparable")
  ok("garbage stamp → named abort")

  puts "version_floor: #{$checks} checks OK"
end
