# frozen_string_literal: true

# Pure decision logic for the TestFlight version-floor pre-check (issue
# #798, triage of #785): the daily leg must abort BEFORE any build when the
# version it is about to stamp is not strictly above the latest version App
# Store Connect has already APPROVED (iris-code 90062 — a 20-minute build
# ending in altool rejection is the failure class this kills). Dependency-
# free — no fastlane/spaceship requires: the Fastfile lane fetches the ASC
# facts, this module decides, so the whole matrix is testable with plain
# ruby (test/version_floor_test.rb — no gems needed).
module VersionFloor
  # App Store states where Apple has APPROVED the version — only these
  # raise the floor Apple's monotonicity check (90062) compares against.
  # A version that merely exists as a TestFlight build or sits in review
  # never counts: it can still be rejected, and the check must not block
  # on it.
  APPROVED_STATES = %w[
    ACCEPTED
    PENDING_DEVELOPER_RELEASE
    READY_FOR_SALE
  ].freeze

  # stamped:  the version the leg is about to stamp — BUILD_NAME, the same
  #           value the build lane passes as --build-name (the one-version
  #           scheme source: pubspec → tag → version job output, gh-785)
  # approved: array of { "state" => ASC appStoreState, "version" => string }
  # Returns a decision Hash:
  #   { "action" => "abort", "floor" => "x.y.z", "reason" => why } — fail FAST, zero build minutes
  #   { "action" => "pass",  "floor" => "x.y.z", "reason" => why }
  def self.decide(stamped:, approved:)
    floor = approved
            .select { |v| APPROVED_STATES.include?(v["state"]) }
            .map { |v| semver(v["version"]) }
            .compact
            .max || [0, 0, 0] # E2: first-ever release — trivially passable floor
    stamped_v = semver(stamped)
    if stamped_v.nil?
      return decision("abort", floor, "stamped version #{stamped.inspect} is not a comparable x.y.z — the one-version scheme (gh-785) is broken")
    end

    if (stamped_v <=> floor) <= 0
      return decision("abort", floor, "stamped #{stamped} ≤ approved #{floor.join('.')} — bump rule / one-version scheme broken (gh-785); refusing to spend build minutes on a guaranteed-rejected upload (iris 90062)")
    end
    decision("pass", floor, "stamped #{stamped} > approved #{floor.join('.')}")
  end

  # Strict x.y.z (minor/patch optional): nil for anything else, so garbage
  # from ASC or the pipeline aborts named instead of comparing wrong.
  def self.semver(string)
    m = string.to_s.strip.match(/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/)
    return nil unless m

    [m[1].to_i, m[2].to_i, m[3].to_i]
  end

  def self.decision(action, floor, reason)
    { "action" => action, "floor" => floor.join("."), "reason" => reason }
  end
end
