/// Headless `fa provider export <name> [--check]` (issue #1704): mints a
/// fresh Bearer credential for the saved ChatGPT/Codex login and prints the
/// shell lines external tools eval — the `GITHUB_TOKEN=$(gh auth token)`
/// parity for the Codex backend.
///
/// The full OAuth blob lives in the entry's secure-store slot; the export
/// refreshes it when stale (so the minted access token is fresh, not the
/// possibly-expired stored one) and prints ONLY the access token — the
/// refresh token never leaves the store. `--check` reports credential
/// health without printing any secret. The base URL is always the Codex
/// backend: ChatGPT access tokens are accepted ONLY by
/// `https://chatgpt.com/backend-api/codex/...`, never by api.openai.com.
library;

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart' show resolveCliProviderSpec;
import '../providers/chatgpt_oauth.dart';
import 'agent_cli.dart';
import 'cli_args.dart';
import 'custom_providers.dart';

/// The exported base URL: the one endpoint family these tokens serve.
const chatGptExportBaseUrl = chatGptCodexBaseUrl;

/// The shell lines an external tool evals: `export OPENAI_API_KEY=<fresh>`
/// + `export OPENAI_BASE_URL=<codex backend>`.
String chatGptExportLines({required String accessToken}) =>
    'export OPENAI_API_KEY=$accessToken\n'
    'export OPENAI_BASE_URL=$chatGptExportBaseUrl';

/// The `--check` health lines for [credentials]: expiry state and
/// refreshability, never a token value. The SSO caveat is part of the
/// contract (issue #1704 notes): corporate session policies can shorten
/// lifetimes or revoke refresh tokens, so the check says exactly that.
List<String> chatGptExportCheckLines(
  ChatGptOAuthCredentials credentials,
  String name,
  DateTime now,
) {
  final expiresAt = credentials.expiresAt;
  final expiry = expiresAt == null
      ? 'access token expiry unknown'
      : expiresAt.isBefore(now)
      ? 'access token EXPIRED'
      : 'access token expires in ${expiresAt.difference(now).inMinutes} min';
  return [
    // The decode contract guarantees a non-empty refresh token, so a
    // stored login is always refreshable HERE — the risk is revocation.
    '$name: $expiry; refresh token present (refreshable)',
    'note: corporate/SSO session policies can shorten lifetimes or revoke '
        'refresh tokens at any time',
  ];
}

/// Resolves the saved ChatGPT entry for [name]: the registry's own lookup
/// (case-insensitive, alias spellings), narrowed to `chatgpt-codex`-kind
/// entries. Null when no saved login of that kind matches.
CustomProviderEntry? findChatGptExportEntry(
  List<CustomProviderEntry> entries,
  String name,
) {
  final spec = resolveCliProviderSpec(name);
  if (spec?.kind == 'chatgpt-codex') {
    // The kind itself (`chatgpt` / `chatgpt-codex`): the saved entry is
    // located by its apiType, first match.
    for (final entry in entries) {
      if (resolveCliProviderSpec(entry.apiType)?.kind == 'chatgpt-codex') {
        return entry;
      }
    }
    return null;
  }
  final entry = CustomProviderRegistry(entries).find(name);
  if (entry == null) return null;
  return resolveCliProviderSpec(entry.apiType)?.kind == 'chatgpt-codex'
      ? entry
      : null;
}

/// Runs one `fa provider <verb>` command and returns the process exit code.
///
/// Key resolution: the entry's own slot first, then the legacy
/// [chatGptOAuthCredentialsEnvName] slot (what the persist fallback and
/// headless env users write). The refresh goes through [refreshFn]
/// (default: the real OAuth refresh) — inject a fake in tests.
Future<int> runProviderCredentialExportCommand(
  ProviderCliCommand cmd, {
  required CliIO io,
  required List<CustomProviderEntry> entries,
  String? Function(String keyName)? secureRead,
  Future<ChatGptOAuthCredentials> Function(ChatGptOAuthCredentials)? refreshFn,
  DateTime Function()? now,
}) async {
  switch (cmd.verb) {
    case 'export':
      return _exportChatGptCredential(
        cmd,
        io: io,
        entries: entries,
        secureRead: secureRead,
        refreshFn: refreshFn,
        now: now,
      );
    default:
      io.writeln('unknown provider verb: ${cmd.verb}');
      return 1;
  }
}

Future<int> _exportChatGptCredential(
  ProviderCliCommand cmd, {
  required CliIO io,
  required List<CustomProviderEntry> entries,
  required String? Function(String keyName)? secureRead,
  required Future<ChatGptOAuthCredentials> Function(ChatGptOAuthCredentials)?
  refreshFn,
  required DateTime Function()? now,
}) async {
  final name = cmd.name ?? '';
  final entry = findChatGptExportEntry(entries, name);
  if (entry == null) {
    final saved = [
      for (final candidate in entries)
        if (resolveCliProviderSpec(candidate.apiType)?.kind == 'chatgpt-codex')
          candidate.name,
    ];
    io.writeln(
      'fa: no saved ChatGPT login "$name"'
      '${saved.isEmpty ? '' : ' (saved: ${saved.join(', ')})'} — '
      'run `/provider chatgpt oauth` first',
    );
    return 1;
  }
  final keyName =
      entry.keyName ??
      CustomProviderRegistry.keyNameFor(
        entry.baseUrl,
        providerName: entry.name,
      );
  final blob =
      secureRead?.call(keyName) ??
      secureRead?.call(chatGptOAuthCredentialsEnvName);
  if (blob == null || blob.isEmpty) {
    io.writeln(
      'fa: no stored credentials in "$keyName" for "${entry.name}" — '
      'run `/provider chatgpt oauth` first',
    );
    return 1;
  }
  final decoded = tryDecodeChatGptCredentials(blob);
  if (decoded == null) {
    io.writeln(
      'fa: stored "$keyName" for "${entry.name}" is not a ChatGPT OAuth '
      'blob — re-authenticate with `/provider chatgpt oauth`',
    );
    return 1;
  }
  var credentials = decoded;
  if (cmd.check) {
    for (final line in chatGptExportCheckLines(
      credentials,
      entry.name,
      (now ?? DateTime.now)(),
    )) {
      io.writeln(line);
    }
    return 0;
  }
  final clock = now ?? DateTime.now;
  if (credentials.needsRefresh(clock())) {
    try {
      credentials = await (refreshFn ?? refreshChatGptCredentials)(credentials);
    } on ConfigException catch (error) {
      io.writeln(
        'fa: could not refresh the ChatGPT credential for '
        '"${entry.name}": ${error.message}\n'
        'The refresh token may be revoked (SSO/corporate session policy) — '
        're-authenticate with `/provider chatgpt oauth` and update the '
        'stored login.',
      );
      return 1;
    }
  }
  io.writeln(chatGptExportLines(accessToken: credentials.accessToken));
  return 0;
}
