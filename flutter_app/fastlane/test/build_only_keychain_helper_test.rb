# frozen_string_literal: true

# gh-1910 — the build_only lane must invoke scripts/keychain_searchlist_add.sh
# via a path resolved from the Fastfile location (__dir__), not a relative
# ../scripts path that depends on the process cwd. On the runner fastlane's
# sh did not honor the assumed lane cwd, so the relative call failed with
# exit 127 (run 4032679374, Fastfile:453).
# Plain ruby, no gems:
#
#   ruby flutter_app/fastlane/test/build_only_keychain_helper_test.rb
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

if $PROGRAM_NAME == __FILE__
  fastfile = File.expand_path("../Fastfile", __dir__)
  source = File.read(fastfile)

  # Extract the build_only lane body (up to the next `lane` or top-level
  # `end` at the same indent).
  lane_match = source.match(/^  lane :build_only do\n(.*?)^  end$/m)
  raise "FAIL: could not locate lane :build_only in Fastfile" unless lane_match

  lane_body = lane_match[1]

  raise "FAIL: build_only still calls the helper via relative ../scripts path (cwd-dependent)" \
    if lane_body.include?('sh("bash", "../scripts/keychain_searchlist_add.sh"')

  helper_expr = 'File.expand_path("../../scripts/keychain_searchlist_add.sh", __dir__)'
  raise "FAIL: build_only does not resolve the helper from the Fastfile location (#{helper_expr})" \
    unless lane_body.include?(helper_expr)

  # Both keychain branches (build.keychain-db and login.keychain-db) must use
  # the resolved helper, and the resolved file must actually exist. Resolve
  # from the Fastfile's directory (flutter_app/fastlane), not this test's.
  fastfile_dir = File.expand_path("..", __dir__)
  resolved = File.expand_path("../../scripts/keychain_searchlist_add.sh", fastfile_dir)
  raise "FAIL: resolved helper #{resolved} does not exist" unless File.exist?(resolved)

  raise "FAIL: build.keychain-db branch does not use the resolved helper" \
    unless lane_body.include?('sh("bash", keychain_helper, "#{Dir.home}/Library/Keychains/build.keychain-db")')
  raise "FAIL: login.keychain-db branch does not use the resolved helper" \
    unless lane_body.include?('sh("bash", keychain_helper, "#{Dir.home}/Library/Keychains/login.keychain-db")')

  # Regression guard: no relative ../scripts sh call anywhere in the file.
  raise "FAIL: another relative ../scripts sh call exists in the Fastfile" \
    if source.match?(/^\s*sh\(.*"\.\.\/scripts\//)

  puts "gh-1910: build_only keychain helper resolved via __dir__ — all checks passed"
end
