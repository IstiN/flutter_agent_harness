import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'chat_list_entry.dart';
import 'chat_list_stores.dart';
import 'local_chat_list_adapter.dart';
import 'network_inbox_adapter.dart';

enum ChatListFilter { all, unread, agents, channels }

enum ChatLoadState { loading, data, empty, error }

enum ChatNetworkFilterKind { all, my, network }

/// Network scoping is a pure list facet. It has no dependency on AppMode,
/// selected channels, sockets, or authentication.
final class ChatNetworkFilter {
  const ChatNetworkFilter.all() : this._(ChatNetworkFilterKind.all);
  const ChatNetworkFilter.my() : this._(ChatNetworkFilterKind.my);
  const ChatNetworkFilter.network(String id)
    : this._(ChatNetworkFilterKind.network, id);
  const ChatNetworkFilter._(this.kind, [this.networkId]);

  final ChatNetworkFilterKind kind;
  final String? networkId;

  @override
  bool operator ==(Object other) =>
      other is ChatNetworkFilter &&
      other.kind == kind &&
      other.networkId == networkId;

  @override
  int get hashCode => Object.hash(kind, networkId);
}

final class ChatListController extends ChangeNotifier {
  ChatListController({
    required this._localAdapter,
    NetworkInboxAdapter? networkAdapter,
    ChatPinStore? pinStore,
    ChatReadCursorStore? readCursorStore,
    Map<String, String> networkNames = const {},
  }) : _networkAdapter = networkAdapter,
       _pinStore = pinStore ?? ChatPinStore.inMemory(accountId: 'local'),
       _readStore =
           readCursorStore ?? ChatReadCursorStore.inMemory(accountId: 'local'),
       _networkNames = Map.of(networkNames),
       _networkStatus = networkAdapter == null
           ? ChatLoadState.empty
           : ChatLoadState.loading {
    _pinStore.addListener(_onStoreChanged);
    _readStore.addListener(_onStoreChanged);
    _subscribeToLocalChanges();
  }

  LocalChatListSource _localAdapter;
  Listenable? _localChanges;
  NetworkInboxAdapter? _networkAdapter;
  ChatPinStore _pinStore;
  ChatReadCursorStore _readStore;
  Map<String, String> _networkNames;

  List<ChatListEntry> _localEntries = const [];
  List<NetworkInboxItem> _networkItems = const [];
  ChatLoadState _localStatus = ChatLoadState.loading;
  ChatLoadState _networkStatus;
  Object? _localError;
  Object? _networkError;
  int _localRequest = 0;
  int _networkRequest = 0;

  ChatListFilter _filter = ChatListFilter.all;
  ChatNetworkFilter _networkFilter = const ChatNetworkFilter.all();
  String _search = '';
  final Map<String, String> _networkReadMarkers = {};

  ChatListFilter get filter => _filter;
  ChatNetworkFilter get networkFilter => _networkFilter;
  String get searchQuery => _search;
  ChatLoadState get networkStatus => _networkStatus;
  String? get networkError => _networkError?.toString();
  String? get localError => _localError?.toString();
  Map<String, String> get networkNames => Map.unmodifiable(_networkNames);

  Future<void> load() async {
    await Future.wait([_loadLocal(), _loadNetwork()]);
  }

  Future<void> _loadLocal() async {
    final request = ++_localRequest;
    _localStatus = ChatLoadState.loading;
    _localError = null;
    notifyListeners();
    try {
      final entries = await _localAdapter.load();
      if (request != _localRequest) return;
      _localEntries = entries;
      _localStatus = entries.isEmpty ? ChatLoadState.empty : ChatLoadState.data;
    } on Object catch (error) {
      if (request != _localRequest) return;
      _localError = error;
      _localStatus = ChatLoadState.error;
    }
    notifyListeners();
  }

  Future<void> _loadNetwork() async {
    final adapter = _networkAdapter;
    if (adapter == null) {
      _networkStatus = ChatLoadState.empty;
      return;
    }
    final request = ++_networkRequest;
    _networkStatus = ChatLoadState.loading;
    _networkError = null;
    notifyListeners();
    try {
      final page = await adapter.fetchInbox(limit: 100);
      if (request != _networkRequest) return;
      _networkItems = page.items;
      _networkStatus = page.items.isEmpty
          ? ChatLoadState.empty
          : ChatLoadState.data;
    } on Object catch (error) {
      if (request != _networkRequest) return;
      // Keep the last good snapshot on a refresh failure, but retain the
      // explicit error state so stale rows are never presented as fresh.
      _networkError = error;
      _networkStatus = ChatLoadState.error;
    }
    notifyListeners();
  }

  Future<void> retryNetwork() => _loadNetwork();

  Future<void> replaceNetworkAdapter(NetworkInboxAdapter? adapter) async {
    if (identical(_networkAdapter, adapter)) return;
    _networkRequest++;
    _networkAdapter = adapter;
    _networkItems = const [];
    _networkError = null;
    if (adapter == null) {
      _networkStatus = ChatLoadState.empty;
      notifyListeners();
      return;
    }
    await _loadNetwork();
  }

  void _subscribeToLocalChanges() {
    final adapter = _localAdapter;
    _localChanges = adapter is LocalChatListChangeSource
        ? adapter.changes
        : null;
    _localChanges?.addListener(_onLocalChanges);
  }

  void _onLocalChanges() {
    unawaited(_loadLocal());
  }

  Future<void> replaceLocalAdapter(LocalChatListSource adapter) async {
    _localChanges?.removeListener(_onLocalChanges);
    _localAdapter = adapter;
    _subscribeToLocalChanges();
    await _loadLocal();
  }

  Future<void> replaceLocalEntries(List<ChatListEntry> entries) async {
    _localRequest++;
    _localEntries = List.of(entries);
    _localStatus = entries.isEmpty ? ChatLoadState.empty : ChatLoadState.data;
    _localError = null;
    notifyListeners();
  }

  void replaceStores({
    required ChatPinStore pinStore,
    required ChatReadCursorStore readCursorStore,
  }) {
    _pinStore.removeListener(_onStoreChanged);
    _readStore.removeListener(_onStoreChanged);
    _pinStore = pinStore;
    _readStore = readCursorStore;
    _pinStore.addListener(_onStoreChanged);
    _readStore.addListener(_onStoreChanged);
    notifyListeners();
  }

  void updateNetworkNames(Map<String, String> names) {
    _networkNames = Map.of(names);
    notifyListeners();
  }

  void _onStoreChanged() => notifyListeners();

  void setFilter(ChatListFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
  }

  void setNetworkFilter(ChatNetworkFilter value) {
    if (_networkFilter == value) return;
    _networkFilter = value;
    notifyListeners();
  }

  void setSearch(String value) {
    if (_search == value) return;
    _search = value;
    notifyListeners();
  }

  Future<void> togglePin(ChatListEntry entry) =>
      _pinStore.setPinned(entry.id, !entry.pinned);

  List<ChatListEntry> get _entries {
    final result = <ChatListEntry>[
      for (final entry in _localEntries) _effectiveLocal(entry),
      for (final item in _networkItems)
        _effectiveNetwork(
          item.toEntry(networkName: _networkNames[item.networkId]),
        ),
    ];
    return result;
  }

  ChatListEntry _effectiveLocal(ChatListEntry entry) {
    final cursor = _readStore.cursorFor(entry.id);
    var unread = entry.unreadCount;
    final count = entry.localMessageCount;
    if (cursor != null && count != null) {
      unread = math.max(0, count - cursor);
    }
    return entry.copyWith(
      pinned: _pinStore.isPinned(entry.id),
      unreadCount: unread,
    );
  }

  ChatListEntry _effectiveNetwork(ChatListEntry entry) {
    final marker = _networkReadMarkers[entry.id.canonical];
    final currentMarker = _networkMarker(entry);
    final unread = marker != null && marker == currentMarker
        ? 0
        : entry.unreadCount;
    return entry.copyWith(
      pinned: _pinStore.isPinned(entry.id),
      unreadCount: unread,
    );
  }

  static String _networkMarker(ChatListEntry entry) =>
      entry.lastEnvelope?.id ?? entry.lastActivity?.toIso8601String() ?? '';

  bool _matchesNetwork(ChatListEntry entry) {
    return switch (_networkFilter.kind) {
      ChatNetworkFilterKind.all => true,
      // Local is deliberately provider-only: server rows, including a
      // network whose id happens to be "my", never leak into this view.
      ChatNetworkFilterKind.my => entry.kind == ChatListEntryKind.localAgent,
      ChatNetworkFilterKind.network =>
        entry.networkId == _networkFilter.networkId,
    };
  }

  bool _matchesKind(ChatListEntry entry) {
    return switch (_filter) {
      ChatListFilter.all => true,
      ChatListFilter.unread => (entry.unreadCount ?? 0) > 0,
      ChatListFilter.agents => entry.kind != ChatListEntryKind.networkChannel,
      ChatListFilter.channels => entry.kind == ChatListEntryKind.networkChannel,
    };
  }

  List<ChatListEntry> get facetEntries {
    final entries = <ChatListEntry>[
      for (final entry in _entries)
        if (_matchesNetwork(entry) && _matchesKind(entry)) entry,
    ]..sort(_compareActivity);
    return List.unmodifiable(entries);
  }

  /// Every projected LOCAL row with pin/unread state applied — regardless
  /// of the active filter/search. The Local folder navigation groups these
  /// by cwd; a filtered Chats toolbar must never hide folders.
  List<ChatListEntry> get localEntries {
    final entries = <ChatListEntry>[
      for (final entry in _localEntries) _effectiveLocal(entry),
    ]..sort(_compareActivity);
    return List.unmodifiable(entries);
  }

  List<ChatListEntry> get visibleEntries {
    final query = _search.trim().toLowerCase();
    return List.unmodifiable([
      for (final entry in facetEntries)
        if (query.isEmpty ||
            '${entry.title} ${entry.networkName ?? ''} ${entry.folderName ?? ''} ${entry.preview ?? ''}'
                .toLowerCase()
                .contains(query))
          entry,
    ]);
  }

  List<ChatListEntry> get pinnedEntries =>
      List.unmodifiable(visibleEntries.where((entry) => entry.pinned));

  List<ChatListEntry> get recentEntries =>
      List.unmodifiable(visibleEntries.where((entry) => !entry.pinned));

  static int _compareActivity(ChatListEntry a, ChatListEntry b) {
    final aTime = a.lastActivity ?? a.createdAt;
    final bTime = b.lastActivity ?? b.createdAt;
    final byTime = bTime.compareTo(aTime);
    return byTime != 0 ? byTime : a.id.canonical.compareTo(b.id.canonical);
  }

  ChatLoadState get status {
    if (visibleEntries.isNotEmpty) return ChatLoadState.data;
    final networkRelevant = _networkFilter.kind != ChatNetworkFilterKind.my;
    if (_localStatus == ChatLoadState.loading ||
        (networkRelevant && _networkStatus == ChatLoadState.loading)) {
      return ChatLoadState.loading;
    }
    if (facetEntries.isEmpty) {
      if (_localStatus == ChatLoadState.error ||
          (networkRelevant && _networkStatus == ChatLoadState.error)) {
        return ChatLoadState.error;
      }
    }
    return ChatLoadState.empty;
  }

  /// Clears unread only after the caller's open action has completed.
  Future<void> markOpened(ChatListEntry entry) async {
    if (entry.kind == ChatListEntryKind.localAgent) {
      final count = entry.localMessageCount;
      if (count != null) await _readStore.markRead(entry.id, count);
      return;
    }
    if (entry.kind == ChatListEntryKind.networkChannel) {
      final adapter = _networkAdapter;
      if (adapter == null) return;
      final envelopeId = entry.lastEnvelope?.id;
      await adapter.markChannelRead(
        entry.id.value,
        envelopeId: envelopeId == null || envelopeId.isEmpty
            ? null
            : envelopeId,
        all: envelopeId == null || envelopeId.isEmpty,
      );
      _networkReadMarkers[entry.id.canonical] = _networkMarker(entry);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _localRequest++;
    _networkRequest++;
    _localChanges?.removeListener(_onLocalChanges);
    _pinStore.removeListener(_onStoreChanged);
    _readStore.removeListener(_onStoreChanged);
    super.dispose();
  }
}
