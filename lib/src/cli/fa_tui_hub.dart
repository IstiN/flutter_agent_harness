// The agents-hub overlay's model machinery (issue #277), split out of
// fa_tui.dart to keep it under the repo's 2800-line gate. Same library,
// so the private members it touches stay private.

part of 'fa_tui.dart';

extension FaTuiModelHub on FaTuiModel {
  /// Host push of fresh hub content (open or refresh): carries the local
  /// interactive bits over so a re-push never resets the user's selection
  /// or scroll anchor.
  (Model, Cmd?) _handleHubStateMsg(HubStateMsg msg) {
    // Refresh-only pushes never open a closed overlay (issue #382). The
    // guard reads the live state at handling time, so a close that raced
    // the in-flight push still wins.
    if (msg.refreshOnly && hub == null) return (this, null);
    return (copyWith(hub: msg.state.carryingFrom(hub)), null);
  }

  /// The open hub overlay owns every key; wheel scrolling moves its tree
  /// selection instead of the chat history.
  (Model, Cmd?) _handleHubKey(KeyMsg msg) {
    // ctrl+c outranks the modal: abort + quit, exactly as on the main path.
    if (msg.key == 'ctrl+c') {
      callbacks.onInterrupt?.call();
      return (this, () => quit());
    }
    final current = hub!;
    final (next, action) = current.handleKey(
      msg.key,
      viewport: _viewportHeight - 3,
    );
    switch (action) {
      case FaHubAction.none:
        return (copyWith(hub: next), null);
      case FaHubAction.enter:
      case FaHubAction.back:
      case FaHubAction.close:
        final cleared = action == FaHubAction.close;
        return (
          // clearHub: a plain hub: null keeps the old state (no close).
          copyWith(hub: next, clearHub: cleared),
          () async {
            await callbacks.onHubAction?.call(action.name, current.selectedKey);
            return null;
          },
        );
    }
  }
}
