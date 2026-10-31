// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../theme/fa2_tokens.dart';

/// Test seam for deterministic goldens and devices where shader output is not
/// stable. Production keeps this false; upstream also falls back automatically
/// on web/Skia and when Flutter GPU is unavailable.
@visibleForTesting
bool debugFaGlassAlwaysFake = false;

/// A semantic Fa surface, optionally rendered with real liquid refraction.
class FaSurface extends StatelessWidget {
  const FaSurface({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.glass = false,
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final bool glass;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final radius = borderRadius ?? BorderRadius.circular(tokens.radiusLg);
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    final interactive = onTap == null
        ? content
        : InkWell(onTap: onTap, borderRadius: radius, child: content);
    if (glass && tokens.direction == FaVisualDirection.glass) {
      return LiquidGlass.auto(
        fake: debugFaGlassAlwaysFake,
        settings: LiquidGlassSettings.ios27Regular(
          brightness: tokens.brightness,
          frost: tokens.glassBlur,
          tintAmount: .35,
        ),
        appearance: LiquidGlassAppearance.ios27Regular(
          brightness: tokens.brightness,
          tint: (color ?? tokens.surface1).withValues(alpha: .7),
        ),
        shape: LiquidRoundedSuperellipse(borderRadius: radius.topLeft.x),
        child: Material(type: MaterialType.transparency, child: interactive),
      );
    }
    return Material(
      color: color ?? tokens.surface1.withValues(alpha: glass ? .94 : 1),
      shape: RoundedSuperellipseBorder(
        borderRadius: radius,
        side: BorderSide(color: tokens.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: interactive,
    );
  }
}

enum FaButtonVariant { primary, secondary, ghost, danger }

/// A 48-pixel-high action with the four styleguide variants.
class FaButton extends StatelessWidget {
  const FaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = FaButtonVariant.primary,
    this.busy = false,
    this.expanded = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final FaButtonVariant variant;
  final bool busy;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final enabled = onPressed != null && !busy;
    final foreground = switch (variant) {
      FaButtonVariant.primary => tokens.accentInk,
      FaButtonVariant.danger => tokens.accentInk,
      _ => tokens.ink1,
    };
    final background = switch (variant) {
      FaButtonVariant.primary => tokens.accent,
      FaButtonVariant.danger => tokens.danger,
      FaButtonVariant.secondary => tokens.surface2,
      FaButtonVariant.ghost => Colors.transparent,
    };
    final labelChild = AnimatedSwitcher(
      duration: FaMotionDuration.resolve(context, tokens.fast),
      child: busy
          ? SizedBox.square(
              key: const ValueKey('busy'),
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Text(label, key: const ValueKey('label')),
    );
    final child = icon == null || busy
        ? labelChild
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              labelChild,
            ],
          );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      foregroundColor: WidgetStatePropertyAll(foreground),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? tokens.surface3
            : background,
      ),
      overlayColor: WidgetStatePropertyAll(
        tokens.accent.withValues(alpha: .12),
      ),
      shape: WidgetStatePropertyAll(
        RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          side: variant == FaButtonVariant.secondary
              ? BorderSide(color: tokens.hairline)
              : BorderSide.none,
        ),
      ),
    );
    final button = variant == FaButtonVariant.ghost
        ? TextButton(
            onPressed: enabled ? onPressed : null,
            style: style,
            child: child,
          )
        : FilledButton(
            onPressed: enabled ? onPressed : null,
            style: style,
            child: child,
          );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A token-colored icon action with an accessible minimum hit area.
class FaIconButton extends StatelessWidget {
  const FaIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    icon: Icon(icon),
    color: FaDesignTokens.of(context).ink2,
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
  );
}

/// The shared Fa 2.0 text-input treatment.
class FaTextField extends StatelessWidget {
  const FaTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.errorText,
    this.prefixIcon,
    this.suffixIcon,
  });

  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: TextStyle(color: tokens.ink1, fontSize: 15, height: 1.4),
      decoration: InputDecoration(
        hintText: hintText,
        labelText: labelText,
        errorText: errorText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: tokens.surface2,
        hintStyle: TextStyle(color: tokens.ink3),
        labelStyle: TextStyle(color: tokens.ink2),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: border(tokens.hairline),
        enabledBorder: border(tokens.hairline),
        focusedBorder: border(tokens.accent, 1.5),
        errorBorder: border(tokens.danger),
        focusedErrorBorder: border(tokens.danger, 1.5),
      ),
    );
  }
}

/// A padded semantic card, optionally tappable.
class FaCard extends StatelessWidget {
  const FaCard({super.key, required this.child, this.padding, this.onTap});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => FaSurface(
    onTap: onTap,
    padding: padding ?? const EdgeInsets.all(20),
    child: child,
  );
}

/// A settings row that remains readable at narrow widths and large text sizes.
class FaSettingsTile extends StatelessWidget {
  const FaSettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return ListTile(
      onTap: onTap,
      leading: leading,
      title: DefaultTextStyle.merge(
        style: TextStyle(color: tokens.ink1, fontWeight: FontWeight.w600),
        child: title,
      ),
      subtitle: subtitle == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(color: tokens.ink2, height: 1.35),
              child: subtitle!,
            ),
      trailing: trailing,
      minTileHeight: 64,
      horizontalTitleGap: 16,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
    );
  }
}

/// A compact status label.
class FaBadge extends StatelessWidget {
  const FaBadge(this.text, {super.key, this.quiet = false});

  final String text;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: quiet ? tokens.surface3 : tokens.accentSoft,
        borderRadius: BorderRadius.circular(tokens.radiusPill),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: quiet ? tokens.ink2 : tokens.accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .2,
        ),
      ),
    );
  }
}

/// A selectable filter/action chip.
class FaChip extends StatelessWidget {
  const FaChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Material(
      color: selected ? tokens.accentSoft : tokens.surface2,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(tokens.radiusPill),
        side: BorderSide(color: selected ? tokens.accent : tokens.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 17,
                    color: selected ? tokens.accent : tokens.ink2,
                  ),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? tokens.accent : tokens.ink1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Styleguide switch wrapper (keeps call sites independent of Material).
class FaSwitch extends StatelessWidget {
  const FaSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      Switch(value: value, onChanged: onChanged);
}

/// Styleguide slider wrapper.
class FaSlider extends StatelessWidget {
  const FaSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;

  @override
  Widget build(BuildContext context) =>
      Slider(value: value, onChanged: onChanged, min: min, max: max);
}

/// Resolves animation durations while honoring the accessibility preference.
abstract final class FaMotionDuration {
  static Duration resolve(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;
}
