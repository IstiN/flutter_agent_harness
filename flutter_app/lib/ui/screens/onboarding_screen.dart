// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/fa_mark.dart';

/// The first-launch onboarding flow, shown once by `BootstrapScreen` when
/// there is no restorable last connection (see [OnboardingStore]): a paged
/// intro (welcome + AI disclaimer → permissions explainer → model preset
/// mini-wizard → privacy) with page dots, a Skip button on every page, and
/// one primary button per page ("Get started" on the last).
///
/// App Store compliance notes: page 1 carries the AI-features description
/// and the "AI can make mistakes" disclaimer, page 2 explains every
/// permission WITHOUT triggering the system prompts (each is requested in
/// context later), and page 4 links the privacy policy. Completing or
/// skipping both call [OnboardingStore.markSeen] and [onFinished] — the boot
/// flow then continues (auto-connect or the setup screen).
class OnboardingScreen extends StatefulWidget {
  /// Creates the flow.
  const OnboardingScreen({
    super.key,
    this.onboardingStore,
    this.mediaModelsStore,
    this.lastConnectionStore,
    this.initialPage = 0,
    this.onFinished,
  });

  /// The seen-flag store; completing or skipping marks it. Null = nothing
  /// persists (tests).
  final OnboardingStore? onboardingStore;

  /// Store the model preset wizard writes slot overrides into; falls back to
  /// the nearest [MediaModelsScope]. When neither is available page 3 shows
  /// the "set up later" path only.
  final MediaModelsStore? mediaModelsStore;

  /// Updated when a preset is applied (the boot auto-connect restores it).
  final LastConnectionStore? lastConnectionStore;

  /// Page to start on (goldens/tests); production always starts at 0.
  final int initialPage;

  /// Called after the seen flag is set — the boot flow continues. [skipped]
  /// is true when the user left via the Skip button.
  final void Function({required bool skipped})? onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 4;

  /// No dedicated privacy policy ships with the app or the project site —
  /// the link points at the project landing page.
  static const _privacyPolicyUrl =
      'https://istin.github.io/flutter_agent_harness/';

  late final PageController _pageController = PageController(
    initialPage: widget.initialPage,
  );
  final PageController _presetPageController = PageController(
    viewportFraction: 0.9,
  );
  late var _page = widget.initialPage;
  var _presetPage = 0;
  String? _appliedPresetId;
  SessionKeysStore? _keysStore;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.onboardingStarted();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keysStore = SessionKeysScope.maybeOf(context);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _presetPageController.dispose();
    super.dispose();
  }

  void _finish({required bool skipped}) {
    if (skipped) {
      AppAnalytics.instance.onboardingSkipped(_page);
    } else {
      AppAnalytics.instance.onboardingCompleted();
    }
    // The flag flips synchronously; the env write rides along.
    unawaited(widget.onboardingStore?.markSeen() ?? Future<void>.value());
    widget.onFinished?.call(skipped: skipped);
  }

  void _nextPage() {
    unawaited(
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  Future<void> _applyPreset(ModelPreset preset) async {
    final store = widget.mediaModelsStore ?? MediaModelsScope.maybeOf(context);
    if (store == null) return;
    await applyModelPreset(
      preset: preset,
      // Pre-connection: only the slot overrides + last connection persist;
      // the boot auto-connect builds the real service from them.
      service: null,
      store: store,
      keysStore: _keysStore,
      lastConnectionStore: widget.lastConnectionStore,
    );
    if (mounted) setState(() => _appliedPresetId = preset.id);
  }

  /// The missing-key jump, mirroring the settings preset card: open the
  /// provider editor, save the returned key under the preset's key name.
  Future<void> _setupPresetKey(ModelPreset preset) async {
    final target = preset.target;
    if (target is! HostedModelPresetTarget) return;
    final provider = target.provider;
    final keyName = hostedProviderKeyName(provider);
    final result = await Navigator.of(context).push<ProviderEditorResult>(
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          title: provider.labelFor(context),
          preset: provider,
          hasSavedKey:
              keyName != null && settingsKeyEnv(keyName, _keysStore).isNotEmpty,
        ),
      ),
    );
    if (result == null || result.apiKey.isEmpty || keyName == null) return;
    await _keysStore?.set(keyName, result.apiKey);
  }

  Future<void> _openPrivacyPolicy() async {
    try {
      await launchUrl(
        Uri.parse(_privacyPolicyUrl),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // Best effort: no browser is not an error worth surfacing here.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isLast = _page == _pageCount - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _finish(skipped: true),
                child: Text(l10n.onboardingSkip),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _buildWelcomePage(theme, l10n),
                  _buildPermissionsPage(theme, l10n),
                  _buildModelsPage(theme, l10n),
                  _buildPrivacyPage(theme, l10n),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pageCount; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.3,
                            ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: isLast ? () => _finish(skipped: false) : _nextPage,
                  child: Text(
                    isLast ? l10n.onboardingGetStarted : l10n.onboardingNext,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Page shell: a vertically scrollable column so small phones never clip.
  Widget _pageScroll(List<Widget> children) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _pageTitle(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _pageBody(ThemeData theme, String body) {
    return Text(
      body,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      textAlign: TextAlign.center,
    );
  }

  // ---------------------------------------------------------------- page 1

  Widget _buildWelcomePage(ThemeData theme, AppLocalizations l10n) {
    return _pageScroll([
      const SizedBox(height: 24),
      const Center(child: FaMark(size: 72)),
      const SizedBox(height: 24),
      _pageTitle(theme, l10n.onboardingWelcomeTitle),
      const SizedBox(height: 8),
      _pageBody(theme, l10n.onboardingWelcomeBody),
      const SizedBox(height: 24),
      _featureRow(
        theme,
        icon: Icons.grid_view_rounded,
        text: l10n.onboardingFeatureApps,
      ),
      _featureRow(
        theme,
        icon: Icons.image_outlined,
        text: l10n.onboardingFeatureMedia,
      ),
      _featureRow(
        theme,
        icon: Icons.auto_awesome,
        text: l10n.onboardingFeatureAutomation,
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.psychology_alt_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.onboardingAiDisclaimerTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.onboardingAiDisclaimer,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
    ]);
  }

  Widget _featureRow(
    ThemeData theme, {
    required IconData icon,
    required String text,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- page 2

  Widget _buildPermissionsPage(ThemeData theme, AppLocalizations l10n) {
    final entries = <(IconData, String, String)>[
      (
        Icons.notifications_outlined,
        l10n.onboardingPermissionNotifications,
        l10n.onboardingPermissionNotificationsDesc,
      ),
      (
        Icons.mic_none,
        l10n.onboardingPermissionMicrophone,
        l10n.onboardingPermissionMicrophoneDesc,
      ),
      (
        Icons.calendar_month_outlined,
        l10n.onboardingPermissionCalendar,
        l10n.onboardingPermissionCalendarDesc,
      ),
      (
        Icons.contacts_outlined,
        l10n.onboardingPermissionContacts,
        l10n.onboardingPermissionContactsDesc,
      ),
      (
        Icons.favorite_border,
        l10n.onboardingPermissionHealth,
        l10n.onboardingPermissionHealthDesc,
      ),
      (
        Icons.home_outlined,
        l10n.onboardingPermissionHome,
        l10n.onboardingPermissionHomeDesc,
      ),
    ];
    return _pageScroll([
      const SizedBox(height: 24),
      _pageTitle(theme, l10n.onboardingPermissionsTitle),
      const SizedBox(height: 8),
      _pageBody(theme, l10n.onboardingPermissionsBody),
      const SizedBox(height: 24),
      for (final (icon, name, desc) in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleSmall),
                    Text(
                      desc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 24),
    ]);
  }

  // ---------------------------------------------------------------- page 3

  Widget _buildModelsPage(ThemeData theme, AppLocalizations l10n) {
    final store = widget.mediaModelsStore ?? MediaModelsScope.maybeOf(context);
    return _pageScroll([
      const SizedBox(height: 24),
      _pageTitle(theme, l10n.onboardingModelsTitle),
      const SizedBox(height: 8),
      _pageBody(theme, l10n.onboardingModelsBody),
      const SizedBox(height: 16),
      if (store != null) ...[
        SizedBox(
          height: 260,
          child: PageView.builder(
            controller: _presetPageController,
            itemCount: kModelPresets.length,
            onPageChanged: (page) => setState(() => _presetPage = page),
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _OnboardingPresetCard(
                preset: kModelPresets[index],
                keyAvailable: modelPresetKeyAvailable(
                  kModelPresets[index],
                  _keysStore,
                ),
                applied: _appliedPresetId == kModelPresets[index].id,
                onApply: () => _applyPreset(kModelPresets[index]),
                onSetKey: () => _setupPresetKey(kModelPresets[index]),
              ),
            ),
          ),
        ),
        if (kModelPresets.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < kModelPresets.length; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _presetPage
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.3,
                            ),
                    ),
                  ),
              ],
            ),
          ),
      ],
      Center(
        child: TextButton(
          onPressed: _nextPage,
          child: Text(l10n.onboardingModelsSetUpLater),
        ),
      ),
      const SizedBox(height: 8),
    ]);
  }

  // ---------------------------------------------------------------- page 4

  Widget _buildPrivacyPage(ThemeData theme, AppLocalizations l10n) {
    final entries = <(IconData, String, String)>[
      (
        Icons.key_outlined,
        l10n.onboardingPrivacyKeysTitle,
        l10n.onboardingPrivacyKeysDesc,
      ),
      (
        Icons.smartphone_outlined,
        l10n.onboardingPrivacyOnDeviceTitle,
        l10n.onboardingPrivacyOnDeviceDesc,
      ),
      (
        Icons.cloud_outlined,
        l10n.onboardingPrivacyProvidersTitle,
        l10n.onboardingPrivacyProvidersDesc,
      ),
    ];
    return _pageScroll([
      const SizedBox(height: 24),
      _pageTitle(theme, l10n.onboardingPrivacyTitle),
      const SizedBox(height: 24),
      for (final (icon, title, desc) in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      InkWell(
        onTap: _openPrivacyPolicy,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.open_in_new,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.onboardingPrivacyPolicyLink,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
    ]);
  }
}

/// One swipeable preset card of the onboarding model page: a light version
/// of the settings `_PresetCard` — name, description, the chat model, the
/// missing-key hint with a jump to the provider editor, and Apply (a check
/// once applied). Applying rides [applyModelPreset] with a null service:
/// the combo persists as the last connection the boot auto-connect restores.
class _OnboardingPresetCard extends StatelessWidget {
  const _OnboardingPresetCard({
    required this.preset,
    required this.keyAvailable,
    required this.applied,
    required this.onApply,
    required this.onSetKey,
  });

  final ModelPreset preset;
  final bool keyAvailable;
  final bool applied;
  final VoidCallback onApply;
  final VoidCallback onSetKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final providerLabel = switch (preset.target) {
      HostedModelPresetTarget(:final provider) => provider.labelFor(context),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(preset.nameFor(l10n), style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              preset.descriptionFor(l10n),
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.modelPresetsChatLabel,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    preset.chatModelId,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (!keyAvailable)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.key_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.modelPresetsKeyMissing(providerLabel),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onSetKey,
                      child: Text(l10n.modelPresetsSetKey),
                    ),
                  ],
                ),
              ),
            if (applied)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.modelPresetsApplied,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              )
            else
              FilledButton(
                onPressed: keyAvailable ? onApply : null,
                child: Text(l10n.settingsApplyButton),
              ),
          ],
        ),
      ),
    );
  }
}
