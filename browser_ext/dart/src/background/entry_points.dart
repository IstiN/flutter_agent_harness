// ONE entry point for every external trigger that starts or steers the
// agent (issue #30, E24): omnibox 'fa <query>', registered command hotkeys,
// context-menu clicks on selection/link/image/page. The hub subscribes the
// three facade streams at construction (so no click is lost during wiring),
// buffers anything that fires before the first listener attaches and
// replays it exactly once on listen. The hub NEVER spawns an agent itself:
// the wiring layer marks runs via setActive/hasActiveRun, and each input's
// delivery tag (steer while a run is active, queued otherwise) tells the
// host whether to feed the input into the live run or park it. Page data
// arriving here is untrusted page content — it is marked 'untrusted': true
// in pageContext and must never be executed, only shown or searched.
library;

import 'dart:async';

import '../chrome_api.dart' as api;

/// How the host should deliver an input relative to the active run:
/// [DeliveryMode.steer] feeds it into the live run as steering,
/// [DeliveryMode.queued] parks it for the next run.
enum DeliveryMode { queued, steer }

/// One normalized external trigger. [source] is a stable machine key
/// ('omnibox' | 'command' | 'context_menu'), [text] the prompt-ready text,
/// [pageContext] verbatim auxiliary data.
sealed class ExternalInput {
  ExternalInput({
    required this.source,
    required this.text,
    Map<String, dynamic>? pageContext,
  }) : pageContext = pageContext == null ? const {} : Map.of(pageContext);

  final String source;
  final String text;
  final Map<String, dynamic> pageContext;

  /// Tagged at delivery time by [EntryPointHub] — whether a run is active is
  /// decided when the event is handed out, not when it fired, so buffered
  /// replays get the current mode too. Mutable for exactly that reason.
  DeliveryMode delivery = DeliveryMode.queued;
}

/// Omnibox entry (`'fa <query>'`); the leading keyword is already stripped.
final class OmniboxInput extends ExternalInput {
  OmniboxInput({required super.text}) : super(source: 'omnibox');
}

/// Registered command hotkey.
final class CommandInput extends ExternalInput {
  CommandInput(String commandName)
    : super(source: 'command', text: commandName);

  String get commandName => text;
}

/// Context-menu click on a page. Everything except [menuItem] is verbatim
/// page data and untrusted; pageContext carries the same fields plus
/// 'untrusted': true so downstream consumers cannot forget the marking.
final class ContextMenuInput extends ExternalInput {
  ContextMenuInput({
    required this.menuItem,
    this.selectionText,
    this.linkUrl,
    this.srcUrl,
    this.pageUrl,
    int? tabId,
  }) : super(
         source: 'context_menu',
         text: selectionText ?? linkUrl ?? srcUrl ?? '',
         pageContext: {
           'selectionText': ?selectionText,
           'linkUrl': ?linkUrl,
           'srcUrl': ?srcUrl,
           'pageUrl': ?pageUrl,
           'tabId': ?tabId,
           'untrusted': true,
         },
       );

  final String menuItem;
  final String? selectionText;
  final String? linkUrl;
  final String? srcUrl;
  final String? pageUrl;
}

/// Fan-in for the three chrome entry streams. Construct it as early as the
/// service worker starts: subscriptions created in the constructor are what
/// makes "no lost clicks during setup" possible at all.
final class EntryPointHub {
  EntryPointHub(api.ChromeApi chrome) {
    _subscriptions = [
      chrome.contextMenus.onClicked.listen(
        (click) => _dispatch(_fromMenuClick(click)),
      ),
      chrome.omnibox.onInputEntered.listen(
        (enter) => _dispatch(OmniboxInput(text: _stripKeyword(enter.text))),
      ),
      chrome.commands.onCommand.listen((name) => _dispatch(CommandInput(name))),
    ];
  }

  late final List<StreamSubscription<void>> _subscriptions;

  /// Events that fired with no listener attached — replayed in arrival
  /// order the moment the first (or a re-attached) listener shows up, then
  /// dropped. This is the no-lost-clicks-during-setup buffer.
  final _buffer = <ExternalInput>[];

  /// Broadcast with a synchronous onListen hook: the no-lost-clicks buffer
  /// replays inside `listen()` itself, so consumers see buffered events
  /// without an extra pump. onListen fires whenever the listener count
  /// returns to one, which is exactly the replay window we want.
  late final StreamController<ExternalInput> _controller =
      StreamController<ExternalInput>.broadcast(
        sync: true,
        onListen: _replayBuffered,
      );

  /// Broadcast stream of normalized inputs. Every event — including ones
  /// buffered before any listener attached — is delivered exactly once per
  /// listener.
  Stream<ExternalInput> get inputs => _controller.stream;

  bool _activeRun = false;

  /// Whether the wiring layer currently has an agent run in flight. The hub
  /// only reads this to tag delivery; it never starts or stops runs itself.
  bool get hasActiveRun => _activeRun;

  /// Mark a run started ([true]) or finished ([false]); later deliveries are
  /// tagged [DeliveryMode.steer] / [DeliveryMode.queued] accordingly.
  void setActive(bool active) => _activeRun = active;

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _controller.close();
  }

  /// Flushes the pre-listener buffer into the controller exactly once per
  /// replay window: the copy-then-clear guarantees an event arriving during
  /// the synchronous replay cannot be delivered twice.
  void _replayBuffered() {
    if (_buffer.isEmpty) return;
    final replay = List.of(_buffer);
    _buffer.clear();
    for (final input in replay) {
      _controller.add(input..delivery = _mode());
    }
  }

  void _dispatch(ExternalInput input) {
    if (!_controller.hasListener) {
      _buffer.add(input);
      return;
    }
    _controller.add(input..delivery = _mode());
  }

  DeliveryMode _mode() => _activeRun ? DeliveryMode.steer : DeliveryMode.queued;

  static ContextMenuInput _fromMenuClick(api.MenuClick click) =>
      ContextMenuInput(
        menuItem: click.menuItemId,
        selectionText: click.selectionText,
        linkUrl: click.linkUrl,
        srcUrl: click.srcUrl,
        pageUrl: click.pageUrl,
        tabId: click.tab?.id,
      );

  /// Chrome prefixes omnibox entries with the extension's keyword
  /// ('fa check this'); the query is what follows it. Case-insensitive on
  /// the keyword, and a keyword-only entry normalizes to ''.
  static String _stripKeyword(String raw) {
    final text = raw.trim();
    final lower = text.toLowerCase();
    if (lower == 'fa') return '';
    if (lower.startsWith('fa ')) return text.substring(3).trim();
    return text;
  }
}
