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
#     canonical secret (#289), the pre-existing PLAY_STORE_JSON_KEY wiring
#     in build-mobile.yml stays honored as a fallback;
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
    key = env["PLAY_STORE_JSON_KEY"].to_s.strip if key.empty?
    if key.empty?
      raise "PLAY_STORE_SERVICE_ACCOUNT_JSON is not set — the Play upload " \
            "needs the Play Developer API service-account JSON key (the " \
            "legacy PLAY_STORE_JSON_KEY name is also honored)"
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
end
