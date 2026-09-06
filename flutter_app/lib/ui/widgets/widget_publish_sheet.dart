// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/github_connect_sheet.dart';

/// Opens the "Publish widget" sheet (issue #35, card §Publish flow):
/// pre-flight first (issues listed with fix hints, publish disabled),
/// then repo name → [service.publish] → success with the PR link. The
/// submission itself is recorded by the service into [ledger].
///
/// Requires a connected [account] — when disconnected the sheet offers a
/// "Connect GitHub" button that opens the connect sheet and resumes.
Future<void> showWidgetPublishSheet(
  BuildContext context, {
  required JsAppInfo app,
  required GithubAccountStore account,
  required WidgetPublishService service,
  required WidgetPublicationStore ledger,
  GithubApiClient Function(String token)? clientFactory,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => WidgetPublishSheet(
      app: app,
      account: account,
      service: service,
      ledger: ledger,
      clientFactory: clientFactory,
    ),
  );
}

/// The publish sheet body (also embeddable in tests).
class WidgetPublishSheet extends StatefulWidget {
  const WidgetPublishSheet({
    super.key,
    required this.app,
    required this.account,
    required this.service,
    required this.ledger,
    this.clientFactory,
  });

  final JsAppInfo app;
  final GithubAccountStore account;
  final WidgetPublishService service;
  final WidgetPublicationStore ledger;

  /// Test hook forwarded to the connect sheet.
  final GithubApiClient Function(String token)? clientFactory;

  @override
  State<WidgetPublishSheet> createState() => _WidgetPublishSheetState();
}

class _WidgetPublishSheetState extends State<WidgetPublishSheet> {
  late final TextEditingController _repoController = TextEditingController(
    text: 'fa-widget-${widget.app.id}',
  );

  /// Null while pre-flight runs.
  List<WidgetPreflightIssue>? _issues;

  bool _publishing = false;
  String? _error;
  WidgetPublishResult? _result;

  @override
  void initState() {
    super.initState();
    _runPreflight();
  }

  @override
  void dispose() {
    _repoController.dispose();
    super.dispose();
  }

  Future<void> _runPreflight() async {
    try {
      final issues = await widget.service.preflight(widget.app);
      if (mounted) setState(() => _issues = issues);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _issues = const [];
          _error = error.toString();
        });
      }
    }
  }

  bool get _canPublish {
    final issues = _issues;
    return widget.account.isConnected &&
        issues != null &&
        issues.isEmpty &&
        _repoController.text.trim().isNotEmpty &&
        !_publishing &&
        _result == null;
  }

  Future<void> _connect() async {
    final connected = await showGithubConnectSheet(
      context,
      account: widget.account,
      clientFactory: widget.clientFactory,
    );
    if (connected == true && mounted) setState(() {});
  }

  Future<void> _publish() async {
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      final result = await widget.service.publish(
        app: widget.app,
        repoName: _repoController.text.trim(),
      );
      if (mounted) {
        setState(() {
          _publishing = false;
          _result = result;
        });
      }
    } on GithubApiException catch (error) {
      if (mounted) {
        setState(() {
          _publishing = false;
          _error = error.message;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _publishing = false;
          _error = error.toString();
        });
      }
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
            l10n.publishWidgetTitle(widget.app.name),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_result != null)
            _buildSuccess(context)
          else ...[
            _buildPreflight(context),
            const SizedBox(height: 12),
            if (!widget.account.isConnected)
              FilledButton.tonal(
                onPressed: _connect,
                child: Text(l10n.githubConnect),
              )
            else ...[
              TextField(
                controller: _repoController,
                decoration: InputDecoration(
                  labelText: l10n.publishRepoNameLabel,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _canPublish ? _publish : null,
                child: _publishing
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(l10n.publishInProgress),
                        ],
                      )
                    : Text(l10n.publishButton),
              ),
            ],
          ],
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

  Widget _buildPreflight(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final issues = _issues;
    if (issues == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (issues.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.publishPreflightFailed,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 8),
        for (final issue in issues)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(issue.message, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSuccess(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 20),
            const SizedBox(width: 8),
            Text(l10n.publishSuccess, style: theme.textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          _result!.prUrl,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.publishDone),
        ),
      ],
    );
  }
}
