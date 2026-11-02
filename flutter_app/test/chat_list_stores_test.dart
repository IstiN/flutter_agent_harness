import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatPinStore', () {
    test('persists pins independently per account', () async {
      final env = MemoryExecutionEnv();
      final id = ChatEntryId.local('session-1');
      final alice = await ChatPinStore.load(env, accountId: 'alice');
      await alice.setPinned(id, true);

      final aliceReloaded = await ChatPinStore.load(env, accountId: 'alice');
      final bob = await ChatPinStore.load(env, accountId: 'bob');
      expect(aliceReloaded.isPinned(id), isTrue);
      expect(bob.isPinned(id), isFalse);

      await aliceReloaded.setPinned(id, false);
      expect(
        (await ChatPinStore.load(env, accountId: 'alice')).isPinned(id),
        isFalse,
      );
    });
  });

  group('ChatReadCursorStore', () {
    test('persists per account and only advances monotonically', () async {
      final env = MemoryExecutionEnv();
      final id = ChatEntryId.local('session-1');
      final store = await ChatReadCursorStore.load(env, accountId: 'alice');
      expect(store.cursorFor(id), isNull);

      await store.markRead(id, 12);
      await store.markRead(id, 7);
      expect(store.cursorFor(id), 12);

      final reloaded = await ChatReadCursorStore.load(env, accountId: 'alice');
      final other = await ChatReadCursorStore.load(env, accountId: 'bob');
      expect(reloaded.cursorFor(id), 12);
      expect(other.cursorFor(id), isNull);
    });

    test('typed ids keep local and network cursors separate', () async {
      final store = ChatReadCursorStore.inMemory(accountId: 'alice');
      final local = ChatEntryId.local('same');
      final remote = ChatEntryId.network(
        ChatListEntryKind.networkChannel,
        networkId: 'n1',
        id: 'same',
      );
      await store.markRead(local, 3);
      expect(store.cursorFor(remote), isNull);
      expect(store.cursorFor(local), 3);
    });
  });
}
