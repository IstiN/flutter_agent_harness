// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:fa/ui/widgets/widget_publications_sheet.dart'
    show WidgetPublicationsSheet;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Out-of-view status polling (issue #35, background-polling invariant):
/// one refresh cycle of every PR-bearing publication when the app resumes
/// to the foreground — the "otherwise on app resume" half the card gives
/// the publications view. The in-view 5-minute cadence lives in
/// [WidgetPublicationsSheet]; this widget covers the sheet-closed case, so
/// a merged or closed catalog PR surfaces without the user opening
/// "My publications" first.
///
/// Boot never blocks: the observer only acts on the resume event, and a
/// cycle is throttled to one per [WidgetPublicationsSheet]
/// `.defaultPollInterval`. Silent no-op when nothing can poll (no env, no
/// session-keys scope, disconnected account, no PR in the ledger). When
/// the sheet IS open, its own observer fires too — the duplicate cycle is
/// idempotent (refreshStatus persists only on a real change).
class WidgetPublicationResumeRefresher extends StatefulWidget {
  const WidgetPublicationResumeRefresher({
    super.key,
    required this.child,
    this.env,
    this.clientFactory,
    this.ledger,
    this.store,
    this.clock,
  });

  final Widget child;

  /// The app sandbox the shared ledger resolves against — the app manager
  /// env. Null disables the observer entirely (tests, bare previews).
  final ExecutionEnv? env;

  /// Test hook forwarded to the on-demand publish service.
  final GithubApiClient Function(String token)? clientFactory;

  /// Ledger override (tests); falls back to the shared store initialized
  /// from [env].
  final WidgetPublicationStore? ledger;

  /// Account store override (tests); falls back to the shared store
  /// resolved from the nearest [SessionKeysScope].
  final GithubAccountStore? store;

  /// Injectable clock for the throttle (tests).
  final DateTime Function()? clock;

  @override
  State<WidgetPublicationResumeRefresher> createState() =>
      _WidgetPublicationResumeRefresherState();
}

class _WidgetPublicationResumeRefresherState
    extends State<WidgetPublicationResumeRefresher>
    with WidgetsBindingObserver {
  DateTime? _lastCycleStarted;

  @override
  void initState() {
    super.initState();
    if (widget.env != null) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshInBackground();
  }

  Future<void> _refreshInBackground() async {
    final env = widget.env;
    if (env == null) return;
    final now = (widget.clock ?? DateTime.now)();
    final last = _lastCycleStarted;
    if (last != null &&
        now.difference(last) < WidgetPublicationsSheet.defaultPollInterval) {
      return;
    }
    // Stamped before the network so rapid resume events never run two
    // cycles in parallel.
    _lastCycleStarted = now;
    final keys = SessionKeysScope.maybeOf(context);
    if (keys == null) return;
    final store = widget.store ?? sharedGithubAccountStore(keys);
    final token = store.token;
    if (token == null) return;
    final ledger = widget.ledger ?? await initSharedWidgetPublicationStore(env);
    if (!ledger.publications.any((p) => p.prNumber != null)) return;
    final service = WidgetPublishService(
      env: env,
      account: store,
      ledger: ledger,
      clientFactory: widget.clientFactory,
    );
    for (final publication in ledger.publications) {
      if (publication.prNumber == null) continue;
      try {
        await service.refreshStatus(publication);
      } on Object {
        // Offline / rate-limited: the record keeps its last-known state;
        // the next resume retries.
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
