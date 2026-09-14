/// The `/model` picker as a table (issue #278): model id, provider,
/// context window and $/Mtok columns, current-model marker, sorted by
/// recency then price, with a narrow-terminal elision order.
///
/// Pure Dart over [ModelRowSpec] values — the caller (provider_models.dart)
/// resolves the numbers from the resolved catalogs (remote catalog +
/// endpoint report + provider spec); nothing here hardcodes a window or a
/// price (E3: a model without pricing renders `—`, never 0.00).
library;

import 'tui_repl.dart';

/// One model row the picker will render, with its resolved metadata.
final class ModelRowSpec {
  const ModelRowSpec({
    required this.provider,
    required this.modelId,
    required this.recency,
    this.contextWindow,
    this.cost,
    this.isCurrent = false,
  });

  /// Provider display name (the menu key encodes `provider|modelId`).
  final String provider;

  /// The model id sent to the provider.
  final String modelId;

  /// Recency rank: lower = more recent. The candidate list already orders
  /// newest-first (live `/v1/models` order, catalog author intent), so the
  /// rank is the source index — the sort keeps that order and uses price
  /// only to break exact ties.
  final int recency;

  /// Resolved total context window in tokens (null = unknown → `—`).
  final int? contextWindow;

  /// Resolved input/output $/Mtok (null = catalog ships no pricing → `—`).
  final ({double input, double output})? cost;

  /// Whether this is the active model (rendered with the `●` marker).
  final bool isCurrent;
}

/// Recency-then-price order: recency rank first (source order — newest
/// first), cheaper total $/Mtok breaking exact recency ties, unpriced rows
/// last among equal recency.
int compareModelRowsByRecencyThenPrice(ModelRowSpec a, ModelRowSpec b) {
  if (a.recency != b.recency) return a.recency.compareTo(b.recency);
  final ca = a.cost;
  final cb = b.cost;
  if (ca == null && cb == null) return 0;
  if (ca == null) return 1;
  if (cb == null) return -1;
  return (ca.input + ca.output).compareTo(cb.input + cb.output);
}

/// Builds the picker rows for [rows] at terminal [width].
///
/// Column layout: `marker id | provider | ctx | cost` (id left-aligned,
/// ctx/cost right-aligned, two-space gaps). On narrow terminals the
/// elision order is cost first, then provider (AC2) — id, marker and ctx
/// always stay.
List<MenuItem> buildModelPickerTable(List<ModelRowSpec> rows, int width) {
  final sorted = [...rows]..sort(compareModelRowsByRecencyThenPrice);
  var showCost = true;
  var showProvider = true;
  while (_tableWidth(sorted, showProvider, showCost) > width - 2) {
    if (showCost) {
      showCost = false; // cost elides first (AC2)
    } else if (showProvider) {
      showProvider = false; // then provider
    } else {
      break; // id + ctx are the floor; the menu row truncates the rest
    }
  }
  final idWidth = sorted.isEmpty
      ? 0
      : sorted.map((r) => r.modelId.length).reduce(_max);
  final providerWidth = !showProvider || sorted.isEmpty
      ? 0
      : sorted.map((r) => r.provider.length).reduce(_max);
  final ctxWidth = sorted.isEmpty
      ? 0
      : sorted
            .map((r) => formatModelContextWindow(r.contextWindow).length)
            .reduce(_max);
  final costWidth = !showCost || sorted.isEmpty
      ? 0
      : sorted.map((r) => formatModelCost(r.cost).length).reduce(_max);
  return [
    for (final row in sorted)
      MenuItem(
        key: '${row.provider}|${row.modelId}',
        label:
            '${row.isCurrent ? '● ' : '  '}${row.modelId.padRight(idWidth)}',
        description: _rowDetails(
          row,
          providerWidth: providerWidth,
          ctxWidth: ctxWidth,
          costWidth: costWidth,
        ),
      ),
  ];
}

int _max(int a, int b) => a > b ? a : b;

/// Widest rendered row: selection prefix (2) + id column + gaps + the
/// shown detail columns.
int _tableWidth(List<ModelRowSpec> rows, bool showProvider, bool showCost) {
  if (rows.isEmpty) return 0;
  var width = rows.map((r) => r.modelId.length).reduce(_max) + 2;
  if (showProvider) {
    width += 2 + rows.map((r) => r.provider.length).reduce(_max);
  }
  width += 2 + rows
        .map((r) => formatModelContextWindow(r.contextWindow).length)
        .reduce(_max);
  if (showCost) {
    width += 2 + rows.map((r) => formatModelCost(r.cost).length).reduce(_max);
  }
  return width;
}

/// The dim detail block after the id column: provider (left), context
/// window and cost (right-aligned fixed columns). Empty when nothing but
/// the ctx column survives.
String _rowDetails(
  ModelRowSpec row, {
  required int providerWidth,
  required int ctxWidth,
  required int costWidth,
}) {
  final buffer = StringBuffer();
  if (providerWidth > 0) buffer.write(row.provider.padRight(providerWidth));
  buffer.write('  ');
  buffer.write(
    formatModelContextWindow(row.contextWindow).padLeft(ctxWidth),
  );
  if (costWidth > 0) {
    buffer.write('  ');
    buffer.write(formatModelCost(row.cost).padLeft(costWidth));
  }
  return buffer.toString();
}

/// Formats a token count like the context presets (`1M`, `200K`, `128000`);
/// null (unresolved) renders `—`.
String formatModelContextWindow(int? tokens) {
  if (tokens == null) return '—';
  if (tokens >= 1048576 && tokens % 1048576 == 0) {
    return '${tokens ~/ 1048576}M';
  }
  if (tokens >= 1024 && tokens % 1024 == 0) {
    return '${tokens ~/ 1024}K';
  }
  return '$tokens';
}

/// Formats input/output $/Mtok (`$0.30/$1.20`); null pricing renders `—`
/// — never 0.00, which would read as "free" (E3).
String formatModelCost(({double input, double output})? cost) {
  final c = cost;
  if (c == null) return '—';
  return '\$${c.input.toStringAsFixed(2)}/\$${c.output.toStringAsFixed(2)}';
}

/// The one-line hint under the model table (footer row).
const modelPickerFooterHint =
    '↑/↓ select · enter switch · type to filter · esc close';
