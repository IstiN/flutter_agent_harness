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
#      (gh-1328: a nil stored sha means Play is still processing — the
#      read is retried with backoff, and an unreadable remote aborts with
#      its own "remote unreadable" class, never as a byte mismatch);
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
  # with clear_plan/expected_state/sync_and_verify!) when adding managed
  # types, or the new types will be rejected pre-flight.
  MANAGED_TYPES = (SCREENSHOT_TYPES + SINGLE_IMAGE_TYPES).freeze

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

  # The screenshot sets to clear: every listing locale (repo ∪ live on the
  # console) × every multi-slot type.
  def clear_plan(metadata_dir, remote_locales)
    all_locales(metadata_dir, remote_locales).flat_map do |locale|
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
  def expected_state(metadata_dir, remote_locales)
    repo = repo_locales(metadata_dir)
    all_locales(metadata_dir, remote_locales).to_h do |locale|
      types = repo.include?(locale) ? MANAGED_TYPES : SCREENSHOT_TYPES
      [locale, types.to_h { |type|
        [type, local_images(metadata_dir, locale, type).map { |path| sha256(path) }]
      }]
    end
  end

  def all_locales(metadata_dir, remote_locales)
    (repo_locales(metadata_dir) + remote_locales.to_a).uniq.sort
  end

  # ── orchestration ───────────────────────────────────────────────────────

  # Replace the listing images with the committed goldens and verify the
  # committed state (edits.images.list). Raises on any mismatch — the
  # fastlane lane turns that into a red job. Returns a summary line.
  def sync_and_verify!(metadata_dir:, json_key:, package_name:, http: Http.new, now: Time.now,
                       sha_attempts: 5, sha_backoff: 30)
    auth = bearer!(json_key, http: http, now: now)

    edit_id = begin_edit!(http, package_name, auth)
    remote_locales = list_locales!(http, package_name, edit_id, auth)

    uploaded = 0
    clear_plan(metadata_dir, remote_locales).each do |entry|
      clear_images!(http, package_name, edit_id, entry[:locale], entry[:type], auth)
    end
    repo_locales(metadata_dir).each do |locale|
      MANAGED_TYPES.each do |type|
        verified_prefix = [] # golden shas already confirmed for this set
        local_images(metadata_dir, locale, type).each do |path|
          local = sha256(path)
          stored = upload_image!(http, package_name, edit_id, locale, type, path, auth)
          if stored.nil?
            # gh-1328: Play answered the upload without a usable sha256 —
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

    verify_committed!(metadata_dir: metadata_dir, json_key: json_key,
                      package_name: package_name, http: http, now: now)
    "Play listing images replaced per locale + device type and verified " \
    "(#{uploaded} image(s), locales: #{all_locales(metadata_dir, remote_locales).join(', ')})"
  end

  # Post-commit gate: edits.images.list must equal the repo goldens for
  # every managed locale/type — including the empty sets (a stale shot on
  # a device type or locale the repo no longer ships fails the job).
  def verify_committed!(metadata_dir:, json_key:, package_name:, http: Http.new, now: Time.now)
    auth = bearer!(json_key, http: http, now: now)
    edit_id = begin_edit!(http, package_name, auth)
    remote_locales = list_locales!(http, package_name, edit_id, auth)

    problems = []
    expected_state(metadata_dir, remote_locales).each do |locale, by_type|
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
    delete_edit!(http, package_name, edit_id, auth) # read-only edit — discard

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

  def list_locales!(http, package_name, edit_id, auth)
    res = http.request(:Get, "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings",
                       headers: auth)
    unless res[:status] == 200
      raise "edits.listings.list failed (HTTP #{res[:status]}): #{api_error_message(res[:body])}"
    end

    JSON.parse(res[:body]).fetch("listings", []).map { |l| l.fetch("language") }
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
  # while Play is still processing the image. nil is UNREADABLE, never a
  # byte mismatch — poll edits.images.list across the processing window
  # (attempts × backoff seconds) and only then classify:
  #   returns the verified sha of the just-uploaded image once the readable
  #   set equals the goldens uploaded so far;
  #   raises "remote sha mismatch" on readable bytes contradicting the
  #   goldens (a real byte/ordering mismatch);
  #   returns nil when still unreadable after `attempts` — the caller
  #   aborts with the distinct "remote unreadable" class.
  def poll_stored_sha!(http, package_name, edit_id, locale, type, expected_prefix, auth,
                       attempts: 5, backoff: 30)
    attempts.times do |attempt|
      readable = list_images!(http, package_name, edit_id, locale, type, auth)
                 .map { |image| image["sha256"] }.compact
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

  def commit_edit!(http, package_name, edit_id, auth)
    res = http.request(:Post, "#{API_ROOT}/#{package_name}/edits/#{edit_id}:commit",
                       headers: auth)
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
