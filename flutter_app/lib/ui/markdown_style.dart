import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:fa/ui/app_theme.dart';

/// The app's shared [MarkdownStyleSheet]: theme text with the landing
/// palette's teal links, mono inline code, and bordered code blocks /
/// quotes — resolved per brightness, so the light theme gets the light
/// palette. Used by the chat transcript and the file browser's Markdown
/// preview so both render Markdown identically.
MarkdownStyleSheet fahMarkdownStyleSheet(ThemeData theme) {
  final isLight = theme.brightness == Brightness.light;
  final teal = isLight ? FahLightPalette.teal : FahPalette.teal;
  final indigo = isLight ? FahLightPalette.indigo : FahPalette.indigo;
  final panelAlt = isLight ? FahLightPalette.panelAlt : FahPalette.panelAlt;
  final border = isLight ? FahLightPalette.border : FahPalette.border;
  final codeBg = isLight ? FahLightPalette.codeBg : FahPalette.codeBg;
  final codeStyle = isLight ? FahLightPalette.mono() : FahPalette.mono();
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    a: TextStyle(color: teal),
    code: codeStyle.copyWith(backgroundColor: codeBg),
    codeblockDecoration: BoxDecoration(
      color: panelAlt,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: border),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: indigo, width: 3)),
    ),
  );
}
