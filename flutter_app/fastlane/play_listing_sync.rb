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
#      listing order), checking each stored sha256 against the local file;
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
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  SCOPE = "https://www.googleapis.com/auth/androidpublisher"

  # Multi-slot types: Play APPENDS uploads, so every listing locale gets its
  # remote set cleared first — including types the repo no longer generates
  # (ru-RU tenInchScreenshots) and never generated (sevenInchScreenshots).
  SCREENSHOT_TYPES = %w[phoneScreenshots sevenInchScreenshots tenInchScreenshots].freeze
  # Single-slot types: an upload replaces the stored image by itself.
  SINGLE_IMAGE_TYPES = %w[icon featureGraphic].freeze
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

  # The post-sync state the listing must have: sha256 sets per
  # [locale, type] — the repo goldens where they exist, empty where they
  # do not (ru-RU tenInch, dropped locales).
  def expected_state(metadata_dir, remote_locales)
    all_locales(metadata_dir, remote_locales).to_h do |locale|
      [locale, MANAGED_TYPES.to_h { |type|
        [type, local_images(metadata_dir, locale, type).map { |path| sha256(path) }.sort]
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
  def sync_and_verify!(metadata_dir:, json_key:, package_name:, http: Http.new, now: Time.now)
    auth = bearer!(json_key, http: http, now: now)

    edit_id = begin_edit!(http, package_name, auth)
    remote_locales = list_locales!(http, package_name, edit_id, auth)

    uploaded = 0
    clear_plan(metadata_dir, remote_locales).each do |entry|
      clear_images!(http, package_name, edit_id, entry[:locale], entry[:type], auth)
    end
    repo_locales(metadata_dir).each do |locale|
      MANAGED_TYPES.each do |type|
        local_images(metadata_dir, locale, type).each do |path|
          stored = upload_image!(http, package_name, edit_id, locale, type, path, auth)
          unless stored == sha256(path)
            raise "Play stored different bytes for #{locale}/#{type}/" \
                  "#{File.basename(path)} (sha256 #{stored.inspect} != local " \
                  "#{sha256(path)}) — aborting before commit, listing untouched"
          end
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
        got = list_images!(http, package_name, edit_id, locale, type, auth)
              .map { |image| image["sha256"] }.compact.sort
        next if got == want

        problems << "  #{locale}/#{type}: remote has #{got.size} image(s), " \
                    "expected #{want.size} (sha256 mismatch)"
      end
    end
    delete_edit!(http, package_name, edit_id, auth) # read-only edit — discard

    return true if problems.empty?

    raise "Play listing does NOT match the committed goldens " \
          "(edits.images.list after upload):\n#{problems.join("\n")}"
  end

  # ── androidpublisher REST calls (all thin + injectable via http) ────────

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
      raise "Play API auth failed (HTTP #{res[:status]}): #{res[:body][0, 300]}"
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
      raise "edits.insert failed (HTTP #{res[:status]}): #{res[:body][0, 300]}"
    end

    JSON.parse(res[:body]).fetch("id")
  end

  def list_locales!(http, package_name, edit_id, auth)
    res = http.request(:Get, "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings",
                       headers: auth)
    unless res[:status] == 200
      raise "edits.listings.list failed (HTTP #{res[:status]}): #{res[:body][0, 300]}"
    end

    JSON.parse(res[:body]).fetch("listings", []).map { |l| l.fetch("language") }
  end

  # Deletes the WHOLE image set of a locale/type. 404 = nothing to clear.
  def clear_images!(http, package_name, edit_id, locale, type, auth)
    res = http.request(:Delete,
                       "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings/" \
                       "#{locale}/images/#{type}", headers: auth)
    return if [200, 204, 404].include?(res[:status])

    raise "edits.images.delete failed for #{locale}/#{type} " \
          "(HTTP #{res[:status]}): #{res[:body][0, 300]}"
  end

  def upload_image!(http, package_name, edit_id, locale, type, path, auth)
    res = http.request(
      :Post,
      "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings/#{locale}/" \
      "images/#{type}?uploadType=media",
      headers: auth, body: File.binread(path), content_type: "image/png"
    )
    unless res[:status] == 200
      raise "edits.images.upload failed for #{locale}/#{type}/" \
            "#{File.basename(path)} (HTTP #{res[:status]}): #{res[:body][0, 300]}"
    end

    JSON.parse(res[:body])["sha256"]
  end

  def list_images!(http, package_name, edit_id, locale, type, auth)
    res = http.request(:Get,
                       "#{API_ROOT}/#{package_name}/edits/#{edit_id}/listings/" \
                       "#{locale}/images/#{type}", headers: auth)
    unless res[:status] == 200
      raise "edits.images.list failed for #{locale}/#{type} " \
            "(HTTP #{res[:status]}): #{res[:body][0, 300]}"
    end

    JSON.parse(res[:body]).fetch("images", [])
  end

  def commit_edit!(http, package_name, edit_id, auth)
    res = http.request(:Post, "#{API_ROOT}/#{package_name}/edits/#{edit_id}:commit",
                       headers: auth)
    return if res[:status] == 200

    raise "edits.commit failed (HTTP #{res[:status]}): #{res[:body][0, 300]}"
  end

  def delete_edit!(http, package_name, edit_id, auth)
    http.request(:Delete, "#{API_ROOT}/#{package_name}/edits/#{edit_id}", headers: auth)
  end

  # ── transport ───────────────────────────────────────────────────────────

  # Minimal HTTPS JSON/binary transport with bounded 5xx/time-out retries.
  # The unit tests substitute a fake with the same `request` signature.
  class Http
    RETRIABLE = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError].freeze

    def request(method, url, headers: {}, body: nil, content_type: nil)
      tries = 0
      begin
        tries += 1
        res = perform(method, url, headers, body, content_type)
        return { status: res.code.to_i, body: res.body.to_s } if res.code.to_i < 500 || tries >= 3

        raise Net::ReadTimeout, "HTTP #{res.code}"
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
