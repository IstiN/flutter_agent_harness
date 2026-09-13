# frozen_string_literal: true

# Issue #289 AC1 — Android release id guard. Plain ruby, no gems (runs on
# the CI runner's stock ruby and anywhere else), mirroring
# appstore_preflight_test.rb:
#
#   ruby flutter_app/fastlane/test/android_release_guard_test.rb
#
# applicationId is IMMUTABLE after the first Play Console upload, so this
# guards the dev.fa1.app flip and keeps dev.fa1.android from creeping back
# in (grep-guard: zero remnants outside changelogs).
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

if $PROGRAM_NAME == __FILE__
  repo_root = File.expand_path("../../..", __dir__)
  app_gradle = File.join(repo_root, "flutter_app/android/app/build.gradle.kts")

  $checks = 0
  def ok(message)
    $checks += 1
    puts "  ok: #{message}"
  end

  raise "FAIL: #{app_gradle} not found" unless File.exist?(app_gradle)
  gradle = File.read(app_gradle)

  # AC1 — namespace + applicationId must both be dev.fa1.app (the iOS bundle
  # id; the owner ruling aligns Android BEFORE any Play upload exists).
  unless gradle =~ /^\s*namespace\s*=\s*"dev\.fa1\.app"/
    raise "FAIL: namespace in app/build.gradle.kts must be \"dev.fa1.app\""
  end
  ok("namespace = dev.fa1.app")

  unless gradle =~ /^\s*applicationId\s*=\s*"dev\.fa1\.app"/
    raise "FAIL: applicationId in app/build.gradle.kts must be \"dev.fa1.app\""
  end
  ok("applicationId = dev.fa1.app")

  # MainActivity must live under the namespace package path and declare it.
  main_activity = File.join(
    repo_root, "flutter_app/android/app/src/main/kotlin/dev/fa1/app/MainActivity.kt")
  unless File.exist?(main_activity)
    raise "FAIL: MainActivity expected at kotlin/dev/fa1/app/MainActivity.kt " \
          "(namespace package path) — not found"
  end
  unless File.read(main_activity) =~ /^package dev\.fa1\.app$/
    raise "FAIL: MainActivity must declare `package dev.fa1.app`"
  end
  ok("MainActivity at kotlin/dev/fa1/app/MainActivity.kt, package dev.fa1.app")

  # AC3 — the release signing config must read the upload keystore from the
  # environment (CI secrets) or key.properties, with a loud strict failure.
  %w[ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD
     ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_STRICT_RELEASE_SIGNING].each do |var|
    unless gradle.include?(var)
      raise "FAIL: app/build.gradle.kts release signing must handle #{var}"
    end
  end
  ok("release signing reads ANDROID_KEYSTORE_* env (strict mode wired)")

  # Grep-guard — zero dev.fa1.android remnants outside changelogs. Scan the
  # surfaces where the old id could leak back (gradle/manifest/kotlin,
  # workflows, docs, scripts); changelogs are history and exempt.
  scan_dirs = %w[
    flutter_app/android flutter_app/fastlane flutter_app/lib flutter_app/test
    flutter_app/tool .github docs scripts
  ].map { |d| File.join(repo_root, d) }.select { |d| File.directory?(d) }

  remnants = []
  require "find"
  Find.find(*scan_dirs) do |path|
    next Find.prune if File.basename(path) == "test" && File.dirname(path).end_with?("fastlane")
    next Find.prune if File.basename(path).start_with?(".")
    next unless File.file?(path) && File.basename(path) =~ /\.(kts|kt|java|xml|gradle|properties|ya?ml|md|rb|sh|json)$/
    next if File.basename(path) =~ /changelog/i

    if File.read(path, mode: "r:BOM|UTF-8") =~ /dev\.fa1\.android/
      remnants << path.sub("#{repo_root}/", "")
    end
  rescue ArgumentError, Errno::ENOENT
    # Binary or unreadable — not a source remnant.
  end
  unless remnants.empty?
    raise "FAIL: dev.fa1.android remnants found (applicationId is immutable on Play — " \
          "the id is dev.fa1.app now): #{remnants.join(', ')}"
  end
  ok("zero dev.fa1.android remnants outside changelogs")

  puts "android_release_guard: #{$checks} checks passed"
end
