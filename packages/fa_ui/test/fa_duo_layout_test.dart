import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FaDuoGeometry _duo({
  FaDuoVerticalBarEdge edge = FaDuoVerticalBarEdge.trailing,
  List<Rect> occlusions = const [Rect.fromLTWH(306, 12, 84, 114)],
}) {
  return FaDuoGeometry(
    isDuo: true,
    hardwareModel: 'iPhone19,4',
    verticalBarEdge: edge,
    safeAreaInsets: const EdgeInsets.only(right: 84, top: 59),
    occlusions: occlusions,
    divisions: const [],
  );
}

Future<({double width, double top, bool active})> _layout(
  WidgetTester tester,
  FaDuoGeometry? geometry, {
  EdgeInsets padding = const EdgeInsets.only(right: 84),
}) async {
  late ({double width, double top, bool active}) result;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(390, 844), padding: padding),
        child: FaDuoLayoutScope(
          geometry: geometry,
          child: Builder(
            builder: (context) {
              result = (
                width: FaDuoControlRail.widthOf(context),
                top: FaDuoControlRail.topOf(context),
                active: FaDuoControlRail.isActive(context),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  return result;
}

void main() {
  group('FaDuoGeometry native snapshot', () {
    test('parses vertical-bar traits and reserved camera regions', () {
      final geometry = FaDuoGeometry.fromChannelValue(const {
        'isDuo': true,
        'hardwareModel': 'iPhone19,4',
        'verticalBarEdge': 2,
        'safeArea': {'left': 0.0, 'top': 59.0, 'right': 84.0, 'bottom': 21.0},
        'occlusions': [
          {
            'left': 306.0,
            'top': 12.0,
            'width': 84.0,
            'height': 114.0,
            'active': true,
          },
        ],
        'divisions': [
          {
            'left': 470.0,
            'top': 0.0,
            'width': 12.0,
            'height': 669.0,
            'active': false,
          },
        ],
      });

      expect(geometry.isDuo, isTrue);
      expect(geometry.verticalBarEdge, FaDuoVerticalBarEdge.trailing);
      expect(geometry.safeAreaInsets.right, 84);
      expect(geometry.occlusions.single, const Rect.fromLTWH(306, 12, 84, 114));
      expect(
        geometry.divisions,
        isEmpty,
        reason: 'inactive folds do not split the canvas',
      );
    });
  });

  group('FaDuoControlRail native layout', () {
    testWidgets('ordinary phones never opt in from a large inherited inset', (
      tester,
    ) async {
      final result = await _layout(
        tester,
        const FaDuoGeometry(
          isDuo: false,
          hardwareModel: 'iPhone18,1',
          verticalBarEdge: FaDuoVerticalBarEdge.unspecified,
          safeAreaInsets: EdgeInsets.only(right: 84),
          occlusions: [Rect.fromLTWH(306, 12, 84, 114)],
          divisions: [],
        ),
      );
      expect(result.active, isFalse);
      expect(result.width, 0);
    });

    testWidgets('Duo trailing bar reserves the real camera clearance', (
      tester,
    ) async {
      final result = await _layout(tester, _duo());
      expect(result.active, isTrue);
      expect(result.width, 84);
      expect(result.top, greaterThanOrEqualTo(134));
    });

    testWidgets('horizontal inner display keeps the ordinary header', (
      tester,
    ) async {
      final result = await _layout(
        tester,
        _duo(
          edge: FaDuoVerticalBarEdge.unspecified,
          occlusions: const [Rect.fromLTWH(867, 280, 84, 100)],
        ),
        padding: const EdgeInsets.only(right: 84),
      );
      expect(result.active, isFalse);
      expect(result.width, 0);
    });

    testWidgets('unscoped hosts retain the inset fallback', (tester) async {
      late double width;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(right: 84),
            ),
            child: Builder(
              builder: (context) {
                width = FaDuoControlRail.widthOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(width, 84);
    });
  });
}
