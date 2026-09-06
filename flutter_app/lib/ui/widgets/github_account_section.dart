// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/github_connect_sheet.dart';
import 'package:fa/ui/widgets/widget_publications_sheet.dart';

/// The shared app-wide GitHub account store for widget publishing.
///
/// No DI scope exists for the account store yet (the app wires
/// [SessionKeysScope] but nothing one level up), so the settings section
/// and the launcher/apps-panel menus all share this lazily created
/// instance — connect/disconnect from any surface propagates everywhere.
GithubAccountStore sharedGithubAccountStore(SessionKeysStore keys) =>
    _shared ??= GithubAccountStore(keys: keys);
GithubAccountStore? _shared;

/// The settings "GitHub account" section (issue #35, card §Connect
/// GitHub): connected → avatar + login + Disconnect / My publications;
/// disconnected → hint + Connect. Service-independent (the store resolves
/// from [SessionKeysScope]), so it renders without an active agent
/// service, like [DapHubSection].
class GithubAccountSection extends StatelessWidget {
  const GithubAccountSection({
    super.key,
    this.store,
    this.ledger,
    this.publishService,
    this.clientFactory,
  });

  /// Store override (tests); falls back to [sharedGithubAccountStore]
  /// resolved from the nearest [SessionKeysScope].
  final GithubAccountStore? store;

  /// Ledger override for the "My publications" sheet; falls back to
  /// [sharedWidgetPublicationStore].
  final WidgetPublicationStore? ledger;

  /// Status refresher for the publications sheet (null = read-only).
  final WidgetPublishService? publishService;

  /// Test hook forwarded to the connect sheet.
  final GithubApiClient Function(String token)? clientFactory;

  GithubAccountStore? _resolveStore(BuildContext context) {
    if (store != null) return store;
    final keys = SessionKeysScope.maybeOf(context);
    return keys == null ? null : sharedGithubAccountStore(keys);
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolveStore(context);
    if (resolved == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: resolved,
      builder: (context, _) => resolved.isConnected
          ? _buildConnected(context, resolved)
          : _buildDisconnected(context, resolved),
    );
  }

  Widget _buildDisconnected(BuildContext context, GithubAccountStore store) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.githubAccountSection, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          l10n.githubAccountHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () => unawaited(
            showGithubConnectSheet(
              context,
              account: store,
              clientFactory: clientFactory,
            ),
          ),
          child: Text(l10n.githubConnect),
        ),
      ],
    );
  }

  Widget _buildConnected(BuildContext context, GithubAccountStore store) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final avatarUrl = store.avatarUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.githubAccountSection, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              child: avatarUrl == null
                  ? const Icon(Icons.person, size: 18)
                  : ClipOval(
                      child: Image.network(
                        avatarUrl,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        // Never crash offline / on a dead avatar host.
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.person, size: 18),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                store.login ?? '',
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => unawaited(_confirmDisconnect(context, store)),
              child: Text(l10n.githubDisconnect),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () => unawaited(
            showWidgetPublicationsSheet(
              context,
              ledger: ledger ?? sharedWidgetPublicationStore(),
              service: publishService,
            ),
          ),
          icon: const Icon(Icons.list_alt, size: 18),
          label: Text(l10n.myPublications),
        ),
      ],
    );
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    GithubAccountStore store,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.githubAccountSection),
        content: Text(l10n.githubDisconnectConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.githubDisconnect),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.disconnect();
  }
}
