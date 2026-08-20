// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('raw Image.network error surface', (tester) async {
    const url =
        'https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/240px-PNG_transparency_demonstration_1.png';
    Object? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Image.network(
            url,
            width: 120,
            height: 120,
            errorBuilder: (_, error, _) {
              captured = error;
              return const Icon(Icons.error);
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final ok = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((r) => r.image != null);
      if (ok || captured != null) break;
    }
    print('[raw] error=$captured');
    final decoded = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .any((r) => r.image != null);
    print('[raw] decoded=$decoded');
  });
}
