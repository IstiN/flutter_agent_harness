// ignore_for_file: avoid_print
import 'package:fa/services/contact_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contacts channel answers on device', (tester) async {
    final api = createContactService();
    print('[probe] isAvailable...');
    final available = await api.isAvailable.timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );
    print('[probe] isAvailable=$available');
    if (!available) return;

    print('[probe] requestAccess...');
    final granted = await api.requestAccess().timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );
    print('[probe] granted=$granted');

    print('[probe] search...');
    final results = await api
        .searchContacts(query: 'zz-nonexistent')
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw StateError('search timeout'),
        );
    print('[probe] search returned ${results.length}');

    print('[probe] create...');
    final id = await api
        .createContact(name: 'Probe Person', phones: const ['+1555'])
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw StateError('create timeout'),
        );
    print('[probe] created $id');
    await api.deleteContact(id: id);
    print('[probe] done');
  });
}
