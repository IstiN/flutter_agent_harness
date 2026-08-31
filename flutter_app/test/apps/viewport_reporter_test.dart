import 'package:fa/apps/viewport_reporter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reports the allotted size once, then only on change', (
    tester,
  ) async {
    final sizes = <Size>[];
    Widget host(double w, double h) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: w,
          height: h,
          child: ViewportReporter(
            onSize: sizes.add,
            child: const ColoredBox(color: Colors.red),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(400, 300));
    await tester.pumpAndSettle();
    expect(sizes, [const Size(400, 300)]);

    // Same size again — no duplicate event.
    await tester.pumpWidget(host(400, 300));
    await tester.pumpAndSettle();
    expect(sizes, hasLength(1));

    // A resize reports the new size.
    await tester.pumpWidget(host(500, 300));
    await tester.pumpAndSettle();
    expect(sizes, [const Size(400, 300), const Size(500, 300)]);
  });

  testWidgets('ignores unbounded (infinite) constraints', (tester) async {
    final sizes = <Size>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            ViewportReporter(
              onSize: sizes.add,
              child: const SizedBox(width: 120, height: 80),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(sizes, isEmpty);
  });
}
