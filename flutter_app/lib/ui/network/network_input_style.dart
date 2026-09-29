// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The unified text-field look for network surfaces: the same borderless
/// pill the session composer uses (`ChatComposer` in fa_ui), so join and
/// sign-in inputs rhyme with the chat the user just came from.
library;

import 'package:flutter/material.dart';

const _pillBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(24)),
  borderSide: BorderSide.none,
);

/// Borderless, filled, radius-24 input; [hint] replaces the old floating
/// labelText (labels render as placeholders, matching the composer).
InputDecoration networkInputDecoration({required String hint}) =>
    InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: _pillBorder,
      enabledBorder: _pillBorder,
      focusedBorder: _pillBorder,
    );
