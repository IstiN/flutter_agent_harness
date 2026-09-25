// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_session_manager.dart';

/// Opens the sign-in dialog (issue #955 iteration 2): login + password →
/// [NetworkSessionManager.signIn] (the dev-login mock while the OAuth
/// flow is pending). On success the manager holds the JWT in memory for
/// the rest of the app run.
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

/// The sign-in form: login + password, the server's error message on
/// failure, a busy spinner while the request is in flight.
class SignInDialog extends StatefulWidget {
  const SignInDialog({super.key, required this.manager});

  /// The session manager receiving the JWT on success.
  final NetworkSessionManager manager;

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final login = _loginController.text.trim();
    final password = _passwordController.text;
    if (login.isEmpty || password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.manager.signIn(login: login, password: password);
      if (mounted) Navigator.of(context).pop();
    } on FaNetworkException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final error = _error;
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
          TextField(
            key: const ValueKey('signInLogin'),
            controller: _loginController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.l10n.networkLoginLabel,
              isDense: true,
            ),
            onSubmitted: (_) => unawaited(_signIn()),
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
            onSubmitted: (_) => unawaited(_signIn()),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error,
              key: const ValueKey('signInError'),
              style: TextStyle(color: colors.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(context.l10n.commonCancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('signInSubmit'),
                onPressed: _busy ? null : () => unawaited(_signIn()),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.networkSignInTitle),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
