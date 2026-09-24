// The slash-menu key cluster (file-length gate, PR #831): the
// FaTuiModel menu-mode key handlers extracted verbatim from fa_tui.dart.
// Same library via `part`, so the private members they touch stay
// private; zero API surface change.

part of 'fa_tui.dart';

extension FaTuiModelSlashMenu on FaTuiModel {
  /// Slash/menu mode: arrows navigate, enter/tab accept, esc closes, and
  /// typing keeps editing the input so `/models` can be typed in full.
  (Model, Cmd?) _handleSlashMenuKey(KeyMsg msg) {
    return _handleSlashMenuNavKey(msg) ??
        _handleSlashMenuAcceptKey(msg) ??
        _handleSlashMenuEditKey(msg);
  }

  /// Path-completion overlay keys: Tab accepts, arrows navigate, esc
  /// closes; everything else falls through (Enter SUBMITS, editing edits).
  (Model, Cmd?)? _handlePathMenuKey(KeyMsg msg) {
    switch (msg.key) {
      case 'tab':
        return _acceptSlashMenuItem();
      case 'esc':
        return (copyWith(menuOpen: false, menuTokenStart: -1), null);
      case 'up':
      case 'down':
        return _handleSlashMenuNavKey(msg);
      default:
        return null;
    }
  }

  /// Slash-menu navigation keys (esc/up/down); null when the key belongs to
  /// the accept or edit clusters.
  (Model, Cmd?)? _handleSlashMenuNavKey(KeyMsg msg) {
    switch (msg.key) {
      case 'esc':
        return (copyWith(menuOpen: false, menuTokenStart: -1), null);
      case 'up':
        return (
          copyWith(menuSelected: menuSelected > 0 ? menuSelected - 1 : 0),
          null,
        );
      case 'down':
        return (
          copyWith(
            menuSelected: menuSelected < menuItems.length - 1
                ? menuSelected + 1
                : menuSelected,
          ),
          null,
        );
      default:
        return null;
    }
  }

  /// Slash-menu accept keys (enter/tab); null for every other key.
  (Model, Cmd?)? _handleSlashMenuAcceptKey(KeyMsg msg) {
    switch (msg.key) {
      case 'enter':
      case 'tab':
        return _acceptSlashMenuItem();
      default:
        return null;
    }
  }

  /// Slash-menu edit keys: backspace and typed characters keep editing the
  /// input so `/models` can be typed in full.
  (Model, Cmd?) _handleSlashMenuEditKey(KeyMsg msg) {
    switch (msg.key) {
      case 'backspace':
        if (cursor > 0 && inputText.isNotEmpty) {
          return (
            _updateMenuForInput(copyWith(editor: editor.backspace())),
            null,
          );
        }
        return (this, null);
      default:
        final text = msg.keyEvent.text;
        if (text.isNotEmpty && text.length == 1) {
          return (
            _updateMenuForInput(copyWith(editor: editor.insert(text))),
            null,
          );
        }
        return (this, null);
    }
  }

  /// Slash-menu accept (enter/tab): fills the input with the picked command,
  /// or switches into the models picker, or submits picker-opening commands
  /// (/sessions, /mode, /approval) immediately.
  (Model, Cmd?) _acceptSlashMenuItem() {
    if (menuItems.isEmpty) return (this, null);
    final item = menuItems[menuSelected];
    if (item.key == '/model' || item.key == '/models') {
      return (
        copyWith(
          menuModelMode: true,
          menuItems: callbacks.buildModelMenu('', termWidth),
          menuSelected: 0,
          modelFilter: '',
          pickerId: 'models',
          pickerTitle: '',
        ),
        null,
      );
    }
    // Commands that open a host-side picker (/sessions, /mode,
    // /approval) submit immediately instead of filling the input.
    if (callbacks.opensPicker?.call(item.key) ?? false) {
      return (
        copyWith(menuOpen: false, inputText: '', cursor: 0, pickerId: ''),
        () async {
          await callbacks.onSubmit(item.key, images: const []);
          return null;
        },
      );
    }
    // Token splice (issue #275): replace just the completed token — an
    // `@`-fragment or a shell word after '!' — with the chosen path plus a
    // trailing space that ends the token. Slash commands (tokenStart == 0,
    // line-start) keep the legacy whole-input replace below.
    if (menuTokenStart > 0) {
      final head = inputText.substring(0, menuTokenStart);
      final tail = inputText.substring(
        cursor.clamp(menuTokenStart, inputText.length),
      );
      final inserted = '${item.key} ';
      return (
        copyWith(
          inputText: head + inserted + tail,
          cursor: menuTokenStart + inserted.length,
          menuOpen: false,
          menuTokenStart: -1,
        ),
        null,
      );
    }
    return (
      copyWith(
        inputText: item.key,
        cursor: item.key.length,
        menuOpen: false,
        menuTokenStart: -1,
      ),
      null,
    );
  }
}
