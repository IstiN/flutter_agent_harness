# frozen_string_literal: true

# Deferred store-appearance verification (gh-1041): a store SUBMIT that
# returned green success is final — the store's read-side lag (group
# membership / track listing / pub.dev replica trailing an already-successful
# distribution, #855) must never fail a leg. Appearance is owned by the
# deferred `store-appearance-check` workflow (scheduled 120 min after the
# daily publish legs, owner ruling 2026-09-28), and every DECISION it makes
# lives in this module — dependency-free plain ruby (no fastlane, no gems),
# the same contract as VersionFloor/AppstorePreflight/PlayUploadPreflight,
# so the whole matrix is testable with the runner's stock ruby
# (test/store_appearance_test.rb, fixture JSON from
# test/fixtures/store_appearance/ — AC5).
#
# The IO glue (JWT minting, HTTP, gh issue lifecycle) lives in
# scripts/store_appearance_check.rb and stays thin: it fetches the facts,
# this module decides.
require "base64"
require "json"
require "openssl"
require "time"

module StoreAppearance
  # Stores the check owns, in report order. Machine id → GitHub-facing
  # display name (used in stub titles, which double as the idempotency key).
  STORES = {
    "testflight" => "TestFlight",
    "play" => "Play",
    "pubdev" => "pub.dev"
  }.freeze

  # Stub title prefix — every auto-filed appearance stub starts with it, so
  # per-store lookups never need to trust gh search fuzziness.
  STUB_PREFIX = "[store-appearance-check]"

  # Hidden marker inside green-summary comments: at most one summary per
  # publish stub per day, no matter how often the check runs (REG idempotency).
  GREEN_SUMMARY_MARKER = "<!-- store-appearance-check:green-summary "

  module_function

  # Strict x.y.z (minor/patch optional) → [x, y, z]; nil for garbage, so a
  # weird store payload can never compare wrong (same contract as
  # VersionFloor.semver).
  def semver(string)
    m = string.to_s.strip.match(/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/)
    return nil unless m

    [m[1].to_i, m[2].to_i, m[3].to_i]
  end

  # a >= b for comparable semvers; false when either side is unparsable —
  # an unparsable observed version is never silently "present".
  def version_gte?(a, b)
    av = semver(a)
    bv = semver(b)
    return false if av.nil? || bv.nil?

    (av <=> bv) >= 0
  end

  # The highest comparable version in a store response — the evidence the
  # report/stub quotes ("pub.dev serves 1.0.484").
  def highest(versions)
    versions.map { |v| [semver(v), v] }.compact.max_by { |sv, _| sv }&.last
  end

  # ── Expected version resolution ───────────────────────────────────────────
  # The repo's tag/version file is the source of truth (one-version scheme,
  # gh-785: auto_release bumps pubspec + tags vX.Y.Z atomically, the daily
  # legs build/attach exactly that train). Resolving the LATEST expectation
  # every run is what makes a missed/skipped schedule self-heal (gh-1041 I2):
  # the check never needs yesterday's run id.
  #
  #   pubspec — root pubspec.yaml version (what the tag-publish publishes)
  #   tag     — newest vX.Y.Z tag (what the mobile/desktop builds stamp)
  # Returns { "app" => x.y.z (TestFlight/Play expectation),
  #           "pubdev" => x.y.z (pub.dev expectation) } or nil when nothing
  # is resolvable (fresh repo without any version source).
  def resolve_expected(pubspec:, tag:)
    pubspec_v = semver(pubspec) && pubspec.to_s.strip
    tag_v = tag.to_s.strip.sub(/\Av/, "")
    tag_v = semver(tag_v) && tag_v
    candidates = [pubspec_v, tag_v].compact
    return nil if candidates.empty?

    app = highest(candidates)
    { "app" => app, "pubdev" => pubspec_v || app }
  end

  # ── Presence verdict (the AC4 contract — identical for all three stores) ──
  # present     — the store serves >= the expected version (equal = appeared)
  # rolled_over — the store serves only NEWER versions than expected: a later
  #               train already superseded it, so the absence is moot
  # absent      — nothing >= expected is served
  # matched     — the highest observed version that satisfies the verdict
  def decide_presence(expected:, observed:)
    satisfying = observed.to_a.select { |v| version_gte?(v, expected) }
    matched = highest(satisfying)
    if matched.nil?
      { "verdict" => "absent", "matched" => nil }
    elsif semver(matched) == semver(expected)
      { "verdict" => "present", "matched" => matched }
    else
      { "verdict" => "rolled_over", "matched" => matched }
    end
  end

  # ── Absence horizon (AC3) ─────────────────────────────────────────────────
  # Absence only files a stub once the horizon (default 120 min, owner
  # ruling) has elapsed since the day's publish legs STARTED — an early
  # manual run reports "absent" without filing. since = the daily-publish
  # scheduled run's created_at; now is injectable for tests.
  def stub_due?(now:, since:, horizon_minutes:)
    return true if since.nil? # no daily run found — a manual check owns the horizon itself

    started = Time.iso8601(since.to_s) rescue nil
    now_t = Time.iso8601(now.to_s) rescue nil
    return true if started.nil? || now_t.nil? # unparsable clock — fail loud, not silent

    (now_t - started) >= horizon_minutes.to_i * 60
  end

  # ── ASC payload parsers (recorded /v1 responses, AC5) ────────────────────
  # GET /v1/apps?filter[bundleId]=… → the app id; nil when ASC knows no app.
  def parse_asc_app_id(json)
    data = json.is_a?(Hash) && json["data"].is_a?(Array) ? json["data"] : []
    data.first.is_a?(Hash) && data.first["id"].is_a?(String) ? data.first["id"] : nil
  end

  # GET /v1/betaGroups?filter[app]=… → id of the group named exactly +group_name+
  # (fastlane/pilot resolves by name the same way — a renamed group is a
  # config error, never a false "absent").
  def parse_asc_group_id(json, group_name)
    data = json.is_a?(Hash) && json["data"].is_a?(Array) ? json["data"] : []
    group = data.find do |g|
      g.is_a?(Hash) && g.dig("attributes", "name") == group_name
    end
    group && group["id"].is_a?(String) ? group["id"] : nil
  end

  # GET /v1/betaGroups/{id}/builds → membership set (build ids in the group).
  def parse_asc_group_build_ids(json)
    data = json.is_a?(Hash) && json["data"].is_a?(Array) ? json["data"] : []
    data.filter_map { |b| b.is_a?(Hash) && b["id"].is_a?(String) ? b["id"] : nil }
  end

  # GET /v1/builds?filter[app]=…&include=preReleaseVersion (VALID only) →
  # marketing versions, joined from the builds' preReleaseVersion relation
  # (the Fastfile's verify_external_distribution! does the same join — the
  # list endpoint ships no usable app_version without the include).
  def parse_asc_build_versions(json)
    data = json.is_a?(Hash) && json["data"].is_a?(Array) ? json["data"] : []
    included = json.is_a?(Hash) && json["included"].is_a?(Array) ? json["included"] : []
    prerelease = {}
    included.each do |row|
      next unless row.is_a?(Hash) && row["type"] == "preReleaseVersions"

      v = row.dig("attributes", "version")
      prerelease[row["id"]] = v if v.is_a?(String)
    end
    data.filter_map do |b|
      next nil unless b.is_a?(Hash)
      next nil unless b.dig("attributes", "processingState") == "VALID"

      rel = b.dig("relationships", "preReleaseVersion", "data", "id")
      prerelease[rel]
    end.compact
  end

  # ── Play payload parser ───────────────────────────────────────────────────
  # GET /androidpublisher/v3/.../edits/{id}/tracks/{track} → version NAMES
  # of the track's releases (Play names bundle releases after the versionName;
  # versionCodes ride along for the evidence block).
  def parse_play_track(json)
    releases = json.is_a?(Hash) && json["releases"].is_a?(Array) ? json["releases"] : []
    names = []
    codes = []
    releases.each do |r|
      next unless r.is_a?(Hash)

      names << r["name"] if r["name"].is_a?(String)
      (r["versionCodes"].is_a?(Array) ? r["versionCodes"] : []).each do |c|
        codes << c.to_s
      end
    end
    { "names" => names, "versionCodes" => codes }
  end

  # ── pub.dev payload parser ────────────────────────────────────────────────
  # GET /api/packages/<pkg> → latest + all served versions (a replica can lag
  # latest while still listing the version — compare against BOTH, AC4).
  def parse_pubdev_package(json)
    return { "latest" => nil, "versions" => [] } unless json.is_a?(Hash)

    latest = json.dig("latest", "version")
    versions = (json["versions"].is_a?(Array) ? json["versions"] : [])
               .filter_map { |v| v.is_a?(Hash) && v["version"].is_a?(String) ? v["version"] : nil }
    { "latest" => latest.is_a?(String) ? latest : nil, "versions" => versions }
  end

  # ── Issue lifecycle planner (AC3 — the whole thing is a pure function) ────
  # Inputs:
  #   expected          — resolve_expected output
  #   verdicts          — { "testflight" => decide_presence output, ... }
  #                       (stores that were skipped/errored are simply absent)
  #   stub_due          — Horizon.stub_due? result
  #   open_stubs        — open issues labeled store-appearance-check:
  #                       [{ "number" => 12, "title" => "[store-appearance-check] …" }]
  #   publish_stub_numbers — open [daily-publish] leg-failure stubs that get
  #                       the green summary comment
  #   summarized        — publish stub numbers that ALREADY carry today's
  #                       green-summary marker (idempotency, REG)
  #   run_url           — this check run's URL (evidence in every body)
  #   now               — RFC3339 stamp for bodies
  # Returns actions; the IO script executes them via gh verbatim:
  #   create_stub / comment_stub / close_stub / comment_summary
  def plan_lifecycle(expected:, verdicts:, stub_due:, open_stubs:, publish_stub_numbers:, summarized:, run_url:, now:)
    actions = []
    STORES.each do |store, display|
      verdict = verdicts[store]
      next if verdict.nil? # skipped or errored — never stubbed, never resolved

      expected_version = store == "pubdev" ? expected["pubdev"] : expected["app"]
      exact_title = "#{STUB_PREFIX} #{display} #{expected_version} absent"
      prefix = "#{STUB_PREFIX} #{display} "
      store_stubs = open_stubs.select { |s| s["title"].to_s.start_with?(prefix) }
      exact_stub = store_stubs.find { |s| s["title"] == exact_title }
      stale_stubs = store_stubs.reject { |s| s == exact_stub }

      case verdict["verdict"]
      when "present", "rolled_over"
        store_stubs.each do |stub|
          reason = if verdict["verdict"] == "rolled_over"
                     "store now serves #{verdict['matched']} (> expected #{expected_version}) — resolved by version rollover"
                   else
                     "#{expected_version} appeared (store serves #{verdict['matched']}) — resolved"
                   end
          actions << { "action" => "close_stub", "number" => stub["number"],
                       "store" => store, "reason" => reason }
        end
      when "absent"
        # A stale stub (expectation moved on, still absent) is superseded by
        # the current expectation's stub — exactly one live stub per store.
        stale_stubs.each do |stub|
          actions << { "action" => "close_stub", "number" => stub["number"],
                       "store" => store,
                       "reason" => "expectation rolled over to #{expected_version} (still absent) — superseding this stub" }
        end
        if stub_due
          body = absence_body(
            display: display, version: expected_version, verdict: verdict,
            run_url: run_url, now: now, updated: !exact_stub.nil?
          )
          if exact_stub
            actions << { "action" => "comment_stub", "number" => exact_stub["number"],
                         "store" => store, "title" => exact_title, "body" => body }
          else
            actions << { "action" => "create_stub", "store" => store,
                         "title" => exact_title, "body" => body }
          end
        end
      end
    end

    if verdicts.values.any? && verdicts.values.all? { |v| %w[present rolled_over].include?(v["verdict"]) }
      publish_stub_numbers.each do |number|
        next if summarized.include?(number)

        actions << { "action" => "comment_summary", "number" => number,
                     "body" => green_summary_body(expected: expected, verdicts: verdicts, run_url: run_url, now: now) }
      end
    end
    actions
  end

  def absence_body(display:, version:, verdict:, run_url:, now:, updated:)
    observed = verdict["observed"] || []
    <<~BODY
      #{STUB_PREFIX} **#{display}**: expected `#{version}` is still **absent** past the horizon.

      - **Expected:** `#{version}` (resolved from the repo tag/version file — gh-1041 I2)
      - **Store serves:** #{observed.empty? ? '_nothing comparable_' : observed.map { |v| "`#{v}`" }.join(', ')}
      - **First check runs 120 min after the daily publish legs start; this stub is updated in place by later checks until the version appears or rolls over (exactly-one-stub guarantee).**
      - **Check run:** #{run_url}
      - **Checked at:** #{now}

      _Auto-filed by `store-appearance-check` (gh-1041) — auto-closes when the version appears. Reuses the submit legs' credentials; strictly read-only against the stores._
    BODY
  end

  def green_summary_body(expected:, verdicts:, run_url:, now:)
    rows = STORES.filter_map do |store, display|
      v = verdicts[store]
      next nil if v.nil?

      expected_version = store == "pubdev" ? expected["pubdev"] : expected["app"]
      icon = v["verdict"] == "present" ? "✅" : "↪️"
      "| #{display} | `#{expected_version}` | #{icon} #{v['verdict']} (serves `#{v['matched']}`) |"
    end
    <<~BODY
      #{GREEN_SUMMARY_MARKER}#{now.to_s[0, 10]} -->

      **Store appearance check — all green.** The versions the daily publish legs shipped are live in all stores:

      | Store | Expected | Verdict |
      | --- | --- | --- |
      #{rows.join("\n")}

      Check run: #{run_url} • checked at #{now}

      _Posted once per day per stub (idempotency guard); appearance failures surface as their own `[store-appearance-check]` stub, never as a failed submit leg (gh-1041)._
    BODY
  end
end
