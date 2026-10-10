# frozen_string_literal: true

# gh-1519 — store-metadata's app_store lanes must CREATE the App Store
# version when absent (deliver with skip_app_version_update:true never
# materializes the record, so release-appstore.yml's pre-flight dead-ended
# on every fresh version). The create/no-create decision lives here, pure
# ruby, no gems:
#
#   ruby flutter_app/fastlane/test/store_version_create_test.rb
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

require_relative "../store_version_create"

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  # gh-1519 REG — existing version: NO create (metadata update only,
  # re-running store-metadata stays idempotent, no duplicate version error)
  raise "FAIL: existing version must not re-create, got #{StoreVersionCreate.needs_create?(existing: %w[1.0.547 1.0.548], version: "1.0.548").inspect}" \
    if StoreVersionCreate.needs_create?(existing: %w[1.0.547 1.0.548], version: "1.0.548")
  ok("existing version → no create (idempotent re-run)")

  # Fresh version → create required (the v1.0.548 hole)
  raise "FAIL: absent version must require create, got #{StoreVersionCreate.needs_create?(existing: %w[1.0.547], version: "1.0.548").inspect}" \
    unless StoreVersionCreate.needs_create?(existing: %w[1.0.547], version: "1.0.548")
  ok("absent version → create required")

  # First version ever → create required
  raise "FAIL: empty version list must require create" \
    unless StoreVersionCreate.needs_create?(existing: [], version: "1.0.0")
  ok("first version ever → create required")

  # Substring traps: 1.0.54 must not satisfy 1.0.548, 1.0.548 must not
  # satisfy 1.0.54
  raise "FAIL: prefix substring must not count as existing" \
    if StoreVersionCreate.needs_create?(existing: %w[1.0.54], version: "1.0.548") == false
  raise "FAIL: longer existing version must not satisfy a shorter one" \
    unless StoreVersionCreate.needs_create?(existing: %w[1.0.548], version: "1.0.54")
  ok("substring look-alikes do not count as the version existing")

  # create_attributes — the POST /v1/appStoreVersions body (Spaceship
  # create_app_store_version), per platform
  ios_attrs = StoreVersionCreate.create_attributes(platform: "IOS", version: "1.0.548")
  raise "FAIL: iOS attrs wrong, got #{ios_attrs.inspect}" \
    unless ios_attrs == { platform: "IOS", versionString: "1.0.548" }
  mac_attrs = StoreVersionCreate.create_attributes(platform: "MAC_OS", version: "1.0.548")
  raise "FAIL: macOS attrs wrong, got #{mac_attrs.inspect}" \
    unless mac_attrs == { platform: "MAC_OS", versionString: "1.0.548" }
  ok("create_attributes → {platform, versionString} for IOS and MAC_OS")

  puts "store_version_create: #{$checks} checks OK"
end
