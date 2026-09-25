// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';

/// Opens the join-network sheet: a dialog on wide layouts, a modal bottom
/// sheet on narrow ones. All state lives inside the sheet — a kill/resume
/// mid-flow leaves nothing half-enrolled (the join is ONE call).
Future<void> showJoinSheet(
  BuildContext context, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
  String? initialNetworkId,
}) {
  final wide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: JoinSheet(
            controller: controller,
            manager: manager,
            initialNetworkId: initialNetworkId,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: JoinSheet(
        controller: controller,
        manager: manager,
        initialNetworkId: initialNetworkId,
      ),
    ),
  );
}

/// The join-network form (issue #955): a network id + password + display
/// name, or a pasted join link (`https://…/join?network=…#pw=…`) that
/// prefills id + password. With a JWT set, the display name is locked to
/// the account (the server decides) and the field hides.
class JoinSheet extends StatefulWidget {
  const JoinSheet({
    super.key,
    required this.controller,
    required this.manager,
    this.initialNetworkId,
  });

  /// The mode controller — a successful join enters the network.
  final NetworkModeController controller;

  /// The session manager performing the join.
  final NetworkSessionManager manager;

  /// Prefills the network id (the public-directory's Join button) and
  /// focuses the password field — the id is known, the password is not.
  final String? initialNetworkId;

  @override
  State<JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<JoinSheet> {
  final _linkController = TextEditingController();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  late final TextEditingController _nameController;

  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.manager.wallet.displayName,
    );
    final initialId = widget.initialNetworkId;
    if (initialId != null) _idController.text = initialId;
  }

  @override
  void dispose() {
    _linkController.dispose();
    _idController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Fills id + password from a pasted network join link. The fragment
  /// (password) is optional — the user can still type it manually.
  void _fillFromLink() {
    try {
      final link = parseNetworkJoinLink(_linkController.text);
      setState(() {
        _idController.text = link.networkId;
        if (link.password != null) _passwordController.text = link.password!;
        _error = null;
      });
    } on InviteFormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _join() async {
    final networkId = _idController.text.trim();
    final password = _passwordController.text;
    final displayName = _nameController.text.trim();
    if (networkId.isEmpty || password.isEmpty) {
      setState(() => _error = context.l10n.networkJoinRequired);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!widget.manager.wallet.hasIdentity) {
        await widget.manager.ensureIdentity(displayName: displayName);
      }
      await widget.manager.join(
        networkId: networkId,
        password: password,
        displayName: widget.manager.hasJwt ? null : displayName,
      );
      await widget.controller.enterNetwork(networkId);
      if (mounted) Navigator.of(context).pop();
    } on FaNetworkException catch (e) {
      final retry = e.retryAfterSeconds;
      setState(() {
        _busy = false;
        _error = e.code == 'invalid_credentials'
            ? context.l10n.networkJoinInvalidCredentials(e.message) +
                  (retry != null
                      ? context.l10n.networkJoinRetryAfter(retry)
                      : '')
            : e.message;
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
            context.l10n.networkJoinTitle,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _linkController,
                  decoration: InputDecoration(
                    labelText: context.l10n.networkJoinLinkLabel,
                    hintText: 'https://…/join?network=…#pw=…', // l10n:ignore
                    isDense: true,
                  ),
                  onSubmitted: (_) => _fillFromLink(),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _fillFromLink,
                child: Text(context.l10n.networkJoinFill),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _idController,
            decoration: InputDecoration(
              labelText: context.l10n.networkIdLabel,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            // A prefilled id (the public directory's Join) lands the caret
            // straight on the password — the only thing left to type.
            autofocus: widget.initialNetworkId != null,
            decoration: InputDecoration(
              labelText: context.l10n.networkPasswordLabel,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          if (widget.manager.hasJwt)
            Text(
              context.l10n.networkDisplayNameLocked,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.dim),
            )
          else
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: context.l10n.networkDisplayNameLabel,
                isDense: true,
              ),
            ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error,
              key: const ValueKey('joinError'),
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
                onPressed: _busy ? null : () => unawaited(_join()),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.networkJoin),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
