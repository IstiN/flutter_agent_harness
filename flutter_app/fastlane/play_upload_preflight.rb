# frozen_string_literal: true

# Play upload pre-flight (issue #289), plain ruby with no gem deps so it
# runs anywhere (fastlane's loader requires it; CI runs its unit test with
# the runner's stock ruby). The Fastfile's android upload_only lane routes
# every decision through here so the behaviour is testable without the
# Play API:
#
#   * track resolution — internal first run, then external beta / open
#     testing (the daily leg dispatches PLAY_TRACK=beta);
#   * service-account JSON key — PLAY_STORE_SERVICE_ACCOUNT_JSON is the
#     one canonical secret name (#289);
#   * AAB path — ANDROID_AAB_PATH override or flutter's conventional
#     build/app/outputs/bundle/release/app-release.aab;
#   * validate-only (dry-run) mapping — every supply upload skip flag on,
#     so the lane authenticates and resolves the track without publishing.
module PlayUploadPreflight
  ALLOWED_TRACKS = %w[internal alpha beta production].freeze

  module_function

  # Track for upload_to_play_store. Default: internal (the first manual
  # upload lands there; the daily promotes to beta / open testing).
  def track!(env)
    track = env["PLAY_TRACK"].to_s.strip
    track = "internal" if track.empty?
    unless ALLOWED_TRACKS.include?(track)
      raise "PLAY_TRACK must be one of #{ALLOWED_TRACKS.join('|')} (got " \
            "'#{track}') — 'internal' is the first-upload track, 'beta' " \
            "is the external/open testing track the daily publishes to"
    end
    track
  end

  # Service-account JSON for the Play Developer API.
  def play_json_key!(env)
    key = env["PLAY_STORE_SERVICE_ACCOUNT_JSON"].to_s.strip
    if key.empty?
      raise "PLAY_STORE_SERVICE_ACCOUNT_JSON is not set — the Play upload " \
            "needs the Play Developer API service-account JSON key"
    end
    key
  end

  def default_aab_path(repo_root)
    File.join(repo_root, "build/app/outputs/bundle/release/app-release.aab")
  end

  # AAB to upload; fails loudly (with the env name) when it is missing.
  def aab_path!(env, repo_root:)
    path = env["ANDROID_AAB_PATH"].to_s.strip
    path = default_aab_path(repo_root) if path.empty?
    unless File.exist?(path)
      raise "AAB not found at #{path} — build it first " \
            "(fastlane android build_release) or point ANDROID_AAB_PATH " \
            "at the bundle"
    end
    path
  end

  # Dry-run mode: authenticate + resolve the track, publish nothing.
  def validate_only?(env)
    %w[1 true yes].include?(env["PLAY_VALIDATE_ONLY"].to_s.strip.downcase)
  end

  # Package name (Android application id) for upload_to_play_store. fastlane
  # cannot infer it from a supply/metadata dir here (there is none in the
  # CI job context — #374), so every Play upload passes it explicitly. The
  # gradle file stays the single source of truth: applicationId is parsed
  # from android/app/build.gradle.kts (it is immutable after the first
  # Play upload; test/android_release_guard_test.rb pins it).
  def package_name!(repo_root)
    gradle_path = File.join(repo_root, "android/app/build.gradle.kts")
    application_id = nil
    if File.exist?(gradle_path)
      application_id = File.read(gradle_path)[/^\s*applicationId\s*=\s*"([^"]+)"/, 1]
    end
    unless application_id
      raise "applicationId not found in #{gradle_path} — upload_to_play_store " \
            "needs package_name (fastlane cannot infer it without a supply " \
            "metadata dir, #374)"
    end
    application_id
  end

  # Options hash for upload_to_play_store. Metadata/screenshots never ride
  # the app upload (store content is a separate lane, mirroring iOS).
  def supply_options(track:, aab:, validate_only:)
    {
      aab: aab,
      track: track,
      skip_upload_aab: validate_only ? true : false,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
      skip_upload_changelogs: true
    }
  end

  # Options hash for the store-listing lane (fastlane android play_store):
  # metadata texts + images (icon/featureGraphic) + screenshots from
  # fastlane/metadata/android/<locale>/ — NEVER a binary (AABs ride the
  # upload_only lane) and never changelogs (Play release notes need a
  # version code and ride the binary upload instead).
  def supply_listing_options(track:, metadata:, images:, validate_only:)
    {
      track: track,
      skip_upload_aab: true,
      skip_upload_metadata: !(metadata && !validate_only),
      skip_upload_images: !(images && !validate_only),
      skip_upload_screenshots: !(images && !validate_only),
      skip_upload_changelogs: true
    }
  end
end
