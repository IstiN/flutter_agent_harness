// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_session_manager.dart';

/// Opens the sign-in dialog (issue #955 iteration 3): OAuth provider
/// buttons driven by `GET /api/oauth-proxy/providers` (falling back to
/// the known four), each running the real loopback flow via
/// [NetworkSessionManager.signInWithProvider], plus a collapsed
/// developer section with the local-only dev login.
Future<void> showSignInDialog(
  BuildContext context, {
  required NetworkSessionManager manager,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SignInDialog(manager: manager),
      ),
    ),
  );
}

/// The sign-in form: provider buttons (or the mobile note on
/// iOS/Android — the `fa://` redirect is not allowlisted server-side
/// yet), the developer login form, the server's error message on
/// failure, and busy indicators while a flow is in flight.
class SignInDialog extends StatefulWidget {
  const SignInDialog({super.key, required this.manager});

  /// The session manager receiving the JWT on success.
  final NetworkSessionManager manager;

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  /// The providers shown when `GET /api/oauth-proxy/providers` fails or
  /// answers empty — the four this deploy supports.
  static const _knownProviders = ['google', 'github', 'microsoft', 'apple'];

  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();

  /// null = the provider list is still loading.
  List<String>? _providers;

  String? _error;
  String? _busyProvider;
  bool _devBusy = false;

  /// Provider sign-in needs the loopback listener; on iOS/Android the
  /// `fa://` custom-scheme redirect is not allowlisted server-side yet,
  /// so only the developer section works there.
  bool get _mobileOnly =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProviders());
  }

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadProviders() async {
    List<String> providers;
    try {
      providers = await widget.manager.oauthProviders();
    } on Object {
      providers = const [];
    }
    if (!mounted) return;
    setState(
      () => _providers = providers.isEmpty ? _knownProviders : providers,
    );
  }

  Future<void> _signInWithProvider(String provider) async {
    setState(() {
      _busyProvider = provider;
      _error = null;
    });
    try {
      await widget.manager.signInWithProvider(provider);
      if (mounted) Navigator.of(context).pop();
    } on FaNetworkException catch (e) {
      _fail(e.message);
    } on AuthFlowException catch (e) {
      _fail(e.message);
    } on Object catch (e) {
      _fail('$e');
    }
  }

  Future<void> _devSignIn() async {
    final login = _loginController.text.trim();
    final password = _passwordController.text;
    if (login.isEmpty || password.isEmpty) return;
    setState(() {
      _devBusy = true;
      _error = null;
    });
    try {
      await widget.manager.signIn(login: login, password: password);
      if (mounted) Navigator.of(context).pop();
    } on FaNetworkException catch (e) {
      _fail(e.message, dev: true);
    } on Object catch (e) {
      _fail('$e', dev: true);
    }
  }

  void _fail(String message, {bool dev = false}) {
    if (!mounted) return;
    setState(() {
      _error = message;
      if (dev) {
        _devBusy = false;
      } else {
        _busyProvider = null;
      }
    });
  }

  String _providerLabel(String provider) => switch (provider) {
    'google' => 'Google',
    'github' => 'GitHub',
    'microsoft' => 'Microsoft',
    'apple' => 'Apple',
    _ when provider.isNotEmpty =>
      provider[0].toUpperCase() + provider.substring(1),
    _ => provider,
  };

  IconData _providerIcon(String provider) => switch (provider) {
    'google' => Icons.g_mobiledata,
    'github' => Icons.code,
    'microsoft' => Icons.window,
    'apple' => Icons.apple,
    _ => Icons.account_circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final error = _error;
    final busyProvider = _busyProvider;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.networkSignInTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.networkSignInHelper,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.dim),
          ),
          const SizedBox(height: 12),
          if (_mobileOnly)
            Text(
              context.l10n.networkSignInMobileNote,
              key: const ValueKey('signInMobileNote'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.dim),
            )
          else
            ..._buildProviders(context, busyProvider),
          if (busyProvider != null) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.networkSignInWaiting,
              key: const ValueKey('signInWaiting'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error,
              key: const ValueKey('signInError'),
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          _buildDeveloperSection(context),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: (busyProvider == null && !_devBusy)
                  ? () => Navigator.of(context).pop()
                  : null,
              child: Text(context.l10n.commonCancel),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildProviders(BuildContext context, String? busyProvider) {
    final providers = _providers;
    if (providers == null) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    return [
      for (final provider in providers)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            key: ValueKey('provider_$provider'),
            onPressed: busyProvider == null
                ? () => unawaited(_signInWithProvider(provider))
                : null,
            icon: busyProvider == provider
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_providerIcon(provider)),
            label: Text(
              context.l10n.networkSignInWithProvider(_providerLabel(provider)),
            ),
          ),
        ),
    ];
  }

  Widget _buildDeveloperSection(BuildContext context) {
    return ExpansionTile(
      key: const ValueKey('signInDevSection'),
      tilePadding: EdgeInsets.zero,
      title: Text(
        context.l10n.networkSignInDeveloperSection,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      children: [
        TextField(
          key: const ValueKey('signInLogin'),
          controller: _loginController,
          decoration: InputDecoration(
            labelText: context.l10n.networkLoginLabel,
            isDense: true,
          ),
          onSubmitted: (_) => unawaited(_devSignIn()),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('signInPassword'),
          controller: _passwordController,
          obscureText: true,
          decoration: InputDecoration(
            labelText: context.l10n.networkPasswordLabel,
            isDense: true,
          ),
          onSubmitted: (_) => unawaited(_devSignIn()),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('signInSubmit'),
            onPressed: _devBusy ? null : () => unawaited(_devSignIn()),
            child: _devBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.networkSignInTitle),
          ),
        ),
      ],
    );
  }
}
