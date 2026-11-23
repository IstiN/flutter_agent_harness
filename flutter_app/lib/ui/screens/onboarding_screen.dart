// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:fa/l10n/app_localizations.dart' show AppLocalizations;
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart' show AgentConfig;
import 'package:fa/services/analytics.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/chatgpt_oauth_flow.dart';
import 'package:fa/services/codemie_sso_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

part 'onboarding_mockups.dart';

/// Onboarding matching the reference prototype pixel-by-pixel.
/// Four pages: welcome (chat/apps mockups), provider picker, permissions,
/// ready. Light marketing design on both platforms (the reference is
/// light-only). Third-party skills (Claude/Copilot/Codex) need no consent
/// page: discovery is on by default, Settings carries the opt-out.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    this.onboardingStore,
    this.initialPage = 0,
    this.onFinished,
    this.registry,
    this.lastConnectionStore,
    this.networkMode,
    this.networkSessions,
    this.productConfig = FaProductConfig.stock,
  });

  final OnboardingStore? onboardingStore;
  final FaProductConfig productConfig;

  final int initialPage;
  final void Function({required bool skipped})? onFinished;

  /// The shared provider registry (the page-2 list is the app's Add
  /// Provider list; a tap opens the real provider config flow). When null
  /// (tests) page 2 renders the list but the mandatory gate stays off.
  final faui.ProviderRegistry? registry;

  /// Where the configured provider is persisted as the restorable last
  /// connection (the boot then auto-connects right after onboarding).
  final LastConnectionStore? lastConnectionStore;

  /// Existing network mode/session manager. Joining uses the same sheet and
  /// credential/key wallet as the rest of the app, never a parallel flow.
  final NetworkModeController? networkMode;
  final NetworkSessionManager? networkSessions;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

// Decorative colors inside the conversational mockups. App chrome and
// semantic state colors come from the active Fa 2.0 direction below.
const _kNavy = Color(0xFF191B2E);
const _kGreen = Color(0xFF10B981);
const _kCardShadow = [
  BoxShadow(color: Color(0x0A172033), blurRadius: 10, offset: Offset(0, 3)),
];

/// The onboarding follows the SYSTEM brightness: light tokens by default,
/// dark counterparts (matching the app's dark theme surfaces) when the
/// surrounding theme is dark — a dark-mode OS must never see a blinding
/// white onboarding with dark popups on top.
bool _onbDark(BuildContext context) =>
    faui.FaDesignTokens.of(context).brightness == Brightness.dark;

Color _onbBg(BuildContext context) =>
    faui.FaDesignTokens.of(context).background;

Color _onbCard(BuildContext context) =>
    faui.FaDesignTokens.of(context).surface1;

Color _onbInk(BuildContext context) => faui.FaDesignTokens.of(context).ink1;

Color _onbGray(BuildContext context) => faui.FaDesignTokens.of(context).ink2;

Color _onbGrayLight(BuildContext context) =>
    faui.FaDesignTokens.of(context).ink3;

Color _onbBorder(BuildContext context) =>
    faui.FaDesignTokens.of(context).hairline;

Color _onbSelBg(BuildContext context) =>
    faui.FaDesignTokens.of(context).accentSoft;

Color _onbPrimary(BuildContext context) =>
    faui.FaDesignTokens.of(context).accent;

List<BoxShadow> _onbCardShadow(BuildContext context) =>
    _onbDark(context) ? [] : _kCardShadow;

class _OnboardingScreenState extends State<OnboardingScreen> {
  /// Step labels in page order.
  List<String> get _labels => [
    context.l10n.onboardingStepAsk,
    context.l10n.onboardingStepThink,
    context.l10n.onboardingStepAct,
    context.l10n.onboardingStepMakeItYours,
  ];

  static const _pageCount = 4;

  final _p2Key = GlobalKey<_P2State>();

  faui.AddProviderPreset? get _defaultProvider {
    final key = widget.productConfig.defaultProviderKey;
    if (key == null || widget.registry == null) return null;
    for (final preset in faui.defaultAddProviderPresets) {
      if (preset.key == key && faui.addProviderPresetEnabled(preset)) {
        return preset;
      }
    }
    return null;
  }

  late final PageController _pc = PageController(
    initialPage: widget.initialPage,
  );
  late var _page = widget.initialPage;

  /// Set when the user finished a provider config flow on page 2 — the
  /// provider step is mandatory: Continue/Skip stay locked until then.
  var _providerConfigured = false;

  /// Which preset completed its flow (the card check). Tracked here, not
  /// in the page, so it survives the PageView recycling the page state.
  String? _configuredProviderKey;

  /// The provider gate applies only in the real app (a registry is wired);
  /// tests pumping the bare screen keep the walkthrough skippable.
  bool get _networkSelected =>
      widget.networkMode?.mode == AppMode.network &&
      widget.networkMode?.networkId != null;

  bool get _providerGateActive =>
      (widget.registry != null || widget.networkMode != null) &&
      !_providerConfigured &&
      !_networkSelected;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.onboardingStarted();
    AppAnalytics.instance.screenOpened('onboarding');
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _finish({required bool skipped}) {
    // This guard is deliberately not just a disabled button: informational
    // Skip/Open Fa actions and programmatic page jumps must not bypass the
    // provider-or-network requirement.
    if (_providerGateActive) return;
    if (skipped) {
      AppAnalytics.instance.onboardingSkipped(_page);
    } else {
      AppAnalytics.instance.onboardingCompleted();
    }
    unawaited(widget.onboardingStore?.markSeen() ?? Future<void>.value());
    widget.onFinished?.call(skipped: skipped);
  }

  void _next() => _pc.nextPage(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOut,
  );
  void _back() => _pc.previousPage(
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOut,
  );

  /// A provider flow completed on page 2: unlock the step and slide on.
  /// The SSO/OAuth flow is async — the user may have swiped to another
  /// page by the time it completes. Always advance when we're still
  /// on the provider page (index 1), so the button unlocks and the
  /// flow moves forward even if the user idled on it.
  void _providerDone(String presetKey) {
    setState(() {
      _providerConfigured = true;
      _configuredProviderKey = presetKey;
    });
    if (_page == 1) _next();
  }

  Future<void> _joinNetwork() async {
    final controller = widget.networkMode;
    final manager = widget.networkSessions;
    if (controller == null || manager == null) return;
    await showJoinSheet(context, controller: controller, manager: manager);
    _completeNetworkJoin();
  }

  void _completeNetworkJoin() {
    if (!mounted || !_networkSelected) return;
    setState(() => _providerConfigured = true);
    _advanceFromProviderPage();
  }

  void _advanceFromProviderPage() {
    if (_page == 1) _next();
  }

  String get _primaryLabel {
    final l10n = context.l10n;
    if (_page == 2) {
      return l10n.onboardingContinueWithoutAccess;
    }
    if (_page == _pageCount - 1) {
      return l10n.onboardingOpenProduct(widget.productConfig.displayName);
    }
    return l10n.onboardingNext;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final last = _page == _pageCount - 1;
    final gated = _page == 1 && _providerGateActive;
    final defaultProvider = _defaultProvider;
    return ProductConfigScope(
      productConfig: widget.productConfig,
      child: Scaffold(
        backgroundColor: _onbBg(context),
        body: SafeArea(
          child: Column(
            children: [
              _Header(
                productConfig: widget.productConfig,
                page: _page,
                labels: _labels,
                wide: wide,
                // The provider step is mandatory — no skipping past it.
                onSkip: _providerGateActive
                    ? null
                    : () => _finish(skipped: true),
              ),
              Expanded(
                child: PageView(
                  controller: _pc,
                  // A fling must not bypass the mandatory provider step —
                  // it would reach "Open Fa" without a provider. The step is
                  // button-driven only while the gate is up. The gate blocks
                  // GESTURE scrolling only (drag/fling/wheel); semantics
                  // scroll actions and programmatic jumps are intentionally
                  // not vetoed — it is a UX guardrail, not a hard boundary.
                  physics: gated ? const NeverScrollableScrollPhysics() : null,
                  onPageChanged: (p) => setState(() => _page = p),
                  children: [
                    _P1(wide: wide),
                    _P2(
                      key: _p2Key,
                      wide: wide,
                      defaultProvider: defaultProvider,
                      registry: widget.registry,
                      lastConnectionStore: widget.lastConnectionStore,
                      configuredKey: _configuredProviderKey,
                      onConfigured: _providerDone,
                      networkSelected: _networkSelected,
                      onJoinNetwork:
                          widget.networkMode != null &&
                              widget.networkSessions != null
                          ? _joinNetwork
                          : null,
                    ),
                    _P3(wide: wide),
                    _P4(wide: wide),
                  ],
                ),
              ),
              _Footer(
                page: _page,
                pageCount: _pageCount,
                wide: wide,
                primaryLabel: _primaryLabel,
                primaryEnabled:
                    (!gated || defaultProvider != null) &&
                    !(last && _providerGateActive),
                onPrimary:
                    _page == 1 && _providerGateActive && defaultProvider != null
                    ? () => _p2Key.currentState?.configureDefault()
                    : last
                    ? () => _finish(skipped: false)
                    : _next,
                onBack: _page > 0 ? _back : null,
                privacyPolicy: widget.productConfig.legalLinks['privacy'],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header: logo + step tabs + Skip
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.productConfig,
    required this.page,
    required this.labels,
    required this.wide,
    required this.onSkip,
  });

  final FaProductConfig productConfig;
  final int page;
  final List<String> labels;
  final bool wide;

  /// Null hides Skip (the mandatory provider step cannot be skipped).
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final steps = _Steps(page: page, labels: labels);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 12, 0),
      child: wide
          ? Row(
              children: [
                _Logo(productConfig: productConfig),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: steps,
                  ),
                ),
                if (onSkip != null) _SkipButton(onTap: onSkip!),
              ],
            )
          : Column(
              children: [
                Row(
                  children: [
                    _Logo(productConfig: productConfig),
                    const Spacer(),
                    if (onSkip != null) _SkipButton(onTap: onSkip!),
                  ],
                ),
                const SizedBox(height: 14),
                steps,
              ],
            ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.productConfig});

  final FaProductConfig productConfig;

  @override
  Widget build(BuildContext context) {
    // The brand app tile (light form — the onboarding is a light design).
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (productConfig.isStock)
          const FaBrandTile(size: 30, dark: false)
        else
          ProductBrandMark(productConfig: productConfig),
        const SizedBox(width: 8),
        Text(
          productConfig.displayName,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: _onbInk(context),
          ),
        ),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: Text(
        context.l10n.onboardingSkip,
        style: TextStyle(
          fontSize: 13,
          color: _onbGray(context),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Step tabs: dots on a connecting line, labels under the dots. Completed
/// steps show a white check in a filled blue circle, the current step is a
/// filled blue dot, future steps are hollow.
class _Steps extends StatelessWidget {
  const _Steps({required this.page, required this.labels});

  final int page;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const dot = 18.0;
        final seg = w / labels.length;
        return SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: seg / 2,
                right: seg / 2,
                top: dot / 2 - 1,
                child: Container(height: 2, color: _onbBorder(context)),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            width: dot,
                            height: dot,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i <= page
                                  ? _onbPrimary(context)
                                  : _onbCard(context),
                              border: Border.all(
                                color: i <= page
                                    ? _onbPrimary(context)
                                    : _onbBorder(context),
                                width: 2,
                              ),
                            ),
                            child: i < page
                                ? const Icon(
                                    Icons.check,
                                    size: 11,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                          const SizedBox(height: 6),
                          // Long labels ("Make it yours") shrink to fit
                          // the narrower 5-step segments.
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                labels[i],
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: i == page
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: i == page
                                      ? _onbPrimary(context)
                                      : _onbGrayLight(context),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Footer: page counter + progress + Back + primary button
// ---------------------------------------------------------------------------

class _Footer extends StatelessWidget {
  const _Footer({
    this.privacyPolicy,
    required this.page,
    required this.pageCount,
    required this.wide,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onBack,
    this.primaryEnabled = true,
  });

  final Uri? privacyPolicy;
  final int page;
  final int pageCount;
  final bool wide;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback? onBack;

  /// False greys out the primary button (mandatory provider step).
  final bool primaryEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final counter = Text(
      l10n.onboardingPageCounter(page + 1, pageCount),
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: _onbInk(context),
      ),
    );
    final back = TextButton(
      onPressed: onBack,
      child: Text(
        l10n.askBack,
        style: TextStyle(
          fontSize: 13.5,
          color: _onbGray(context),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
    final privacy = _PrivacyLink(privacyPolicy);
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 22),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                counter,
                const SizedBox(width: 14),
                _ProgressBar(fraction: (page + 1) / pageCount, width: 200),
                const Spacer(),
                if (onBack != null) ...[back, const SizedBox(width: 16)],
                SizedBox(
                  width: 250,
                  child: _PrimaryButton(
                    label: primaryLabel,
                    onTap: onPrimary,
                    enabled: primaryEnabled,
                  ),
                ),
              ],
            ),
            // Pinned to the footer center: the Back button appearing on
            // later pages must not shift the link horizontally.
            Center(child: privacy),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          Text(
            l10n.onboardingPageCounter(page + 1, pageCount),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: _onbPrimary(context),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (onBack != null) ...[back, const SizedBox(width: 12)],
              Expanded(
                child: _PrimaryButton(
                  label: primaryLabel,
                  onTap: onPrimary,
                  showArrow: false,
                  enabled: primaryEnabled,
                ),
              ),
            ],
          ),
          privacy,
        ],
      ),
    );
  }
}

/// Link to the published privacy policy (fa1.dev/privacy.html).
class _PrivacyLink extends StatelessWidget {
  const _PrivacyLink(this.uri);

  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final product = ProductConfigScope.of(context);
    final destination =
        uri ??
        (product.isStock ? Uri.parse('https://fa1.dev/privacy.html') : null);
    if (destination == null) return const SizedBox.shrink();
    return TextButton(
      onPressed: () => url_launcher.launchUrl(
        destination,
        mode: url_launcher.LaunchMode.externalApplication,
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        context.l10n.onboardingPrivacyPolicy,
        style: TextStyle(
          fontSize: 11,
          color: _onbGrayLight(context),
          decoration: TextDecoration.underline,
          decorationColor: _onbGrayLight(context),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction, required this.width});

  final double fraction;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: _onbBorder(context),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction,
          child: Container(
            decoration: BoxDecoration(
              color: _onbPrimary(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.showArrow = true,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool showArrow;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled
          ? _onbPrimary(context)
          : (_onbDark(context)
                ? const Color(0xFF2A3350)
                : const Color(0xFFB9C2D8)),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 52,
          child: Stack(
            children: [
              Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (showArrow)
                const Positioned(
                  right: 18,
                  top: 0,
                  bottom: 0,
                  child: Icon(
                    Icons.arrow_forward,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

class _TitleBlock extends StatelessWidget {
  const _TitleBlock(this.title, this.subtitle, {this.compact = false});

  final String title;
  final String subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 24 : 34,
            fontWeight: FontWeight.w800,
            color: _onbInk(context),
            letterSpacing: -0.5,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 13 : 15,
            color: _onbGray(context),
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

Widget _card(
  BuildContext context, {
  required Widget child,
  EdgeInsets padding = const EdgeInsets.all(16),
}) {
  final dark = _onbDark(context);
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: dark ? const Color(0xFF10141F) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: dark ? Border.all(color: _onbBorder(context)) : null,
      boxShadow: dark ? null : _kCardShadow,
    ),
    child: child,
  );
}

/// Page-viewport wrapper: renders the page body at its natural size inside
/// a vertically scrollable viewport, capped at [maxWidth] and centered.
/// Replaces two wrappers: the desktop one (centered, scrollable) and the
/// phone one, which scaled the whole page down uniformly — squashing the
/// mockups relative to the chrome around them and shrinking interactive
/// controls (the Allow/Later pills) to near-unusable sizes on phones
/// (issue #1824). Tall pages now scroll instead of shrinking.
class _Fit extends StatelessWidget {
  const _Fit({
    required this.child,
    required this.maxWidth,
    this.centerVertically = false,
  });

  final Widget child;

  /// Content width cap: 1060 for the desktop layout, the 460px reference
  /// prototype width for phones.
  final double maxWidth;

  /// Center short pages vertically in the viewport (desktop); phones keep
  /// pages top-aligned so page transitions never shift content.
  final bool centerVertically;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: centerVertically ? constraints.maxHeight : 0,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Page 1: Start with an idea
// ---------------------------------------------------------------------------

class _P1 extends StatelessWidget {
  const _P1({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          l10n.onboardingP1Title,
          l10n.onboardingP1Subtitle,
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 18),
        if (wide) _wideBody(context) else _narrowBody(context),
        SizedBox(height: wide ? 24 : 18),
        _FeaturesRow(wide: wide),
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    return _Fit(
      maxWidth: wide ? 1060 : 460,
      centerVertically: wide,
      child: body,
    );
  }

  Widget _wideBody(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 26),
                child: _card(
                  context,
                  padding: const EdgeInsets.all(26),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(flex: 12, child: _ChatColumn()),
                      const SizedBox(width: 24),
                      const Expanded(flex: 8, child: _FocusCard()),
                      const SizedBox(width: 24),
                      Expanded(
                        flex: 11,
                        child: _AppsGrid(
                          columns: 3,
                          // Mock app-tile labels (the focus timer badge
                          // is a notification count, not copy).
                          kinds: [
                            (
                              _AppKind.calendar,
                              l10n.onboardingPermissionCalendar,
                              null,
                            ),
                            (_AppKind.notes, l10n.onboardingMockupNotes, null),
                            (
                              _AppKind.utilities,
                              l10n.onboardingMockupUtilities,
                              null,
                            ),
                            (_AppKind.files, l10n.filesPanelTitle, null),
                            (
                              _AppKind.calculator,
                              l10n.onboardingMockupCalculator,
                              null,
                            ),
                            (_AppKind.maps, l10n.onboardingMockupMaps, null),
                            (
                              _AppKind.focusTimer,
                              l10n.onboardingMockupFocusTimer,
                              '1',
                            ),
                            (_AppKind.settings, l10n.settingsTitle, null),
                            (
                              _AppKind.addApp,
                              l10n.onboardingMockupAddApp,
                              null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(top: 0, left: 380, child: _IdeaPill()),
            ],
          ),
        ),
        const SizedBox(width: 20),
        const Opacity(
          opacity: 0.45,
          child: IgnorePointer(
            child: SizedBox(width: 230, child: _ProviderGhost()),
          ),
        ),
      ],
    );
  }

  Widget _narrowBody(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        _card(
          context,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _UserBubble(wide: false),
              SizedBox(height: 12),
              _TypingBubble(),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // "Your idea" card + mini step indicator (like the reference).
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _onbCard(context),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: _onbCardShadow(context),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _onbSelBg(context),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.lightbulb_outline,
                        size: 18,
                        color: _onbPrimary(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.onboardingMockupYourIdea,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _onbInk(context),
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            l10n.onboardingMockupFocusRequest,
                            style: TextStyle(
                              fontSize: 12,
                              color: _onbGray(context),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            const _MiniSteps(),
          ],
        ),
      ],
    );
  }
}

/// Floating idea pill above the desktop page-1 panel.
class _IdeaPill extends StatelessWidget {
  const _IdeaPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _onbCard(context),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1410132B),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 15, color: _onbPrimary(context)),
          SizedBox(width: 8),
          Text(
            context.l10n.onboardingMockupFocusRequestPill,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: _onbInk(context),
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mini 3-dot step indicator next to the idea card (mobile page 1).
class _MiniSteps extends StatelessWidget {
  const _MiniSteps();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = [
      l10n.onboardingStepThink,
      l10n.onboardingStepAct,
      l10n.onboardingMiniStepYours,
    ];
    return SizedBox(
      width: 150,
      height: 40,
      child: Stack(
        children: [
          Positioned(
            left: 25,
            right: 25,
            top: 5,
            child: Divider(height: 2, thickness: 2, color: _onbBorder(context)),
          ),
          Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == 0
                              ? _onbPrimary(context)
                              : _onbCard(context),
                          border: Border.all(
                            color: i == 0
                                ? _onbPrimary(context)
                                : _onbBorder(context),
                            width: 2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      // A RU label ("Действуйте") is wider than the 50px
                      // column: scale it down instead of wrapping mid-word.
                      // EN labels fit at scale 1.0 and render top-centred,
                      // so the stock frame stays pixel-identical (goldens).
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: Text(
                          labels[i],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: i == 0
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: i == 0
                                ? _onbInk(context)
                                : _onbGrayLight(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatColumn extends StatelessWidget {
  const _ChatColumn();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _UserBubble(wide: true),
        SizedBox(height: 14),
        _TypingBubble(),
        SizedBox(height: 16),
        _ChatInput(),
      ],
    );
  }
}

class _AppsGrid extends StatelessWidget {
  const _AppsGrid({required this.columns, required this.kinds});

  final int columns;
  final List<(_AppKind, String, String?)> kinds;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 14,
      children: [
        for (final (kind, label, badge) in kinds)
          _AppTile(kind, label, badge: badge),
      ],
    );
  }
}

class _FeaturesRow extends StatelessWidget {
  const _FeaturesRow({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = [
      (
        Icons.chat_bubble,
        l10n.onboardingFeatureAnswers,
        const Color(0xFF5B63F0),
      ),
      (
        Icons.apps_rounded,
        l10n.onboardingFeatureUsesApps,
        const Color(0xFF2EBD9E),
      ),
      (
        Icons.auto_awesome,
        l10n.onboardingFeatureBuildsApps,
        const Color(0xFF5B63F0),
      ),
    ];
    if (wide) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (icon, label, color) in items) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: _onbGray(context),
              ),
            ),
            const SizedBox(width: 36),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (final (icon, label, color) in items) ...[
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              decoration: BoxDecoration(
                color: _onbCard(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _onbBorder(context)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: _onbInk(context),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (label != items.last.$2) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// Faded "Choose how Fa thinks." preview shown on page 1 (desktop).
class _ProviderGhost extends StatelessWidget {
  const _ProviderGhost();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.onboardingChooseHowThinks(
            ProductConfigScope.of(context).displayName,
          ),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: _onbInk(context),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.onboardingConnectProviderToStart,
          style: TextStyle(fontSize: 11.5, color: _onbGray(context)),
        ),
        const SizedBox(height: 16),
        // Provider names are brands (never translated); badges and the
        // one-line descriptions are copy.
        _ghostRow(
          context,
          Icons.autorenew,
          'OpenRouter',
          l10n.onboardingBadgeRecommended,
          l10n.onboardingGhostOpenRouterDesc,
          recommended: true,
        ),
        _ghostRow(
          context,
          Icons.cruelty_free,
          'Ollama',
          l10n.onboardingBadgeLocal,
          l10n.onboardingGhostOllamaDesc,
        ),
        _ghostRow(
          context,
          Icons.auto_awesome,
          'Google Gemini',
          null,
          l10n.onboardingGhostGeminiDesc,
        ),
        _ghostRow(
          context,
          Icons.code,
          l10n.onboardingGhostCustomProvider,
          null,
          l10n.onboardingGhostCustomDesc,
        ),
      ],
    );
  }

  Widget _ghostRow(
    BuildContext context,
    IconData icon,
    String name,
    String? badge,
    String desc, {
    bool recommended = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: _onbGrayLight(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: _onbInk(context),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 6),
                      _Badge(badge, recommended: recommended),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: _onbGray(context),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.recommended = false});
  final String text;

  /// The "Recommended" badge takes the blue tint; every other badge the
  /// green one. A flag, not a string compare — the text is localized.
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final rec = recommended;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: rec ? const Color(0xFFE5EAFE) : const Color(0xFFE3F7EE),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: rec ? _onbPrimary(context) : Color(0xFF0E9F6E),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page 2: Choose how Fa thinks
// ---------------------------------------------------------------------------

class _P2 extends StatefulWidget {
  const _P2({
    super.key,
    required this.wide,
    this.defaultProvider,
    this.registry,
    this.lastConnectionStore,
    this.configuredKey,
    this.onConfigured,
    this.networkSelected = false,
    this.onJoinNetwork,
  });

  final bool wide;

  /// Branded first-run default. It is selected immediately, but its real
  /// connect flow still has to complete before the provider gate unlocks.
  final faui.AddProviderPreset? defaultProvider;

  /// The shared provider registry; null renders the list inert (tests).
  final faui.ProviderRegistry? registry;

  /// Persists the configured provider as the restorable last connection.
  final LastConnectionStore? lastConnectionStore;

  /// The preset that completed its flow (its card gets the check).
  final String? configuredKey;

  /// Fired with the preset key once a config flow completes successfully.
  final ValueChanged<String>? onConfigured;

  final bool networkSelected;
  final VoidCallback? onJoinNetwork;

  @override
  State<_P2> createState() => _P2State();
}

class _P2State extends State<_P2> {
  var _busy = false;
  Timer? _busyTimer;

  /// Presets whose config flow is currently running. An SSO/OAuth flow
  /// waits on the system browser for minutes — far longer than the 3s
  /// double-tap lock — so a re-tap on the SAME card must stay ignored for
  /// the whole flow (two taps used to spawn two callback servers and two
  /// browser tabs).
  final _runningPresets = <String>{};

  @override
  void dispose() {
    _busyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: widget.wide ? 20 : 12),
        _TitleBlock(
          l10n.onboardingChooseHowThinks(
            ProductConfigScope.of(context).displayName,
          ),
          l10n.onboardingP2Subtitle,
          compact: !widget.wide,
        ),
        SizedBox(height: widget.wide ? 24 : 18),
        if (widget.wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 220, child: _RequestCard()),
              const SizedBox(width: 24),
              Expanded(child: _cards()),
              const SizedBox(width: 24),
              const Opacity(
                opacity: 0.45,
                child: IgnorePointer(
                  child: SizedBox(width: 220, child: _AccessGhost()),
                ),
              ),
            ],
          )
        else ...[
          const _RequestConfirmedCard(),
          const SizedBox(height: 14),
          _cards(),
        ],
        const SizedBox(height: 18),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F8),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 15,
                  color: _onbGrayLight(context),
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.onboardingP2KeysNote,
                    style: TextStyle(
                      fontSize: 11,
                      color: _onbGray(context),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: widget.wide ? 28 : 20),
      ],
    );
    return _Fit(
      maxWidth: widget.wide ? 1060 : 460,
      centerVertically: widget.wide,
      child: body,
    );
  }

  Widget _cards() {
    // The SAME list the app's "Add provider" picker shows — filtered by
    // the catalog visibility rules (hidden providers like ChatGPT Codex
    // and the FA_PROVIDERS build filter never appear here).
    return Column(
      children: [
        for (final preset in faui.defaultAddProviderPresets.where(
          faui.addProviderPresetEnabled,
        )) ...[
          _ProviderCard(
            preset: preset,
            selected:
                widget.configuredKey == null &&
                widget.defaultProvider?.key == preset.key,
            configured: widget.configuredKey == preset.key,
            onTap: _busy ? null : () => _configure(preset),
          ),
          const SizedBox(height: 10),
        ],
        if (widget.onJoinNetwork != null) ...[
          const SizedBox(height: 6),
          _NetworkCard(
            selected: widget.networkSelected,
            onTap: _busy ? null : widget.onJoinNetwork,
          ),
        ],
      ],
    );
  }

  /// The footer's default-provider action: the same real flow as a card
  /// tap, never a visual-only bypass of the connection gate.
  Future<void> configureDefault() async {
    final preset = widget.defaultProvider;
    if (preset != null) await _configure(preset);
  }

  /// Routes a preset tap to the provider's real config flow (the same
  /// routing as the app's Add Provider picker): SSO/OAuth flows for
  /// CodeMie/ChatGPT, the editor for key-based presets and Custom.
  Future<void> _configure(faui.AddProviderPreset preset) async {
    final registry = _beginPresetFlow(preset);
    if (registry == null) return;
    var ok = false;
    try {
      ok = await _runPresetFlow(preset, registry);
    } on Object catch (e) {
      _showFlowError(e);
    } finally {
      _endPresetFlow(preset.key);
    }
    _notifyConfigured(preset.key, ok);
  }

  /// Claims the tap for [preset] (null = ignore): no registry, the
  /// double-tap lock, or the same preset already mid-flow.
  faui.ProviderRegistry? _beginPresetFlow(faui.AddProviderPreset preset) {
    final registry = widget.registry;
    if (registry == null || _busy) return null;
    if (!_runningPresets.add(preset.key)) return null; // flow already running
    setState(() => _busy = true);
    _armBusyTimer();
    return registry;
  }

  /// The busy flag is double-tap protection, NOT a flow-long lock: an SSO
  /// flow waits on the system browser and may hang for minutes when the
  /// user abandons it — it must never lock the whole list. The flows are
  /// modal anyway, so a short window is all the protection needed.
  void _armBusyTimer() {
    _busyTimer?.cancel();
    _busyTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _busy = false);
    });
  }

  void _endPresetFlow(String presetKey) {
    _runningPresets.remove(presetKey);
    _busyTimer?.cancel();
    if (mounted) setState(() => _busy = false);
  }

  void _showFlowError(Object e) {
    debugPrint('[onboarding] provider flow failed: $e');
    if (mounted) {
      final l10n = context.l10n;
      faui.showFahErrorSnack(context, l10n.onboardingFlowError('$e'));
    }
  }

  void _notifyConfigured(String presetKey, bool ok) {
    if (ok && mounted) widget.onConfigured?.call(presetKey);
  }

  /// The SSO/OAuth presets, routed to their flows below (the same set the
  /// app's Add Provider picker routes); everything else is key-based.
  static const _ssoFlowKeys = {'codemie', 'chatgpt', 'aiin'};

  Future<bool> _runPresetFlow(
    faui.AddProviderPreset preset,
    faui.ProviderRegistry registry,
  ) {
    if (preset.key == 'custom') return _connectCustom(preset, registry);
    if (_ssoFlowKeys.contains(preset.key)) {
      return _connectSso(preset.key, registry);
    }
    return _configureKeyBased(preset, registry);
  }

  Future<bool> _connectSso(String presetKey, faui.ProviderRegistry registry) {
    if (presetKey == 'codemie') return _connectCodemie(registry);
    return _connectChatGptOrAiin(presetKey, registry);
  }

  /// The remaining SSO presets (gh-1848 split): ChatGPT → its OAuth
  /// browser flow, everything else (AIIN) → its connect flow.
  Future<bool> _connectChatGptOrAiin(
    String presetKey,
    faui.ProviderRegistry registry,
  ) {
    switch (presetKey) {
      case 'chatgpt':
        return _connectChatGpt(registry);
      default:
        return _connectAiin(registry);
    }
  }

  Future<bool> _connectCodemie(faui.ProviderRegistry registry) =>
      runCodemieSsoFlow(
        context: context,
        registry: registry,
        service: null, // no live service during onboarding
        lastConnectionStore:
            widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
      );

  Future<bool> _connectChatGpt(faui.ProviderRegistry registry) =>
      runChatGptOAuthFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore:
            widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
      );

  Future<bool> _connectAiin(faui.ProviderRegistry registry) =>
      runAiinConnectFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore:
            widget.lastConnectionStore ?? LastConnectionStore.inMemory(),
      );

  Future<bool> _connectCustom(
    faui.AddProviderPreset preset,
    faui.ProviderRegistry registry,
  ) async {
    final provider = await faui.pushProviderEditor(
      context,
      registry,
      title: preset.name,
      // Issue #1020: boarding cannot leave without a chat model — the
      // editor refuses a model-less save instead of unlocking the step
      // into an unusable chat.
      requireModel: true,
    );
    if (provider == null) return false;
    await _saveConnection(provider.baseUrl, provider.modelId, '');
    return true;
  }

  /// Key-based preset keys and the editor preset each opens; a key not in
  /// the map gets the editable custom editor (see [_keyBasedEditorPage]).
  static const _keyBasedPresetModes = <String, faui.ProviderPreset>{
    'openrouter': faui.ProviderPreset.openrouter,
    'ollama': faui.ProviderPreset.ollamaCloud,
    'google': faui.ProviderPreset.gemini,
    'dial': faui.ProviderPreset.dial,
  };

  /// Key-based preset: the editor pre-filled with the preset endpoint,
  /// then persist the provider, its key, and the last connection.
  Future<bool> _configureKeyBased(
    faui.AddProviderPreset preset,
    faui.ProviderRegistry registry,
  ) async {
    final presetMode = _keyBasedPresetModes[preset.key];
    final result = await faui.pushFaPage<faui.ProviderEditorResult>(
      context,
      _keyBasedEditorPage(preset, presetMode, registry),
    );
    if (result == null || result.deleted) return false;
    await _persistKeyBased(result, registry);
    return true;
  }

  /// Every key-based preset keeps an editable base URL in the editor —
  /// the preset endpoint is just the prefill (self-hosted DIAL/Ollama
  /// instances point at their own URL). An unknown key (or [presetMode]
  /// null) opens the fully editable custom editor pre-filled with the
  /// preset's name/URL.
  faui.ProviderEditorPage _keyBasedEditorPage(
    faui.AddProviderPreset preset,
    faui.ProviderPreset? presetMode,
    faui.ProviderRegistry registry,
  ) {
    final editable = presetMode == null;
    return faui.ProviderEditorPage(
      title: preset.name,
      preset: editable ? null : presetMode,
      // Issue #1020: same boarding gate as the custom editor — Z.AI/Kimi
      // prefill name/URL but no model, and a model-less save must not
      // unlock the step.
      requireModel: true,
      prefillName: editable ? preset.name : null,
      prefillBaseUrl: editable ? preset.baseUrl : null,
      keyHelpUrl: preset.keyHelpUrl,
      registry: registry,
      openRouterOAuthCallbackUrl:
          OpenRouterOAuthCoordinator.instance.platformCallbackUrl,
      openRouterOAuthCapture: OpenRouterOAuthCoordinator.instance.capture,
    );
  }

  Future<void> _persistKeyBased(
    faui.ProviderEditorResult result,
    faui.ProviderRegistry registry,
  ) async {
    final provider = await registry.add(
      name: result.name,
      baseUrl: result.baseUrl,
      modelId: result.modelId,
    );
    if (result.apiKey.isNotEmpty) {
      registry.rememberKey(provider.id, result.apiKey);
    }
    await _saveConnection(result.baseUrl, result.modelId, result.apiKey);
  }

  /// Persists the fresh connection so the boot auto-connects straight to
  /// chat after onboarding (the key itself resolves via the registry).
  Future<void> _saveConnection(String baseUrl, String modelId, String apiKey) {
    final store = widget.lastConnectionStore;
    if (store == null) return Future<void>.value();
    // Belt-and-braces under the editor's requireModel gate (issue #1020
    // review): boarding must never persist a model-less connection, even
    // if a future flow pops the editor without the flag.
    assert(
      modelId.isNotEmpty,
      'boarding must never persist a model-less connection (#1020)',
    );
    return store.saveFromConfig(
      AgentConfig(
        providerKind: 'openai-completions',
        modelId: modelId,
        baseUrl: baseUrl,
        apiKey: apiKey,
      ),
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback? onTap;

  Color _background(BuildContext context) =>
      selected ? _onbSelBg(context) : _onbCard(context);

  Color _border(BuildContext context) =>
      selected ? _onbPrimary(context) : _onbBorder(context);

  IconData get _trailingIcon =>
      selected ? Icons.check_circle : Icons.arrow_forward;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _background(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: _border(context)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(Icons.hub_outlined, color: _onbPrimary(context), size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.onboardingJoinNetwork,
                      style: TextStyle(
                        color: _onbInk(context),
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.onboardingJoinNetworkSubtitle,
                      style: TextStyle(
                        color: _onbGray(context),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(_trailingIcon, color: _onbPrimary(context), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Built-in provider preset key → the card description in the app's ARB.
///
/// The shared fa_ui catalog carries English-only descriptions, so the
/// onboarding card resolves the same copy from [AppLocalizations] by preset
/// key (the English values mirror the fa_ui preset text exactly). Names are
/// brands and stay as the preset declares them.
final _presetDescriptions = <String, String Function(AppLocalizations l10n)>{
  'aiin': (l10n) => l10n.onboardingProviderDescAin,
  'openrouter': (l10n) => l10n.onboardingProviderDescOpenrouter,
  'chatgpt': (l10n) => l10n.onboardingProviderDescChatgpt,
  'copilot': (l10n) => l10n.onboardingProviderDescCopilot,
  'codemie': (l10n) => l10n.onboardingProviderDescCodemie,
  'openai': (l10n) => l10n.onboardingProviderDescOpenai,
  'anthropic': (l10n) => l10n.onboardingProviderDescAnthropic,
  'google': (l10n) => l10n.onboardingProviderDescGoogle,
  'dial': (l10n) => l10n.onboardingProviderDescDial,
  'kimi': (l10n) => l10n.onboardingProviderDescKimi,
  'minimax': (l10n) => l10n.onboardingProviderDescMinimax,
  'zai': (l10n) => l10n.onboardingProviderDescZai,
  'ollama': (l10n) => l10n.onboardingProviderDescOllama,
  'custom': (l10n) => l10n.onboardingProviderDescCustom,
};

/// The one-line description under a provider card's name. A preset the map
/// does not know (a host-added one) keeps its own description.
String _presetDescription(BuildContext context, faui.AddProviderPreset preset) {
  final l10n = context.l10n;
  return (_presetDescriptions[preset.key] ?? (_) => preset.description)(l10n);
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.preset,
    required this.selected,
    required this.configured,
    required this.onTap,
  });

  final faui.AddProviderPreset preset;
  final bool selected;
  final bool configured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = selected || configured;
    return Material(
      color: active ? _onbSelBg(context) : _onbCard(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? _onbPrimary(context) : _onbBorder(context),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              faui.ProviderMark(preset.key, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: _onbInk(context),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _presetDescription(context, preset),
                      style: TextStyle(fontSize: 12, color: _onbGray(context)),
                    ),
                  ],
                ),
              ),
              if (configured)
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _onbPrimary(context),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check, size: 13, color: Colors.white),
                )
              else if (selected)
                // Painted radio dot, not an Icons.* glyph: the styleguide
                // ratchet freezes this file's Material icon count.
                Container(
                  key: const ValueKey('onboardingProviderSelected'),
                  width: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _onbPrimary(context), width: 2),
                  ),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _onbPrimary(context),
                    ),
                  ),
                )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: _onbGrayLight(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating "Your request" card (desktop page 2).
class _RequestCard extends StatelessWidget {
  const _RequestCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _onbCard(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _onbBorder(context)),
        boxShadow: _onbCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.onboardingYourRequest,
            style: TextStyle(
              fontSize: 11,
              color: _onbGray(context),
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.auto_awesome, size: 15, color: _onbPrimary(context)),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.l10n.onboardingMockupFocusRequest,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: _onbInk(context),
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact confirmed-request card (mobile page 2).
class _RequestConfirmedCard extends StatelessWidget {
  const _RequestConfirmedCard();

  @override
  Widget build(BuildContext context) {
    return _card(
      context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Color(0xFFE3F7EE),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check, size: 17, color: _kGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.onboardingMockupFocusRequest,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _onbInk(context),
                height: 1.3,
              ),
            ),
          ),
          Icon(Icons.auto_awesome, size: 18, color: _onbPrimary(context)),
        ],
      ),
    );
  }
}

/// Faded "Give access" preview shown on page 2 (desktop).
class _AccessGhost extends StatelessWidget {
  const _AccessGhost();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final product = ProductConfigScope.of(context).displayName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.onboardingProductCanAct(product),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: _onbInk(context),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.onboardingProductAsksOnly(product),
          style: TextStyle(fontSize: 11, color: _onbGray(context)),
        ),
        const SizedBox(height: 14),
        for (final (icon, label) in [
          (Icons.calendar_month, l10n.onboardingPermCalendarTitle),
          (Icons.notifications, l10n.onboardingPermissionNotifications),
          (Icons.mic, l10n.onboardingPermissionMicrophone),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: _onbGrayLight(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: _onbInk(context),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  l10n.onboardingAskWhenNeeded,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: _onbPrimary(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Page 3: Give access only when it helps
// ---------------------------------------------------------------------------

class _P3 extends StatelessWidget {
  const _P3({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          l10n.onboardingP3Title,
          l10n.onboardingP3Subtitle(ProductConfigScope.of(context).displayName),
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    const _FlowDiagram(),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _PermCard(
                            icon: Icons.calendar_month,
                            tint: Color(0xFFEF4444),
                            tintBg: Color(0xFFFDECEC),
                            title: l10n.onboardingPermCalendarTitle,
                            desc: l10n.onboardingPermCalendarDesc,
                            vertical: true,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: _PermCard(
                            icon: Icons.notifications,
                            tint: Color(0xFF3B82F6),
                            tintBg: Color(0xFFEAF2FE),
                            title: l10n.onboardingPermissionNotifications,
                            desc: l10n.onboardingPermNotificationsDesc,
                            vertical: true,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: _PermCard(
                            icon: Icons.mic,
                            tint: Color(0xFF8B5CF6),
                            tintBg: Color(0xFFF1EDFE),
                            title: l10n.onboardingPermissionMicrophone,
                            desc: l10n.onboardingPermMicrophoneDesc(
                              ProductConfigScope.of(context).displayName,
                            ),
                            vertical: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              const Expanded(flex: 2, child: _WhatYouGet()),
            ],
          )
        else ...[
          const _FlowCard(),
          const SizedBox(height: 10),
          _PermCard(
            icon: Icons.calendar_month,
            tint: Color(0xFFEF4444),
            tintBg: Color(0xFFFDECEC),
            title: l10n.onboardingPermCalendarTitle,
            desc: l10n.onboardingPermCalendarDesc,
          ),
          const SizedBox(height: 8),
          _PermCard(
            icon: Icons.notifications,
            tint: Color(0xFF3B82F6),
            tintBg: Color(0xFFEAF2FE),
            title: l10n.onboardingPermissionNotifications,
            desc: l10n.onboardingPermNotificationsDesc,
          ),
          const SizedBox(height: 8),
          _PermCard(
            icon: Icons.mic,
            tint: Color(0xFF8B5CF6),
            tintBg: Color(0xFFF1EDFE),
            title: l10n.onboardingPermissionMicrophone,
            desc: l10n.onboardingPermMicrophoneDesc(
              ProductConfigScope.of(context).displayName,
            ),
          ),
        ],
        SizedBox(height: wide ? 18 : 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 16,
              color: Color(0xFF5B63F0),
            ),
            SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.onboardingNothingEnabledByDefault,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _onbInk(context),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    l10n.onboardingManageAccessInSettings,
                    style: TextStyle(fontSize: 11, color: _onbGray(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (!wide) ...[const SizedBox(height: 12), const _MyAppsMini()],
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    return _Fit(
      maxWidth: wide ? 1060 : 460,
      centerVertically: wide,
      child: body,
    );
  }
}

// ---------------------------------------------------------------------------
// Page 4: Your sandbox is ready
// ---------------------------------------------------------------------------

class _P4 extends StatelessWidget {
  const _P4({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: wide ? 20 : 12),
        _TitleBlock(
          l10n.onboardingP4Title,
          l10n.onboardingP4Subtitle(ProductConfigScope.of(context).displayName),
          compact: !wide,
        ),
        SizedBox(height: wide ? 24 : 16),
        if (wide)
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _CreatedColumn()),
              SizedBox(width: 20),
              Expanded(flex: 6, child: _MyAppsPanel()),
            ],
          )
        else ...const [
          _CreatedCard(),
          SizedBox(height: 10),
          _MyAppsPanel(compact: true),
        ],
        SizedBox(height: wide ? 22 : 14),
        Text(
          l10n.onboardingTryIdeas,
          style: TextStyle(fontSize: 12, color: _onbGray(context)),
        ),
        const SizedBox(height: 8),
        _Suggestions(wide: wide),
        SizedBox(height: wide ? 28 : 20),
      ],
    );
    return _Fit(
      maxWidth: wide ? 1060 : 460,
      centerVertically: wide,
      child: body,
    );
  }
}
