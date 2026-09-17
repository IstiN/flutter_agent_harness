// Picker key handling for the FA TUI: navigation (esc/arrows/pgup/pgdown),
// select/filter (backspace/enter/tab/type-to-filter), accept, and the
// shared accept flow used by both the keyboard and the mouse (issue #278).
//
// Lives in a part file to keep fa_tui.dart under the line gate (same
// pattern as fa_tui_rows.dart / fa_tui_mouse.dart); the picker state
// (menuItems, pickerId, modelFilter, ...) is declared on [FaTuiModel]
// itself — extensions cannot add fields.
part of 'fa_tui.dart';

extension _TuiPickerKeys on FaTuiModel {
  /// Picker mode: arrows navigate, enter/tab select, esc closes. Every
  /// picker has a type-to-filter input — the models picker rebuilds through
  /// the host callback, generic pickers (sessions, settings, agents, ...)
  /// filter their static item list locally.
  (Model, Cmd?) _handlePickerKey(KeyMsg msg) {
    return _handlePickerNavKey(msg) ?? _handlePickerSelectKey(msg);
  }

  /// Picker navigation keys (esc/arrows/pgup/pgdown); null when the key
  /// belongs to the select/filter cluster.
  (Model, Cmd?)? _handlePickerNavKey(KeyMsg msg) {
    return _handlePickerEscKey(msg) ??
        _handlePickerArrowKey(msg) ??
        _handlePickerPageKey(msg);
  }

  /// Picker esc: closes the picker; generic pickers also report the
  /// cancellation to the host (wizard flows wait on the answer). Null when
  /// the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerEscKey(KeyMsg msg) {
    final isModelsPicker = pickerId == 'models';
    switch (msg.key) {
      case 'esc':
        if (!isModelsPicker && pickerId.isNotEmpty) {
          callbacks.onPickerCancelled?.call(pickerId);
        }
        return (
          copyWith(
            menuOpen: false,
            menuModelMode: false,
            modelFilter: '',
            menuAllItems: const [],
            pickerId: '',
            pickerTitle: '',
          ),
          null,
        );
      default:
        return null;
    }
  }

  /// Picker arrow keys (↑/↓); null when the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerArrowKey(KeyMsg msg) {
    switch (msg.key) {
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

  /// Picker page keys (pgup/pgdown jump to the first/last item); null when
  /// the key belongs to another cluster.
  (Model, Cmd?)? _handlePickerPageKey(KeyMsg msg) {
    switch (msg.key) {
      case 'pgup':
        return (copyWith(menuSelected: 0), null);
      case 'pgdown':
        return (
          copyWith(menuSelected: menuItems.isEmpty ? 0 : menuItems.length - 1),
          null,
        );
      default:
        return null;
    }
  }

  /// Picker select/filter keys (backspace/enter/tab/type-to-filter).
  (Model, Cmd?) _handlePickerSelectKey(KeyMsg msg) {
    return _handlePickerBackspaceKey(msg) ??
        _handlePickerAcceptKey(msg) ??
        _pickerTypeFilter(msg);
  }

  /// Picker backspace: trims the filter and rebuilds the item list (the
  /// models picker via [FaTuiCallbacks.buildModelMenu], generic pickers by
  /// locally filtering [menuAllItems]). Null when the key belongs to another
  /// cluster.
  (Model, Cmd?)? _handlePickerBackspaceKey(KeyMsg msg) {
    switch (msg.key) {
      case 'backspace':
        if (modelFilter.isEmpty) return (this, null);
        final nextFilter = modelFilter.substring(0, modelFilter.length - 1);
        return (_filteredPicker(nextFilter), null);
      default:
        return null;
    }
  }

  /// The picker state with [filter] applied: the models picker rebuilds via
  /// the host callback, generic pickers filter [menuAllItems] locally
  /// (case-insensitive contains over label + description).
  FaTuiModel _filteredPicker(String filter) {
    final isModelsPicker = pickerId == 'models';
    final items = isModelsPicker
        ? callbacks.buildModelMenu(filter, termWidth)
        : _filterItems(menuAllItems, filter);
    return copyWith(modelFilter: filter, menuItems: items, menuSelected: 0);
  }

  /// The local generic-picker filter: [items] whose label or description
  /// contains [filter] (case-insensitive); an empty filter keeps everything.
  List<MenuItem> _filterItems(List<MenuItem> items, String filter) {
    final query = filter.trim().toLowerCase();
    if (query.isEmpty) return items;
    return [
      for (final item in items)
        if ('${item.label} ${item.description}'.toLowerCase().contains(query))
          item,
    ];
  }

  /// Picker accept (enter/tab): closes the picker and resolves the
  /// selection through the host (the model pick for the models picker,
  /// [FaTuiCallbacks.onPickerSelected] for generic pickers). Null when the
  /// key belongs to another cluster.
  (Model, Cmd?)? _handlePickerAcceptKey(KeyMsg msg) {
    switch (msg.key) {
      case 'enter':
      case 'tab':
        if (menuItems.isEmpty) return (this, null);
        return _acceptPickerAt(menuSelected);
      default:
        return null;
    }
  }

  /// Accepts the picker row at [index] — the shared accept flow for the
  /// keyboard (enter/tab on [menuSelected]) and the mouse (a menuRow hit
  /// region, issue #278). Closes the picker and resolves the selection
  /// through the host ([FaTuiCallbacks.onPickerSelected] for pickers).
  (Model, Cmd?) _acceptPickerAt(int index) {
    final pickerId = this.pickerId;
    final isModelsPicker = pickerId == 'models';
    final item = menuItems[index];
    if (item.key.isEmpty) return (this, null);
    return (
      copyWith(
        menuOpen: false,
        menuModelMode: false,
        modelFilter: '',
        menuAllItems: const [],
        pickerId: '',
        pickerTitle: '',
        inputText: '',
        cursor: 0,
      ),
      () async {
        if (isModelsPicker) {
          await callbacks.onModelSelected(item.key);
        } else {
          await callbacks.onPickerSelected?.call(pickerId, item.key);
        }
        return null;
      },
    );
  }

  /// Picker type-to-filter: each printable character extends the filter and
  /// rebuilds the item list (host callback for the models picker, a local
  /// [menuAllItems] filter for generic pickers).
  (Model, Cmd?) _pickerTypeFilter(KeyMsg msg) {
    if (FaTuiModel._isCommandKeystroke(msg.key)) return (this, null);
    final text = msg.keyEvent.text;
    if (text.isNotEmpty && text.length == 1) {
      if (text == ' ' && modelFilter.isEmpty) return (this, null);
      return (_filteredPicker(modelFilter + text), null);
    }
    return (this, null);
  }
}
