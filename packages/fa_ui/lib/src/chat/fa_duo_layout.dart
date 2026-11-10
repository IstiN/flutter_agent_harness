import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Where UIKit prefers system bars when they are presented vertically.
enum FaDuoVerticalBarEdge { unspecified, leading, trailing }

/// Native display geometry relevant to adaptive foldable layouts.
///
/// The values come from UIKit's `verticalBarEdge` and
/// `UIView.reservedRegions`, in logical view coordinates. A model identifier
/// is diagnostic only; it never enables a layout on its own.
@immutable
final class FaDuoGeometry {
  const FaDuoGeometry({
    required this.isDuo,
    required this.hardwareModel,
    required this.verticalBarEdge,
    required this.safeAreaInsets,
    required this.occlusions,
    required this.divisions,
  });

  final bool isDuo;
  final String hardwareModel;
  final FaDuoVerticalBarEdge verticalBarEdge;
  final EdgeInsets safeAreaInsets;

  /// Active hardware occlusions (including the front camera).
  final List<Rect> occlusions;

  /// Active folding divisions. An open display normally has none.
  final List<Rect> divisions;

  static const notDuo = FaDuoGeometry(
    isDuo: false,
    hardwareModel: '',
    verticalBarEdge: FaDuoVerticalBarEdge.unspecified,
    safeAreaInsets: EdgeInsets.zero,
    occlusions: <Rect>[],
    divisions: <Rect>[],
  );

  /// Decodes the `fah/duo_layout` snapshot. Inactive reserved regions are
  /// deliberately discarded: an inactive fold must not split the UI.
  factory FaDuoGeometry.fromChannelValue(Map<Object?, Object?> value) {
    final edge = switch ((value['verticalBarEdge'] as num?)?.toInt() ?? 0) {
      1 => FaDuoVerticalBarEdge.leading,
      2 => FaDuoVerticalBarEdge.trailing,
      _ => FaDuoVerticalBarEdge.unspecified,
    };
    return FaDuoGeometry(
      isDuo: value['isDuo'] == true,
      hardwareModel: value['hardwareModel'] as String? ?? '',
      verticalBarEdge: edge,
      safeAreaInsets: _insets(value['safeArea']),
      occlusions: _regions(value['occlusions']),
      divisions: _regions(value['divisions']),
    );
  }

  static EdgeInsets _insets(Object? value) {
    if (value is! Map) return EdgeInsets.zero;
    double side(String key) => (value[key] as num?)?.toDouble() ?? 0;
    return EdgeInsets.fromLTRB(
      side('left'),
      side('top'),
      side('right'),
      side('bottom'),
    );
  }

  static List<Rect> _regions(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map && item['active'] == true)
          Rect.fromLTWH(
            (item['left'] as num?)?.toDouble() ?? 0,
            (item['top'] as num?)?.toDouble() ?? 0,
            (item['width'] as num?)?.toDouble() ?? 0,
            (item['height'] as num?)?.toDouble() ?? 0,
          ),
    ];
  }

  Iterable<Rect> _trailingOcclusions(Size size) => occlusions.where(
    (region) =>
        !region.isEmpty &&
        region.center.dx >= size.width * .6 &&
        region.right >= size.width - math.max(2, safeAreaInsets.right + 2),
  );

  /// Width reserved by UIKit's trailing vertical-bar/camera region.
  double trailingWidth(Size size, EdgeInsets viewPadding) {
    var width = math.max(viewPadding.right, safeAreaInsets.right);
    for (final camera in _trailingOcclusions(size)) {
      width = math.max(width, size.width - camera.left);
    }
    return width;
  }

  /// First safe y for controls in the trailing rail. A camera part-way down
  /// the rail moves controls below the whole occlusion instead of painting
  /// glass and hit targets underneath it.
  double controlsTop(double fallback) {
    var top = fallback;
    for (final camera in occlusions) {
      if (!camera.isEmpty) top = math.max(top, camera.bottom + 8);
    }
    return top;
  }
}

/// Native source for [FaDuoLayoutScope]. Injectable in widget tests.
abstract interface class FaDuoGeometrySource {
  Future<FaDuoGeometry?> read();
  Stream<void> get changes;
}

/// UIKit bridge. Unsupported/missing handlers resolve to `null`; the scope
/// then retains the conservative inset fallback until a real snapshot lands.
final class FaDuoGeometryChannel implements FaDuoGeometrySource {
  FaDuoGeometryChannel._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'layoutChanged') _changes.add(null);
    });
  }

  static final instance = FaDuoGeometryChannel._();
  static const _channel = MethodChannel('fah/duo_layout');
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<FaDuoGeometry?> read() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('snapshot');
      if (value == null) return null;
      return FaDuoGeometry.fromChannelValue(value);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Publishes native Duo geometry above the navigator so pushed chat, app and
/// dialog routes all observe the same pose. Passing [geometry] pins a snapshot
/// for golden tests and performs no platform calls.
final class FaDuoLayoutScope extends StatefulWidget {
  const FaDuoLayoutScope({
    super.key,
    required this.child,
    this.geometry,
    this.source,
  });

  final Widget child;
  final FaDuoGeometry? geometry;
  final FaDuoGeometrySource? source;

  static FaDuoGeometry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FaDuoLayoutInherited>()
      ?.geometry;

  @override
  State<FaDuoLayoutScope> createState() => _FaDuoLayoutScopeState();
}

class _FaDuoLayoutScopeState extends State<FaDuoLayoutScope>
    with WidgetsBindingObserver {
  FaDuoGeometry? _liveGeometry;
  FaDuoGeometrySource? _source;
  StreamSubscription<void>? _subscription;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _configureSource();
  }

  @override
  void didUpdateWidget(FaDuoLayoutScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.geometry != widget.geometry ||
        oldWidget.source != widget.source) {
      _configureSource();
    }
  }

  void _configureSource() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _source = null;
    if (widget.geometry != null) {
      _liveGeometry = widget.geometry;
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      _liveGeometry = FaDuoGeometry.notDuo;
      return;
    }
    _liveGeometry = null;
    final source = _source = widget.source ?? FaDuoGeometryChannel.instance;
    _subscription = source.changes.listen((_) => unawaited(_refresh()));
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final source = _source;
    if (source == null || _reading) return;
    _reading = true;
    try {
      final value = await source.read();
      if (!mounted || source != _source || widget.geometry != null) return;
      if (value != null && value != _liveGeometry) {
        setState(() => _liveGeometry = value);
      }
    } finally {
      _reading = false;
    }
  }

  @override
  void didChangeMetrics() => unawaited(_refresh());

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FaDuoLayoutInherited(
    geometry: widget.geometry ?? _liveGeometry,
    child: widget.child,
  );
}

final class _FaDuoLayoutInherited extends InheritedWidget {
  const _FaDuoLayoutInherited({required this.geometry, required super.child});

  final FaDuoGeometry? geometry;

  @override
  bool updateShouldNotify(_FaDuoLayoutInherited oldWidget) =>
      geometry != oldWidget.geometry;
}
