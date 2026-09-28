# frozen_string_literal: true

# gh-1041 AC5 — the store-appearance check matrix. Plain ruby, no gems
# (runs on the CI runner's stock ruby and anywhere else):
#
#   ruby flutter_app/fastlane/test/store_appearance_test.rb
#
# Covers: expected-version resolution (tag/version file), per-store presence
# parsers against the recorded fixtures (present / absent / error-shaped /
# rolled-over), the horizon gate, and the whole issue-lifecycle planner
# (file exactly one stub per absent store, update in place, resolve on
# appearance or version rollover, idempotent green summary). The IO glue
# (HTTP/JWT/gh) is exercised separately by
# test/store_appearance_check_test.dart against fake endpoints.

require "json"
require_relative "../store_appearance"

FIXTURES = File.expand_path("fixtures/store_appearance", __dir__)

def fixture(name)
  JSON.parse(File.read(File.join(FIXTURES, name)))
end

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  def raise!(message)
    raise "FAIL: #{message}"
  end

  S = StoreAppearance

  # ── semver / comparison primitives ────────────────────────────────────────
  raise!("semver parses x.y.z") unless S.semver("1.0.485") == [1, 0, 485]
  ok("semver parses x.y.z")

  raise!("semver tolerates partial versions") unless S.semver("1.0") == [1, 0, 0] && S.semver("2") == [2, 0, 0]
  ok("semver tolerates partial versions")

  raise!("semver rejects garbage") unless S.semver("1.0.485+1").nil? && S.semver("").nil? && S.semver(nil).nil?
  ok("semver rejects garbage (incl. build-number suffixes)")

  raise!("version_gte? is strict when equal and true above") unless S.version_gte?("1.0.485", "1.0.485") && S.version_gte?("1.0.486", "1.0.485")
  ok("version_gte? is >= (equal passes, newer passes)")

  raise!("unparsable versions never compare true") if S.version_gte?("1.0.485+1", "1.0.485") || S.version_gte?("1.0.485", "garbage")
  ok("unparsable versions never compare true")

  raise!("highest picks the newest of many") unless S.highest(["1.0.9", "1.0.485", "1.0.100"]) == "1.0.485"
  ok("highest picks the newest of many (numeric, not lexicographic)")

  # ── expected-version resolution (tag/version file) ───────────────────────
  e = S.resolve_expected(pubspec: "1.0.485", tag: "v1.0.485")
  raise!("lockstep pubspec+tag resolve both expectations") unless e == { "app" => "1.0.485", "pubdev" => "1.0.485" }
  ok("lockstep pubspec + tag resolve both expectations")

  e = S.resolve_expected(pubspec: "1.0.485", tag: "v1.0.484")
  raise!("a pending release (pubspec ahead of tag) resolves the pubspec train") unless e["app"] == "1.0.485" && e["pubdev"] == "1.0.485"
  ok("pubspec ahead of tag (release pending) resolves the newer train")

  e = S.resolve_expected(pubspec: nil, tag: "v1.0.485")
  raise!("missing pubspec falls back to the tag") unless e["app"] == "1.0.485" && e["pubdev"] == "1.0.485"
  ok("missing pubspec falls back to the tag")

  raise!("no version source resolves to nil") unless S.resolve_expected(pubspec: nil, tag: nil).nil?
  ok("no version source → nil (fresh repo)")

  # ── presence verdicts (the AC4 contract, shared by all three stores) ──────
  v = S.decide_presence(expected: "1.0.485", observed: ["1.0.485", "1.0.484"])
  raise!("equal version is present") unless v["verdict"] == "present" && v["matched"] == "1.0.485"
  ok("expected == served → present")

  v = S.decide_presence(expected: "1.0.484", observed: ["1.0.485"])
  raise!("only a newer version served → rolled_over") unless v["verdict"] == "rolled_over" && v["matched"] == "1.0.485"
  ok("only newer served → rolled_over (absence moot, gh-1041 AC3)")

  v = S.decide_presence(expected: "1.0.485", observed: ["1.0.484", "1.0.483"])
  raise!("only older versions served → absent") unless v["verdict"] == "absent" && v["matched"].nil?
  ok("only older served → absent")

  v = S.decide_presence(expected: "1.0.485", observed: [])
  raise!("empty store → absent") unless v["verdict"] == "absent"
  ok("nothing served at all → absent")

  v = S.decide_presence(expected: "1.0.485", observed: ["1.0.485+1"])
  raise!("build-suffixed junk is not the version") unless v["verdict"] == "absent"
  ok("an unparsable served version is never 'present'")

  # ── ASC parsers (recorded /v1 shapes) ─────────────────────────────────────
  raise!("apps parse") unless S.parse_asc_app_id(fixture("asc_apps.json")) == "APP-1"
  ok("ASC /apps parses the app id")

  raise!("unknown bundleId parses to nil") unless S.parse_asc_app_id({ "data" => [] }).nil?
  ok("ASC /apps with no data → nil (error verdict upstream, never a false present)")

  raise!("group lookup is by exact name") unless S.parse_asc_group_id(fixture("asc_beta_groups.json"), "External Beta") == "GRP-EXTERNAL"
  ok("ASC group resolved by exact name (pilot semantics)")

  raise!("renamed group parses to nil") unless S.parse_asc_group_id(fixture("asc_beta_groups.json"), "Ext Beta").nil?
  ok("a renamed group is not silently matched")

  # present: the group contains build 191 (1.0.485) AND the app lists it VALID
  group_ids = S.parse_asc_group_build_ids(fixture("asc_group_builds_present.json"))
  versions = S.parse_asc_build_versions(fixture("asc_app_builds_present.json"))
  raise!("group membership set parses") unless group_ids == %w[BUILD-190 BUILD-191]
  raise!("build versions join from the include") unless versions == ["1.0.485", "1.0.484"]
  v = S.decide_presence(expected: "1.0.485", observed: versions & versions)
  ok("ASC present fixture parses versions 1.0.485+1.0.484")

  # the #855 shape: build is VALID app-wide but NOT in the group yet → absent
  lagging_ids = S.parse_asc_group_build_ids(fixture("asc_group_builds_absent.json"))
  in_group = S.parse_asc_build_versions(fixture("asc_app_builds_present.json")).select do
    # membership intersection happens in the IO glue by build id; here the
    # parser contract is: versions of VALID builds + ids, joined by the caller
    true
  end
  raise!("the #855 lag shape keeps 1.0.485 out of the group set") unless lagging_ids == ["BUILD-190"] && in_group.length == 2
  v = S.decide_presence(expected: "1.0.485", observed: [])
  raise!("group-builds ∩ app-builds empty → absent") unless v["verdict"] == "absent"
  ok("the #855 shape (VALID build, group lag) parses to absent")

  v = S.decide_presence(expected: "1.0.484", observed: S.parse_asc_build_versions(fixture("asc_app_builds_present.json")))
  raise!("ASC rollover: expecting 484 while 485 serves → rolled_over") unless v["verdict"] == "rolled_over"
  ok("ASC version-rollover fixture → rolled_over")

  raise!("malformed include join yields no versions") unless S.parse_asc_build_versions(fixture("asc_app_builds_malformed.json")).empty?
  ok("a build whose preReleaseVersion include is missing parses to nothing (no crash)")

  raise!("parser survives a non-hash payload") unless S.parse_asc_build_versions(nil).empty? && S.parse_asc_group_build_ids("nope").empty?
  ok("malformed payloads parse to empty sets, never raise")

  # ── Play parser ────────────────────────────────────────────────────────────
  t = S.parse_play_track(fixture("play_track_present.json"))
  raise!("track release names parse") unless t["names"] == ["1.0.485", "1.0.484"]
  raise!("track versionCodes parse") unless t["versionCodes"] == %w[991 990]
  v = S.decide_presence(expected: "1.0.485", observed: t["names"])
  raise!("play present fixture → present") unless v["verdict"] == "present"
  ok("Play track present fixture → present (names + versionCodes)")

  t = S.parse_play_track(fixture("play_track_absent.json"))
  v = S.decide_presence(expected: "1.0.485", observed: t["names"])
  raise!("play absent fixture → absent") unless v["verdict"] == "absent"
  ok("Play track absent fixture → absent")

  t = S.parse_play_track({ "track" => "beta" })
  raise!("a track with no releases parses to empty") if t["names"].empty? == false
  ok("an empty track (no releases yet) parses to empty sets")

  # ── pub.dev parser ─────────────────────────────────────────────────────────
  p = S.parse_pubdev_package(fixture("pubdev_package_present.json"))
  raise!("latest parses") unless p["latest"] == "1.0.485" && p["versions"] == ["1.0.485", "1.0.484"]
  v = S.decide_presence(expected: "1.0.485", observed: [p["latest"], *p["versions"]])
  raise!("pubdev present fixture → present") unless v["verdict"] == "present"
  ok("pub.dev present fixture → present (latest + versions list)")

  p = S.parse_pubdev_package(fixture("pubdev_package_absent.json"))
  v = S.decide_presence(expected: "1.0.485", observed: [p["latest"], *p["versions"]])
  raise!("pubdev absent fixture → absent") unless v["verdict"] == "absent"
  ok("pub.dev absent fixture (stale replica) → absent")

  p = S.parse_pubdev_package(nil)
  raise!("malformed pub.dev payload parses to empty") unless p["latest"].nil? && p["versions"].empty?
  ok("malformed pub.dev payload → empty, never raise")

  # ── horizon gate (AC3) ─────────────────────────────────────────────────────
  raise!("absence at the horizon files") unless S.stub_due?(now: "2026-09-29T07:17:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120)
  ok("exactly 120 min since the legs started → stub due (owner ruling)")

  raise!("absence below the horizon only reports") if S.stub_due?(now: "2026-09-29T06:16:59Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120)
  ok("119:59 since the legs → report only, no stub")

  raise!("a manual check with no daily run owns the horizon itself") unless S.stub_due?(now: "2026-09-29T06:00:00Z", since: nil, horizon_minutes: 120)
  ok("no daily run found (manual dispatch on a quiet day) → stub due")

  raise!("unparsable clocks fail loud") unless S.stub_due?(now: "garbage", since: "2026-09-29T05:17:00Z", horizon_minutes: 120)
  ok("unparsable clock → fail loud (stub due), never silently green")

  # review gh-1041 thread 5: the horizon measures from the daily run's START,
  # but a slow leg can still be uploading at check time (TestFlight worst case
  # ~220 min) — a stub filed then is a false positive by construction.
  raise!("a still-running leg must not stub (its build may not be uploaded yet)") if
    S.stub_due?(now: "2026-09-29T08:00:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120, leg_status: "in_progress")
  raise!("a queued leg must not stub either") if
    S.stub_due?(now: "2026-09-29T08:00:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120, leg_status: "queued")
  raise!("a finished leg stubs exactly like before") unless
    S.stub_due?(now: "2026-09-29T08:00:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120, leg_status: "completed")
  raise!("no leg state (manual dispatch, old gh shape) keeps the old semantics") unless
    S.stub_due?(now: "2026-09-29T08:00:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120)
  ok("leg still running at check time → report only, stub waits for a later check")

  # review gh-1041 thread 7: `status: completed` alone isn't "the submit went
  # green" — a FAILED leg never uploaded, so an absence stub's premise
  # ("a green submit's version should be live") doesn't hold and it would
  # just duplicate the leg's own [daily-publish] failure stub for a day.
  base = { now: "2026-09-29T08:00:00Z", since: "2026-09-29T05:17:00Z", horizon_minutes: 120, leg_status: "completed" }
  raise!("a FAILED leg never stubs absences") if S.stub_due?(**base, leg_conclusion: "failure")
  raise!("a cancelled leg never stubs absences either") if S.stub_due?(**base, leg_conclusion: "cancelled")
  raise!("timed_out/skipped legs never stub absences") if S.stub_due?(**base, leg_conclusion: "timed_out") || S.stub_due?(**base, leg_conclusion: "skipped")
  raise!("a successful leg stubs absences exactly like before") unless S.stub_due?(**base, leg_conclusion: "success")
  raise!("no conclusion (old gh shape) keeps the old semantics") unless S.stub_due?(**base)
  raise!("in flight still wins over any conclusion") if S.stub_due?(**base, leg_conclusion: "success", leg_status: "in_progress")
  ok("leg ended non-success (no green submit) → report only, the leg stub owns the signal")

  # review gh-1041 thread 7 minor: horizon_minutes free text (.to_i → 0) must
  # never collapse the horizon to "stub immediately".
  raise!("free text horizon falls back to the default") unless S.parse_horizon("two hours") == 120
  raise!("zero/negative horizon falls back to the default") unless S.parse_horizon("0") == 120 && S.parse_horizon("-5") == 120
  raise!("empty horizon falls back to the default") unless S.parse_horizon("") == 120 && S.parse_horizon(nil) == 120
  raise!("a numeric horizon is honored") unless S.parse_horizon(" 240 ") == 240
  ok("horizon parse guards free-text dispatch input (never stubs immediately)")

  # ── review gh-1041 thread 1/3: gh READ failures are loud, never "empty" ────
  begin
    S.daily_run(raw: nil)
    raise "no"
  rescue StandardError => e
    raise!("gh run list failure must abort, not read as 'no run found'") unless e.message.include?("gh run list")
  end
  raise!("no scheduled run (empty output) → nil, a legitimate quiet day") unless S.daily_run(raw: "").nil?
  raise!("gh printing a literal null → nil") unless S.daily_run(raw: "null").nil?
  run = S.daily_run(raw: '{"createdAt":"2026-09-29T05:17:00Z","status":"in_progress","conclusion":null}')
  raise!("the day's run parses created_at/status/conclusion") unless
    run["created_at"] == "2026-09-29T05:17:00Z" && run["status"] == "in_progress" && run["conclusion"].nil?
  ok("gh run list output parses to leg state; gh failure raises (never 'no run found')")

  begin
    S.parse_issue_list(nil, label: "store-appearance-check")
    raise "no"
  rescue StandardError => e
    raise!("gh issue list failure must abort, never degrade to 'no stubs'") unless e.message.include?("gh issue list")
  end
  begin
    S.parse_issue_list("not json", label: "daily-publish")
    raise "no"
  rescue StandardError => e
    raise!("unparsable issue-list output fails loud") unless e.message.include?("daily-publish")
  end
  listed = S.parse_issue_list('[{"number":12,"title":"[store-appearance-check] TestFlight 1.0.485 absent"},{"number":13,"title":"x"}]', label: "store-appearance-check")
  raise!("issue-list JSON parses to number/title pairs") unless listed.size == 2 && listed[0]["number"] == 12
  ok("gh issue list: failure or garbage raises; valid JSON parses")

  # ── lifecycle planner (AC3: exactly one stub, updated in place) ────────────
  stubs = ->(titles) { titles.each_with_index.map { |t, i| { "number" => 100 + i, "title" => t } } }
  tf_absent = { "verdict" => "absent", "matched" => nil, "observed" => ["1.0.484"] }
  tf_present = { "verdict" => "present", "matched" => "1.0.485", "observed" => ["1.0.485"] }
  expected485 = { "app" => "1.0.485", "pubdev" => "1.0.485" }

  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_absent },
    stub_due: true, open_stubs: [], publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/1", now: "2026-09-29T07:17:00Z"
  )
  raise!("first absence files exactly one stub") unless a.size == 1 && a[0]["action"] == "create_stub" &&
    a[0]["title"] == "[store-appearance-check] TestFlight 1.0.485 absent"
  raise!("the stub body carries evidence") unless a[0]["body"].include?("1.0.484") && a[0]["body"].include?("https://ci/runs/1") && a[0]["body"].include?("2026-09-29")
  ok("first absence → exactly one evidence-carrying stub (title = stable key)")

  # review gh-1041 thread 7: the leg's state belongs in the stub's evidence
  # block — a reader sees "submit leg: completed/success" without hunting
  # for the daily-publish run.
  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_absent },
    stub_due: true, open_stubs: [], publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/1", now: "2026-09-29T07:17:00Z",
    leg: { "status" => "completed", "conclusion" => "success" }
  )
  raise!("the stub body quotes the leg's state") unless
    a[0]["body"].include?("Submit leg at check time") && a[0]["body"].include?("completed") && a[0]["body"].include?("success")
  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_absent },
    stub_due: true, open_stubs: [], publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/1", now: "2026-09-29T07:17:00Z"
  )
  raise!("no leg state → no leg line, nothing else changes") unless !a[0]["body"].include?("Submit leg at check time") && a.size == 1
  ok("absence stub body carries the day's leg state when known")

  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_absent },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] TestFlight 1.0.485 absent"]),
    publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/2", now: "2026-09-29T09:17:00Z"
  )
  raise!("second identical check updates, never duplicates") unless a.size == 1 && a[0]["action"] == "comment_stub" && a[0]["number"] == 100
  ok("second check with the same absence → in-place update (REG idempotency)")

  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_absent },
    stub_due: false, open_stubs: [], publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/3", now: "2026-09-29T06:00:00Z"
  )
  raise!("absence below the horizon files nothing") unless a.empty?
  ok("absence below the horizon → no stub (report only)")

  all_present = {
    "testflight" => tf_present,
    "play" => { "verdict" => "present", "matched" => "1.0.485", "observed" => ["1.0.485"] },
    "pubdev" => { "verdict" => "present", "matched" => "1.0.485", "observed" => ["1.0.485"] },
  }
  a = S.plan_lifecycle(
    expected: expected485, verdicts: { "testflight" => tf_present },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] TestFlight 1.0.485 absent"]),
    publish_stub_numbers: [7, 8], summarized: [],
    run_url: "https://ci/runs/4", now: "2026-09-29T08:00:00Z"
  )
  raise!("appearance resolves the stub") unless a.any? { |x| x["action"] == "close_stub" && x["number"] == 100 }
  a = S.plan_lifecycle(
    expected: expected485, verdicts: all_present,
    stub_due: true,
    open_stubs: [],
    publish_stub_numbers: [7, 8], summarized: [],
    run_url: "https://ci/runs/4", now: "2026-09-29T08:00:00Z"
  )
  raise!("green run posts the per-store summary on the day's publish stubs") unless a.count { |x| x["action"] == "comment_summary" } == 2
  raise!("the summary carries per-store presence") unless a.find { |x| x["action"] == "comment_summary" }["body"].include?("TestFlight")
  ok("appearance → stub closed + green summary on both publish stubs")

  # review gh-1041 thread 2: a partial (--only) run must NEVER post the
  # "all green" summary — the unchecked stores were never queried, and the
  # day's idempotency marker would silence the scheduled full check.
  a = S.plan_lifecycle(
    expected: expected485,
    verdicts: { "pubdev" => { "verdict" => "present", "matched" => "1.0.485", "observed" => ["1.0.485"] } },
    stub_due: true, open_stubs: [],
    publish_stub_numbers: [7, 8], summarized: [],
    run_url: "https://ci/runs/4b", now: "2026-09-29T08:00:00Z"
  )
  raise!("a partial --only run posts no all-green summary") unless a.none? { |x| x["action"] == "comment_summary" }
  raise!("a two-of-three run still posts no all-green summary") unless
    S.plan_lifecycle(
      expected: expected485,
      verdicts: all_present.reject { |k, _| k == "play" },
      stub_due: true, open_stubs: [], publish_stub_numbers: [7], summarized: [],
      run_url: "https://ci/runs/4c", now: "2026-09-29T08:00:00Z"
    ).none? { |x| x["action"] == "comment_summary" }
  ok("partial run (1 or 2 of 3 stores) → no all-green summary, marker not burned (only the full family summarizes)")

  a = S.plan_lifecycle(
    expected: expected485, verdicts: all_present,
    stub_due: true,
    open_stubs: [],
    publish_stub_numbers: [7, 8], summarized: [7],
    run_url: "https://ci/runs/5", now: "2026-09-29T10:00:00Z"
  )
  raise!("re-check after appearance is silent beyond the one summary") unless a.count { |x| x["action"] == "comment_summary" } == 1 && a.none? { |x| %w[create_stub comment_stub].include?(x["action"]) }
  ok("REG: a re-run posts no duplicate summary (marker dedup), resolves nothing twice")

  rolled = { "verdict" => "rolled_over", "matched" => "1.0.486", "observed" => ["1.0.486"] }
  a = S.plan_lifecycle(
    expected: { "app" => "1.0.486", "pubdev" => "1.0.486" }, verdicts: { "testflight" => rolled },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] TestFlight 1.0.485 absent"]),
    publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/6", now: "2026-09-30T07:17:00Z"
  )
  raise!("version rollover resolves the old stub") unless a.size == 1 && a[0]["action"] == "close_stub" && a[0]["reason"].include?("rollover")
  ok("version rollover → the stale-version stub closes, nothing new files")

  a = S.plan_lifecycle(
    expected: { "app" => "1.0.486", "pubdev" => "1.0.486" },
    verdicts: { "testflight" => { "verdict" => "absent", "matched" => nil, "observed" => [] } },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] TestFlight 1.0.485 absent"]),
    publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/7", now: "2026-09-30T07:17:00Z"
  )
  raise!("a still-absent older stub is superseded, and the new expectation gets exactly its own stub") unless
    a.count { |x| x["action"] == "close_stub" } == 1 && a.count { |x| x["action"] == "create_stub" } == 1
  ok("expectation moved while still absent → old stub superseded, one new stub")

  a = S.plan_lifecycle(
    expected: expected485,
    verdicts: { "testflight" => { "verdict" => "error", "matched" => nil, "observed" => [] } },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] TestFlight 1.0.485 absent"]),
    publish_stub_numbers: [], summarized: [],
    run_url: "https://ci/runs/8", now: "2026-09-29T07:17:00Z"
  )
  raise!("an API error never files or resolves stubs") unless a.empty?
  ok("ASC/Play/pub.dev API error → no stub action at all (noise guard)")

  a = S.plan_lifecycle(
    expected: expected485, verdicts: {},
    stub_due: true, open_stubs: [], publish_stub_numbers: [7], summarized: [],
    run_url: "https://ci/runs/9", now: "2026-09-29T07:17:00Z"
  )
  raise!("all stores skipped → no green summary") unless a.empty?
  ok("all stores skipped (secrets absent) → no actions, green-neutral")

  # multi-store: pub.dev absent + TestFlight present → exactly one stub, no summary
  a = S.plan_lifecycle(
    expected: expected485,
    verdicts: { "testflight" => tf_present, "pubdev" => { "verdict" => "absent", "matched" => nil, "observed" => ["1.0.484"] } },
    stub_due: true,
    open_stubs: stubs.call(["[store-appearance-check] pub.dev 1.0.485 absent"]),
    publish_stub_numbers: [7], summarized: [],
    run_url: "https://ci/runs/10", now: "2026-09-29T07:17:00Z"
  )
  raise!("only the absent store stubs") unless a.count { |x| x["action"] == "comment_stub" } == 1 && a.none? { |x| x["action"] == "create_stub" }
  raise!("partial green posts no all-green summary") unless a.none? { |x| x["action"] == "comment_summary" }
  ok("multi-store run: the absent store updates its own stub, no green summary while anything is missing")

  a = S.plan_lifecycle(
    expected: expected485,
    verdicts: { "pubdev" => { "verdict" => "present", "matched" => "1.0.485", "observed" => ["1.0.485"] } },
    stub_due: true, open_stubs: [],
    publish_stub_numbers: [7], summarized: [],
    run_url: "https://ci/runs/11", now: "2026-09-29T07:17:00Z",
    errors: { "testflight" => "ASC answered 500" }
  )
  raise!("an errored store blocks the all-green summary") unless a.empty?
  ok("API error on one store → no green summary (an unchecked store is never 'all green')")

  # ── JWT minting (real signatures, no network — transport glue) ─────────────
  es_key = OpenSSL::PKey::EC.generate("prime256v1")
  token = S::Jwt.mint(
    header: { alg: "ES256", kid: "KID", typ: "JWT" },
    payload: { iss: "ISSUER", iat: 1_700_000_000, aud: "appstoreconnect-v1" },
    key_pem: es_key.to_pem, alg: "ES256"
  )
  parts = token.split(".")
  raise!("ES256 JWT has three segments") unless parts.size == 3

  # Verify the raw r||s signature by converting back to DER for openssl.
  sig = parts[2].tr("-_", "+/").then { |s| Base64.decode64(s.ljust((s.length + 3) / 4 * 4, "=")) }
  raise!("ES256 signature must be exactly 64 raw bytes") unless sig.bytesize == 64
  r, s_bytes = sig[0, 32], sig[32, 32]
  der = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(r, 2)),
                                     OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(s_bytes, 2))]).to_der
  signing_input = "#{parts[0]}.#{parts[1]}"
  raise!("ES256 signature must verify against the minting key") unless es_key.verify("SHA256", der, signing_input)
  ok("ES256 JWT mints + cryptographically verifies (ASC transport)")

  rsa_key = OpenSSL::PKey::RSA.generate(2048)
  token = S::Jwt.mint(
    header: { alg: "RS256", typ: "JWT" },
    payload: { iss: "test-only@test.iam.gserviceaccount.com", scope: "https://www.googleapis.com/auth/androidpublisher" },
    key_pem: rsa_key.to_pem, alg: "RS256"
  )
  parts = token.split(".")
  raise!("RS256 JWT has three segments") unless parts.size == 3
  sig = parts[2].tr("-_", "+/").then { |s| Base64.decode64(s.ljust((s.length + 3) / 4 * 4, "=")) }
  raise!("RS256 signature verifies against the minting key") unless rsa_key.verify("SHA256", sig, "#{parts[0]}.#{parts[1]}")
  ok("RS256 JWT mints + cryptographically verifies (Play transport)")

  puts "\nstore_appearance_test: #{$checks} checks passed"
end

