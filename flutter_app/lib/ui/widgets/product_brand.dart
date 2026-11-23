import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fa_mark.dart';

/// Ambient product identity for composite marketing/mockup trees.
class ProductConfigScope extends InheritedWidget {
  const ProductConfigScope({
    super.key,
    required this.productConfig,
    required super.child,
  });

  final FaProductConfig productConfig;

  static FaProductConfig of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProductConfigScope>()
          ?.productConfig ??
      FaProductConfig.stock;

  @override
  bool updateShouldNotify(ProductConfigScope oldWidget) =>
      productConfig != oldWidget.productConfig;
}

/// Host-owned brand mark for first-run and setup surfaces.
///
/// Branded web builds publish their icon beside `product_config.js`, so a
/// root-relative network image uses the real host asset. Native hosts may
/// bundle the same declared asset path. A deterministic monogram remains if
/// no asset was declared or it cannot be decoded — never the stock Fa logo.
class ProductBrandMark extends StatelessWidget {
  const ProductBrandMark({
    super.key,
    required this.productConfig,
    this.size = 30,
  });

  final FaProductConfig productConfig;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (productConfig.isStock) return FaMark(size: size);
    final asset =
        productConfig.brandAssets['icon192'] ??
        productConfig.brandAssets['icon512'];
    if (asset != null) {
      Widget errorBuilder(
        BuildContext context,
        Object error,
        StackTrace? stack,
      ) => _monogram(context);
      final image = kIsWeb
          ? Image.network(
              asset,
              key: const ValueKey('productBrandImage'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: errorBuilder,
            )
          : Image.asset(
              asset,
              key: const ValueKey('productBrandImage'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: errorBuilder,
            );
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: SizedBox(width: size, height: size, child: image),
      );
    }
    return _monogram(context);
  }

  Widget _monogram(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final initial = productConfig.displayName
        .trim()
        .characters
        .first
        .toUpperCase();
    return Container(
      key: const ValueKey('productBrandMonogram'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(size * .22),
        border: Border.all(color: colors.primary.withValues(alpha: .45)),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: colors.onPrimaryContainer,
          fontSize: size * .52,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}
