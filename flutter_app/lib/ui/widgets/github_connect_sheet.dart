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
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/github_oauth_web_flow.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        CopilotDeviceFlowError,
        CopilotDeviceFlowErrorKind,
        CopilotDeviceGrant,
        copilotDeviceClientId,
        pollCopilotDeviceGrant,
        requestCopilotDeviceGrant;

/// The "Fa Widgets" OAuth App client id, injected at build time (`--dart
/// -define=FA_GITHUB_CLIENT_ID=...`). When empty the device flow falls back
/// to the VS Code Copilot plugin's public client id
/// ([copilotDeviceClientId] — same github.com/login/device endpoint); the
/// `public_repo` scope is granted by the user on the device page either way.
const String githubWidgetsClientId = String.fromEnvironment(
  'FA_GITHUB_CLIENT_ID',
);

/// Resolves the device-flow client id: the build-time OAuth App when
/// configured, else the public Copilot plugin id (identity-only — GitHub
/// pins its consent screen, the token can never publish). At runtime the
/// app can configure a user-registered OAuth App via the
/// [githubOauthClientIdKeyName] key in the settings Keys section.
const githubOauthClientIdKeyName = 'github_oauth_client_id';

/// Which connect method the sheet shows.
enum _ConnectTab { token, device, web }

/// Opens the "Connect GitHub" sheet (issue #35): PAT paste (always
/// available) plus, on non-web platforms, the RFC 8628 device flow and the
/// OAuth web flow (both need a client id — the build-time OAuth App or the
/// runtime Keys entry; device also falls back to the public Copilot plugin
/// id, which GitHub limits to identity-only tokens).
///
/// Resolves `true` when an account was connected, `false`/null otherwise.
/// [clientFactory] injects a scripted `GithubApiClient` in tests,
/// [webFlow] the github.com code exchange.
Future<bool?> showGithubConnectSheet(
  BuildContext context, {
  required GithubAccountStore account,
  GithubApiClient Function(String token)? clientFactory,
  String? deviceClientId,
  String? webClientId,
  GithubOauthWebFlow webFlow = const GithubOauthWebFlow(),
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => GithubConnectSheet(
      account: account,
      clientFactory: clientFactory,
      deviceClientId: deviceClientId,
      webClientId: webClientId,
      webFlow: webFlow,
    ),
  );
}

/// The connect sheet body (also embeddable in tests without the modal).
class GithubConnectSheet extends StatefulWidget {
  const GithubConnectSheet({
    super.key,
    required this.account,
    this.clientFactory,
    this.deviceClientId,
    this.webClientId,
    this.webFlow = const GithubOauthWebFlow(),
  });

  final GithubAccountStore account;

  /// Test hook: builds the API client used to validate a pasted token.
  final GithubApiClient Function(String token)? clientFactory;

  /// Device-flow client id override. Null resolves
  /// the build-time OAuth App, the runtime Keys entry, or the public
  /// Copilot plugin id); an empty string disables the device tab (tests).
  final String? deviceClientId;

  /// Web-flow (Browser tab) client id override. Null resolves the
  /// build-time OAuth App or the runtime Keys entry; an empty string
  /// disables the tab (tests). The public Copilot fallback id never
  /// enables it — the web flow needs OUR app: its redirect URI is
  /// registered to us and the code exchange needs its secret.
  final String? webClientId;

  /// Test hook: replaces the github.com code exchange.
  final GithubOauthWebFlow webFlow;

  @override
  State<GithubConnectSheet> createState() => _GithubConnectSheetState();
}

class _GithubConnectSheetState extends State<GithubConnectSheet> {
  final _tokenController = TextEditingController();

  /// The resolved device-flow client id; set in [didChangeDependencies]
  /// (needs the inherited keys store). Null until then.
  String? _deviceClientId;

  /// True when the fallback Copilot plugin id is in use: GitHub pins that
  /// app's consent to identity-only scopes, so the token can verify the
  /// login but can NEVER publish (no public_repo). Surfaced as a warning.
  bool _fallbackDeviceId = false;

  /// Whether the device-flow tab exists (needs a client id and a non-web
  /// platform — github.com serves no CORS headers).
  bool get _deviceFlowAvailable => !kIsWeb && _deviceClientId!.isNotEmpty;

  /// Whether the browser (OAuth web flow) tab exists: it needs an owned
  /// OAuth App id and a non-web platform (github.com serves no CORS
  /// headers, so the web build cannot exchange the code).
  bool get _webFlowAvailable => !kIsWeb && _webClientId!.isNotEmpty;

  /// The connect method the sheet shows.
  _ConnectTab _tab = _ConnectTab.token;

  /// Guards the one-time device-flow auto-start after id resolution.
  bool _deviceStarted = false;

  String? _error;
  bool _busy = false;

  /// Set by cancel/dispose so the in-flight device-flow poll loop abandons
  /// its result instead of connecting a dismissed sheet.
  bool _cancelled = false;

  CopilotDeviceGrant? _grant;

  /// The web-flow (Browser tab) client id; '' = no owned OAuth App, the
  /// tab stays hidden. Resolved alongside the device id.
  String? _webClientId;

  /// The one-time code field of the Browser tab.
  final _webCodeController = TextEditingController();

  /// Guards the one-time authorize-URL auto-open per tab entry.
  bool _webLaunched = false;


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_deviceClientId == null) {
      final override = widget.deviceClientId?.trim();
      if (override != null) {
        // Explicit override: empty string disables the device tab (tests).
        _deviceClientId = override;
      } else if (githubWidgetsClientId.isNotEmpty) {
        _deviceClientId = githubWidgetsClientId;
      } else {
        // A user-registered OAuth App id can be configured at runtime in
        // Settings → Keys under [githubOauthClientIdKeyName] — no rebuild
        // needed. Without it the fallback Copilot plugin id stays
        // identity-only (GitHub pins its consent screen).
        final keys = SessionKeysScope.maybeOf(context);
        final configured = keys?.valueOf(
          githubOauthClientIdKeyName,
        )?.trim();
        if (configured != null && configured.isNotEmpty) {
          _deviceClientId = configured;
        } else {
          _deviceClientId = copilotDeviceClientId;
          _fallbackDeviceId = true;
        }
      }
      _resolveWebClientId();
      _tab = _deviceFlowAvailable ? _ConnectTab.device : _ConnectTab.token;
    }
    if (_tab == _ConnectTab.device &&
        !_deviceStarted &&
        _grant == null &&
        !_busy) {
      _deviceStarted = true;
      _startDeviceFlow();
    }
  }

  /// Resolves the Browser-tab client id once: the explicit override
  /// (empty string hides the tab), the build-time OAuth App, or the
  /// runtime Keys entry. Never the public Copilot fallback id.
  void _resolveWebClientId() {
    final override = widget.webClientId?.trim();
    if (override != null) {
      _webClientId = override;
    } else if (githubWidgetsClientId.isNotEmpty) {
      _webClientId = githubWidgetsClientId;
    } else {
      final keys = SessionKeysScope.maybeOf(context);
      final configured = keys?.valueOf(githubOauthClientIdKeyName)?.trim();
      _webClientId =
          (configured != null && configured.isNotEmpty) ? configured : '';
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _tokenController.dispose();
    _webCodeController.dispose();
    super.dispose();
  }

  // --- shared connect tail ---------------------------------------------------

  /// Validates the fresh token's scopes and stores the connection — the
  /// shared tail of all three connect methods. Publishing needs repo
  /// rights: verify the granted scopes before storing the connection —
  /// the public Copilot plugin id often yields a token without
  /// public_repo, which would only fail later at repo creation with an
  /// opaque 403.
  Future<void> _finishConnect(String token) async {
    final client =
        widget.clientFactory?.call(token) ?? GithubApiClient(token: token);
    final (user, scopes) = await client.getUserAndScopes();
    if (_cancelled) return;
    if (!GithubApiClient.tokenCanCreateRepos(scopes)) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.l10n.githubTokenNoRepoScope;
        });
      }
      return;
    }
    await widget.account.connect(
      token: token,
      login: user.login,
      avatarUrl: user.avatarUrl,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Shared failure handling: GitHub errors surface their server message,
  /// anything else its toString.
  void _connectFailed(Object error) {
    if (_cancelled || !mounted) return;
    setState(() {
      _busy = false;
      _error = error is GithubApiException ? error.message : error.toString();
    });
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
      final (user, scopes) = await client.getUserAndScopes();
      if (_cancelled) return;
      if (!GithubApiClient.tokenCanCreateRepos(scopes)) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = context.l10n.githubTokenNoRepoScope;
          });
        }
        return;
      }
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
        clientId: _deviceClientId!,
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
        clientId: _deviceClientId!,
        delay: Future<void>.delayed,
      );
      if (_cancelled) return;
      await _finishConnect(token);
    } on CopilotDeviceFlowError catch (error) {
      if (_cancelled || !mounted) return;
      if (error.kind == CopilotDeviceFlowErrorKind.endpointDisabled) {
        // The OAuth App is not registered (or its device flow is off):
        // fall back to the PAT tab, carrying the explanation.
        setState(() {
          _tab = _ConnectTab.token;
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

  void _switchTab(_ConnectTab tab) {
    setState(() {
      _tab = tab;
      _error = null;
    });
    if (tab == _ConnectTab.device && _grant == null) _startDeviceFlow();
    if (tab == _ConnectTab.web) _openWebAuthorize();
  }

  // --- browser (OAuth web flow) ---------------------------------------------

  /// Opens the github.com authorize page once per sheet lifetime; the user
  /// completes sign-in in the browser and copies the one-time code the
  /// fa1.dev callback page shows ([githubOauthWebRedirectUri]).
  void _openWebAuthorize() {
    if (_webLaunched || _webClientId!.isEmpty) return;
    _webLaunched = true;
    unawaited(
      url_launcher.launchUrl(
        buildGithubOauthAuthorizeUrl(clientId: _webClientId!),
        mode: url_launcher.LaunchMode.externalApplication,
      ),
    );
  }

  Future<void> _connectWithBrowser() async {
    final code = _webCodeController.text.trim();
    if (code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keys = SessionKeysScope.maybeOf(context);
      final token = await widget.webFlow.exchange(
        clientId: _webClientId!,
        code: code,
        clientSecret: keys?.valueOf(githubOauthClientSecretKeyName)?.trim(),
      );
      await _finishConnect(token);
    } on Object catch (error) {
      _connectFailed(error);
    }
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
          if (_deviceFlowAvailable || _webFlowAvailable) ...[
            SegmentedButton<_ConnectTab>(
              segments: [
                ButtonSegment(
                  value: _ConnectTab.token,
                  label: Text(l10n.githubConnectTokenTab),
                ),
                if (_deviceFlowAvailable)
                  ButtonSegment(
                    value: _ConnectTab.device,
                    label: Text(l10n.githubConnectDeviceTab),
                  ),
                if (_webFlowAvailable)
                  ButtonSegment(
                    value: _ConnectTab.web,
                    label: Text(l10n.githubConnectWebTab),
                  ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) => _switchTab(selection.first),
            ),
            const SizedBox(height: 12),
          ],
          switch (_tab) {
            _ConnectTab.device => _buildDevicePane(context),
            _ConnectTab.web => _buildWebPane(context),
            _ConnectTab.token => _buildPatPane(context),
          },
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
        if (_fallbackDeviceId) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.githubDeviceFallbackWarn,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
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

  Widget _buildWebPane(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.githubBrowserHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!_webLaunched) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              _webLaunched = false;
              _openWebAuthorize();
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(l10n.githubBrowserOpen),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _webCodeController,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: l10n.githubBrowserCodeHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _connectWithBrowser(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _connectWithBrowser,
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
}
