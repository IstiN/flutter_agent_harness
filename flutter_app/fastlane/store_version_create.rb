# frozen_string_literal: true

# gh-1519 — store-metadata's app_store lanes must CREATE the App Store
# version when absent. Before this fix, deliver ran with
# skip_app_version_update:true, which never materializes the version
# record: store-metadata went green while creating nothing, and
# release-appstore.yml's pre-flight dead-ended on every fresh version
# (v1.0.548 needed a manual ASC click). Deliberately dependency-free —
# the Fastfile performs the Spaceship calls, this module decides, so the
# matrix is testable with plain ruby
# (test/store_version_create_test.rb — no gems needed).
module StoreVersionCreate
  # existing: version strings already in App Store Connect for the
  # platform (get_app_store_versions → version_string).
  # version:    the version the lane is about to ship (pubspec).
  # Returns true when an explicit appStoreVersions POST is required
  # BEFORE deliver — false keeps the re-run idempotent (metadata update
  # only, no duplicate version error).
  def self.needs_create?(existing:, version:)
    !existing.map(&:to_s).include?(version.to_s)
  end

  # Attributes for the POST /v1/appStoreVersions call (Spaceship
  # create_app_store_version). Pure data — the Fastfile performs the POST.
  def self.create_attributes(platform:, version:)
    { platform: platform, versionString: version }
  end
end
