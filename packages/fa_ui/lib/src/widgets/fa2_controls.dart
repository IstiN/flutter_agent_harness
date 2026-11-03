// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../theme/fa2_tokens.dart';

/// Test seam for deterministic goldens and devices where shader output is not
/// stable: the kit glass renders its zero-shader frosted fallback
/// ([GlassQuality.minimal]) instead of the standard lightweight shader.
/// Production keeps this false; the kit's [AdaptiveGlass] also falls back
/// automatically on web/Skia and when Flutter GPU is unavailable.
@visibleForTesting
bool debugFaGlassAlwaysFake = false;

/// The styleguide's tuned kit-glass material, shared by every Fa glass
/// adapter ([FaSurface], [FaHeaderCircularAction], the [FaIconActionButton]
/// kit delegate, the host's SessionSearchField). The pixel audit pinned the
/// reference look: the background under small glass diffuses by ~4-6 pt with
/// a mild rim refraction, the interior stays near-clear, and the specular
/// ring comes from the kit shader — not from a painted fill. The kit's
/// default material (iOS-26 rim, fresnel specular) carries the optics; we
/// map only the Fa tokens onto it:
///
/// - `blur` ← [frost] (the audit's sigma: [kFaGlassFrost] for control-scale
///   discs, `tokens.glassBlur` for panels);
/// - `glassColor` ← [tint], the low-alpha surface wash (audit: alpha ≤ ~.5);
/// - `chromaticAberration` 0 — the audit measured zero dispersion on the
///   iOS-27 reference chrome.
const double kFaGlassFrost = 5.0;

/// The glass wash alpha ceiling: the interior tint mixes at most this far
/// toward the surface color (audit: interior tint alpha ≤ ~0.5; the old
/// surface1@.94 fill was the murky-glass regression).
const double kFaGlassTintAlpha = .40;

/// The iOS-27 tint-slider position the wash defaults to (0 clear → 1
/// tinted; the reference discs sit near clear).
const double kFaGlassTintAmount = .12;

/// The kit [LiquidGlassSettings] for Fa chrome — see the constants above.
LiquidGlassSettings faGlassSettings({Color? tint, double? frost}) =>
    LiquidGlassSettings(
      // Colors.transparent (not a hex literal — the styleguide guard
      // bans one-off hex palettes here): alpha 0 keeps the kit's inherited-
      // tint path (glassColor.a > 0 marks an explicit wash).
      glassColor: tint ?? Colors.transparent,
      blur: frost ?? kFaGlassFrost,
      chromaticAberration: 0,
    );

/// A semantic Fa surface, optionally rendered with real liquid refraction.
///
/// Glass mode rides the liquid_glass_widgets kit ([AdaptiveGlass]) — the
/// same canonical wrapper the kit's own widgets use, with the Fa token
/// mapping from [faGlassSettings]. Non-glass directions keep the opaque
/// token surface (the styleguide rule: real glass in the glass direction,
/// opaque fallbacks elsewhere).
class FaSurface extends StatelessWidget {
  const FaSurface({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.glass = false,
    this.onTap,
    this.color,
    this.useBackdropGroup = false,
    this.circular = false,
    this.tintAmount,
    this.tintOpacity,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final bool glass;
  final VoidCallback? onTap;
  final Color? color;

  /// Shares one backdrop capture with sibling chrome over the same content.
  ///
  /// Retained for API compatibility: the kit's [AdaptiveGlass] currently
  /// gives each surface its own layer, so the shared-sample optimization is
  /// advisory only (no call site changes behavior).
  final bool useBackdropGroup;

  /// Uses a true circle in both the real glass renderer and opaque fallback.
  /// The caller must give the surface square constraints.
  final bool circular;

  /// Glass tint amount override — the iOS-27 tint-slider position (0 clear,
  /// 1 tinted; null keeps the styleguide default [kFaGlassTintAmount]). It
  /// scales the wash alpha relative to that default, so a call site passing
  /// tintAmount .10 gets roughly a third of the ceiling alpha.
  final double? tintAmount;

  /// Glass tint alpha override — the wash mix ceiling (null keeps the
  /// styleguide default [kFaGlassTintAlpha]).
  final double? tintOpacity;

  /// The wash color the kit `glassColor` channel carries: an explicitly
  /// passed translucent [color] is used as-is (the caller shaped its own
  /// alpha); otherwise surface1 mixes at the tint ceiling scaled by
  /// [tintAmount].
  Color _glassTint(FaDesignTokens tokens) {
    final base = color ?? tokens.surface1;
    if (color != null && color!.a < 1) return base;
    final alpha =
        ((tintOpacity ?? kFaGlassTintAlpha) *
                ((tintAmount ?? kFaGlassTintAmount) / kFaGlassTintAmount))
            .clamp(0.0, 1.0);
    return base.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final radius = borderRadius ?? BorderRadius.circular(tokens.radiusLg);
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    final interactive = onTap == null
        ? content
        : InkWell(onTap: onTap, borderRadius: radius, child: content);
    if (glass && tokens.direction == FaVisualDirection.glass) {
      return AdaptiveGlass(
        shape: circular
            ? const LiquidOval()
            : LiquidRoundedSuperellipse(borderRadius: radius.topLeft.x),
        settings: faGlassSettings(
          tint: _glassTint(tokens),
          frost: tokens.glassBlur,
        ),
        quality: debugFaGlassAlwaysFake
            ? GlassQuality.minimal
            : GlassQuality.standard,
        clipBehavior: Clip.antiAlias,
        child: Material(type: MaterialType.transparency, child: interactive),
      );
    }
    return Material(
      color: color ?? tokens.surface1.withValues(alpha: glass ? .94 : 1),
      shape: circular
          ? CircleBorder(side: BorderSide(color: tokens.hairline))
          : RoundedSuperellipseBorder(
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
    this.focusNode,
    this.hintText,
    this.labelText,
    this.helperText,
    this.obscureText = false,
    this.dense = false,
    this.keyboardType,
    this.autofocus = false,
    this.enabled = true,
    this.autocorrect = true,
    this.boxHeight,
    this.enableSuggestions = true,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.prefixIcon,
    this.suffixIcon,
    this.maxLength,
    this.textInputAction,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final String? labelText;

  /// One-line helper under the field (token dim ink).
  final String? helperText;
  final bool obscureText;
  final bool dense;
  final TextInputType? keyboardType;
  final bool autofocus;
  final bool enabled;

  /// Whether the OS text-correction pipeline applies (off for secrets).
  final bool autocorrect;

  /// Character cap (the shared search field's 100-char paste cap); the
  /// counter stays hidden.
  final int? maxLength;

  /// The keyboard's action button; null keeps the platform default.
  final TextInputAction? textInputAction;

  /// The host's fixed box height: FaTextField pads the field's content
  /// so the InputDecorator's intrinsic layout is EXACTLY this tall — the
  /// painted fill and the text genuinely occupy the box, vertically
  /// centered, instead of the intrinsic dense box (~18pt) top-aligned
  /// inside the host's taller one. For chrome that owns a fixed field
  /// box taller than the intrinsic field (the Files band's 40pt search
  /// capsule mirrors the composer's field row). Null (the default) keeps
  /// intrinsic sizing everywhere else; nothing about the composer or
  /// settings fields changes. Hosts must give the field a matching tight
  /// height and keep the field single-line without helper/error text
  /// (their intrinsic heights would exceed the box).
  final double? boxHeight;

  /// Whether the OS suggestion pipeline applies (off for secrets).
  final bool enableSuggestions;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
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
    // Fill the host's fixed box ([boxHeight]): the InputDecorator only
    // paints what its intrinsic layout computes, so the content padding
    // grows to make that layout exactly the box — the fill and the text
    // occupy it top-to-bottom. The theme's visual density shifts the
    // decorator's own content height, so it is subtracted here too.
    final lineHeight = (dense ? 13.0 : 15.0) * 1.4;
    final contentPadding = boxHeight == null
        ? EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 0 : 14)
        : EdgeInsets.symmetric(
            horizontal: 16,
            vertical: math.max(
              0,
              (boxHeight! -
                      lineHeight -
                      Theme.of(context).visualDensity.baseSizeAdjustment.dy) /
                  2,
            ),
          );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      autofocus: autofocus,
      enabled: enabled,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      maxLength: maxLength,
      buildCounter: maxLength == null
          ? null
          : (_, {required currentLength, required isFocused, maxLength}) =>
                null,
      textInputAction: textInputAction,
      style: TextStyle(
        color: tokens.ink1,
        fontSize: dense ? 13 : 15,
        height: 1.4,
      ),
      decoration: InputDecoration(
        isDense: dense,
        hintText: hintText,
        labelText: labelText,
        helperText: helperText,
        errorText: errorText,
        prefixIcon: prefixIcon,
        prefixIconConstraints: dense
            ? const BoxConstraints.tightFor(width: 32, height: 32)
            : null,
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: tokens.surface2,
        hintStyle: TextStyle(color: tokens.ink3),
        labelStyle: TextStyle(color: tokens.ink2),
        helperStyle: TextStyle(color: tokens.ink3, fontSize: 12),
        contentPadding: contentPadding,
        border: border(tokens.hairline),
        enabledBorder: border(tokens.hairline),
        focusedBorder: border(tokens.accent, 1.5),
        errorBorder: border(tokens.danger),
        focusedErrorBorder: border(tokens.danger, 1.5),
      ),
    );
  }
}

/// The styleguide's only divider: a 1px token hairline with symmetric
/// vertical rhythm (the stock [Divider] leaks the M3 defaults and an
/// asymmetric 24/16 spacing). [indent] aligns the line with a card's
/// text column.
class FaHairline extends StatelessWidget {
  const FaHairline({super.key, this.indent = 0, this.symmetry = 24});

  final double indent;

  /// Vertical space on both sides — symmetric by contract.
  final double symmetry;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: symmetry),
      child: Container(
        margin: EdgeInsets.only(left: indent),
        height: 1,
        color: tokens.hairline,
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

/// Styleguide switch: a custom-painted capsule track with an animated
/// squircle thumb, sized for desktop rows (40 × 24). Theming a Material
/// `Switch` cannot reshape its stock M3 geometry, so the toggle is painted
/// straight from [FaDesignTokens] — accent track + accentInk thumb when on,
/// surface3 track + ink1 thumb when off, a 55% wash when disabled — while
/// the public API (`value`/`onChanged`) and the toggle semantics stay.
class FaSwitch extends StatefulWidget {
  const FaSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<FaSwitch> createState() => _FaSwitchState();
}

class _FaSwitchState extends State<FaSwitch> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'FaSwitch');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onChanged != null;

  void _activate() => widget.onChanged!(!widget.value);

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Semantics(
      toggled: widget.value,
      enabled: _enabled,
      child: GestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTap: _enabled ? _activate : null,
        child: Focus(
          focusNode: _focusNode,
          onKeyEvent: _enabled
              ? (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.space ||
                      key == LogicalKeyboardKey.enter ||
                      key == LogicalKeyboardKey.numpadEnter) {
                    _activate();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                }
              : null,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.value ? 1.0 : 0.0),
            duration: FaMotionDuration.resolve(context, tokens.fast),
            curve: Curves.easeOutCubic,
            builder: (context, position, _) => CustomPaint(
              size: FaSwitchPainter.switchSize,
              painter: FaSwitchPainter(
                position: position,
                enabled: _enabled,
                tokens: tokens,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the [FaSwitch] capsule: a full-round track that lerps surface3 →
/// accent and a rounded-superellipse (squircle) thumb that slides across
/// and lerps ink1 → accentInk. Disabled controls fade to a 55% wash.
@visibleForTesting
class FaSwitchPainter extends CustomPainter {
  FaSwitchPainter({
    required this.position,
    required this.enabled,
    required this.tokens,
  }) : assert(position >= 0 && position <= 1);

  /// The visual size of the switch: 40 × 24 desktop capsule.
  static const Size switchSize = Size(40, 24);

  static const double _thumbDiameter = 18;
  static const double _thumbInset = 3;

  /// Thumb travel: 0 (off) → 1 (on).
  final double position;

  final bool enabled;

  final FaDesignTokens tokens;

  /// The current (lerped) capsule track color.
  Color get trackColor => _wash(Color.lerp(trackOff, trackOn, position)!);

  /// The current (lerped) squircle thumb color.
  Color get thumbColor => _wash(Color.lerp(thumbOff, thumbOn, position)!);

  Color get trackOn => tokens.accent;
  Color get trackOff => tokens.surface3;
  Color get thumbOn => tokens.accentInk;
  Color get thumbOff => tokens.ink1;

  Color _wash(Color color) => enabled ? color : color.withValues(alpha: .55);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawPath(
      StadiumBorder().getOuterPath(rect),
      Paint()
        ..color = trackColor
        ..isAntiAlias = true,
    );
    final x = lerpDouble(
      _thumbInset,
      size.width - _thumbInset - _thumbDiameter,
      position,
    )!;
    final thumbRect = Rect.fromLTWH(
      x,
      (size.height - _thumbDiameter) / 2,
      _thumbDiameter,
      _thumbDiameter,
    );
    canvas.drawPath(
      RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(_thumbDiameter / 2),
      ).getOuterPath(thumbRect),
      Paint()
        ..color = thumbColor
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(FaSwitchPainter oldDelegate) =>
      position != oldDelegate.position ||
      enabled != oldDelegate.enabled ||
      tokens != oldDelegate.tokens;
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
