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

  lane_match = source.match(/^  lane :build_only do\n(.*?)^  end$/m)
  raise "FAIL: could not locate lane :build_only in Fastfile" unless lane_match

  lane_body = lane_match[1]

  # gh-1865 model v3: the retired per-job-keychain helper must never come
  # back (its additive union kept concurrent keychains but made
  # same-subject certificates ambiguous — run 40455401630).
  raise "FAIL: build_only references the RETIRED keychain_searchlist_add.sh helper" \
    if lane_body.include?('keychain_searchlist_add')

  # The persistent-keychain unlock must be resolved absolutely from the
  # Fastfile location (gh-1910 lesson: fastlane's sh does not honor the
  # assumed lane cwd; a relative ../scripts path failed with exit 127,
  # run 4032679374).
  ci_sign_expr = 'File.expand_path("../../scripts/ci-sign", __dir__)'
  raise "FAIL: build_only does not resolve scripts/ci-sign from the Fastfile location (#{ci_sign_expr})" \
    unless lane_body.include?(ci_sign_expr)

  raise "FAIL: build_only does not unlock the persistent signing keychain via ci-sign" \
    unless lane_body.include?('sh(ci_sign, "unlock")')

  puts "PASS: build_only resolves ci-sign from __dir__ and unlocks the persistent keychain"
end
