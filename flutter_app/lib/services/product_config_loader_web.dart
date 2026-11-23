import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

@JS('__faProductProfile')
external JSAny? get _productProfile;

/// Reads the public, same-origin product_config.js emitted by the generic
/// branded build. Invalid/tampered metadata fails closed instead of silently
/// presenting stock Fa or an unreviewed host profile.
FaProductConfig loadInjectedProductConfig() {
  final raw = _productProfile.dartify();
  if (raw == null) return FaProductConfig.stock;
  if (raw is! Map) {
    throw const FormatException('injected product profile must be an object');
  }
  final json = jsonDecode(jsonEncode(raw));
  return FaProductConfig.fromJson((json as Map).cast<String, Object?>());
}
