// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_llm/fa_llm.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fa_ui/src/strings/fa_ui_strings.dart';

/// The host-injected Copilot auth chain. Every step is a function so tests
/// run the sheet without any network; the app wires the real fa_llm
/// device-flow functions.
class CopilotConnectCallbacks {
  /// Creates the callback bundle.
  const CopilotConnectCallbacks({
    required this.requestDeviceCode,
    required this.pollAccessToken,
    required this.fetchLogin,
  });

  /// Starts the GitHub OAuth device flow.
  final Future<CopilotDeviceCode> Function() requestDeviceCode;

  /// One full poll loop (authorization_pending / slow_down included) that
  /// resolves with the GitHub access token.
  final Future<String> Function(CopilotDeviceCode deviceCode) pollAccessToken;

  /// Resolves the GitHub login for a token (the default entry name seed).
  final Future<String> Function(String githubToken) fetchLogin;
}

/// What a completed Copilot connect hands back to the host.
class CopilotConnectResult {
  /// Creates the result.
  const CopilotConnectResult({
    required this.githubToken,
    required this.login,
    required this.entryName,
    required this.accountType,
    this.baseUrlOverride,
  });

  /// The GitHub access token (stored entry-scoped by the host, never the
  /// short-lived Copilot API token — that one the provider refreshes).
  final String githubToken;

  /// The GitHub login the token belongs to.
  final String login;

  /// Registry entry name; defaults to `copilot-<login>`.
  final String entryName;

  /// The picked Copilot plan.
  final CopilotAccountType accountType;

  /// Explicit base URL for the `Custom endpoint` plan; null when the
  /// account type default applies.
  final String? baseUrlOverride;
}

/// Runs the GitHub Copilot connect flow as a modal bottom sheet:
/// device-flow sign-in (or paste an existing GitHub token), then plan +
/// entry name. Reports [CopilotConnectResult] through [onResult] once the
/// user finishes; dismissing the sheet at any point (including mid-poll)
/// reports nothing and pops cleanly.
Future<void> showCopilotConnectSheet({
  required BuildContext context,
  required CopilotConnectCallbacks callbacks,
  required ValueChanged<CopilotConnectResult> onResult,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _CopilotConnectSheet(callbacks: callbacks, onResult: onResult),
  );
}

enum _Step { start, waiting, form }

class _CopilotConnectSheet extends StatefulWidget {
  const _CopilotConnectSheet({required this.callbacks, required this.onResult});

  final CopilotConnectCallbacks callbacks;
  final ValueChanged<CopilotConnectResult> onResult;

  @override
  State<_CopilotConnectSheet> createState() => _CopilotConnectSheetState();
}

class _CopilotConnectSheetState extends State<_CopilotConnectSheet> {
  _Step _step = _Step.start;
  String? _error;
  bool _pastingToken = false;
  CopilotDeviceCode? _deviceCode;
  String _token = '';
  String _login = '';
  CopilotAccountType _accountType = CopilotAccountType.individual;
  bool _custom = false;
  final _tokenController = TextEditingController();
  final _entryNameController = TextEditingController();
  final _baseUrlController = TextEditingController();

  /// Builds the outcome; `Custom endpoint` rides [CopilotConnectResult.baseUrlOverride].
  CopilotConnectResult _buildResult() => CopilotConnectResult(
    githubToken: _token,
    login: _login,
    entryName: _entryNameController.text.trim(),
    accountType: _custom ? CopilotAccountType.individual : _accountType,
    baseUrlOverride: _custom ? _baseUrlController.text.trim() : null,
  );

  @override
  void dispose() {
    _tokenController.dispose();
    _entryNameController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _error = null;
      _step = _Step.waiting;
    });
    try {
      final deviceCode = await widget.callbacks.requestDeviceCode();
      if (!mounted) return;
      setState(() => _deviceCode = deviceCode);
      final token = await widget.callbacks.pollAccessToken(deviceCode);
      await _adoptToken(token);
    } on CopilotAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _step = _Step.start;
        _error = error is CopilotTokenExchangeException
            ? FaUiStrings.of(context).copilotEndpointDisabled
            : error.message;
      });
    }
  }

  Future<void> _adoptToken(String token) async {
    if (!mounted) return;
    String login;
    try {
      login = await widget.callbacks.fetchLogin(token);
    } on CopilotAuthException {
      // The token still works for Copilot even when /user is unavailable.
      login = '';
    }
    if (!mounted) return;
    setState(() {
      _token = token;
      _login = login;
      _entryNameController.text = login.isEmpty ? 'copilot' : 'copilot-$login';
      _step = _Step.form;
    });
  }

  Future<void> _openVerificationUri() async {
    final uri = _deviceCode?.verificationUri;
    if (uri == null) return;
    final launched = await launchUrl(
      Uri.parse(uri),
      mode: LaunchMode.externalApplication,
    );
    if (launched || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(FaUiStrings.of(context).copilotOpenManually)),
    );
  }

  void _finish() {
    widget.onResult(_buildResult());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final strings = FaUiStrings.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: switch (_step) {
        _Step.start => _buildStart(strings),
        _Step.waiting => _buildWaiting(strings),
        _Step.form => _buildForm(strings),
      },
    );
  }

  Widget _buildStart(FaUiStrings strings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.copilotSheetTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          onPressed: _pastingToken ? null : _signIn,
          icon: const Icon(Icons.login),
          label: Text(strings.copilotSignInButton),
        ),
        const SizedBox(height: 8),
        if (_pastingToken) ...[
          TextField(
            controller: _tokenController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: strings.copilotPasteTokenLabel,
            ),
            onSubmitted: (_) => _submitPastedToken(),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _submitPastedToken,
            child: Text(strings.copilotPasteTokenContinue),
          ),
        ] else
          TextButton(
            onPressed: () => setState(() => _pastingToken = true),
            child: Text(strings.copilotPasteTokenToggle),
          ),
      ],
    );
  }

  Future<void> _submitPastedToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _error = null;
      _step = _Step.waiting;
    });
    await _adoptToken(token);
  }

  Widget _buildWaiting(FaUiStrings strings) {
    final deviceCode = _deviceCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.copilotSheetTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (deviceCode == null)
          const Center(child: CircularProgressIndicator())
        else ...[
          Text(strings.copilotUserCodeHint(deviceCode.verificationUri)),
          const SizedBox(height: 8),
          Center(
            child: SelectableText(
              deviceCode.userCode,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openVerificationUri,
            icon: const Icon(Icons.open_in_new),
            label: Text(strings.copilotOpenVerification),
          ),
          const SizedBox(height: 12),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 8),
          Text(strings.copilotWaiting, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.copilotCancel),
        ),
      ],
    );
  }

  Widget _buildForm(FaUiStrings strings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.copilotSheetTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Text(strings.copilotPlanLabel),
        RadioGroup<CopilotAccountType>(
          groupValue: _custom ? null : _accountType,
          onChanged: (value) => setState(() {
            _custom = false;
            _accountType = value!;
          }),
          child: Column(
            children: [
              RadioListTile<CopilotAccountType>(
                title: Text(strings.copilotPlanIndividual),
                value: CopilotAccountType.individual,
              ),
              RadioListTile<CopilotAccountType>(
                title: Text(strings.copilotPlanBusiness),
                value: CopilotAccountType.business,
              ),
              RadioListTile<CopilotAccountType>(
                title: Text(strings.copilotPlanEnterprise),
                value: CopilotAccountType.enterprise,
              ),
            ],
          ),
        ),
        RadioGroup<bool>(
          groupValue: _custom,
          onChanged: (value) => setState(() => _custom = value ?? false),
          child: RadioListTile<bool>(
            title: Text(strings.copilotPlanCustom),
            value: true,
          ),
        ),
        if (_custom)
          TextField(
            controller: _baseUrlController,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: strings.copilotCustomBaseUrlLabel,
            ),
          ),
        TextField(
          controller: _entryNameController,
          decoration: InputDecoration(labelText: strings.copilotEntryNameLabel),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _finish,
          child: Text(strings.copilotConnectButton),
        ),
      ],
    );
  }
}
