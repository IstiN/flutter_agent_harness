import 'package:flutter/widgets.dart';

/// Reports the allotted size to a listener as it changes — the host side
/// of the js_widget_runtime viewport API (`jsr.viewport`/`jsr.onViewport`).
///
/// `js_widget_runtime`'s own `JsWidgetRuntimeWidget` dispatches these
/// automatically, but Fa renders JS trees through a bare
/// `JsonWidgetRenderer` (full app views and board tiles), so the host
/// wraps the render output in this reporter and forwards each size as a
/// `'viewport'` host event. Reporting is post-frame (never during layout),
/// deduplicated by [Size], and skips unbounded/empty constraints (an
/// infinite width inside a horizontal scroll view carries no adaptive
/// signal).
class ViewportReporter extends StatefulWidget {
  const ViewportReporter({
    super.key,
    required this.onSize,
    required this.child,
  });

  /// Called (post-frame) with every NEW finite, non-empty allotted size.
  final ValueChanged<Size> onSize;

  /// The rendered subtree whose constraints are observed.
  final Widget child;

  @override
  State<ViewportReporter> createState() => _ViewportReporterState();
}

class _ViewportReporterState extends State<ViewportReporter> {
  Size? _reported;

  void _maybeReport(Size size) {
    if (!size.isFinite || size.isEmpty) return;
    if (_reported == size) return;
    _reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A newer layout may have superseded this size while the callback
      // was queued — report only if it is still current.
      if (mounted && _reported == size) widget.onSize(size);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maybeReport(constraints.biggest);
        return widget.child;
      },
    );
  }
}
