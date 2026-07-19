/// Shared pre-processing for HTML file previews (used by
/// `html_preview_web.dart` and `html_preview_stub.dart`).
library;

/// Injected ahead of the previewed document so unstyled pages render on a
/// light canvas even though the app itself is dark: the iframe/webview
/// propagates the app's dark color-scheme, which leaves default (dark)
/// text on a dark background. Being first, the document's own styles still
/// win (equal specificity, later rule wins); `color-scheme: light` keeps
/// UA defaults — text color, form controls, scrollbars — light.
const String lightCanvasStyle =
    '<style>html{background:#fff;color-scheme:light}</style>';

/// Returns [html] with [lightCanvasStyle] injected — right after the
/// doctype when one is present (anything before a doctype switches the
/// document into quirks mode), at the very start otherwise.
String lightCanvasDocument(String html) {
  final trimmed = html.trimLeft();
  if (trimmed.length >= 9 &&
      trimmed.substring(0, 9).toLowerCase() == '<!doctype') {
    final close = trimmed.indexOf('>');
    if (close != -1) {
      final offset = html.length - trimmed.length + close + 1;
      return '${html.substring(0, offset)}$lightCanvasStyle'
          '${html.substring(offset)}';
    }
  }
  return '$lightCanvasStyle$html';
}
