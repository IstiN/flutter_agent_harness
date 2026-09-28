#!/usr/bin/env ruby
# frozen_string_literal: true

# Deferred store-appearance check (gh-1041) — the IO half of the goal.
#
# A store SUBMIT that returned green success is final: this job — not the
# submit legs — owns APPEARANCE. Scheduled 120 min after the daily publish
# legs (owner ruling 2026-09-28), it re-checks the three stores READ-ONLY
# (ASC API / Play API / pub.dev API, the legs' own credentials — I3) for the
# expected version resolved from the repo's tag/version file, then:
#
#   * all present   → one green-summary comment on the day's [daily-publish]
#                     stubs (once per day per stub — idempotency, REG);
#   * absent past the horizon (default 120 min) → EXACTLY ONE stub per store
#                     (label store-appearance-check), updated in place by
#                     later checks until the version appears or rolls over;
#   * API error     → reported, never stubbed (noise guard) — the run goes
#                     red but files nothing.
#
# Decisions live in flutter_app/fastlane/store_appearance.rb (plain-ruby
# tested); this script is transport + gh issue lifecycle only. Stdlib only —
# runs on the runner's stock ruby.
#
# Env (all store endpoints overridable for fake-endpoint IT):
#   STORE_APPEARANCE_PUBDEV_BASE   default https://pub.dev/api
#   STORE_APPEARANCE_ASC_BASE      default https://api.appstoreconnect.apple.com
#   STORE_APPEARANCE_PLAY_BASE     default https://androidpublisher.googleapis.com
#   STORE_APPEARANCE_PLAY_TOKEN_URL default https://oauth2.googleapis.com/token
#   STORE_APPEARANCE_NOW / _SINCE / _HORIZON_MINUTES / _RUN_URL   (tests/ops)
#   STORE_APPEARANCE_DRY_RUN=1     compute + print actions, no gh writes
#   APP_STORE_CONNECT_KEY_ID/_ISSUER_ID/_KEY_CONTENT, PLAY_STORE_SERVICE_ACCOUNT_JSON
#   TESTFLIGHT_EXTERNAL_GROUP, IOS_BUNDLE_ID, PLAY_PACKAGE_NAME, PLAY_TRACK,
#   PUBDEV_PACKAGE, DAILY_PUBLISH_ASSIGNEE
#
# Usage: ruby scripts/store_appearance_check.rb [--only testflight|play|pubdev]

require "json"
require "net/http"
require "tempfile"
require "uri"

SCRIPT_DIR = __dir__
require_relative "#{SCRIPT_DIR}/../flutter_app/fastlane/store_appearance"

S = StoreAppearance

# ── configuration ────────────────────────────────────────────────────────────
def env(name, default = nil)
  value = ENV[name].to_s.strip
  value.empty? ? default : value
end

repo = env("GITHUB_REPOSITORY")
assignee = env("DAILY_PUBLISH_ASSIGNEE", "ai-teammate")
now = env("STORE_APPEARANCE_NOW") || Time.now.utc.iso8601
horizon = S.parse_horizon(env("STORE_APPEARANCE_HORIZON_MINUTES", "120"))
run_url = env("STORE_APPEARANCE_RUN_URL") ||
          (repo && !repo.empty? ? "#{env('GITHUB_SERVER_URL', 'https://github.com')}/#{repo}/actions/runs/#{ENV['GITHUB_RUN_ID']}" : "local")
only = nil
if (i = ARGV.index("--only"))
  only = ARGV[i + 1].to_s.strip
  unless S::STORES.key?(only)
    warn "unknown --only store '#{only}' (want one of #{S::STORES.keys.join(', ')})"
    exit 64
  end
end

root = `git rev-parse --show-toplevel 2>/dev/null`.strip
root = Dir.pwd if root.empty?
pubspec_text = File.read(File.join(root, "pubspec.yaml")) rescue ""
pubspec_version = pubspec_text[/^version:\s*(\S+)/, 1]
publish_to_none = pubspec_text.match?(/^publish_to:\s*none/)
tag_version = `git -C '#{root}' tag --sort=-v:refname 2>/dev/null`.lines.map(&:strip)
             .find { |t| t.match?(/\Av\d+\.\d+\.\d+\z/) }
expected = S.resolve_expected(pubspec: pubspec_version, tag: tag_version)
if expected.nil?
  warn "store-appearance-check: no version source (pubspec/tag) — nothing to check"
  exit 1
end

# ── HTTP helpers ─────────────────────────────────────────────────────────────
def http(verb, url, headers:, body: nil)
  uri = URI(url)
  request = Net::HTTP.const_get(verb).new(uri)
  headers.each { |k, v| request[k] = v }
  request.body = body if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                             open_timeout: 20, read_timeout: 60) { |http| http.request(request) }
  [response.code.to_i, response.body.to_s]
rescue StandardError => e
  raise "HTTP #{verb} #{uri.host} failed: #{e.class}: #{e.message.to_s[0, 160]}"
end

def json_response(verb, url, headers:, body: nil)
  code, raw = http(verb, url, headers: headers, body: body)
  parsed = raw.empty? ? {} : (JSON.parse(raw) rescue {})
  [code, parsed, raw]
end

# ── store clients (read-only) ────────────────────────────────────────────────
def asc_token(now)
  key_id = env("APP_STORE_CONNECT_KEY_ID")
  issuer = env("APP_STORE_CONNECT_ISSUER_ID")
  key = env("APP_STORE_CONNECT_KEY_CONTENT")
  return nil if key_id.nil? || issuer.nil? || key.nil?

  S::Jwt.mint(
    header: { alg: "ES256", kid: key_id, typ: "JWT" },
    payload: { iss: issuer, iat: Time.parse(now).to_i - 30, exp: Time.parse(now).to_i + 1100,
               aud: "appstoreconnect-v1" },
    key_pem: key, alg: "ES256"
  )
end

def check_testflight(now, expected)
  base = env("STORE_APPEARANCE_ASC_BASE", "https://api.appstoreconnect.apple.com")
  bundle_id = env("IOS_BUNDLE_ID", "dev.fa1.app")
  group_name = env("TESTFLIGHT_EXTERNAL_GROUP")
  raise "TESTFLIGHT_EXTERNAL_GROUP is not set" if group_name.nil?
  token = asc_token(now)
  raise "App Store Connect API key is not configured" if token.nil?

  headers = { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
  code, apps, raw = json_response("Get", "#{base}/v1/apps?#{URI.encode_www_form('filter[bundleId]' => bundle_id)}", headers: headers)
  raise "ASC /v1/apps answered #{code}: #{raw[0, 160]}" unless code == 200

  app_id = S.parse_asc_app_id(apps)
  raise "ASC has no app for bundleId #{bundle_id}" if app_id.nil?

  code, groups, raw = json_response("Get", "#{base}/v1/betaGroups?#{URI.encode_www_form('filter[app]' => app_id, 'page[limit]' => 200)}", headers: headers)
  raise "ASC /v1/betaGroups answered #{code}: #{raw[0, 160]}" unless code == 200

  group_id = S.parse_asc_group_id(groups, group_name)
  raise "ASC external group '#{group_name}' not found (repo variable drift)" if group_id.nil?

  code, group_builds, raw = json_response("Get", "#{base}/v1/betaGroups/#{group_id}/builds?#{URI.encode_www_form('page[limit]' => 200)}", headers: headers)
  raise "ASC group builds answered #{code}: #{raw[0, 160]}" unless code == 200

  code, app_builds, raw = json_response("Get", "#{base}/v1/builds?#{URI.encode_www_form('filter[app]' => app_id, 'filter[processingState]' => 'VALID', 'include' => 'preReleaseVersion', 'page[limit]' => 200, 'sort' => '-uploadedDate')}", headers: headers)
  raise "ASC /v1/builds answered #{code}: #{raw[0, 160]}" unless code == 200

  # #855 semantics: a build is "appeared" only when group membership and the
  # app's VALID build list agree — intersect by build id client-side.
  in_group = S.parse_asc_group_build_ids(group_builds)
  if app_builds.is_a?(Hash) && app_builds["data"].is_a?(Array)
    app_builds["data"].select! { |b| in_group.include?(b["id"]) }
  end
  versions = S.parse_asc_build_versions(app_builds).uniq
  S.decide_presence(expected: expected["app"], observed: versions).merge("observed" => versions)
end

def check_play(root, expected)
  base = env("STORE_APPEARANCE_PLAY_BASE", "https://androidpublisher.googleapis.com")
  token_url = env("STORE_APPEARANCE_PLAY_TOKEN_URL", "https://oauth2.googleapis.com/token")
  package = env("PLAY_PACKAGE_NAME")
  if package.nil?
    gradle = File.join(root, "flutter_app/android/app/build.gradle.kts")
    package = File.read(gradle)[/^\s*applicationId\s*=\s*"([^"]+)"/, 1] rescue nil
  end
  raise "Play package name not resolvable (gradle + PLAY_PACKAGE_NAME)" if package.nil?

  track = env("PLAY_TRACK", "beta")
  sa_json = env("PLAY_STORE_SERVICE_ACCOUNT_JSON")
  raise "PLAY_STORE_SERVICE_ACCOUNT_JSON is not set" if sa_json.nil?

  sa = JSON.parse(sa_json) rescue raise("PLAY_STORE_SERVICE_ACCOUNT_JSON is not valid JSON")
  now_i = Time.now.to_i
  assertion = S::Jwt.mint(
    header: { alg: "RS256", typ: "JWT" },
    payload: { iss: sa["client_email"], scope: "https://www.googleapis.com/auth/androidpublisher",
               aud: token_url, iat: now_i - 30, exp: now_i + 1100 },
    key_pem: sa["private_key"], alg: "RS256"
  )
  code, token_res, raw = json_response("Post", token_url,
                                       headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                       body: URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                                                 assertion: assertion))
  raise "Play token endpoint answered #{code}: #{raw[0, 160]}" unless code == 200

  access = token_res["access_token"]
  raise "Play token endpoint returned no access_token" if access.nil?

  headers = { "Authorization" => "Bearer #{access}", "Accept" => "application/json" }
  api = "#{base}/androidpublisher/v3/applications/#{package}"

  code, edit, raw = json_response("Post", "#{api}/edits", headers: headers, body: "{}")
  raise "Play edits.insert answered #{code}: #{raw.to_s[0, 160]}" unless [200, 201].include?(code)

  edit_id = edit["id"]
  begin
    code, track_res, raw = json_response("Get", "#{api}/edits/#{edit_id}/tracks/#{track}", headers: headers)
    if code == 404
      versions = [] # the track exists conceptually but has no releases yet
    elsif code == 200
      versions = S.parse_play_track(track_res)["names"].uniq
    else
      raise "Play tracks.get answered #{code}: #{raw.to_s[0, 160]}"
    end
  ensure
    # Abandon the edit — nothing was committed; this call stays strictly
    # read-only against the store (gh-1041 I3).
    http("Delete", "#{api}/edits/#{edit_id}", headers: headers) rescue nil
  end
  S.decide_presence(expected: expected["app"], observed: versions).merge("observed" => versions)
end

def check_pubdev(expected)
  base = env("STORE_APPEARANCE_PUBDEV_BASE", "https://pub.dev/api")
  package = env("PUBDEV_PACKAGE", "flutter_agent_harness")
  code, payload, raw = json_response("Get", "#{base}/packages/#{package}", headers: { "Accept" => "application/json" })
  raise "pub.dev answered #{code}: #{raw.to_s[0, 160]}" unless code == 200

  parsed = S.parse_pubdev_package(payload)
  versions = ([parsed["latest"]] + parsed["versions"]).compact.uniq
  S.decide_presence(expected: expected["pubdev"], observed: versions).merge("observed" => versions)
end

# ── run the checks ───────────────────────────────────────────────────────────
skips = []
skips << "testflight: App Store Connect key not configured" if env("APP_STORE_CONNECT_KEY_CONTENT").nil?
skips << "testflight: TESTFLIGHT_EXTERNAL_GROUP not set" if env("TESTFLIGHT_EXTERNAL_GROUP").nil?
skips << "play: PLAY_STORE_SERVICE_ACCOUNT_JSON not set" if env("PLAY_STORE_SERVICE_ACCOUNT_JSON").nil?
skips << "pubdev: pubspec declares publish_to: none" if publish_to_none

stores = S::STORES.keys.select { |s| only.nil? || only == s }
verdicts = {}
errors = {}
stores.each do |store|
  if skips.any? { |s| s.start_with?("#{store}:") }
    warn "store-appearance-check: skipping #{skips.find { |s| s.start_with?("#{store}:") }}"
    next
  end
  begin
    verdicts[store] = case store
                      when "testflight" then check_testflight(now, expected)
                      when "play" then check_play(root, expected)
                      when "pubdev" then check_pubdev(expected)
                      end
  rescue StandardError => e
    errors[store] = e.message.to_s[0, 300]
    warn "store-appearance-check: #{store} API error — #{e.message}"
  end
end

# ── horizon + gh issue lifecycle ─────────────────────────────────────────────
def gh(*args)
  out = `gh #{args.map { |a| "'#{a.to_s.gsub("'", "'\\\\''")}'" }.join(' ')} 2>/dev/null`
  $?.success? ? out : nil
end

# Review gh-1041 thread 3: a gh READ failure must be loud — nil degrades to
# "empty state" downstream, which is exactly what files duplicate stubs.
def gh!(*args)
  out = gh(*args)
  raise "gh #{args.first} #{args[1]} failed" if out.nil?

  out
end

# since = when the day's daily-publish legs started (review thread 1: needs
# `actions: read` on the workflow token; review thread 3: a FAILED read
# aborts the lifecycle — it is never "no run found").
leg = nil
since = env("STORE_APPEARANCE_SINCE")
lifecycle_error = nil
if since.nil? && !repo.to_s.empty?
  begin
    leg = S.daily_run(raw: gh!("run", "list", "--repo", repo, "--workflow", "daily-publish.yml",
                               "--event", "schedule", "--limit", "5", "--json", "createdAt,status,conclusion",
                               "--jq", ".[0]"))
    since = leg&.dig("created_at")
  rescue StandardError => e
    lifecycle_error = e.message
    warn "store-appearance-check: #{e.message}"
  end
end
# review thread 5: a daily-publish leg still running at check time has
# possibly not uploaded yet — report only, never stub. review thread 7:
# a leg that ended NON-success never went green — its own [daily-publish]
# failure stub owns the "version missing" signal, not this check.
stub_due = S.stub_due?(now: now, since: since, horizon_minutes: horizon,
                       leg_status: leg&.dig("status"),
                       leg_conclusion: leg&.dig("conclusion"))

dry_run = %w[1 true yes].include?(env("STORE_APPEARANCE_DRY_RUN", "").to_s.downcase) || repo.to_s.empty?
open_stubs = []
publish_stubs = []
summarized = []
unless dry_run || lifecycle_error
  begin
    gh("label", "create", "store-appearance-check", "--repo", repo,
       "--color", "5319E7", "--description", "Auto-filed by the deferred store-appearance check (gh-1041)")
    S.parse_issue_list(gh!("issue", "list", "--repo", repo, "--state", "open", "--label",
                           "store-appearance-check", "--limit", "200", "--json", "number,title"),
                       label: "store-appearance-check").each do |issue|
      open_stubs << issue
    end
    S.parse_issue_list(gh!("issue", "list", "--repo", repo, "--state", "open", "--label",
                           "daily-publish", "--limit", "200", "--json", "number,title"),
                       label: "daily-publish").each do |issue|
      publish_stubs << issue["number"]
    end
    today = now[0, 10]
    publish_stubs.each do |number|
      bodies = gh!("issue", "view", number, "--repo", repo, "--json", "comments",
                   "--jq", "[.comments[].body] | join(\"\\n\")")
      summarized << number if bodies.include?(S::GREEN_SUMMARY_MARKER + today)
    end
  rescue StandardError => e
    lifecycle_error = e.message
    warn "store-appearance-check: lifecycle aborted — #{e.message}"
  end
end

# A failed lifecycle read leaves the state partially known: plan NOTHING
# (no stub on unread state, no close on unread state) and go red.
actions = lifecycle_error ? [] : S.plan_lifecycle(
  expected: expected, verdicts: verdicts, stub_due: stub_due,
  open_stubs: open_stubs, publish_stub_numbers: publish_stubs,
  summarized: summarized, run_url: run_url, now: now, errors: errors,
  leg: leg
)

# ── execute the plan ─────────────────────────────────────────────────────────
def write_temp(body)
  file = Tempfile.create(["store-appearance", ".md"])
  file.write(body)
  file.close
  file.path
end

executed = []
write_failures = []
actions.each do |action|
  # review gh-1041 thread 8: a failed gh WRITE must not pass silently —
  # record `done` per action, collect failures, and fold them into `failed`
  # so a partially-executed lifecycle never reports a clean green.
  record = lambda do |ok, extra = {}|
    write_failures << "#{action['action']} #{action['title'] || action['number']}" unless ok
    executed << action.merge("done" => ok, **extra)
  end
  case action["action"]
  when "create_stub"
    next executed << action.merge("skipped" => "dry-run") if dry_run
    body = write_temp(action["body"])
    url = gh("issue", "create", "--repo", repo, "--title", action["title"], "--body-file", body,
             "--label", "bug", "--label", "store-appearance-check", "--assignee", assignee)
    record.call(!url.nil?, "issue" => url.to_s.strip)
  when "comment_stub"
    next executed << action.merge("skipped" => "dry-run") if dry_run
    body = write_temp(action["body"])
    record.call(!gh("issue", "comment", action["number"], "--repo", repo, "--body-file", body).nil?)
  when "close_stub"
    next executed << action.merge("skipped" => "dry-run") if dry_run
    record.call(!gh("issue", "close", action["number"], "--repo", repo, "--comment", action["reason"]).nil?)
  when "comment_summary"
    next executed << action.merge("skipped" => "dry-run") if dry_run
    body = write_temp(action["body"])
    record.call(!gh("issue", "comment", action["number"], "--repo", repo, "--body-file", body).nil?)
  end
end

# ── report ───────────────────────────────────────────────────────────────────
failed = errors.any? || !lifecycle_error.nil? || write_failures.any? ||
         verdicts.any? { |_, v| v["verdict"] == "absent" && stub_due }
result = {
  "expected" => expected, "now" => now, "since" => since, "stub_due" => stub_due,
  "verdicts" => verdicts, "errors" => errors, "skips" => skips,
  "lifecycle_error" => lifecycle_error, "write_failures" => write_failures,
  "actions" => dry_run ? actions : executed, "dry_run" => dry_run
}

summary_rows = stores.map do |store|
  display = S::STORES[store]
  if (v = verdicts[store])
    icon = { "present" => "✅", "rolled_over" => "↪️", "absent" => "❌" }[v["verdict"]]
    served = v["observed"].empty? ? "-" : "`#{S.highest(v['observed'])}`"
    "| #{display} | `#{store == 'pubdev' ? expected['pubdev'] : expected['app']}` | #{icon} #{v['verdict']} (serves #{served}) |"
  elsif errors[store]
    "| #{display} | - | ⚠️ API error: #{errors[store].to_s[0, 80]} |"
  else
    "| #{display} | - | ⏭️ skipped |"
  end
end
if (path = ENV["GITHUB_STEP_SUMMARY"])
  names = (dry_run ? actions : executed).map { |a| a['action'] }
  leg_bits = leg&.dig('status') ? " • leg: #{leg['status']}#{leg['conclusion'] ? "/#{leg['conclusion']}" : ''}" : ''
  bits = +""
  bits << " • LIFECYCLE ABORTED: #{lifecycle_error.to_s[0, 120]}" if lifecycle_error
  bits << " • WRITE FAILURES: #{write_failures.join('; ').to_s[0, 200]}" if write_failures.any?
  File.write(path, <<~SUMMARY, mode: "a")
    ## Store appearance check (gh-1041)

    Expected: app `#{expected['app']}` • pub.dev `#{expected['pubdev']}` • horizon #{horizon} min (legs started: `#{since || 'unknown'}`#{leg_bits}) • stub due: #{stub_due}#{bits}

    | Store | Expected | Verdict |
    | --- | --- | --- |
    #{summary_rows.join("\n")}

    Actions: #{names.empty? ? '_none_' : names.join(', ')}
  SUMMARY

end

puts "STORE_APPEARANCE_RESULT #{JSON.generate(result)}"
exit(failed ? 1 : 0)
