// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';

/// The shared list-section label: dim sentence-case eyebrow used by the
/// chat list (Pinned/Recent), the Activity toolbar and the Apps directory.
/// Keeping one widget stops sidebar headings from drifting in typography
/// or letter case.
final class FaSectionEyebrow extends StatelessWidget {
  const FaSectionEyebrow({
    super.key,
    required this.label,
    this.padding = const EdgeInsets.fromLTRB(12, 11, 10, 3),
  });

  final String label;

  /// Zero padding keeps the eyebrow usable inside toolbar rows.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: FaDesignTokens.of(context).ink2,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: .2,
        ),
      ),
    );
  }
}
