import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'html_preview_document.dart';

/// Mobile/desktop HTML preview: a [WebViewWidget] fed the file's markup.
///
/// Selected unless `dart.library.html` is available (see the conditional
/// import in `file_preview.dart`). The markup is pre-processed by
/// [lightCanvasDocument] so unstyled pages stay readable against the app's
/// dark theme.
///
/// The webview plugin needs a registered platform implementation, which
/// host widget tests do not have — tests inject a fake
/// `HtmlPreviewBuilder` instead of constructing this widget.
class HtmlFilePreview extends StatefulWidget {
  const HtmlFilePreview({super.key, required this.html});

  /// The HTML markup to render.
  final String html;

  @override
  State<HtmlFilePreview> createState() => _HtmlFilePreviewState();
}

class _HtmlFilePreviewState extends State<HtmlFilePreview> {
  late final WebViewController _controller = WebViewController()
    // Local file rendering: scripts run so pages render close to a
    // browser, but main-frame navigation away from the previewed document
    // is blocked — the preview must not turn into a browser.
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          // Allow the initial about:blank/data: load that loadHtmlString
          // performs; prevent links/redirects to anything else.
          final url = request.url;
          if (url == 'about:blank' || url.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ),
    )
    ..loadHtmlString(lightCanvasDocument(widget.html));

  @override
  void didUpdateWidget(HtmlFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _controller.loadHtmlString(lightCanvasDocument(widget.html));
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
