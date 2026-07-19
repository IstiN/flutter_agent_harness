import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import 'html_preview_document.dart';

/// Browser HTML preview: an `<iframe>` fed the file's markup via `srcdoc`,
/// registered as a platform view. Selected when `dart.library.html` is
/// available (see the conditional import in `file_preview.dart`).
///
/// The markup is pre-processed by [lightCanvasDocument] so unstyled pages
/// stay readable against the app's dark theme.
///
/// The `sandbox` attribute keeps the previewed document contained: scripts
/// may run so pages render close to a browser, but the frame cannot
/// navigate the top window, open popups, submit forms, or touch the app's
/// same-origin storage (the web sandbox filesystem lives in IndexedDB).
class HtmlFilePreview extends StatefulWidget {
  const HtmlFilePreview({super.key, required this.html});

  /// The HTML markup to render.
  final String html;

  @override
  State<HtmlFilePreview> createState() => _HtmlFilePreviewState();
}

int _nextViewId = 0;

class _HtmlFilePreviewState extends State<HtmlFilePreview> {
  late final String _viewType = 'fah-html-preview-${_nextViewId++}';

  late final html.IFrameElement _iframe = html.IFrameElement()
    ..style.border = '0'
    ..style.width = '100%'
    ..style.height = '100%'
    ..setAttribute('sandbox', 'allow-scripts')
    ..srcdoc = lightCanvasDocument(widget.html);

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _iframe,
    );
  }

  @override
  void didUpdateWidget(HtmlFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _iframe.srcdoc = lightCanvasDocument(widget.html);
    }
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
