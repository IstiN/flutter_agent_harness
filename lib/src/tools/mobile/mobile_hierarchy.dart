/// The accessibility hierarchy XML → filtered element index (issue #622,
/// UT-hierarchy-1).
///
/// Ports artemis's filter IDEA, not its architecture: keep the
/// informative-or-interactive nodes (`text` / `content-desc` non-empty,
/// `resource-id` present, clickable / scrollable / editable / checkable),
/// drop pure containers and zero-area nodes, and number what survives
/// `e1..eN` in document order so the model can address taps by id with a
/// coordinate fallback. Password fields never expose their text.
///
/// The accepted input is the uiautomator-dump shape our Android service
/// serializes (`<hierarchy …><node index="…" text="…" …/></hierarchy>`).
/// The parser is a bounded scanner over exactly that grammar — attribute
/// values are XML-entity-decoded, no general XML stack is pulled into the
/// pure core.
///
/// Pure Dart: no `dart:io`.
library;

import 'mobile_backend.dart';

/// Default cap on kept elements (one screen rarely exceeds ~100).
const defaultMobileElementCap = 200;

/// Extracts the filtered [MobileElementIndex] from a hierarchy XML dump.
///
/// [packageHint] names the window when the XML carries no package
/// attribute (defensive: uiautomator dumps always do). [cap] bounds the
/// index; hitting it sets `truncated` with a scroll hint in the render.
MobileElementIndex parseMobileHierarchy(
  String xml, {
  String packageHint = 'unknown',
  int cap = defaultMobileElementCap,
}) {
  final kept = <MobileElement>[];
  var truncated = false;
  var packageName = '';

  final nodeTag = RegExp(r'<node\b((?:[^>"]|"[^"]*")*?)/?>');
  final attr = RegExp(r'([\w-]+)="([^"]*)"');

  for (final match in nodeTag.allMatches(xml)) {
    final attrs = <String, String>{
      for (final a in attr.allMatches(match.group(1)!)) a.group(1)!: a.group(2)!,
    };

    final pkg = _unescape(attrs['package'] ?? '');
    if (pkg.isNotEmpty && packageName.isEmpty) packageName = pkg;

    final bounds = _nodeBounds(attrs['bounds']);
    if (bounds == null) continue; // malformed/absent bounds or zero-area
    final (left, top, right, bottom) = bounds;

    final clickable = attrs['clickable'] == 'true';
    final scrollable = attrs['scrollable'] == 'true';
    // uiautomator dumps carry no `editable` flag — the EditText class is
    // the signal (focused nodes of other classes are not text fields).
    final editable = attrs['class']?.contains('EditText') == true;
    final checkable = attrs['checkable'] == 'true';
    final text = _unescape(attrs['text'] ?? '');
    final contentDesc = _unescape(attrs['content-desc'] ?? '');
    final viewId = _unescape(attrs['resource-id'] ?? '');
    final password = attrs['password'] == 'true';

    // The artemis keep-rule: informative or interactive only.
    if (!_isInformative(
      text: text,
      contentDesc: contentDesc,
      viewId: viewId,
      clickable: clickable,
      scrollable: scrollable,
      editable: editable,
      checkable: checkable,
    )) {
      continue;
    }

    if (kept.length >= cap) {
      truncated = true;
      break;
    }
    kept.add(
      MobileElement(
        id: 'e${kept.length + 1}',
        text: _visibleText(text, password: password),
        contentDesc: contentDesc.isEmpty ? null : contentDesc,
        className: _classNameOf(attrs['class']),
        viewId: viewId.isEmpty ? null : viewId,
        clickable: clickable,
        scrollable: scrollable,
        editable: editable,
        checkable: checkable,
        checked: attrs['checked'] == 'true',
        bounds: '[$left,$top][$right,$bottom]',
        centerX: (left + right) ~/ 2,
        centerY: (top + bottom) ~/ 2,
      ),
    );
  }

  return MobileElementIndex(
    packageName: packageName.isEmpty ? packageHint : packageName,
    elements: kept,
    truncated: truncated,
  );
}

/// The short class name (`android.widget.Button` → `Button`).
String? _classNameOf(String? full) {
  if (full == null || full.isEmpty) return null;
  final dot = full.lastIndexOf('.');
  return dot < 0 ? full : full.substring(dot + 1);
}

/// Parses `[l,t][r,b]`; null when the value does not match the shape.
(int, int, int, int)? _parseBounds(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$').firstMatch(raw);
  if (m == null) return null;
  return (
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
  );
}

/// Valid, non-zero-area bounds: malformed/absent and zero-area nodes are
/// not actionable (artemis prunes them first).
(int, int, int, int)? _nodeBounds(String? raw) {
  final bounds = _parseBounds(raw);
  if (bounds == null) return null;
  final (left, top, right, bottom) = bounds;
  if (right <= left || bottom <= top) return null;
  return bounds;
}

/// The artemis keep-rule: a node survives when it carries text, an
/// accessibility label, a view id, or any interactive affordance.
bool _isInformative({
  required String text,
  required String contentDesc,
  required String viewId,
  required bool clickable,
  required bool scrollable,
  required bool editable,
  required bool checkable,
}) {
  return text.isNotEmpty ||
      contentDesc.isNotEmpty ||
      viewId.isNotEmpty ||
      clickable ||
      scrollable ||
      editable ||
      checkable;
}

/// Screen text of a node: password fields never expose their value.
String? _visibleText(String text, {required bool password}) {
  if (password || text.isEmpty) return null;
  return text;
}

/// Decodes the five XML predefined entities the serializer emits.
String _unescape(String raw) => raw
    .replaceAllMapped(
      RegExp(r'&(amp|lt|gt|quot|apos);'),
      (m) => switch (m.group(1)) {
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        _ => '&',
      },
    );
