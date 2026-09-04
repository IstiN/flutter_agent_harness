/// L3: the fast `indexOf` pre-screen in front of the vendor layer.
///
/// This layer never produces spans of its own inside the pipeline — the
/// pipeline uses [quickScreen] as a gate in front of the vendor regex pass.
/// Standalone, [layerPrefix] flags exactly the spans the vendor layer would,
/// and returns nothing when the vendor layer is disabled.
library;

import 'redaction_types.dart';
import 'layer_vendor.dart';

export 'layer_vendor.dart' show quickScreen, vendorPrefixes;

/// Thin pre-pass over the vendor token shapes; see the library docs.
List<RedactionMatch> layerPrefix(String text, RedactionConfig cfg) {
  if (!cfg.isLayerEnabled(RedactionLayer.vendor)) return const [];
  return layerVendor(text, cfg);
}
