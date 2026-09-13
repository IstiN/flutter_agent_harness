/// Boot-time hub credential seeding.
///
/// The hub plugin's kill switch reads the master-secret key from the
/// (mutable) environment overlay: empty → the plugin never connects.
/// `/dap start` and the settings-hub flow persist the dial credential
/// into `~/.dap/config.json` ("clientSecret") explicitly so that "the
/// next boot is online by itself" — but nothing copied it back into the
/// environment, so the next boot stayed offline until the user exported
/// the secret by hand.
///
/// [seedHubBootCredential] closes that gap: with no explicit env
/// credential present, the persisted config credential is mirrored into
/// the master key. The dial itself still prefers the proper sources in
/// priority order (env client secret > config client secret > env
/// master), so the seed only flips the kill switch — it never changes
/// which credential goes on the wire.
///
/// Pure Dart: the host (bin/, io-allowed) reads and parses the config
/// file and passes the map in.
library;

/// Seeds `environment[masterSecretKey]` from an already-configured DAP
/// credential when the environment carries none.
///
/// Resolution order:
///
/// 1. `masterSecretKey` already set → nothing to do (returns `null`).
/// 2. `clientSecretKey` set → mirror it into the master key so the
///    kill switch flips; the dial still prefers the client key.
/// 3. `dapConfig['clientSecret']` non-empty → seed from the persisted
///    config (the explicit prior opt-in from `/dap start`).
/// 4. Otherwise → nothing; the hub stays off and quiet.
///
/// Empty/whitespace-only values count as unset. Returns the seeded
/// value, or `null` when nothing was seeded.
String? seedHubBootCredential(
  Map<String, String> environment, {
  required String masterSecretKey,
  required String clientSecretKey,
  required Map<String, dynamic>? dapConfig,
}) {
  String? present(String key) {
    final value = environment[key];
    return (value == null || value.trim().isEmpty) ? null : value;
  }

  if (present(masterSecretKey) != null) return null;
  final client = present(clientSecretKey);
  if (client != null) {
    environment[masterSecretKey] = client;
    return client;
  }
  final stored = dapConfig?['clientSecret'];
  if (stored is String && stored.trim().isNotEmpty) {
    environment[masterSecretKey] = stored;
    return stored;
  }
  return null;
}
