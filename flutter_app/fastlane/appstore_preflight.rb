# frozen_string_literal: true

# Pure pre-flight decision logic for the manual App Store review submission
# (release-appstore.yml, issue #239 AC3). Deliberately dependency-free — no
# fastlane/spaceship requires: the Fastfile lane fetches the ASC facts, this
# module decides, so the whole matrix is testable with plain ruby
# (test/appstore_preflight_test.rb — no gems needed).
module AppstorePreflight
  # App Store version states where the version is already in review, or
  # approved and pending/released: a re-run must be a green no-op, never a
  # duplicate submission (AC3 idempotency, E2). Rejected states are NOT
  # listed — a rejected version may legitimately be resubmitted.
  SUBMITTED_STATES = %w[
    WAITING_FOR_REVIEW
    IN_REVIEW
    PENDING_DEVELOPER_RELEASE
    READY_FOR_SALE
    ACCEPTED
  ].freeze

  # Fat-finger guard: the workflow's `confirm` input must repeat `version`
  # exactly (AC3). Returns the fail decision with a named reason — the lane
  # surfaces it via UI.user_error!, no stack trace, nothing mutated.
  def self.confirm_mismatch?(version:, confirm:)
    confirm != version
  end

  # facts:
  #   version           String, e.g. "1.2.3"
  #   confirm           Workflow `confirm` input — must repeat `version` exactly
  #   app_store_version nil, or { "state" => AppStoreState string }
  #   builds            Array of { "number" => build number string,
  #                               "state"  => "PROCESSING"|"VALID"|"FAILED"|"INVALID" }
  # Returns a decision Hash:
  #   { "action" => "fail",   "reason" => why, "build_number" => nil } — fail BEFORE any mutation
  #   { "action" => "noop",   "reason" => why, "build_number" => nil } — green no-op notice
  #   { "action" => "submit", "reason" => why, "build_number" => n }   — latest processed build
  def self.decide(version:, confirm:, app_store_version:, builds:)
    if confirm_mismatch?(version: version, confirm: confirm)
      return fail_decision("CONFIRM MISMATCH: confirm (#{confirm.inspect}) does not equal version (#{version.inspect}) — aborting before any mutation")
    end
    if app_store_version.nil?
      return fail_decision("App Store version #{version} does not exist yet — run store-metadata.yml (metadata_only) first so the version exists. Nothing was mutated.")
    end
    if builds.empty?
      return fail_decision("No TestFlight build exists for version #{version} — dispatch build-mobile.yml / build-macos.yml first. Nothing was mutated.")
    end

    ready = builds.select { |b| b["state"] == "VALID" }
    if ready.empty?
      states = builds.map { |b| b["state"] }.tally.map { |s, n| "#{n} #{s}" }.join(", ")
      return fail_decision("Build(s) for version #{version} are still processing (#{states}) — Apple usually needs 5-30 min; re-run in ~15 minutes. Nothing was mutated.")
    end
    if SUBMITTED_STATES.include?(app_store_version["state"])
      return noop("Version #{version} is already submitted (App Store state #{app_store_version['state']}) — green no-op, nothing re-submitted")
    end

    build_number = ready.map { |b| b["number"].to_i }.max.to_s
    submit("Submitting #{version} (build #{build_number}, latest processed) for App Store review", build_number)
  end

  def self.fail_decision(reason)
    { "action" => "fail", "reason" => reason, "build_number" => nil }
  end

  def self.noop(reason)
    { "action" => "noop", "reason" => reason, "build_number" => nil }
  end

  def self.submit(reason, build_number)
    { "action" => "submit", "reason" => reason, "build_number" => build_number }
  end
end
