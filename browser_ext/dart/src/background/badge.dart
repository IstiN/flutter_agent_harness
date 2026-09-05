// Toolbar badge + notification plumbing (issue #30, IT-B2): one owner for
// every chrome.action write, so the badge always shows the live system
// state (idle / busy / 'mail!') derived from the controller's two inputs —
// is a run going, is there unread mail — instead of scattered setBadgeText
// calls that can drift apart. Pure Dart: the facade carries the chrome
// calls, tests drive this against FakeChrome.
library;

import '../chrome_api.dart';

/// Display states of the extension badge. Display priority is
/// mail > busy > idle: unread mail is the one thing the user must not
/// miss while an agent run is working.
enum BadgeState { idle, busy, mail }

/// Renders the live agent state onto chrome.action and sends
/// notifications.
///
/// WHY a controller instead of direct calls: E25 honesty — after a forced
/// kill/wake the service worker's remembered transitions can no longer be
/// trusted, so [BadgeController.resync] recomputes the badge from
/// authoritative inputs (running? unread mail?) rather than replaying
/// history. WHY the text is coarse ('busy', 'mail!'): a badge fits a few
/// characters; detail belongs in notifications and the action title.
final class BadgeController {
  BadgeController(this._api);

  final ChromeApi _api;

  /// Badge background per state — same shape, different hue, glanceable.
  static const _colors = {
    BadgeState.idle: '#5f6368',
    BadgeState.busy: '#1a73e8',
    BadgeState.mail: '#d93025',
  };

  bool _running = false;
  int _unreadMail = 0;

  BadgeState get state {
    if (_unreadMail > 0) return BadgeState.mail;
    if (_running) return BadgeState.busy;
    return BadgeState.idle;
  }

  String get _text => switch (state) {
    BadgeState.mail => 'mail!',
    BadgeState.busy => 'busy',
    // Chrome's convention: the empty string clears the badge.
    BadgeState.idle => '',
  };

  /// An agent run began.
  Future<void> runStarted() async {
    _running = true;
    await _render();
  }

  /// The agent run ended.
  Future<void> runEnded() async {
    _running = false;
    await _render();
  }

  /// Unread mail landed — allowed at any time, it outranks busy.
  Future<void> mailArrived() async {
    _unreadMail += 1;
    await _render();
  }

  /// The user has seen the mail; fall back to the run state.
  Future<void> mailSeen() async {
    _unreadMail = 0;
    await _render();
  }

  /// E25: recompute the badge from authoritative inputs. A forced kill
  /// can leave the badge stuck on 'busy' while nothing runs anymore; the
  /// host calls this after a wake with what is actually true.
  Future<void> resync({required bool running, required int unreadMail}) async {
    _running = running;
    _unreadMail = unreadMail;
    await _render();
  }

  /// Sends a notification; returns whether it was shown. On a denied
  /// permission (E20) nothing is thrown — the badge text carries the
  /// signal ('!') instead, and the next state render restores the badge.
  Future<bool> notify({required String title, required String message}) async {
    final shown = await _api.notifications.create(
      id: 'fa-agent',
      title: title,
      message: message,
    );
    if (!shown) await _api.action.setBadgeText('!');
    return shown;
  }

  Future<void> _render() async {
    await _api.action.setBadgeText(_text);
    await _api.action.setBadgeBackgroundColor(_colors[state]!);
  }
}
