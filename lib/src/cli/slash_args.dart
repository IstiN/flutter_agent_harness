// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared slash-command argument parsing (`/skills`, `/tools`, ...).
library;

/// Splits a slash-command [rest] into its subcommand token and the
/// remaining positional parts (`"/skills access ask"` → `('access',
/// ['access', 'ask'])`; an empty rest yields `('', [])`).
(String sub, List<String> parts) splitSlashArgs(String rest) {
  final parts = rest
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  return (parts.isEmpty ? '' : parts.first, parts);
}
