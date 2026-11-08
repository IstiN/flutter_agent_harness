// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n_ext.dart';
import '../../services/analytics.dart';
import '../../services/links_loader.dart';
import '../../services/store_banner_store.dart';

/// The dismissible, non-blocking App Store Get banner (issue #691 AC4):
/// shown on the web + macOS Get surface (Settings top) only — iOS and
/// Android users are already in a store ecosystem, and the desktop CLI
/// has its own install story.
///
/// Every URL and the Android slot label come from the `links:` config
/// section via [StoreBannerView] (one source of truth — flip the link
/// in the config and the banner flips with it, AC1). `links.banner:
/// false` mounts NOTHING anywhere (the AC7 regression switch — the
/// surface stays byte-identical to the legacy UI). Dismissal persists
/// through [StoreBannerStore] and survives restarts; the banner never
/// blocks interaction (it is a card in the scroll, not an overlay).
class StoreGetBanner extends StatefulWidget {
  const StoreGetBanner({
    super.key,
    required this.env,
    this.links,
    this.showOnPlatform = true,
    this.platformLabel,
  });

  /// The sandbox root — hosts the dismissal store file.
  final ExecutionEnv env;

  /// The resolved links (tests inject; default [resolveAppLinks]).
  final AppLinksResolution? links;

  /// Whether the CURRENT platform carries the banner at all — the host
  /// decides (`kIsWeb || defaultTargetPlatform == macOS`); tests force.
  final bool showOnPlatform;

  /// The analytics platform split label (`web` / `macos`); defaults from
  /// the compile-time platform.
  final String? platformLabel;

  @override
  State<StoreGetBanner> createState() => _StoreGetBannerState();
}

class _StoreGetBannerState extends State<StoreGetBanner> {
  late final AppLinksResolution _links = widget.links ?? resolveAppLinks();
  late final StoreBannerView _view = StoreBannerView.from(_links.links);
  late final StoreBannerStore _store = StoreBannerStore(widget.env);
  bool _dismissed = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _store.loadDismissed().then((dismissed) {
      if (mounted) setState(() => _dismissed = dismissed);
      if (mounted) setState(() => _ready = true);
    });
  }

  String get _platform =>
      widget.platformLabel ?? (kIsWeb ? 'web' : defaultTargetPlatform.name);

  @override
  Widget build(BuildContext context) {
    // The AC7 regression switch: banner off = nothing mounts, anywhere.
    if (!widget.showOnPlatform || !_links.links.banner || _dismissed) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final tokens = faui.FaDesignTokens.of(context);
    // Until the persisted dismissal loads, reserve nothing — the banner
    // appears at most one frame later on a fresh sandbox.
    if (!_ready) return const SizedBox.shrink();
    final androidLabel = _view.androidComingSoon
        ? l10n.storeBannerAndroidSoon
        : _view.androidLabel;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.storeBannerTitle,
          style: TextStyle(
            color: tokens.ink1,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '${l10n.storeBannerBody} · $androidLabel',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tokens.ink2, fontSize: 12, height: 1.3),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        faui.FaButton(
          label: l10n.storeBannerCta,
          dense: true,
          onPressed: () => _open(_view.appstoreUrl, target: 'appstore'),
        ),
        faui.FaButton(
          label: l10n.storeBannerBeta,
          variant: faui.FaButtonVariant.ghost,
          dense: true,
          onPressed: () => _open(_view.testflightUrl, target: 'testflight'),
        ),
      ],
    );
    final dismiss = faui.FaIconActionButton(
      diameter: 32,
      glyphSize: 16,
      glass: false,
      tooltip: l10n.storeBannerDismiss,
      onPressed: _dismiss,
      child: const faui.FaIcon(faui.FaSemanticIcon.close),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: faui.FaSurface(
        key: const ValueKey('storeGetBannerSurface'),
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final icon = faui.FaIcon(
                faui.FaSemanticIcon.phone,
                size: 20,
                color: tokens.accent,
              );
              if (constraints.maxWidth < 900) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [copy, const SizedBox(height: 8), actions],
                      ),
                    ),
                    dismiss,
                  ],
                );
              }
              return Row(
                children: [
                  icon,
                  const SizedBox(width: 10),
                  Expanded(child: copy),
                  const SizedBox(width: 12),
                  actions,
                  dismiss,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _open(String url, {required String target}) {
    AppAnalytics.instance.storeReferralTap(
      placement: 'get_banner',
      platform: _platform,
      target: target,
    );
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _dismiss() async {
    AppAnalytics.instance.storeBannerDismissed(_platform);
    setState(() => _dismissed = true);
    await _store.saveDismissed();
  }
}
