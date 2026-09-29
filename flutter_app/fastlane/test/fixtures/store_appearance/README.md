# store-appearance-check fixtures (gh-1041)

Recorded store-API response shapes for the fixture-based test suites:

- `test/store_appearance_test.rb` — plain-ruby unit matrix (parser +
  presence + lifecycle decisions), run by ci.yml's "Fastlane pre-flight
  suites (ruby)" loop;
- `test/store_appearance_check_test.dart` — IT: the real
  `scripts/store_appearance_check.rb` against local fake endpoints serving
  these exact files (no real network).

`*_present.*` = the store serves the expected version, `*_absent.*` = it
serves only an older one. `test_asc_key.p8` and
`test_play_service_account.json` are THROWAWAY test-only keys generated for
JWT-mint coverage in the IT suite — they open nothing; the fake endpoints
never validate signatures.
