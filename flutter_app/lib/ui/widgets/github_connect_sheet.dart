// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa_llm/fa_llm.dart' show fetchGithubLogin;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        CopilotDeviceFlowError,
        CopilotDeviceFlowErrorKind,
        CopilotDeviceGrant,
        pollCopilotDeviceGrant,
        requestCopilotDeviceGrant;

/// The "Fa Widgets" OAuth App client id, injected at build time (`--dart
/// -define=FA_GITHUB_CLIENT_ID=...`). Empty until the OAuth App is
/// registered (card §Open questions) — then only the PAT tab shows.
const String githubWidgetsClientId = String.fromEnvironment(
  'FA_GITHUB_CLIENT_ID',
);

/// Opens the "Connect GitHub" sheet (issue #35): PAT paste (always
/// available) plus, when [githubWidgetsClientId] is configured and the
/// platform is not web, the RFC 8628 device flow.
///
/// Resolves `true` when an account was connected, `false`/null otherwise.
/// [clientFactory] injects a scripted `GithubApiClient` in tests.
Future<bool?> showGithubConnectSheet(
  BuildContext context, {
  required GithubAccountStore account,
  GithubApiClient Function(String token)? clientFactory,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        GithubConnectSheet(account: account, clientFactory: clientFactory),
  );
}

/// The connect sheet body (also embeddable in tests without the modal).
class GithubConnectSheet extends StatefulWidget {
  const GithubConnectSheet({
    super.key,
    required this.account,
    this.clientFactory,
  });

  final GithubAccountStore account;

  /// Test hook: builds the API client used to validate a pasted token.
  final GithubApiClient Function(String token)? clientFactory;

  @override
  State<GithubConnectSheet> createState() => _GithubConnectSheetState();
}

class _GithubConnectSheetState extends State<GithubConnectSheet> {
  final _tokenController = TextEditingController();

  /// Whether the device-flow tab exists (needs the OAuth client id and a
  /// non-web platform — github.com serves no CORS headers).
  bool get _deviceFlowAvailable => !kIsWeb && githubWidgetsClientId.isNotEmpty;

  /// True while the device tab is the visible one.
  late bool _deviceMode = _deviceFlowAvailable;

  String? _error;
  bool _busy = false;

  /// Set by cancel/dispose so the in-flight device-flow poll loop abandons
  /// its result instead of connecting a dismissed sheet.
  bool _cancelled = false;

  CopilotDeviceGrant? _grant;

  @override
  void initState() {
    super.initState();
    if (_deviceMode) _startDeviceFlow();
  }

  @override
  void dispose() {
    _cancelled = true;
    _tokenController.dispose();
    super.dispose();
  }

  // --- PAT -----------------------------------------------------------------

  Future<void> _connectWithToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client =
          widget.clientFactory?.call(token) ?? GithubApiClient(token: token);
      final user = await client.getUser();
      if (_cancelled) return;
      await widget.account.connect(
        token: token,
        login: user.login,
        avatarUrl: user.avatarUrl,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on GithubApiException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  // --- device flow ---------------------------------------------------------

  Future<void> _startDeviceFlow() async {
    setState(() {
      _busy = true;
      _error = null;
      _grant = null;
    });
    try {
      final grant = await requestCopilotDeviceGrant(
        clientId: githubWidgetsClientId,
        scope: 'public_repo',
      );
      if (_cancelled) return;
      setState(() => _grant = grant);
      unawaited(
        url_launcher.launchUrl(
          Uri.parse(grant.verificationUri),
          mode: url_launcher.LaunchMode.externalApplication,
        ),
      );
      final token = await pollCopilotDeviceGrant(
        grant: grant,
        clientId: githubWidgetsClientId,
        delay: Future<void>.delayed,
      );
      if (_cancelled) return;
      final login = await fetchGithubLogin(githubToken: token);
      if (_cancelled) return;
      await widget.account.connect(token: token, login: login);
      if (mounted) Navigator.of(context).pop(true);
    } on CopilotDeviceFlowError catch (error) {
      if (_cancelled || !mounted) return;
      if (error.kind == CopilotDeviceFlowErrorKind.endpointDisabled) {
        // The OAuth App is not registered (or its device flow is off):
        // fall back to the PAT tab, carrying the explanation.
        setState(() {
          _deviceMode = false;
          _busy = false;
          _error = error.message;
        });
      } else {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    } on Object catch (error) {
      if (_cancelled || !mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  void _switchTab({required bool device}) {
    setState(() {
      _deviceMode = device;
      _error = null;
    });
    if (device && _grant == null) _startDeviceFlow();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.githubConnect,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_deviceFlowAvailable) ...[
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(l10n.githubConnectTokenTab),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(l10n.githubConnectDeviceTab),
                ),
              ],
              selected: {_deviceMode},
              onSelectionChanged: (selection) =>
                  _switchTab(device: selection.first),
            ),
            const SizedBox(height: 12),
          ],
          if (_deviceMode)
            _buildDevicePane(context)
          else
            _buildPatPane(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPatPane(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _tokenController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: l10n.githubTokenHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _connectWithToken(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _connectWithToken,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.githubConnect),
        ),
      ],
    );
  }

  Widget _buildDevicePane(BuildContext context) {
    final l10n = context.l10n;
    final grant = _grant;
    if (grant == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.githubConnectDeviceInstructions,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            grant.userCode,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(letterSpacing: 2),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: grant.userCode));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(l10n.githubCopyCode),
            ),
            OutlinedButton.icon(
              onPressed: () => unawaited(
                url_launcher.launchUrl(
                  Uri.parse(grant.verificationUri),
                  mode: url_launcher.LaunchMode.externalApplication,
                ),
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.githubOpenDevicePage),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ],
    );
  }
}
