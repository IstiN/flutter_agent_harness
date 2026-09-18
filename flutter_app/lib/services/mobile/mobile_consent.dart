/// Mobile device-automation consent: a pure-Dart state machine plus the
/// async control surface the consent screen needs.
///
/// No Flutter imports — the state machine unit-tests without a widget
/// binding (UT-consent-1). The audit trail (event log) records every
/// consent transition with an ISO-8601 timestamp.
library;

/// The platform surface the consent screen drives (Android accessibility
/// service + screen projection). Slice B's `MobileControl`
/// (lib/services/mobile/mobile_services.dart) implements this interface;
/// the widget tests fake it directly.
abstract interface class MobileControlContract {
  /// The build flavor: 'store' builds never show the consent surface.
  Future<String> flavor();

  /// Whether the accessibility service is currently enabled system-wide.
  Future<bool> accessibilityEnabled();

  /// Opens the system accessibility settings page.
  Future<void> openAccessibilitySettings();

  /// One-tap disable of the accessibility service.
  Future<void> disableAccessibility();

  /// Whether the screen-projection consent (MediaProjection) is granted.
  Future<bool> projectionConsent();
}

/// Consent lifecycle for device automation:
///
/// notShown → acknowledged → servicePending → serviceOn | serviceOff
///
/// `acknowledge` records the explicit accept on the consent screen,
/// `markServicePending` the moment the user is sent to system settings,
/// `refreshService` the outcome observed on return, and `disable` the
/// one-tap kill switch (legal from any stage). Illegal transitions throw
/// [StateError]; every legal transition appends an audit line.
enum MobileConsentStage { notShown, acknowledged, servicePending, serviceOn, serviceOff }

/// Mutable consent controller with an append-only audit log.
class MobileConsentModel {
  MobileConsentModel({
    this.stage = MobileConsentStage.notShown,
    List<String>? eventLog,
  }) : eventLog = eventLog ?? <String>[];

  /// Current consent stage.
  MobileConsentStage stage;

  /// Append-only consent audit trail: `<ISO-8601 timestamp> <event>`.
  final List<String> eventLog;

  /// The user accepted the consent explanation. notShown → acknowledged.
  void acknowledge() {
    _require(MobileConsentStage.notShown, 'acknowledge');
    stage = MobileConsentStage.acknowledged;
    _log('acknowledge');
  }

  /// The user is heading to system settings. acknowledged → servicePending.
  void markServicePending() {
    _require(MobileConsentStage.acknowledged, 'markServicePending');
    stage = MobileConsentStage.servicePending;
    _log('markServicePending');
  }

  /// The service state observed on return from system settings.
  /// Legal from servicePending, and from acknowledged (the user flipped
  /// the toggle without an intermediate pending state).
  void refreshService(bool enabled) {
    switch (stage) {
      case MobileConsentStage.servicePending:
      case MobileConsentStage.acknowledged:
        stage = enabled
            ? MobileConsentStage.serviceOn
            : MobileConsentStage.serviceOff;
      case _:
        throw StateError(
          'refreshService($enabled) is illegal from stage ${stage.name}',
        );
    }
    _log('refreshService($enabled)');
  }

  /// One-tap disable — legal from every stage.
  void disable() {
    stage = MobileConsentStage.serviceOff;
    _log('disable');
  }

  /// Re-arms the consent flow (stage only; the audit trail is kept).
  void reset() {
    stage = MobileConsentStage.notShown;
    _log('reset');
  }

  void _require(MobileConsentStage expected, String action) {
    if (stage != expected) {
      throw StateError(
        '$action is illegal from stage ${stage.name} '
        '(expected ${expected.name})',
      );
    }
  }

  void _log(String event) {
    eventLog.add('${DateTime.now().toIso8601String()} $event');
  }
}
