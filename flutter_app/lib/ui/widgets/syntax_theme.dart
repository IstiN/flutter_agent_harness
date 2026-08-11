import 'package:flutter/material.dart';
import 'package:fa_ui/fa_ui.dart';

/// Maps re_highlight scope names to [FahPalette]-based colors for the
/// dark theme. Keys are the CSS-class-like scope strings highlight.js
/// uses: `keyword`, `string`, `comment`, `number`, `title`, `built_in`,
/// `literal`, `meta`, `attr`, `variable`, `type`, `symbol`, `regexp`.
///
/// The app is primarily dark-themed, so [FahPalette] is used regardless
/// of [brightness]; the optional param is kept for future use.
Map<String, TextStyle> syntaxTheme([Brightness? brightness]) {
  // The app is primarily dark-themed — use FahPalette for both.
  final indigo = FahPalette.indigo;
  final teal = FahPalette.teal;
  final dim = FahPalette.dim;
  final text = FahPalette.text;

  return {
    'keyword': TextStyle(color: indigo, fontWeight: FontWeight.w600),
    'string': TextStyle(color: teal),
    'comment': TextStyle(color: dim, fontStyle: FontStyle.italic),
    'number': TextStyle(color: teal),
    'literal': TextStyle(color: indigo),
    'title': TextStyle(color: text, fontWeight: FontWeight.w600),
    'function': TextStyle(color: indigo),
    'built_in': TextStyle(color: teal),
    'type': TextStyle(color: indigo),
    'class': TextStyle(color: teal),
    'attr': TextStyle(color: teal),
    'variable': TextStyle(color: text),
    'meta': TextStyle(color: dim),
    'symbol': TextStyle(color: teal),
    'regexp': TextStyle(color: teal),
    'property': TextStyle(color: teal),
    'params': TextStyle(color: text),
    'operator': TextStyle(color: indigo),
    'punctuation': TextStyle(color: dim),
  };
}
