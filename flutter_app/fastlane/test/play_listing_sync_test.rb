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
  # delete/upload/list images → commit/delete-edit. The image paths mirror
  # the REAL androidpublisher v3 contract (gh-1261): the AppImageType enum
  # value sits DIRECTLY in the path (.../listings/<locale>/<imageType>) —
  # there is no "images" collection segment.
  class FakePlayHttp
    attr_reader :calls, :store, :committed
    attr_accessor :upload_sha_override, :upload_omit_sha, :token_response, :remote_languages,
                  :post_commit_drift, :post_commit_reverse, :image_delete_error,
                  :edit_insert_error, :listings_error, :commit_error,
                  :edit_delete_error, :untitled_languages,
                  :hide_shas_until_list_no

    def initialize
      @calls = []
      @store = Hash.new { |h, key| h[key] = [] }
      @committed = []
      @remote_languages = %w[en-US ru-RU]
      @list_reads = Hash.new(0)
    end

    def request(method, url, headers: {}, body: nil, content_type: nil)
      @calls << [method, url]
      case
      when method == :Post && url.include?("oauth2.googleapis.com/token")
        @token_assertion = body
        @token_response || { status: 200, body: { access_token: "t0k3n" }.to_json }
      when method == :Post && url.end_with?("/edits")
        return @edit_insert_error if @edit_insert_error
        { status: 200, body: { id: "edit1" }.to_json }
      when method == :Get && url.end_with?("/listings")
        return @listings_error if @listings_error
        # gh-1402: Play answers edits.listings.list with language + title
        # (among others) — the store-side title surface the sync gates on.
        { status: 200, body: { listings: @remote_languages.map { |l|
          { language: l, title: @untitled_languages.to_a.include?(l) ? "" : "Fa — Personal AI Agent" }
        } }.to_json }
      when method == :Delete && (m = url.match(%r{/listings/([^/]+)/([^/]+)\z}))
        return @image_delete_error if @image_delete_error
        @store.delete([m[1], m[2]])
        { status: 204, body: "" }
      when method == :Post && (m = url.match(%r{/listings/([^/]+)/([^/]+)\?uploadType=media\z}))
        sha = @upload_sha_override || Digest::SHA256.hexdigest(body.to_s)
        @store[[m[1], m[2]]] << sha
        # gh-1328: Play sometimes 200s the upload WITHOUT a usable sha256
        # while the image is still processing.
        { status: 200, body: (@upload_omit_sha ? {} : { sha256: sha }).to_json }
      when method == :Get && (m = url.match(%r{/listings/([^/]+)/([^/]+)\z}))
        key = [m[1], m[2]]
        @list_reads[key] += 1
        images = @store[key].map { |s| { sha256: s } }
        # Post-commit drift injection: the committed listing keeps an image
        # the sync never uploaded (the stale-state failure mode #947 gates).
        if !@committed.empty? && @post_commit_drift == key
          images += [{ sha256: Digest::SHA256.hexdigest("drift-junk") }]
        end
        # Post-commit order injection: the committed listing serves the same
        # image set in a different order (the ordering failure mode).
        images.reverse! if !@committed.empty? && @post_commit_reverse == key
        # gh-1328: an entry (or its sha) may be unreadable until Play
        # finishes processing the just-uploaded bytes.
        images = images.map { |img| { sha256: nil } } if @hide_shas_until_list_no && @list_reads[key] <= @hide_shas_until_list_no
        { status: 200, body: { images: images }.to_json }
      when method == :Post && url.include?(":commit")
        return @commit_error if @commit_error
        @committed << url
        { status: 200, body: { id: "edit1" }.to_json }
      when method == :Delete && url.end_with?("/edits/edit1")
        return @edit_delete_error if @edit_delete_error
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
    # gh-1402: both locales carry the Play-mandatory listing texts (the
    # pre-flight completeness gate runs inside sync_and_verify!).
    base = File.join(root, "android")
    write_png(File.join(base, "en-US/images/icon.png"), "icon-en")
    write_png(File.join(base, "en-US/images/featureGraphic.png"), "fg-en")
    write_png(File.join(base, "en-US/images/phoneScreenshots/01_store_chat.png"), "phone-en-1")
    write_png(File.join(base, "en-US/images/phoneScreenshots/02_store_apps.png"), "phone-en-2")
    write_png(File.join(base, "en-US/images/tenInchScreenshots/01_store_chat.png"), "ten-en-1")
    write_png(File.join(base, "ru-RU/images/icon.png"), "icon-ru")
    write_png(File.join(base, "ru-RU/images/phoneScreenshots/01_store_chat.png"), "phone-ru-1")
    write_listing_texts(base, "en-US")
    write_listing_texts(base, "ru-RU")
    base
  end

  # gh-1402 fixture helper: Play-mandatory listing texts for a locale
  # (title + short description + full description — all non-empty).
  def write_listing_texts(metadata_dir, locale)
    FileUtils.mkdir_p(File.join(metadata_dir, locale))
    { "title.txt" => "Fa — Personal AI Agent",
      "short_description.txt" => "Chat with any AI, privately",
      "full_description.txt" => "Fa is a personal AI agent that lives on your phone." }.each do |name, content|
      File.write(File.join(metadata_dir, locale, name), content)
    end
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

    # The #947 regression pin: the clear plan (clear_sets — the production
    # plan is clear_sets(managed locales); the locale-union clear_plan
    # wrapper is gone, gh-1405 review) covers EVERY locale × EVERY
    # multi-slot type — including ru-RU tenInch (no longer generated) and
    # sevenInch (never generated).
    plan = PlayListingSync.clear_sets(%w[de-DE en-US ru-RU])
    expected = %w[de-DE en-US ru-RU].product(PlayListingSync::SCREENSHOT_TYPES).size
    raise "FAIL: clear plan size #{plan.size} != #{expected}" unless plan.size == expected
    raise "FAIL: ru-RU tenInch must be cleared" unless plan.any? { |e| e[:locale] == "ru-RU" && e[:type] == "tenInchScreenshots" }
    raise "FAIL: console-only locale must be cleared" unless plan.any? { |e| e[:locale] == "de-DE" }
    ok("clear plan = every locale × every multi-slot type (#{expected} sets)")

    # gh-1405 review: the managed/skipped partition — ONE union
    # computation, managed = titled listings, skipped = the untitled
    # remainder of the SAME union.
    managed, skipped = PlayListingSync.managed_and_skipped(
      metadata_dir,
      [{ "language" => "en-US", "title" => "Fa" },
       { "language" => "ru-RU", "title" => "Фа" },
       { "language" => "de-DE", "title" => "" }]
    )
    raise "FAIL: managed #{managed.inspect}" unless managed == %w[en-US ru-RU]
    raise "FAIL: skipped #{skipped.inspect}" unless skipped == %w[de-DE]
    managed, skipped = PlayListingSync.managed_and_skipped(
      metadata_dir,
      [{ "language" => "en-US", "title" => "Fa" },
       { "language" => "de-DE", "title" => "" }],
      skip_untitled: false
    )
    raise "FAIL: override must manage the whole union, got #{managed.inspect}" unless managed == %w[de-DE en-US ru-RU]
    raise "FAIL: override leaves nothing skipped, got #{skipped.inspect}" unless skipped == []
    ok("managed_and_skipped partitions the union once (managed_locales stays its first half)")

    state = PlayListingSync.expected_state(metadata_dir, %w[en-US ru-RU])
    raise "FAIL: en-US tenInch expected non-empty" unless state["en-US"]["tenInchScreenshots"].size == 1
    raise "FAIL: ru-RU tenInch expected EMPTY" unless state["ru-RU"]["tenInchScreenshots"] == []
    raise "FAIL: expected state must carry sha256 digests" unless state["en-US"]["icon"] == [Digest::SHA256.hexdigest("icon-en")]
    ok("expected state = repo goldens by sha256, empty where the repo ships none")
  end

  # ── gh-1402: pre-flight language-completeness gate (pure local) ─────────
  # The incident: Google rejected the listing edit AT COMMIT —
  # `edits.commit failed (HTTP 403): PERMISSION_DENIED: This app has no
  # title for language ru-RU.` (runs 37732646663 / 37732832488) — because
  # a language the edit touched had no title store-side. Title
  # completeness is checkable locally before ANY network call; the gate
  # must say it first, naming the language, the field, and the path.
  Dir.mktmpdir do |root|
    metadata_dir = metadata_dir_with_goldens(root)
    write_listing_texts(metadata_dir, "en-US")
    write_listing_texts(metadata_dir, "ru-RU")
    File.delete(File.join(metadata_dir, "ru-RU", "title.txt")) # MISSING, not empty

    begin
      PlayListingSync.validate_listing_completeness!(metadata_dir)
      raise "FAIL: a missing title.txt must fail the gate"
    rescue RuntimeError => e
      raise "FAIL: must name the language, got: #{e.message}" unless e.message.include?("ru-RU")
      raise "FAIL: must name the field, got: #{e.message}" unless e.message.include?("title")
      unless e.message.include?(File.join(metadata_dir, "ru-RU", "title.txt"))
        raise "FAIL: must name the path, got: #{e.message}"
      end
    end
    ok("gh-1402: a missing title.txt fails the gate naming language + field + path")

    # An EMPTY (whitespace) title is the same violation.
    File.write(File.join(metadata_dir, "ru-RU", "title.txt"), "  \n\t")
    begin
      PlayListingSync.validate_listing_completeness!(metadata_dir)
      raise "FAIL: an empty title.txt must fail the gate"
    rescue RuntimeError => e
      unless e.message.include?("ru-RU") && e.message.include?("title")
        raise "FAIL: empty title must name ru-RU + title, got: #{e.message}"
      end
    end
    ok("gh-1402: an empty (whitespace) title.txt fails the gate the same way")

    # full_description is Play-mandatory too ("title at minimum;
    # full-description per Play requirements").
    File.write(File.join(metadata_dir, "ru-RU", "title.txt"), "Fa — личный ИИ-агент")
    File.delete(File.join(metadata_dir, "ru-RU", "full_description.txt"))
    begin
      PlayListingSync.validate_listing_completeness!(metadata_dir)
      raise "FAIL: a missing full_description.txt must fail the gate"
    rescue RuntimeError => e
      unless e.message.include?("full_description") && e.message.include?("ru-RU")
        raise "FAIL: must name field full_description for ru-RU, got: #{e.message}"
      end
    end
    ok("gh-1402: a missing full_description.txt fails the gate per Play requirements")

    File.write(File.join(metadata_dir, "ru-RU", "full_description.txt"), "Fa — личный ИИ-агент на вашем телефоне.")
    unless PlayListingSync.validate_listing_completeness!(metadata_dir) == true
      raise "FAIL: a complete tree must pass the gate"
    end
    ok("gh-1402: a complete metadata tree passes the gate")
  end

  # gh-1402 AC2: the REAL fastlane/metadata/android tree must always pass
  # the gate (file-only check — runs in ci.yml's stock-ruby loop, no
  # network, no credentials).
  unless PlayListingSync.validate_listing_completeness!(
    File.expand_path("../metadata/android", __dir__)
  ) == true
    raise "FAIL: the real fastlane/metadata/android tree is incomplete"
  end
  ok("gh-1402: the real fastlane/metadata/android tree passes the gate")

  # ── gh-1405 review: the gate runs BEFORE any network call ───────────────
  # The headline gh-1402 guarantee was pinned only via the gate's own unit
  # coverage — the SEQUENCE (no HTTP request precedes it inside
  # sync_and_verify!) was not. An incomplete tree + a recording transport:
  # the gate must raise with the transport never touched.
  Dir.mktmpdir do |root|
    metadata_dir = metadata_dir_with_goldens(root)
    File.delete(File.join(metadata_dir, "ru-RU", "title.txt"))
    http = FakePlayHttp.new
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir,
                                       json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: the incomplete tree must abort the sync at the gate"
    rescue RuntimeError => e
      unless e.message.include?("INCOMPLETE") && e.message.include?("ru-RU")
        raise "FAIL: the gate must raise its own report, got: #{e.message}"
      end
    end
    unless http.calls.empty?
      raise "FAIL: the gate must precede EVERY network call, got: #{http.calls.inspect}"
    end
    ok("gh-1405: the completeness gate runs before any network call (zero requests)")
  end

  # ── gh-1402: store-side untitled languages are skipped, never touched ───
  # The sync discovers languages from repo dirs ∪ the Play listing. A
  # listing language with NO store-side title cannot be part of an image
  # edit — any clear/upload drafts it and Google rejects the whole edit at
  # commit (the 403 above). The sync must skip it (the listing-texts
  # deploy in the same lane creates/completes it; images land next run),
  # name the skip in the summary, and not fail the post-commit verify on
  # the untouched locale.
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.untitled_languages = %w[ru-RU] # the incident's store state
    metadata_dir = metadata_dir_with_goldens(root)
    # Stale ru-RU shots on the store: if the verify did NOT skip the
    # untitled locale it would demand the ru-RU goldens here — a false red.
    http.store[["ru-RU", "phoneScreenshots"]] << Digest::SHA256.hexdigest("stale-ru-untitled")

    summary = PlayListingSync.sync_and_verify!(
      metadata_dir: metadata_dir, json_key: service_account_json,
      package_name: "dev.fa1.app", http: http
    )

    ru_calls = http.calls.count { |_m, u| u.include?("/listings/ru-RU/") }
    raise "FAIL: untitled ru-RU must never be touched, got #{ru_calls} call(s)" unless ru_calls.zero?
    unless http.calls.any? { |m, u| m == :Post && u.include?("/listings/en-US/icon?uploadType=media") }
      raise "FAIL: the titled en-US listing must still sync"
    end
    raise "FAIL: the edit must still commit" unless http.committed.size == 1
    unless summary.include?("skipped") && summary.include?("ru-RU")
      raise "FAIL: the summary must name the skipped locale, got: #{summary}"
    end
    ok("gh-1402: untitled store language skipped cleanly (no clear/upload/verify), named in the summary")

    # "…unless explicitly adding one": the override restores full management.
    http2 = FakePlayHttp.new
    http2.untitled_languages = %w[ru-RU]
    PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                     package_name: "dev.fa1.app", http: http2, skip_untitled: false)
    unless http2.calls.any? { |m, u| m == :Post && u.include?("/listings/ru-RU/icon?uploadType=media") }
      raise "FAIL: skip_untitled: false must manage ru-RU again"
    end
    ok("gh-1402: skip_untitled: false explicitly manages untitled languages")
  end

  # ── gh-1402 AC3: a commit-time 403 discards the open edit, then raises ──
  # `commit_edit!` failing leaves the edit OPEN on Play — stuck-edit drift
  # the next run must not inherit. The sync discards it best-effort
  # (edits.delete) BEFORE re-raising the original error.
  commit_403 = { status: 403, body: { error: { status: "PERMISSION_DENIED",
                                               message: "This app has no title for language ru-RU." } }.to_json }
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.commit_error = commit_403
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http)
      raise "FAIL: a commit 403 must raise"
    rescue RuntimeError => e
      unless e.message.include?("edits.commit failed (HTTP 403)") &&
             e.message.include?("no title for language ru-RU")
        raise "FAIL: the 403 must re-raise readably, got: #{e.message}"
      end
    end
    commit_at = http.calls.index { |m, u| m == :Post && u.include?(":commit") }
    discard_at = http.calls.index { |m, u| m == :Delete && u.end_with?("/edits/edit1") }
    raise "FAIL: the failed edit must be discarded (edits.delete missing)" unless discard_at
    raise "FAIL: the discard must follow the failed commit" unless discard_at > commit_at
    ok("gh-1402: commit-time 403 discards the open edit (edits.delete) before re-raising")

    # The discard is BEST-EFFORT: a failing edits.delete must never mask
    # the original commit error.
    http2 = FakePlayHttp.new
    http2.commit_error = commit_403
    http2.edit_delete_error = { status: 500, body: "{}" }
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http2)
      raise "FAIL: a commit 403 must raise"
    rescue RuntimeError => e
      unless e.message.include?("edits.commit failed (HTTP 403)")
        raise "FAIL: the discard failure must not mask the commit error, got: #{e.message}"
      end
    end
    ok("gh-1402: a failing edits.delete stays best-effort (original error preserved)")
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
      raise "FAIL: #{locale}/#{type} not cleared" unless deletes.any? { |u| u.include?("/listings/#{locale}/#{type}") }
    end
    ok("stale sets cleared for every locale × multi-slot type (ru-RU tenInch, sevenInch, stale en shot)")

    uploads = http.calls.count { |m, u| m == :Post && u.include?("uploadType=media") }
    raise "FAIL: expected 7 uploads (en-US 5, ru-RU 2), got #{uploads}" unless uploads == 7
    ok("all committed goldens uploaded (en-US 5, ru-RU 2)")

    raise "FAIL: commit missing" unless http.committed.size == 1
    # Play began rejecting auto-review commits (HTTP 400 INVALID_ARGUMENT,
    # run 37576738205 job 112650057915): the commit URL must carry the opt-out.
    unless http.committed.first.end_with?(":commit?changesNotSentForReview=true")
      raise "FAIL: commit must set changesNotSentForReview=true, got: #{http.committed.first}"
    end
    commit_index = http.calls.index { |m, u| m == :Post && u.include?(":commit") }
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
      raise "FAIL: error must carry the gh-1328 mismatch class, got: #{e.message}" unless
        e.message.include?("remote sha mismatch") && e.message.include?("stored different bytes")
    end
    raise "FAIL: a failed upload must never commit" unless http.committed.empty?
    ok("stored-bytes mismatch aborts before commit (listing untouched)")
  end

  # ── gh-1328: a nil stored sha is UNREADABLE, not a byte mismatch ────────
  # edits.images.upload may answer 200 without a usable sha256 while Play
  # is still processing the upload (transcoding window). The sync retries
  # the read across that window and only then classifies: verified →
  # proceed, different bytes → abort, still unreadable → abort with an
  # error DISTINCT from the byte-mismatch one.
  class PollHttp
    def initialize(responses)
      @responses = responses
    end

    def request(_method, _url, headers: {}, body: nil, content_type: nil)
      images = @responses.shift
      raise "FAIL: scripted list responses exhausted" if images.nil?

      { status: 200, body: { images: images }.to_json }
    end
  end

  sha1 = Digest::SHA256.hexdigest("golden-01")
  sha2 = Digest::SHA256.hexdigest("golden-02")
  poll_auth = { "Authorization" => "Bearer t" }

  poll = PollHttp.new([[{ "sha256" => nil }, { "sha256" => nil }],
                       [{ "sha256" => sha1 }],
                       [{ "sha256" => sha1 }, { "sha256" => sha2 }]])
  verified = PlayListingSync.poll_stored_sha!(
    poll, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots",
    [sha1, sha2], poll_auth, attempts: 3, backoff: 0
  )
  raise "FAIL: the sha must verify once it materializes, got #{verified.inspect}" unless verified == sha2
  ok("gh-1328: nil stored sha is retried across the processing window, then verifies")

  [["foreign sha", [{ "sha256" => sha1 }, { "sha256" => "junk" }]],
   ["reordered goldens", [{ "sha256" => sha2 }, { "sha256" => sha1 }]]].each do |label, images|
    poll = PollHttp.new([images])
    begin
      PlayListingSync.poll_stored_sha!(poll, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots",
                                       [sha1, sha2], poll_auth, attempts: 3, backoff: 0)
      raise "FAIL: #{label} must classify as a mismatch"
    rescue RuntimeError => e
      raise "FAIL: #{label} must carry the mismatch class, got: #{e.message}" unless
        e.message.include?("remote sha mismatch")
    end
  end
  ok("gh-1328: readable-but-different bytes stay a hard mismatch (never retried away)")

  poll = PollHttp.new([[{ "sha256" => nil }], [{ "sha256" => nil }], [{ "sha256" => nil }]])
  verdict = PlayListingSync.poll_stored_sha!(poll, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots",
                                             [sha1, sha2], poll_auth, attempts: 3, backoff: 0)
  raise "FAIL: an unreadable-after-window poll must return nil, got #{verdict.inspect}" unless verdict.nil?
  ok("gh-1328: unreadable after the window yields the distinct unreadable verdict")

  # gh-1328 rework (review thread 1): an EMPTY-STRING sha256 is the same
  # unreadable payload shape as an omitted field — on the list side it must
  # count as unreadable (retry), never as a readable foreign sha.
  poll = PollHttp.new([[{ "sha256" => "" }], [{ "sha256" => "" }], [{ "sha256" => "" }]])
  verdict = PlayListingSync.poll_stored_sha!(poll, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots",
                                             [sha1, sha2], poll_auth, attempts: 3, backoff: 0)
  raise "FAIL: an empty-string list sha must stay in the retry window, got #{verdict.inspect}" unless verdict.nil?
  ok("gh-1328 rework: empty-string list sha is unreadable, never a foreign-sha mismatch")

  # gh-1328 rework (review thread 4): a PARTIAL readable set in the wrong
  # order (expected [sha1, sha2], readable [sha2]) is known-but-incomplete —
  # the conservative verdict is the retry window, and if it never resolves,
  # the DISTINCT unreadable class. Pinned so no refactor reclassifies it as
  # a mismatch (or a prefix-match) untested.
  poll = PollHttp.new([[{ "sha256" => sha2 }]] * 3)
  verdict = PlayListingSync.poll_stored_sha!(poll, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots",
                                             [sha1, sha2], poll_auth, attempts: 3, backoff: 0)
  raise "FAIL: partial out-of-order set must stay in the retry window, got #{verdict.inspect}" unless verdict.nil?
  ok("gh-1328 rework: partial out-of-order readable set stays a retry, lands on unreadable")

  # End-to-end (never-again #3): a fake Play returning a DELAYED listing
  # must produce a green verify after the delay, not an abort.
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.upload_omit_sha = true       # every upload answers without a sha256
    http.hide_shas_until_list_no = 2  # entries materialize on the 3rd read
    metadata_dir = metadata_dir_with_goldens(root)
    summary = PlayListingSync.sync_and_verify!(
      metadata_dir: metadata_dir, json_key: service_account_json,
      package_name: "dev.fa1.app", http: http, sha_backoff: 0
    )
    raise "FAIL: the delayed listing must go green, got: #{summary.inspect}" unless summary.include?("verified")
    raise "FAIL: the listing must commit once every sha materializes" unless http.committed.size == 1
    ok("gh-1328: delayed-materialization listing verifies and commits (no false abort)")
  end

  # End-to-end: never materializes → abort with the DISTINCT unreadable class.
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.upload_omit_sha = true
    http.hide_shas_until_list_no = 10_000 # still processing for the whole window
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http,
                                       sha_attempts: 2, sha_backoff: 0)
      raise "FAIL: a permanently unreadable remote must raise"
    rescue RuntimeError => e
      raise "FAIL: must name the unreadable class, got: #{e.message}" unless
        e.message.include?("remote unreadable after 2 attempts")
      raise "FAIL: must NOT claim a byte mismatch, got: #{e.message}" if e.message.include?("stored different bytes")
    end
    raise "FAIL: an unreadable remote must never commit" unless http.committed.empty?
    ok("gh-1328: still-unreadable aborts with 'remote unreadable', never a false mismatch")
  end

  # End-to-end (review thread 1): `{"sha256": ""}` on the upload response is
  # the same UNREADABLE payload shape as an omitted field — it must abort
  # with the DISTINCT unreadable class, never the byte-mismatch one.
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    http.upload_sha_override = ""         # {"sha256": ""} — present, unusable
    http.hide_shas_until_list_no = 10_000 # still processing for the whole window
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                       package_name: "dev.fa1.app", http: http,
                                       sha_attempts: 2, sha_backoff: 0)
      raise "FAIL: an empty-string upload sha must abort"
    rescue RuntimeError => e
      raise "FAIL: must name the unreadable class, got: #{e.message}" unless
        e.message.include?("remote unreadable after 2 attempts")
      raise "FAIL: must NOT claim a byte mismatch, got: #{e.message}" if e.message.include?("stored different bytes")
    end
    raise "FAIL: an unreadable remote must never commit" unless http.committed.empty?
    ok("gh-1328 rework: empty-string upload sha routes to the unreadable class, never a mismatch")
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
      http.calls.any? { |m, u| m == :Delete && u.include?("/listings/de-DE/phoneScreenshots") }
    raise "FAIL: de-DE icon must not be deleted or uploaded" unless
      http.calls.none? { |m, u| m != :Get && u.include?("/listings/de-DE/icon") }
    raise "FAIL: de-DE featureGraphic must not be deleted or uploaded" unless
      http.calls.none? { |m, u| m != :Get && u.include?("/listings/de-DE/featureGraphic") }
    raise "FAIL: verify must not read de-DE single-image slots" unless
      http.calls.none? { |m, u| m == :Get && u =~ %r{/listings/de-DE/(icon|featureGraphic)\z} }
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

  # ── gh-1261: REST path contract pins the AppImageType enum in the path ──
  # The Play API binds {imageType} directly (.../listings/<locale>/<type>).
  # The bug: the module sent .../images/<type>, so the literal "images" sat
  # in the enum slot → HTTP 400 INVALID_ARGUMENT (daily-publish Play leg).
  # Delete-all and list ride API_ROOT; upload rides the /upload/ media host.
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    PlayListingSync.sync_and_verify!(metadata_dir: metadata_dir, json_key: service_account_json,
                                     package_name: "dev.fa1.app", http: http)
    api = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/dev.fa1.app/edits/edit1"
    deletes = http.calls.select { |m, u| m == :Delete && u.include?("/listings/") }.map { |_m, u| u }
    raise "FAIL: expected screenshot deletes" if deletes.empty?
    deletes.each do |u|
      m = u.match(%r{\A#{Regexp.escape(api)}/listings/([^/]+)/([^/]+)\z})
      raise "FAIL: delete must be .../listings/<locale>/<imageType> (no 'images' segment): #{u}" unless m
      unless PlayListingSync::SCREENSHOT_TYPES.include?(m[2])
        raise "FAIL: delete imageType must be an AppImageType enum value, got #{m[2].inspect} in #{u}"
      end
    end
    uploads = http.calls.select { |m, u| m == :Post && u.include?("uploadType=media") }.map { |_m, u| u }
    raise "FAIL: expected image uploads" if uploads.empty?
    uploads.each do |u|
      m = u.match(%r{\Ahttps://androidpublisher\.googleapis\.com/upload/androidpublisher/v3/applications/dev\.fa1\.app/edits/edit1/listings/([^/]+)/([^/]+)\?uploadType=media\z})
      raise "FAIL: upload must be /upload/.../listings/<locale>/<imageType>?uploadType=media: #{u}" unless m
      unless PlayListingSync::MANAGED_TYPES.include?(m[2])
        raise "FAIL: upload imageType must be an AppImageType enum value, got #{m[2].inspect} in #{u}"
      end
    end
    lists = http.calls.select { |m, u| m == :Get && u =~ %r{/listings/[^/]+/[^/]+\z} }.map { |_m, u| u }
    raise "FAIL: expected edits.images.list calls" if lists.empty?
    lists.each do |u|
      unless u.match?(%r{\A#{Regexp.escape(api)}/listings/[^/]+/[^/]+\z})
        raise "FAIL: list must be .../listings/<locale>/<imageType> (no 'images' segment): #{u}"
      end
    end
    ok("gh-1261: delete/list = .../listings/<locale>/<imageType>, upload = /upload/ host")
  end

  # ── gh-1261 AC2: image_type pinned/validated BEFORE the API call ────────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    metadata_dir = metadata_dir_with_goldens(root)
    # The exact bad value from the incident: the collection name "images"
    # where the AppImageType enum is expected.
    begin
      PlayListingSync.clear_images!(http, "dev.fa1.app", "edit1", "en-US", "images", {})
      raise "FAIL: clear_images! must reject a non-enum image_type before the API call"
    rescue RuntimeError => e
      unless e.message.include?("image_type") && e.message.include?("\"images\"") &&
             e.message.include?("phoneScreenshots")
        raise "FAIL: rejection must name the bad value and the expected enum, got: #{e.message}"
      end
    end
    raise "FAIL: a rejected image_type must never reach the transport" unless http.calls.empty?
    ok("gh-1261: clear_images! pins image_type before any HTTP call")
  end

  # ── gh-1261 AC2: recorded 400 payload surfaces as a readable message ────
  Dir.mktmpdir do |root|
    http = FakePlayHttp.new
    # The verbatim error body the daily-publish run logged for
    # en-US/phoneScreenshots — kept as the contract fixture.
    http.image_delete_error = {
      status: 400,
      body: {
        error: {
          code: 400,
          message: "Invalid value at 'image_type' (type.googleapis.com/google.play.publishingapi.v3.AppImageType), \"images\"",
          status: "INVALID_ARGUMENT"
        }
      }.to_json
    }
    metadata_dir = metadata_dir_with_goldens(root)
    begin
      PlayListingSync.clear_images!(http, "dev.fa1.app", "edit1", "en-US", "phoneScreenshots", {})
      raise "FAIL: a 400 delete response must raise"
    rescue RuntimeError => e
      unless e.message.include?("edits.images.delete failed for en-US/phoneScreenshots (HTTP 400)") &&
             e.message.include?("INVALID_ARGUMENT") &&
             e.message.include?("Invalid value at 'image_type'")
        raise "FAIL: the API error must surface readably, got: #{e.message}"
      end
      if e.message.include?("\"error\":") || e.message.include?("{")
        raise "FAIL: the error must be a readable message, not a raw JSON dump: #{e.message}"
      end
    end
    ok("gh-1261: recorded 400 fixture fails with a readable INVALID_ARGUMENT message")
  end

  # ── gh-1261 rework: api_error_message never renders a bare ": msg" ──────
  # Several Google endpoints omit `status` (code + message only), and
  # OAuth-style errors shape the error field as a string — both must still
  # surface a readable `LABEL: message`, never a leading ": " or raw JSON.
  api_error_cases = [
    # code + message, no status → the numeric code is the label.
    ['{"error":{"code":400,"message":"Request contains an invalid argument."}}',
     "400: Request contains an invalid argument."],
    # message only → a stable ERROR label, not ": message".
    ['{"error":{"message":"backend exploded"}}', "ERROR: backend exploded"],
    # OAuth token errors: error is a string, details in error_description.
    ['{"error":"invalid_grant","error_description":"bad jwt"}',
     "invalid_grant: bad jwt"],
    # The recorded incident payload keeps rendering status-first.
    [{ error: { code: 400, message: "Invalid value at 'image_type'",
                status: "INVALID_ARGUMENT" } }.to_json,
     "INVALID_ARGUMENT: Invalid value at 'image_type'"],
    # Non-JSON bodies still fall back to the trimmed raw body.
    ["<html>proxy error</html>", "<html>proxy error</html>"]
  ]
  api_error_cases.each do |body, want|
    got = PlayListingSync.api_error_message(body)
    raise "FAIL: api_error_message(#{body[0, 60]}...) must render #{want.inspect}, got #{got.inspect}" unless got == want
  end
  ok("gh-1261 rework: api_error_message falls back to code/ERROR/OAuth labels")

  # ── gh-1261 rework: sibling REST wrappers render readable failures ──────
  # bearer!/begin_edit!/list_listings!/commit_edit! used to truncate-dump
  # raw JSON bodies — the same readability problem the image calls fixed.
  Dir.mktmpdir do |_root|
    http = FakePlayHttp.new
    http.token_response = { status: 401,
                            body: { error: "invalid_grant", error_description: "bad jwt" }.to_json }
    begin
      PlayListingSync.bearer!(service_account_json, http: http)
      raise "FAIL: a 401 token response must raise"
    rescue RuntimeError => e
      raise "FAIL: bearer! must render the OAuth error readably, got: #{e.message}" unless
        e.message.include?("Play API auth failed (HTTP 401): invalid_grant: bad jwt")
    end

    http = FakePlayHttp.new
    http.edit_insert_error = { status: 400,
                               body: { error: { code: 400, message: "Package not found" } }.to_json }
    begin
      PlayListingSync.begin_edit!(http, "dev.fa1.app", {})
      raise "FAIL: a 400 edits.insert must raise"
    rescue RuntimeError => e
      raise "FAIL: begin_edit! must render the code-labelled error, got: #{e.message}" unless
        e.message.include?("edits.insert failed (HTTP 400): 400: Package not found")
      raise "FAIL: begin_edit! must not dump raw JSON: #{e.message}" if e.message.include?("{")
    end

    http = FakePlayHttp.new
    http.listings_error = { status: 403,
                            body: { error: { status: "PERMISSION_DENIED", message: "no access" } }.to_json }
    begin
      PlayListingSync.list_listings!(http, "dev.fa1.app", "edit1", {})
      raise "FAIL: a 403 edits.listings.list must raise"
    rescue RuntimeError => e
      raise "FAIL: list_listings! must render the status-labelled error, got: #{e.message}" unless
        e.message.include?("edits.listings.list failed (HTTP 403): PERMISSION_DENIED: no access")
    end

    http = FakePlayHttp.new
    http.commit_error = { status: 400,
                          body: { error: { status: "FAILED_PRECONDITION", message: "edit expired" } }.to_json }
    begin
      PlayListingSync.commit_edit!(http, "dev.fa1.app", "edit1", {})
      raise "FAIL: a 400 edits.commit must raise"
    rescue RuntimeError => e
      raise "FAIL: commit_edit! must render the status-labelled error, got: #{e.message}" unless
        e.message.include?("edits.commit failed (HTTP 400): FAILED_PRECONDITION: edit expired")
    end
    ok("gh-1261 rework: bearer!/begin_edit!/list_listings!/commit_edit! fail readably")
  end

  # ── gh-1261 rework: MANAGED_TYPES is the module-local enum guard ────────
  # Every managed type passes; a real-but-unmanaged AppImageType enum value
  # (tvScreenshots) is still rejected pre-flight — the guard pins against
  # MANAGED_TYPES, which must grow in lock-step with new managed types.
  PlayListingSync::MANAGED_TYPES.each { |type| PlayListingSync.validate_image_type!(type) }
  begin
    PlayListingSync.validate_image_type!("tvScreenshots")
    raise "FAIL: an unmanaged AppImageType enum value must be rejected pre-flight"
  rescue RuntimeError => e
    raise "FAIL: the rejection must name the value and MANAGED_TYPES, got: #{e.message}" unless
      e.message.include?("\"tvScreenshots\"") && e.message.include?("MANAGED_TYPES")
  end
  ok("gh-1261 rework: validate_image_type! pins MANAGED_TYPES (extend-on-add)")

  # ── gh-1261 AC3: 4xx is never retried; only 5xx/transport errors are ────
  StubResp = Struct.new(:code, :body)
  # Scripted transport: `perform` is replaced (no network), the real retry
  # loop in Http#request runs against it. Backoff sleeps are stubbed out.
  class ScriptedHttp < PlayListingSync::Http
    attr_reader :perform_calls
    def initialize(*script)
      @script = script
      @perform_calls = 0
    end
    def sleep(*); end
    private
    def perform(*_args)
      @perform_calls += 1
      step = @script.shift || @last
      @last = step
      raise step if step.is_a?(StandardError)
      step
    end
  end

  http400 = ScriptedHttp.new(StubResp.new("400", '{"error":{"status":"INVALID_ARGUMENT"}}'))
  res = http400.request(:Delete, "https://example.test/x")
  raise "FAIL: a 400 must be returned to the caller" unless res[:status] == 400
  raise "FAIL: a 400 must never be retried, got #{http400.perform_calls} attempt(s)" unless http400.perform_calls == 1

  http500 = ScriptedHttp.new(StubResp.new("500", "{}"))
  res = http500.request(:Get, "https://example.test/x")
  raise "FAIL: a persistent 5xx must surface to the caller (which raises readably)" unless res[:status] == 500
  raise "FAIL: a 5xx must be retried up to 3 attempts, got #{http500.perform_calls}" unless http500.perform_calls == 3

  flaky = ScriptedHttp.new(Net::ReadTimeout.new("boom"), StubResp.new("200", "{}"))
  res = flaky.request(:Get, "https://example.test/x")
  raise "FAIL: a transport timeout followed by a 200 must succeed" unless res[:status] == 200
  raise "FAIL: transport errors must be retried, got #{flaky.perform_calls} attempt(s)" unless flaky.perform_calls == 2
  ok("gh-1261: 4xx never retried; 5xx/time-out retried with bounded backoff")

  puts "play_listing_sync: #{$checks} checks passed"
end
