# frozen_string_literal: true

# Issue #947 — Play listing-image sync. Plain ruby, no gems (runs on the
# CI runner's stock ruby), mirroring play_upload_preflight_test.rb:
#
#   ruby flutter_app/fastlane/test/play_listing_sync_test.rb
#
# Everything is exercised against a stateful fake of the androidpublisher
# REST transport — no network. The fake records every call so the checks
# pin the exact behaviour the Sep 24 rejection demanded: stale screenshot
# sets deleted per locale + device type (including ru-RU tenInch and
# never-generated sevenInch), goldens uploaded with sha256 verification,
# commit only after every image checks out, and a post-commit
# edits.images.list gate that fails on any drift.
#
# Guarded by $PROGRAM_NAME so an accidental require by fastlane's loader
# never executes the checks.

require "digest"
require "json"
require "openssl"
require "tmpdir"
require "fileutils"

require_relative "../play_listing_sync"

if $PROGRAM_NAME == __FILE__
  $checks = 0

  def ok(message)
    $checks += 1
    puts "  ok #{message}"
  end

  # ── fake transport ──────────────────────────────────────────────────────
  # Stateful androidpublisher stand-in: token → edit → listings →
  # delete/upload/list images → commit/delete-edit.
  class FakePlayHttp
    attr_reader :calls, :store, :committed
    attr_accessor :upload_sha_override, :token_response, :remote_languages,
                  :post_commit_drift, :post_commit_reverse

    def initialize
      @calls = []
      @store = Hash.new { |h, key| h[key] = [] }
      @committed = []
      @remote_languages = %w[en-US ru-RU]
    end

    def request(method, url, headers: {}, body: nil, content_type: nil)
      @calls << [method, url]
      case
      when method == :Post && url.include?("oauth2.googleapis.com/token")
        @token_assertion = body
        @token_response || { status: 200, body: { access_token: "t0k3n" }.to_json }
      when method == :Post && url.end_with?("/edits")
        { status: 200, body: { id: "edit1" }.to_json }
      when method == :Get && url.end_with?("/listings")
        { status: 200, body: { listings: @remote_languages.map { |l| { language: l } } }.to_json }
      when method == :Delete && (m = url.match(%r{/listings/([^/]+)/images/([^/]+)\z}))
        @store.delete([m[1], m[2]])
        { status: 204, body: "" }
      when method == :Post && (m = url.match(%r{/listings/([^/]+)/images/([^/]+)\?uploadType=media\z}))
        sha = @upload_sha_override || Digest::SHA256.hexdigest(body.to_s)
        @store[[m[1], m[2]]] << sha
        { status: 200, body: { sha256: sha }.to_json }
      when method == :Get && (m = url.match(%r{/listings/([^/]+)/images/([^/]+)\z}))
        images = @store[[m[1], m[2]]].map { |s| { sha256: s } }
        # Post-commit drift injection: the committed listing keeps an image
        # the sync never uploaded (the stale-state failure mode #947 gates).
        if !@committed.empty? && @post_commit_drift == [m[1], m[2]]
          images += [{ sha256: Digest::SHA256.hexdigest("drift-junk") }]
        end
        # Post-commit order injection: the committed listing serves the same
        # image set in a different order (the ordering failure mode).
        images.reverse! if !@committed.empty? && @post_commit_reverse == [m[1], m[2]]
        { status: 200, body: { images: images }.to_json }
      when method == :Post && url.end_with?(":commit")
        @committed << url
        { status: 200, body: { id: "edit1" }.to_json }
      when method == :Delete && url.end_with?("/edits/edit1")
        { status: 200, body: "" }
      else
        raise "unexpected call: #{method} #{url}"
      end
    end
  end

  def write_png(path, bytes)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def metadata_dir_with_goldens(root)
    # Mirrors the real tree shape: en-US carries icon + featureGraphic +
    # phone + tenInch sets; ru-RU has NO tenInch set (falls back to phone).
    base = File.join(root, "android")
    write_png(File.join(base, "en-US/images/icon.png"), "icon-en")
    write_png(File.join(base, "en-US/images/featureGraphic.png"), "fg-en")
    write_png(File.join(base, "en-US/images/phoneScreenshots/01_store_chat.png"), "phone-en-1")
    write_png(File.join(base, "en-US/images/phoneScreenshots/02_store_apps.png"), "phone-en-2")
    write_png(File.join(base, "en-US/images/tenInchScreenshots/01_store_chat.png"), "ten-en-1")
    write_png(File.join(base, "ru-RU/images/icon.png"), "icon-ru")
    write_png(File.join(base, "ru-RU/images/phoneScreenshots/01_store_chat.png"), "phone-ru-1")
    base
  end

  def service_account_json
    @key ||= OpenSSL::PKey::RSA.generate(2048)
    JSON.generate(
      "client_email" => "play@fa1.iam.gserviceaccount.com",
      "private_key" => @key.to_pem
    )
  end

  puts "play_listing_sync:"

  # ── pure helpers ────────────────────────────────────────────────────────
  Dir.mktmpdir do |root|
    metadata_dir = metadata_dir_with_goldens(root)

    locales = PlayListingSync.repo_locales(metadata_dir)
    raise "FAIL: repo locales #{locales.inspect}" unless locales == %w[en-US ru-RU]
    ok("repo locales discovered from the metadata dirs")

    phone = PlayListingSync.local_images(metadata_dir, "en-US", "phoneScreenshots")
    raise "FAIL: phone shots not sorted" unless phone.map { |p| File.basename(p) } == ["01_store_chat.png", "02_store_apps.png"]
    raise "FAIL: missing dir must yield []" unless PlayListingSync.local_images(metadata_dir, "ru-RU", "tenInchScreenshots") == []
    ok("local image sets sorted; missing dirs yield an empty set")

    # The #947 regression pin: the clear plan covers EVERY listing locale ×
    # EVERY multi-slot type — including ru-RU tenInch (no longer generated)
    # and sevenInch (never generated).
    plan = PlayListingSync.clear_plan(metadata_dir, ["de-DE"])
    expected = %w[de-DE en-US ru-RU].product(PlayListingSync::SCREENSHOT_TYPES).size
    raise "FAIL: clear plan size #{plan.size} != #{expected}" unless plan.size == expected
    raise "FAIL: ru-RU tenInch must be cleared" unless plan.any? { |e| e[:locale] == "ru-RU" && e[:type] == "tenInchScreenshots" }
    raise "FAIL: console-only locale must be cleared" unless plan.any? { |e| e[:locale] == "de-DE" }
    ok("clear plan = every listing locale × every multi-slot type (#{expected} sets)")

    state = PlayListingSync.expected_state(metadata_dir, [])
    raise "FAIL: en-US tenInch expected non-empty" unless state["en-US"]["tenInchScreenshots"].size == 1
    raise "FAIL: ru-RU tenInch expected EMPTY" unless state["ru-RU"]["tenInchScreenshots"] == []
    raise "FAIL: expected state must carry sha256 digests" unless state["en-US"]["icon"] == [Digest::SHA256.hexdigest("icon-en")]
    ok("expected state = repo goldens by sha256, empty where the repo ships none")
  end

  # ── service-account JWT ─────────────────────────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    key = OpenSSL::PKey::RSA.generate(2048)
    json_key = JSON.generate("client_email" => "play@fa1.iam.gserviceaccount.com",
                             "private_key" => key.to_pem)
    PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: json_key,
                                     package_name: "dev.fa1.app", http: http)
    assertion = http.instance_variable_get(:@token_assertion)
    raise "FAIL: token request missing assertion" unless assertion.to_s.include?("assertion=")
    jwt = assertion.split("assertion=").last.split("&").first
    header, payload, signature = jwt.split(".")
    decode = ->(part) { JSON.parse(Base64.urlsafe_decode64(part)) }
    raise "FAIL: alg must be RS256" unless decode.call(header)["alg"] == "RS256"
    claims = decode.call(payload)
    raise "FAIL: iss" unless claims["iss"] == "play@fa1.iam.gserviceaccount.com"
    raise "FAIL: scope" unless claims["scope"] == PlayListingSync::SCOPE
    raise "FAIL: aud" unless claims["aud"] == PlayListingSync::TOKEN_URL
    raise "FAIL: exp must be in the future" unless claims["exp"] > claims["iat"]
    unless key.public_key.verify("SHA256", Base64.urlsafe_decode64(signature), "#{header}.#{payload}")
      raise "FAIL: JWT signature does not verify"
    end
    ok("service-account JWT: RS256 signature verifies, iss/scope/aud correct")
  end

  # ── happy path: replace + verify ────────────────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    # Pre-seed STALE remote state: the old-copy phone screenshot that Play
    # reviewed, plus a tenInch set on ru-RU (a type the repo dropped) and a
    # never-generated sevenInch set.
    http.store[["en-US", "phoneScreenshots"]] << Digest::SHA256.hexdigest("STALE the-first-mobile-agent-harness")
    http.store[["ru-RU", "tenInchScreenshots"]] << Digest::SHA256.hexdigest("stale-ru-teninch")
    http.store[["en-US", "sevenInchScreenshots"]] << Digest::SHA256.hexdigest("stale-seven")

    summary = PlayListingSync.sync_and_verify!(
      metadata_dir: metadata_dir, json_key: service_account_json,
      package_name: "dev.fa1.app", http: http
    )

    raise "FAIL: expected a summary line, got #{summary.inspect}" unless summary.include?("verified")
    deletes = http.calls.select { |m, _u| m == :Delete }.map { |_m, u| u }
    [%w[en-US phoneScreenshots], %w[ru-RU phoneScreenshots],
     %w[en-US tenInchScreenshots], %w[ru-RU tenInchScreenshots],
     %w[en-US sevenInchScreenshots], %w[ru-RU sevenInchScreenshots]].each do |locale, type|
      raise "FAIL: #{locale}/#{type} not cleared" unless deletes.any? { |u| u.include?("/listings/#{locale}/images/#{type}") }
    end
    ok("stale sets cleared for every locale × multi-slot type (ru-RU tenInch, sevenInch, stale en shot)")

    uploads = http.calls.count { |m, u| m == :Post && u.include?("uploadType=media") }
    raise "FAIL: expected 7 uploads (en-US 5, ru-RU 2), got #{uploads}" unless uploads == 7
    ok("all committed goldens uploaded (en-US 5, ru-RU 2)")

    raise "FAIL: commit missing" unless http.committed.size == 1
    commit_index = http.calls.index { |m, u| m == :Post && u.end_with?(":commit") }
    last_upload_index = http.calls.rindex { |m, u| m == :Post && u.include?("uploadType=media") }
    raise "FAIL: commit must come after every upload" unless commit_index > last_upload_index
    ok("single commit strictly after the last upload")
  end

  # ── upload sha mismatch aborts BEFORE commit ────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.upload_sha_override = Digest::SHA256.hexdigest("recompressed-bytes")
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: sha mismatch must raise"
    rescue RuntimeError => e
      raise "FAIL: error must name the mismatch, got: #{e.message}" unless e.message.include?("stored different bytes")
    end
    raise "FAIL: a failed upload must never commit" unless http.committed.empty?
    ok("stored-bytes mismatch aborts before commit (listing untouched)")
  end

  # ── post-commit drift fails the job ─────────────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    # Every upload checks out and the edit commits — but the committed
    # listing keeps a stale image the sync never uploaded (the exact
    # stale-state failure mode #947 closes). The edits.images.list gate
    # must catch it and fail the job.
    http.post_commit_drift = %w[ru-RU phoneScreenshots]
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: drifted listing must raise"
    rescue RuntimeError => e
      unless e.message.include?("does NOT match the committed goldens") &&
             e.message.include?("edits.images.list") &&
             e.message.include?("ru-RU/phoneScreenshots")
        raise "FAIL: wrong error, got: #{e.message}"
      end
    end
    verify_edit_discarded = http.calls.any? { |m, u| m == :Delete && u.end_with?("/edits/edit1") }
    raise "FAIL: the read-only verify edit must be discarded" unless verify_edit_discarded
    ok("post-commit edits.images.list drift fails the job loudly")
  end

  # ── console-only locale: screenshots self-heal, single images don't care ──
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.remote_languages = %w[de-DE en-US ru-RU]
    metadata_dir = metadata_dir_with_goldens(root)
    # A locale added in Play Console only (de-DE: no repo metadata dir)
    # inherits stale screenshots from whatever locale was cloned in the
    # console. The sync must clear EVERY de-DE screenshot slot (self-heal)
    # but never touch de-DE icon/featureGraphic (no goldens to push, and
    # the verify gate must not read those slots either).
    http.store[["de-DE", "icon"]] << Digest::SHA256.hexdigest("icon-de")
    http.store[["de-DE", "featureGraphic"]] << Digest::SHA256.hexdigest("fg-junk")
    http.store[["de-DE", "phoneScreenshots"]] << Digest::SHA256.hexdigest("stale-de")
    summary = PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                               package_name: "dev.fa1.app", http: http)
    raise "FAIL: stale de-DE phone screenshot must be cleared" unless
      http.calls.any? { |m, u| m == :Delete && u.include?("/listings/de-DE/images/phoneScreenshots") }
    raise "FAIL: de-DE icon must not be deleted or uploaded" unless
      http.calls.none? { |m, u| m != :Get && u.include?("/listings/de-DE/images/icon") }
    raise "FAIL: de-DE featureGraphic must not be deleted or uploaded" unless
      http.calls.none? { |m, u| m != :Get && u.include?("/listings/de-DE/images/featureGraphic") }
    raise "FAIL: verify must not read de-DE single-image slots" unless
      http.calls.none? { |m, u| m == :Get && u =~ %r{/listings/de-DE/images/(icon|featureGraphic)\z} }
    ok("console-only locale: screenshot slots cleared, single images untouched")
  end

  # ── post-commit ordering drift fails the job ────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    # Same sha set, served in a different order after commit (Play reordering
    # or partial replace): the verify gate must catch it, not just per-image
    # sha equality.
    http.post_commit_reverse = %w[en-US phoneScreenshots]
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: reordered listing must raise"
    rescue RuntimeError => e
      unless e.message.include?("order") && e.message.include?("en-US/phoneScreenshots")
        raise "FAIL: wrong error, got: #{e.message}"
      end
    end
    order_edit_discarded = http.calls.any? { |m, u| m == :Delete && u.end_with?("/edits/edit1") }
    raise "FAIL: the read-only verify edit must be discarded" unless order_edit_discarded
    ok("post-commit screenshot order drift fails the job loudly")
  end

  # ── auth failure is loud ────────────────────────────────────────────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.token_response = { status: 401, body: { error: "invalid_grant" }.to_json }
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: 401 token response must raise"
    rescue RuntimeError => e
      raise "FAIL: error must name the auth failure, got: #{e.message}" unless e.message.include?("Play API auth failed (HTTP 401)")
    end
    ok("token failure fails loudly with the HTTP status")
  end

  puts "play_listing_sync: #{$checks} checks passed"
end
