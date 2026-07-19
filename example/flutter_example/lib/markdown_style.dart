import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'app_theme.dart';

/// The app's shared [MarkdownStyleSheet]: dark-theme text with the landing
/// palette's teal links, mono inline code, and bordered code blocks /
/// quotes. Used by the chat transcript and the file browser's Markdown
/// preview so both render Markdown identically.
MarkdownStyleSheet fahMarkdownStyleSheet(ThemeData theme) {
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    a: const TextStyle(color: FahPalette.teal),
    code: FahPalette.mono().copyWith(backgroundColor: FahPalette.codeBg),
    codeblockDecoration: BoxDecoration(
      color: FahPalette.panelAlt,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: FahPalette.border),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: FahPalette.indigo, width: 3)),
    ),
  );
}
