import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/provider_flow.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Scripted host for [runCustomProviderFlow]: queued picker/line answers,
/// a failing model fetch (forcing the manual model step), and a captured
/// apply result.
final class _ScriptedHost {
  final io = FakeCliIO();
  final optionAnswers = <String?>[];
  final lineAnswers = <String?>[];
  final optionTitles = <String>[];
  CustomProviderSetup? applied;

  CustomProviderFlowConfig config({
    String? editName,
    ({String label, Future<String?> Function() run})? reauth,
    String? initialType,
    String? initialBaseUrl,
    String? initialName,
    String? initialModelId,
  }) {
    return CustomProviderFlowConfig(
      askLine: (question, {bool secret = false}) async =>
          lineAnswers.isEmpty ? null : lineAnswers.removeAt(0),
      pickOption: (title, options, {String? initialKey}) async {
        optionTitles.add(title);
        return optionAnswers.isEmpty ? null : optionAnswers.removeAt(0);
      },
      fetchModels: (spec, baseUrl, {String? token}) async => const [],
      applyResult: (setup) async => applied = setup,
      currentModelId: () => 'current-model',
      rolesActive: false,
      deriveName: (baseUrl) => 'derived-name',
      initialType: initialType ?? 'openai',
      initialBaseUrl: initialBaseUrl ?? 'https://openrouter.ai/api/v1',
      initialName: initialName ?? 'openrouter.ai',
      initialModelId: initialModelId ?? 'm1',
      editName: editName,
      reauth: reauth,
    );
  }
}

void main() {
  group('custom provider flow — edit re-auth choice', () {
    final reauth = (
      label: 'Browser OAuth (openrouter.ai)',
      run: () async => 'sk-or-minted',
    );

    test('re-auth choice applies the browser-minted key', () async {
      final host = _ScriptedHost()
        // api type, base URL (keep), name (keep), key step, model (keep).
        ..optionAnswers.addAll(['openai', 'reauth'])
        ..lineAnswers.addAll(['', '', '']);
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'openrouter.ai', reauth: reauth),
      );

      expect(host.optionTitles, contains('API key'));
      final setup = host.applied;
      expect(setup, isNotNull);
      expect(setup!.token, 'sk-or-minted');
      expect(setup.name, 'openrouter.ai');
      expect(setup.baseUrl, 'https://openrouter.ai/api/v1');
      expect(setup.modelId, 'm1');
    });

    test('keep choice leaves the stored key untouched (null token)', () async {
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', 'keep'])
        ..lineAnswers.addAll(['', '', '']);
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'openrouter.ai', reauth: reauth),
      );

      expect(host.applied, isNotNull);
      expect(host.applied!.token, isNull);
    });

    test('new-key choice falls through to the secret prompt', () async {
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', 'new'])
        ..lineAnswers.addAll(['', '', 'typed-key', '']);
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'openrouter.ai', reauth: reauth),
      );

      expect(host.applied, isNotNull);
      expect(host.applied!.token, 'typed-key');
    });

    test('cancelled re-auth falls back to manual entry', () async {
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', 'reauth'])
        ..lineAnswers.addAll(['', '', 'typed-after', '']);
      final cancelledReauth = (
        label: 'Browser OAuth (openrouter.ai)',
        run: () async => null,
      );
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'openrouter.ai', reauth: cancelledReauth),
      );

      expect(
        host.io.out.toString(),
        contains('authorization did not complete'),
      );
      expect(host.applied, isNotNull);
      expect(host.applied!.token, 'typed-after');
    });

    test('cancelling the key-step picker aborts the edit', () async {
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', null])
        ..lineAnswers.addAll(['', '']);
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'openrouter.ai', reauth: reauth),
      );

      expect(host.applied, isNull);
      expect(host.io.out.toString(), contains('provider edit cancelled'));
    });

    test('add mode ignores the re-auth option (plain key prompt)', () async {
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai'])
        ..lineAnswers.addAll(['', '', 'typed-key', '']);
      await runCustomProviderFlow(host.io, host.config(reauth: reauth));

      expect(host.optionTitles, isNot(contains('API key')));
      expect(host.applied, isNotNull);
      expect(host.applied!.token, 'typed-key');
    });

    test(
      'codemie SSO re-auth option mints a fresh cookie and stores it',
      () async {
        // The picker that `_editReauthOption` returns for a CodeMie SSO
        // entry — its `run` is the SSO browser flow that mints a fresh
        // cookie. The wizard then applies the cookie through the
        // SSO-aware switch path (model.headers, not Bearer).
        final host = _ScriptedHost()
          ..optionAnswers.addAll(['openai', 'reauth'])
          ..lineAnswers.addAll(['', '', '', '']);
        final codemieReauth = (
          label: 'Browser SSO (CodeMie)',
          run: () async => '_oauth2_proxy=fresh-cookie;KEYCLOAK_IDENTITY=k1',
        );
        await runCustomProviderFlow(
          host.io,
          host.config(editName: 'codemie.lab.epam.com', reauth: codemieReauth),
        );

        expect(host.optionTitles, contains('API key'));
        // The minted cookie is what the wizard applies.
        expect(host.applied, isNotNull);
        expect(
          host.applied!.token,
          '_oauth2_proxy=fresh-cookie;KEYCLOAK_IDENTITY=k1',
        );
      },
    );

    test('codemie JWT re-auth option stores the freshly pasted JWT', () async {
      final freshJwt =
          '${_b64u('{"alg":"none"}')}.${_b64u('{"exp":9999999999}')}.sig';
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', 'reauth'])
        ..lineAnswers.addAll(['', '', '', '']);
      final jwtReauth = (label: 'Paste a new JWT', run: () async => freshJwt);
      await runCustomProviderFlow(
        host.io,
        host.config(editName: 'codemie.lab.epam.com', reauth: jwtReauth),
      );

      expect(host.optionTitles, contains('API key'));
      expect(host.applied, isNotNull);
      expect(host.applied!.token, freshJwt);
    });

    test('edit wizard applies with the entry-derived prefills '
        '(not the active model)', () async {
      // Documents the contract `_startProviderEditWizard` honours after
      // the prefill fix: the entry's own baseUrl/modelId/name flow into
      // the wizard, so editing a codemie entry while kimi is active does
      // NOT pre-fill Kimi's URL/model into the codemie wizard.
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai'])
        ..lineAnswers.addAll(['', '', '', '']);
      await runCustomProviderFlow(
        host.io,
        host.config(
          editName: 'codemie.lab.epam.com',
          initialBaseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          initialName: 'codemie.lab.epam.com',
          initialModelId: 'codemie-model-1',
        ),
      );

      expect(host.applied, isNotNull);
      expect(
        host.applied!.baseUrl,
        'https://codemie.lab.epam.com/code-assistant-api/v1',
      );
      expect(host.applied!.modelId, 'codemie-model-1');
      expect(host.applied!.name, 'codemie.lab.epam.com');
    });

    test('reauth picker appears for a legacy CodeMie entry '
        '(authMethod=apiKey fallback)', () async {
      // Regression: entries written before `authMethod` was serialised
      // carry `apiKey` and a stored cookie — the picker must still offer
      // the browser-SSO refresh option, otherwise editing such an entry
      // jumps straight to a bare token prompt.
      final host = _ScriptedHost()
        ..optionAnswers.addAll(['openai', 'reauth'])
        ..lineAnswers.addAll(['', '', '', '']);
      final codemieLegacyReauth = (
        label: 'Browser SSO (CodeMie)',
        run: () async => '_oauth2_proxy=refreshed;KEYCLOAK_IDENTITY=k1',
      );
      await runCustomProviderFlow(
        host.io,
        host.config(
          editName: 'codemie.lab.epam.com',
          reauth: codemieLegacyReauth,
        ),
      );

      expect(host.optionTitles, contains('API key'));
      expect(host.applied, isNotNull);
      expect(
        host.applied!.token,
        '_oauth2_proxy=refreshed;KEYCLOAK_IDENTITY=k1',
      );
    });
  });
}

/// Minimal base64url-no-pad helper for synthesizing JWT-shaped test
/// fixtures (the wizard test only cares about the string round-trip —
/// the apply path's format detection does the real routing).
String _b64u(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
