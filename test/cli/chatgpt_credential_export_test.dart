import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The `fa provider export <name> [--check]` command (issue #1704): fake
/// secure store + injected refresh/clock — no network, and the refresh
/// token never appears in the output.
void main() {
  final now = DateTime.utc(2026, 10, 19, 12);

  CustomProviderEntry chatGptEntry({String? keyName}) => CustomProviderEntry(
    name: 'my-chatgpt',
    apiType: 'chatgpt',
    baseUrl: chatGptCodexBaseUrl,
    modelId: 'gpt-5-codex',
    keyName: keyName,
  );

  String staleBlob() => ChatGptOAuthCredentials(
    accessToken: 'stale-at',
    refreshToken: 'rt-secret',
    idToken: 'it-1',
    accountId: 'acc-1',
    expiresAt: DateTime.utc(2026, 10, 19, 11),
  ).encode();

  String freshBlob() => ChatGptOAuthCredentials(
    accessToken: 'fresh-at',
    refreshToken: 'rt-secret',
    idToken: 'it-1',
    accountId: 'acc-1',
    expiresAt: DateTime.utc(2026, 10, 19, 13),
  ).encode();

  Future<(int, String)> run(
    ProviderCliCommand cmd, {
    required List<CustomProviderEntry> entries,
    Map<String, String> store = const {},
  }) async {
    final io = FakeCliIO();
    final code = await runProviderCredentialExportCommand(
      cmd,
      io: io,
      entries: entries,
      secureRead: (name) => store[name],
      now: () => now,
    );
    final output = io.out.toString();
    await io.close();
    return (code, output);
  }

  test('a stale login refreshes and prints the export lines', () async {
    var refreshed = 0;
    final io = FakeCliIO();
    final code = await runProviderCredentialExportCommand(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt'),
      io: io,
      entries: [chatGptEntry(keyName: 'SLOT')],
      secureRead: (name) => name == 'SLOT' ? staleBlob() : null,
      refreshFn: (credentials) async {
        refreshed++;
        expect(credentials.refreshToken, 'rt-secret');
        return ChatGptOAuthCredentials(
          accessToken: 'minted-at',
          refreshToken: 'rt-rotated',
          idToken: 'it-2',
          accountId: 'acc-1',
          expiresAt: DateTime.utc(2026, 10, 19, 14),
        );
      },
      now: () => now,
    );
    final output = io.out.toString();
    await io.close();
    expect(code, 0);
    expect(refreshed, 1);
    expect(
      output,
      'export OPENAI_API_KEY=minted-at\n'
      'export OPENAI_BASE_URL=https://chatgpt.com/backend-api/codex\n',
    );
    // The refresh token — stored OR rotated — never prints.
    expect(output, isNot(contains('rt-secret')));
    expect(output, isNot(contains('rt-rotated')));
  });

  test('a fresh login exports without touching the refresh endpoint', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt'),
      entries: [chatGptEntry(keyName: 'SLOT')],
      store: {'SLOT': freshBlob()},
    );
    expect(code, 0);
    expect(output, contains('export OPENAI_API_KEY=fresh-at'));
    expect(output, isNot(contains('rt-secret')));
  });

  test('--check reports health and prints no secret', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt', check: true),
      entries: [chatGptEntry(keyName: 'SLOT')],
      store: {'SLOT': staleBlob()},
    );
    expect(code, 0);
    expect(output, contains('my-chatgpt'));
    expect(output, contains('EXPIRED'));
    expect(output, contains('refresh token present'));
    expect(output, contains('SSO'));
    expect(output, isNot(contains('stale-at')));
    expect(output, isNot(contains('rt-secret')));
  });

  test('the kind-shaped name resolves the saved chatgpt entry', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'chatgpt-codex'),
      entries: [chatGptEntry(keyName: 'SLOT')],
      store: {'SLOT': freshBlob()},
    );
    expect(code, 0);
    expect(output, contains('export OPENAI_API_KEY=fresh-at'));
  });

  test('an unknown name exits 1 naming the saved logins', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'nope'),
      entries: [chatGptEntry(keyName: 'SLOT')],
      store: {'SLOT': freshBlob()},
    );
    expect(code, 1);
    expect(output, contains('no saved ChatGPT login "nope"'));
    expect(output, contains('my-chatgpt'));
  });

  test('a non-chatgpt entry name is refused', () async {
    final openai = CustomProviderEntry(
      name: 'corp-proxy',
      apiType: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      modelId: 'gpt-5',
      keyName: 'OPENAI_API_KEY',
    );
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'corp-proxy'),
      entries: [openai],
    );
    expect(code, 1);
    expect(output, contains('no saved ChatGPT login "corp-proxy"'));
  });

  test('an empty slot exits 1 with the store name', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt'),
      entries: [chatGptEntry(keyName: 'SLOT')],
    );
    expect(code, 1);
    expect(output, contains('no stored credentials in "SLOT"'));
  });

  test('an empty entry slot falls back to the legacy env-name slot', () async {
    final (code, output) = await run(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt'),
      entries: [chatGptEntry(keyName: null)],
      store: {'CHATGPT_OAUTH_CREDENTIALS': freshBlob()},
    );
    expect(code, 0);
    expect(output, contains('export OPENAI_API_KEY=fresh-at'));
  });

  test('a revoked refresh token fails loud with the recovery path', () async {
    final io = FakeCliIO();
    final code = await runProviderCredentialExportCommand(
      const ProviderCliCommand(verb: 'export', name: 'my-chatgpt'),
      io: io,
      entries: [chatGptEntry(keyName: 'SLOT')],
      secureRead: (name) => name == 'SLOT' ? staleBlob() : null,
      refreshFn: (credentials) async => throw const ConfigException(
        'ChatGPT OAuth token request failed '
        '(400): invalid_grant',
      ),
      now: () => now,
    );
    final output = io.out.toString();
    await io.close();
    expect(code, 1);
    expect(output, contains('could not refresh'));
    expect(output, contains('invalid_grant'));
    expect(output, contains('revoke'));
    expect(output, isNot(contains('rt-secret')));
  });
}
