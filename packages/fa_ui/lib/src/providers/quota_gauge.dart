// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The per-provider quota gauge trailing a [ProvidersSection] row (issue
/// #823): a thin usage bar plus a `used/limit · reset` line for metered
/// providers, a silent `unmetered` label, `…` on a cold cache, and
/// `unknown (reason)` for a failed fetch — never a crash, never a null
/// literal.
///
/// Render-only: every read goes through the service's synchronous
/// [ProviderQuotaService.peek]; a cold peek kicks the service's own
/// background refresh, and this widget repaints when the `changes` stream
/// announces the completed fetch. It never fetches on the UI path.
library;

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

class QuotaGauge extends StatelessWidget {
  const QuotaGauge({
    super.key,
    required this.service,
    required this.providerId,
  });

  /// The quota cache to render from (peek-only).
  final ProviderQuotaService service;

  /// The quota key for this row ('openrouter', 'codemie', 'dial', or an
  /// on-device provider kind).
  final String providerId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 11,
    );
    return StreamBuilder<void>(
      stream: service.changes,
      builder: (context, _) {
        final result = service.peek(providerId);
        // Cold cache (null) — the peek already kicked a background refresh;
        // the changes stream repaints this widget when it lands.
        if (result == null) {
          return Text('…', style: style);
        }
        final quota = result.quota;
        if (quota == null) {
          return Text('unknown (${result.reason})', style: style);
        }
        if (quota.isUnmetered) {
          return Text('unmetered', style: style);
        }
        final limit = quota.limit;
        final used = quota.used;
        final fraction =
            (limit != null && limit > 0 && used != null)
            ? (used / limit).clamp(0.0, 1.0)
            : null;
        final reset = formatQuotaReset(quota.resetsAt, DateTime.now());
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${formatQuotaUsedLimit(quota)}'
              '${reset.isEmpty ? '' : ' · $reset'}',
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
            if (fraction != null) ...[
              const SizedBox(height: 3),
              SizedBox(
                width: 72,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
