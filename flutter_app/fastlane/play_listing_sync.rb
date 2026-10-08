# frozen_string_literal: true

# Play listing-image sync (issue #947). Plain ruby, no gems — the same
# contract as play_upload_preflight.rb so the CI fastlane suites run it on
# the runner's stock ruby.
#
# Why this exists: the supply `play_store` lane only UPLOADS images. Play
# appends screenshot uploads to the existing set, so whatever is stale on
# the listing (an old-copy screenshot, a device type or locale the repo no
# longer generates — ru-RU tenInch, for instance) survives the upload
# forever. Google reviewed that stale image and rejected the dev.fa1.app
# update on Sep 24 while the repo goldens were already fixed.
#
# This module replaces the WHOLE listing-image state per locale and device
# type, then proves the committed state matches the repo goldens:
#
#   1. one edit: clear every managed screenshot set for EVERY listing
#      locale (repo locales ∪ locales live on the Play listing), then
#      upload the committed goldens (sorted — file name order is the
#      listing order), checking each stored sha256 against the local file
#      (gh-1328: a nil/blank stored sha means Play is still processing —
#      the read is retried with backoff, and an unreadable remote aborts
#      with its own "remote unreadable" class, never as a byte mismatch);
#   2. commit — a failed upload aborts BEFORE the commit, so the live
#      listing keeps its previous state;
#   3. a fresh read-only edit re-reads edits.images.list and fails the job
#      unless every managed locale/type matches the goldens exactly
#      (icon + featureGraphic + all screenshot types, empty where the repo
#      ships nothing).
#
# supply keeps handling the metadata TEXTS (the lane passes
# skip_upload_images/skip_upload_screenshots); images ride this module only.
require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

module PlayListingSync
  API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
  # Media-upload host prefix: edits.images.upload POSTs the SAME path under
  # the /upload/ prefix with ?uploadType=media (gh-1261).
  UPLOAD_ROOT = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  SCOPE = "https://www.googleapis.com/auth/androidpublisher"

  # Multi-slot types: Play APPENDS uploads, so every listing locale gets its
  # remote set cleared first — including types the repo no longer generates
  # (ru-RU tenInchScreenshots) and never generated (sevenInchScreenshots).
  SCREENSHOT_TYPES = %w[phoneScreenshots sevenInchScreenshots tenInchScreenshots].freeze
  # Single-slot types: an upload replaces the stored image by itself.
  SINGLE_IMAGE_TYPES = %w[icon featureGraphic].freeze
  # The image types this sync manages. validate_image_type! pins every
  # image call against this list BEFORE any HTTP request — it is a
  # module-local guard, NOT the full AppImageType enum (tvScreenshots,
  # wearScreenshots, promo graphics, …). EXTEND THIS LIST (in lock-step
  # with expected_state/sync_and_verify!) when adding managed types, or
  # the new types will be rejected pre-flight.
  MANAGED_TYPES = (SCREENSHOT_TYPES + SINGLE_IMAGE_TYPES).freeze

  # Play-mandatory listing TEXT fields per language (gh-1402). Google
  # rejects the WHOLE listing edit at commit time — HTTP 403
  # PERMISSION_DENIED "This app has no title for language <lang>" (runs
  # 37732646663 / 37732832488) — when a language the edit touches has no
  # title; a listing is only complete with short + full descriptions too.
  # All three are checkable locally, before any network call.
  MANDATORY_LISTING_FIELDS = {
    "title" => "title.txt",
    "short_description" => "short_description.txt",
    "full_description" => "full_description.txt"
  }.freeze

  module_function

  # ── pure helpers (unit-tested, no I/O beyond the metadata dir) ──────────

  # The locale dirs the repo ships (fastlane/metadata/android/<locale>/).
  def repo_locales(metadata_dir)
    Dir.children(metadata_dir)
       .select { |entry| File.directory?(File.join(metadata_dir, entry)) }
       .sort
  end

  # Committed golden paths for a locale/type, sorted (file name order IS
  # the Play listing order). Screenshot types live in an images/<type>/
  # dir; the single-slot types are flat files (images/icon.png,
  # images/featureGraphic.png). Missing everything = the repo ships none.
  def local_images(metadata_dir, locale, type)
    dir = File.join(metadata_dir, locale, "images", type)
    file = "#{dir}.png"
    paths =
      if Dir.exist?(dir)
        Dir.children(dir).grep(/\.png\z/i).sort.map { |name| File.join(dir, name) }
      elsif File.exist?(file)
        [file]
      else
        []
      end
    paths.sort
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  # The screenshot sets to clear for an EXPLICIT locale list (gh-1402:
  # callers pass only the locales the sync may manage — titled ones).
  # The production plan (sync_and_verify!) is clear_sets(managed locales).
  def clear_sets(locales)
    locales.sort.flat_map do |locale|
      SCREENSHOT_TYPES.map { |type| { locale: locale, type: type } }
    end
  end

  # The post-sync state the listing must have: sha256 SEQUENCES per
  # [locale, type] in listing order (local_images sorts — file name order
  # IS the Play listing order) — the repo goldens where they exist, empty
  # where they do not (ru-RU tenInch, dropped locales).
  #
  # icon/featureGraphic are single-slot brand assets and Play Console does
  # not allow an empty icon on a listing locale, so for locales the repo
  # does NOT ship they are "don't care": a console-created locale keeps
  # its icon/feature graphic (the sync only clears + enforces the
  # screenshot sets there — issue #947 review).
  def expected_state(metadata_dir, locales)
    repo = repo_locales(metadata_dir)
    locales.sort.to_h do |locale|
      types = repo.include?(locale) ? MANAGED_TYPES : SCREENSHOT_TYPES
      [locale, types.to_h { |type|
        [type, local_images(metadata_dir, locale, type).map { |path| sha256(path) }]
      }]
    end
  end

  def all_locales(metadata_dir, remote_locales)
    (repo_locales(metadata_dir) + remote_locales.to_a).uniq.sort
  end

  # gh-1402 pre-flight language gate: every repo listing locale must carry
  # ALL Play-mandatory text fields, present and non-empty. Violations name
  # language + field + path and fail BEFORE any network call — Google
  # never gets to say it first at commit time (the 05:46Z incident: the
  # whole edit died on 403 "This app has no title for language ru-RU").
  # Returns true; raises one report listing every violation.
  def validate_listing_completeness!(metadata_dir)
    problems = []
    repo_locales(metadata_dir).each do |locale|
      MANDATORY_LISTING_FIELDS.each do |field, filename|
        path = File.join(metadata_dir, locale, filename)
        next if File.exist?(path) && !File.read(path).to_s.strip.empty?

        problems << "  #{locale}: mandatory Play listing field '#{field}' is missing or empty (#{path})"
      end
    end
    return true if problems.empty?

    raise "Play listing metadata is INCOMPLETE — a listing edit touching these " \
          "languages would be rejected at commit (HTTP 403 'This app has no " \
          "title for language <lang>'):\n#{problems.join("\n")}"
  end

  # gh-1402: the languages this sync may manage — store-side listings with
  # a NON-EMPTY title (repo-backed or console-created alike; a repo locale
  # with no store listing yet is also untouchable, the upload would draft
  # it title-less). A language outside this set must not be part of an
  # image edit: any clear/upload drafts it and Google rejects the WHOLE
  # edit at commit (HTTP 403 "This app has no title for language <lang>").
  # The listing-texts deploy in the same lane (supply) creates/completes
  # those listings; their images sync on a later run. skip_untitled: false
  # restores full management ("unless explicitly adding one").
  def managed_locales(metadata_dir, listings, skip_untitled: true)
    all = all_locales(metadata_dir, listings.map { |listing| listing.fetch("language") })
    return all unless skip_untitled

    titled = listings.reject { |listing| listing["title"].to_s.strip.empty? }
                     .map { |listing| listing.fetch("language") }
    all & titled
  end

  def untitled_locales(listings)
    listings.select { |listing| listing["title"].to_s.strip.empty? }
            .map { |listing| listing.fetch("language") }
  end

  # ── orchestration ───────────────────────────────────────────────────────

  # Replace the listing images with the committed goldens and verify the
  # committed state (edits.images.list). Raises on any mismatch — the
  # fastlane lane turns that into a red job. Returns a summary line.
  #
  # gh-1402: runs the LOCAL language-completeness gate before any network
  # call, manages only TITLED Play listings (untitled ones are skipped,
  # never touched — a touch would 403 the whole edit at commit), and
  # discards the open edit (best-effort edits.delete) on ANY failure so a
  # failed commit never leaves stuck-edit drift behind.
  def sync_and_verify!(metadata_dir:, json_key:, package_name:, http: Http.new, now: Time.now,
                       sha_attempts: 5, sha_backoff: 30, skip_untitled: true)
    validate_listing_completeness!(metadata_dir)

    auth = bearer!(json_key, http: http, now: now)
    edit_id = begin_edit!(http, package_name, auth)
    begin
      listings = list_listings!(http, package_name, edit_id, auth)
      managed = managed_locales(metadata_dir, listings, skip_untitled: skip_untitled)
      skipped = all_locales(metadata_dir, listings.map { |l| l.fetch("language") }) - managed
      skipped.each do |locale|
        warn "play_listing_sync: skipping #{locale} — no title on the Play listing " \
             "(gh-1402: an image edit would be rejected at commit, HTTP 403 'This " \
             "app has no title for language #{locale}'). The listing-texts deploy " \
             "creates or completes it; its images sync on a later run."
      end

      uploaded = 0
      clear_sets(managed).each do |entry|
        clear_images!(http, package_name, edit_id, entry[:locale], entry[:type], auth)
      end
      (repo_locales(metadata_dir) & managed).each do |locale|
        MANAGED_TYPES.each do |type|
          verified_prefix = [] # golden shas already confirmed for this set
          local_images(metadata_dir, locale, type).each do |path|
            local = sha256(path)
            stored = upload_image!(http, package_name, edit_id, locale, type, path, auth)
            if stored.to_s.strip.empty?
              # gh-1328: Play answered the upload without a usable sha256
              # (nil, or a blank string — same unreadable payload shape) —
              # the remote is UNREADABLE (usually still processing), never a
              # byte mismatch. Poll edits.images.list across the processing
              # window before classifying.
              stored = poll_stored_sha!(http, package_name, edit_id, locale, type,
                                        verified_prefix + [local], auth,
                                        attempts: sha_attempts, backoff: sha_backoff)
              if stored.nil?
                raise "remote unreadable after #{sha_attempts} attempts for " \
                      "#{locale}/#{type}/#{File.basename(path)} — Play never " \
                      "returned a usable sha256 for the just-uploaded image — " \
                      "aborting before commit, listing untouched"
              end
            end
            unless stored == local
              raise "remote sha mismatch: Play stored different bytes for " \
                    "#{locale}/#{type}/#{File.basename(path)} (sha256 " \
                    "#{stored.inspect} != local #{local}) — aborting before " \
                    "commit, listing untouched"
            end
            verified_prefix << local
            uploaded += 1
          end
        end
      end
      commit_edit!(http, package_name, edit_id, auth)
    rescue StandardError
      # gh-1402 edit hygiene: a failed commit (e.g. HTTP 403 "This app has
      # no title for language <lang>") leaves the edit OPEN on Play —
      # discard it best-effort so the next run starts clean, then re-raise
      # the original error.
      begin
        delete_edit!(http, package_name, edit_id, auth)
      rescue StandardError
        nil
      end
      raise
    end

    verify_committed!(metadata_dir: metadata_dir, json_key: json_key,
                      package_name: package_name, http: http, now: now,
                      skip_untitled: skip_untitled)
    summary = "Play listing images replaced per locale + device type and verified " \
              "(#{uploaded} image(s), locales: #{managed.join(', ')})"
    unless skipped.empty?
      summary += "; skipped untitled Play listing(s) (images sync after the texts " \
                 "deploy creates them): #{skipped.join(', ')}"
    end
    summary
  end

  # Post-commit gate: edits.images.list must equal the repo goldens for
  # every managed locale/type — including the empty sets (a stale shot on
  # a device type or locale the repo no longer ships fails the job).
  # gh-1402: untitled Play listings are NOT managed (never touched by the
  # sync edit) and are skipped here too — and the read-only edit is
  # discarded even when the gate fails, so no stuck-edit drift.
  def verify_committed!(metadata_dir:, json_key:, package_name:, http: Http.new, now: Time.now,
                        skip_untitled: true)
    auth = bearer!(json_key, http: http, now: now)
    edit_id = begin_edit!(http, package_name, auth)
    problems = []
    begin
      listings = list_listings!(http, package_name, edit_id, auth)
      managed = managed_locales(metadata_dir, listings, skip_untitled: skip_untitled)

      expected_state(metadata_dir, managed).each do |locale, by_type|
        by_type.each do |type, want|
          # Sequence compare (no sort): uploads go out in listing order, so
          # a Play-side reordering (02_… shown before 01_…) must fail too.
          got = list_images!(http, package_name, edit_id, locale, type, auth)
                .map { |image| image["sha256"] }.compact
          next if got == want

          problems << "  #{locale}/#{type}: remote has #{got.size} image(s), " \
                      "expected #{want.size} (sha256 or listing-order mismatch)"
        end
      end
    ensure
      begin
        delete_edit!(http, package_name, edit_id, auth) # read-only edit — discard
      rescue StandardError
        nil
      end
    end

    return true if problems.empty?

    raise "Play listing does NOT match the committed goldens " \
          "(edits.images.list after upload):\n#{problems.join("\n")}"
  end

  # ── androidpublisher REST calls (all thin + injectable via http) ────────

  # gh-1261 AC2: the {imageType} path slot takes an AppImageType ENUM value
  # (phoneScreenshots, …) — never the collection name "images". Pin the
  # value BEFORE the API call so a bad type fails here with a readable
  # message instead of a raw HTTP 400 INVALID_ARGUMENT from Play.
  def validate_image_type!(type)
    return if MANAGED_TYPES.include?(type)

    raise "invalid Play image_type #{type.inspect} — the edits.images path " \
          "takes an AppImageType enum value managed here (MANAGED_TYPES), " \
          "one of: #{MANAGED_TYPES.join(', ')}"
  end

  # One-line readable rendering of a Google API error body. The `error`
  # field is usually a Hash ({"status": …, "message": …} — but several
  # endpoints omit `status` and carry only `code` + `message`) and, for
  # OAuth token endpoints, a plain string with `error_description`. Any
  # other shape falls back to a trimmed raw body.
  def api_error_message(body)
    parsed = JSON.parse(body.to_s)
    err = parsed["error"]
    case err
    when Hash
      return body.to_s[0, 300] unless err["message"]

      label = err["status"] || err["code"] || "ERROR"
      "#{label}: #{err['message']}"[0, 300]
    when String
      err.empty? ? body.to_s[0, 300] : "#{err}: #{parsed['error_description']}"[0, 300].sub(/: \z/, "")
    else
      body.to_s[0, 300]
    end
  rescue JSON::ParserError
    body.to_s[0, 300]
  end

  def bearer!(json_key, http:, now: Time.now)
    account = JSON.parse(json_key)
    %w[client_email private_key].each do |field|
      raise "service-account JSON is missing '#{field}'" if account[field].to_s.strip.empty?
    end
    assertion = jwt_assertion!(account, now: now)
    res = http.request(:Post, TOKEN_URL, body: URI.encode_www_form(
      "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion" => assertion
    ), content_type: "application/x-www-form-urlencoded")
    unless res[:status] == 200
      raise "Play API auth failed (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    { "Authorization" => "Bearer #{JSON.parse(res[:body]).fetch("access_token")}" }
  end

  # RS256 JWT (stdlib OpenSSL) for the service-account bearer grant.
  def jwt_assertion!(account, now: Time.now)
    header = encode64('{"alg":"RS256","typ":"JWT"}')
    claims = encode64(JSON.generate(
      "iss" => account["client_email"],
      "scope" => SCOPE,
      "aud" => TOKEN_URL,
      "iat" => now.to_i,
      "exp" => now.to_i + 3600
    ))
    signing_input = "#{header}.#{claims}"
    key = OpenSSL::PKey::RSA.new(account["private_key"])
    signature = encode64(key.sign("SHA256", signing_input))
    "#{signing_input}.#{signature}"
  end

  def encode64(text)
    Base64.urlsafe_encode64(text, padding: false)
  end

  def begin_edit!(http, package_name, auth)
    res = http.request(:Post, "#{API_ROOT}/#{package_name}/edits", headers: auth)
    unless res[:status] == 200
      raise "edits.insert failed (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    JSON.parse(res[:body]).fetch("id")
  end

  # gh-1402: the FULL listings payload (language + title + descriptions) —
  # the store-side surface the untitled-language gate reads. list_locales!
  # stays for locale-only callers.
  def list_listings!(http, package_name, edit_id, auth)
    res = http.request(:Get, "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings",
                       headers: auth)
    unless res[:status] == 200
      raise "edits.listings.list failed (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    JSON.parse(res[:body]).fetch("listings", [])
  end

  def list_locales!(http, package_name, edit_id, auth)
    list_listings!(http, package_name, edit_id, auth).map { |l| l.fetch("language") }
  end

  # Deletes the WHOLE image set of a locale/type. 404 = nothing to clear.
  # Contract (gh-1261): DELETE …/listings/<locale>/<imageType> — the enum
  # value sits DIRECTLY in the path; there is no "images" collection
  # segment (the old …/images/<type> path put the literal "images" into the
  # {imageType} slot → HTTP 400 INVALID_ARGUMENT from Play).
  def clear_images!(http, package_name, edit_id, locale, type, auth)
    validate_image_type!(type)
    res = http.request(:Delete,
                       "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings/" \
                       "#{locale}/#{type}", headers: auth)
    return if [200, 204, 404].include?(res[:status])

    raise "edits.images.delete failed for #{locale}/#{type} " \
          "(HTTP #{res[:status]}): #{api_error_message(res[:body])}"
  end

  # Contract (gh-1261): POST {UPLOAD_ROOT}/…/listings/<locale>/<imageType>?uploadType=media.
  def upload_image!(http, package_name, edit_id, locale, type, path, auth)
    validate_image_type!(type)
    res = http.request(
      :Post,
      "#{UPLOAD_ROOT}/#{package_name}/edits/#{edit_id}/listings/#{locale}/" \
      "#{type}?uploadType=media",
      headers: auth, body: File.binread(path), content_type: "image/png"
    )
    unless res[:status] == 200
      raise "edits.images.upload failed for #{locale}/#{type}/" \
            "#{File.basename(path)} (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    JSON.parse(res[:body])["sha256"]
  end

  # gh-1328: edits.images.upload may answer 200 WITHOUT a usable sha256
  # (an omitted field → nil, or a blank string) while Play is still
  # processing the image. An unreadable sha is UNREADABLE, never a byte
  # mismatch — poll edits.images.list across the processing window
  # ((attempts - 1) sleeps of `backoff` between `attempts` reads) and only
  # then classify:
  #   returns the verified sha of the just-uploaded image once the readable
  #   set equals the goldens uploaded so far;
  #   raises "remote sha mismatch" on readable bytes contradicting the
  #   goldens (a real byte/ordering mismatch);
  #   returns nil when still unreadable after `attempts` — the caller
  #   aborts with the distinct "remote unreadable" class.
  #
  # Assumption (gh-1328 review): multi-slot sets are cleared first, so
  # during the processing window their list can only hold missing entries
  # or nil/blank shas — both retry. Single-slot types (icon/featureGraphic)
  # are NOT cleared (console-only locales keep theirs), so the poll relies
  # on Play serving a nil/blank entry — not the PREVIOUS image's sha —
  # while a replacement processes. A readable set contradicting the goldens
  # still classifies "remote sha mismatch" by design (the issue's
  # foreign-sha → mismatch table); if a daily leg ever reds on a single-slot
  # replace serving the old sha, treat that as unreadable here.
  def poll_stored_sha!(http, package_name, edit_id, locale, type, expected_prefix, auth,
                       attempts: 5, backoff: 30)
    attempts.times do |attempt|
      readable = list_images!(http, package_name, edit_id, locale, type, auth)
                 .map { |image| image["sha256"] }.reject { |sha| sha.to_s.strip.empty? }
      return expected_prefix.last if readable == expected_prefix

      if readable.any? { |sha| !expected_prefix.include?(sha) } ||
         readable.size == expected_prefix.size
        raise "remote sha mismatch: edits.images.list for #{locale}/#{type} " \
              "shows #{readable.size} readable sha256(s) contradicting the " \
              "#{expected_prefix.size} golden(s) uploaded so far — Play " \
              "stored different bytes — aborting before commit, listing untouched"
      end
      warn "play_listing_sync: remote unreadable for #{locale}/#{type} " \
           "(attempt #{attempt + 1}/#{attempts}, Play still processing?) — " \
           "retrying in #{backoff}s"
      sleep(backoff) if attempt < attempts - 1
    end
    nil
  end

  # Contract (gh-1261): GET …/listings/<locale>/<imageType>.
  def list_images!(http, package_name, edit_id, locale, type, auth)
    validate_image_type!(type)
    res = http.request(:Get,
                       "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings/" \
                       "#{locale}/#{type}", headers: auth)
    unless res[:status] == 200
      raise "edits.images.list failed for #{locale}/#{type} " \
            "(HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    JSON.parse(res[:body]).fetch("images", [])
  end

  # Google no longer auto-sends edits for review: the commit must opt out via
  # the changesNotSentForReview query param, else the API rejects with 400
  # INVALID_ARGUMENT. Review is triggered from the Play Console UI instead.
  def commit_edit!(http, package_name, edit_id, auth)
    res = http.request(:Post,
                       "#{API_ROOT}/#{package_name}/edits/#{edit_id}:commit" \
                       "?changesNotSentForReview=true", headers: auth)
    return if res[:status] == 200

    raise "edits.commit failed (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
  end

  def delete_edit!(http, package_name, edit_id, auth)
    http.request(:Delete, "#{API_ROOT}/#{package_name}/edits/#{edit_id}", headers: auth)
  end

  # ── transport ───────────────────────────────────────────────────────────

  # Minimal HTTPS JSON/binary transport with bounded 5xx/time-out retries.
  # The unit tests substitute a fake with the same `request` signature.
  class Http
    # A received 5xx response — retriable exactly like a transport
    # timeout, but named so nobody mistakes it for one.
    class HttpServerError < StandardError; end

    RETRIABLE = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError,
      HttpServerError
    ].freeze

    def request(method, url, headers: {}, body: nil, content_type: nil)
      tries = 0
      begin
        tries += 1
        res = perform(method, url, headers, body, content_type)
        status = res.code.to_i
        return { status: status, body: res.body.to_s } if status < 500 || tries >= 3

        raise HttpServerError, "HTTP #{status}"
      rescue *RETRIABLE
        raise if tries >= 3

        sleep(5 * tries)
        retry
      end
    end

    private

    def perform(method, url, headers, body, content_type)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 30
      http.read_timeout = 300
      req = Net::HTTP.const_get(method).new(uri)
      headers.each { |name, value| req[name] = value }
      req["Content-Type"] = content_type if content_type
      req.body = body if body
      http.request(req)
    end
  end
end
