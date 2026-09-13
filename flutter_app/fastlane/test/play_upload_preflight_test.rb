# frozen_string_literal: true

# Issue #289 AC4 — Play upload pre-flight. Plain ruby, no gems (runs on the
# CI runner's stock ruby and anywhere else), mirroring
# appstore_preflight_test.rb:
#
#   ruby flutter_app/fastlane/test/play_upload_preflight_test.rb
#
# This is the mocked-track dry-run half of the AC: the track name, AAB path
# and service-account resolution are asserted WITHOUT touching the real
# Play API (the real upload is a one-time owner action to the internal
# track).
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

require_relative "../play_upload_preflight"

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  def assert_raises_named(fragment)
    yielded = false
    begin
      yield
    rescue => e
      yielded = true
      unless e.message.include?(fragment)
        raise "FAIL: expected error mentioning '#{fragment}', got: #{e.message}"
      end
    end
    raise "FAIL: expected an error mentioning '#{fragment}', none raised" unless yielded
  end

  # ── track resolution ────────────────────────────────────────────────────
  # Issue: "track: internal first run, then external beta / open testing" —
  # the lane defaults to internal; the daily leg passes PLAY_TRACK=beta.
  t = PlayUploadPreflight.track!({})
  raise "FAIL: default track must be internal, got #{t}" unless t == "internal"
  ok("default track = internal")

  %w[internal alpha beta production].each do |track|
    got = PlayUploadPreflight.track!({ "PLAY_TRACK" => track })
    raise "FAIL: track #{track} not accepted" unless got == track
  end
  ok("internal/alpha/beta/production accepted")

  assert_raises_named("PLAY_TRACK") { PlayUploadPreflight.track!({ "PLAY_TRACK" => "external" }) }
  ok("bogus track fails loudly, names PLAY_TRACK")

  # ── service-account JSON key ────────────────────────────────────────────
  key = PlayUploadPreflight.play_json_key!({ "PLAY_STORE_SERVICE_ACCOUNT_JSON" => "{a:1}" })
  raise "FAIL: PLAY_STORE_SERVICE_ACCOUNT_JSON must win" unless key == "{a:1}"
  ok("PLAY_STORE_SERVICE_ACCOUNT_JSON is the canonical secret")

  legacy = PlayUploadPreflight.play_json_key!({ "PLAY_STORE_JSON_KEY" => "{b:2}" })
  raise "FAIL: legacy PLAY_STORE_JSON_KEY must be honored" unless legacy == "{b:2}"
  ok("legacy PLAY_STORE_JSON_KEY falls back")

  assert_raises_named("PLAY_STORE_SERVICE_ACCOUNT_JSON") do
    PlayUploadPreflight.play_json_key!({})
  end
  ok("missing service account fails loudly, names both secret names")

  # ── AAB path ────────────────────────────────────────────────────────────
  repo_root = File.expand_path("../..", __dir__) # flutter_app
  aab = PlayUploadPreflight.aab_path!(
    { "ANDROID_AAB_PATH" => File.join(repo_root, "Gemfile") }, repo_root: repo_root)
  raise "FAIL: ANDROID_AAB_PATH override ignored" unless File.exist?(aab)
  ok("ANDROID_AAB_PATH override wins when the file exists")

  assert_raises_named("ANDROID_AAB_PATH") do
    PlayUploadPreflight.aab_path!(
      { "ANDROID_AAB_PATH" => "/nonexistent/app-release.aab" }, repo_root: repo_root)
  end
  ok("missing AAB fails loudly, names ANDROID_AAB_PATH")

  # Default path follows flutter build appbundle's conventional location.
  default = PlayUploadPreflight.default_aab_path(repo_root)
  expected = File.join(repo_root, "build/app/outputs/bundle/release/app-release.aab")
  raise "FAIL: default AAB path #{default} != #{expected}" unless default == expected
  ok("default AAB path = build/app/outputs/bundle/release/app-release.aab")

  # ── validate-only (dry-run) mode ────────────────────────────────────────
  unless PlayUploadPreflight.validate_only?({}) == false
    raise "FAIL: validate_only? must default to false"
  end
  raise "FAIL: PLAY_VALIDATE_ONLY=1 must flip validate_only?" unless
    PlayUploadPreflight.validate_only?({ "PLAY_VALIDATE_ONLY" => "1" }) &&
    PlayUploadPreflight.validate_only?({ "PLAY_VALIDATE_ONLY" => "true" })
  ok("PLAY_VALIDATE_ONLY=1/true flips validate-only")

  # ── supply options mapping ──────────────────────────────────────────────
  opts = PlayUploadPreflight.supply_options(track: "beta", aab: "/tmp/a.aab", validate_only: false)
  raise "FAIL: track not mapped" unless opts[:track] == "beta"
  raise "FAIL: aab not mapped" unless opts[:aab] == "/tmp/a.aab"
  raise "FAIL: metadata must never ride the daily app_only upload" unless
    opts[:skip_upload_metadata] == true && opts[:skip_upload_screenshots] == true &&
    opts[:skip_upload_images] == true && opts[:skip_upload_changelogs] == true
  raise "FAIL: real upload must upload the AAB" unless opts[:skip_upload_aab] == false
  ok("supply options: beta track + aab, no metadata/screenshots")

  dry = PlayUploadPreflight.supply_options(track: "internal", aab: "/tmp/a.aab", validate_only: true)
  raise "FAIL: validate-only must skip the AAB upload" unless dry[:skip_upload_aab] == true
  ok("validate-only: every upload skip flag on (auth + track validated only)")

  puts "play_upload_preflight: #{$checks} checks passed"
end
