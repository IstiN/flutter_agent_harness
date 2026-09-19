import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/mobile/mobile_consent.dart';

/// Consent screen for mobile device automation (issue #622).
///
/// Threat-model requirements: the explanation comes BEFORE activation
/// (what the accessibility service enables, that it is off by default,
/// the one-tap disable in Fa settings, and that data never leaves the
/// device except inline to the configured model), activation links into
/// the system accessibility settings, and the disable stays one tap away.
/// Store builds never show this surface — [MobileControlContract.flavor]
/// gates it here defensively (the Settings entry is god-flavor only).
///
/// `wire:` the caller passes the platform control — slice B's
/// `defaultMobileControl` implements [MobileControlContract] directly,
/// and the widget tests fake the same interface, so the screen never
/// touches a method channel.
class MobileConsentScreen extends StatefulWidget {
  const MobileConsentScreen({
    super.key,
    required this.control,
    this.model,
  });

  /// The platform control driving accessibility settings.
  final MobileControlContract control;

  /// Consent model override (tests); defaults to a fresh controller.
  final MobileConsentModel? model;

  @override
  State<MobileConsentScreen> createState() => _MobileConsentScreenState();
}

class _MobileConsentScreenState extends State<MobileConsentScreen>
    with WidgetsBindingObserver {
  late final MobileConsentModel _model;
  bool? _enabled;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _model = widget.model ?? MobileConsentModel();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user returns from system settings — re-read the service state.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final flavor = await widget.control.flavor();
    if (!mounted) return;
    if (flavor == 'store') {
      setState(() => _unavailable = true);
      return;
    }
    final enabled = await widget.control.accessibilityEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      // Reconcile the audit trail only when the flip happened inside the
      // consent flow (acknowledged/servicePending); a service the user
      // enabled outside this screen leaves the log alone.
      if (_model.stage == MobileConsentStage.servicePending ||
          _model.stage == MobileConsentStage.acknowledged) {
        _model.refreshService(enabled);
      }
    });
  }

  Future<void> _onEnable() async {
    if (_model.stage == MobileConsentStage.notShown) _model.acknowledge();
    _model.markServicePending();
    setState(() {});
    await widget.control.openAccessibilitySettings();
    // No refresh here: the user is on the system page and has not had a
    // chance to flip the toggle — the lifecycle resume reconciles.
  }

  Future<void> _onDisable() async {
    _model.disable();
    await widget.control.disableAccessibility();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mobileConsentTitle)),
      body: _unavailable
          ? Center(child: Text(l10n.mobileConsentStoreUnavailable))
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(l10n.mobileConsentWhat,
                      style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 12),
                  Text(l10n.mobileConsentOffByDefault),
                  const SizedBox(height: 12),
                  Text(l10n.mobileConsentDisableHint),
                  const SizedBox(height: 12),
                  Text(l10n.mobileConsentPrivacy),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Icon(
                        _enabled == true
                            ? Icons.accessibility_new
                            : Icons.accessibility_new_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _enabled == true
                              ? l10n.mobileConsentStatusOn
                              : l10n.mobileConsentStatusOff,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_enabled == true)
                    FilledButton.tonal(
                      onPressed: _onDisable,
                      child: Text(l10n.mobileConsentDisable),
                    )
                  else
                    FilledButton(
                      onPressed: _onEnable,
                      child: Text(l10n.mobileConsentEnable),
                    ),
                ],
              ),
            ),
    );
  }
}
