// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared slash-command argument parsing (`/skills`, `/tools`, ...).
library;

/// Splits a slash-command [rest] into its subcommand token and the
/// positional tail *excluding* the subcommand (`"/skills access ask"` →
/// `(sub: 'access', args: ['ask'])`; a bare `/skills` yields
/// `(sub: '', args: [])`).
({String sub, List<String> args}) splitSlashArgs(String rest) {
  final parts = rest
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return (sub: '', args: const []);
  return (sub: parts.first, args: parts.sublist(1));
}
