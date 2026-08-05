// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Promo capture harness: renders the promo video's app captures as goldens
/// (`test/golden/goldens/promo_*.png`) with the REAL JS engine, portrait
/// 1290×2796 (App Preview size). Regenerate with:
///
/// ```bash
/// flutter test test/golden/promo_golden_test.dart --update-goldens \
///   --dart-define=PROMO_CAPTURE=true
/// ```
///
/// Gated behind the PROMO_CAPTURE dart-define so normal suites skip it (the
/// stocks demo fetches live quotes; these captures are marketing assets,
/// refreshed on demand, not a CI contract).
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

const _enabled = bool.fromEnvironment('PROMO_CAPTURE');

/// App Preview portrait.
const _promoSize = Size(1290, 2796);

/// A self-contained promo 3D-game frame: the real scene3d host with a
/// staged dodge scene (player cube + red blocks mid-fall + populated HUD).
/// The bundled game's rAF loop doesn't tick in the capture sandbox, so the
/// promo scene is posed instead of played.
const _promoGameWidget = '''
(function() {
  var sceneId = 'promo-dodge';
  jsr.scene3d.create(sceneId, {
    camera: { position: [0, 12, 14], target: [0, 0, -4], fov: 55 },
    light: { position: [5, 10, 8], color: '#ffffff', ambient: 0.5, diffuse: 0.7 }
  });
  jsr.scene3d.addModel(sceneId, {
    modelId: 'player', primitive: 'cube', color: '#22d3ee',
    position: [-1.2, 0, 2], scale: [1.2, 1.2, 1.2]
  });
  var blocks = [
    { x: 0.6, z: -3.5 }, { x: -2.4, z: -7 }, { x: 2.2, z: -10.5 },
    { x: -0.4, z: -14 }, { x: 1.6, z: -17.5 }, { x: -1.8, z: -20 }
  ];
  for (var i = 0; i < blocks.length; i++) {
    jsr.scene3d.addModel(sceneId, {
      modelId: 'block-' + i, primitive: 'cube', color: '#ef4444',
      position: [blocks[i].x, 0, blocks[i].z], scale: [1, 1, 1]
    });
  }
  function stat(t, label, value) {
    return {type:'column',mainAxisSize:'min',children:[
      {type:'text',data:label,style:{fontSize:9,color:t.muted,letterSpacing:1.1}},
      {type:'text',data:value,style:{fontSize:13,fontWeight:'w700',color:t.text}}
    ]};
  }
  function render() {
    var t = jsr.theme;
    jsr.render({
      type:'column',crossAxisAlignment:'stretch',children:[
        {type:'expanded',child:{type:'stack',fit:'expand',children:[
          {type:'scene3d',id:sceneId,interactive:false}
        ]}},
        {type:'container',color:t.surface,padding:[10,16,10,16],child:{
          type:'row',mainAxisAlignment:'spaceBetween',crossAxisAlignment:'center',children:[
            stat(t,'SCORE','4.8s'),
            {type:'text',data:'♥♥♥',style:{fontSize:16}},
            stat(t,'BEST','12.3s'),
            {type:'text',data:'drag to steer',style:{fontSize:11,color:t.muted}}
          ]
        }}
      ]
    });
  }
  jsr.onEvent(function() {});
  render();
})();
''';

/// A self-contained promo ticker widget in the stocks app's visual language
/// (dark #1e293b cards, green/red change badges, sparkline) with canned
/// quotes that tick — staging for the promo capture (the live Yahoo call is
/// rate-limited in sandboxes).
const _promoTickerWidget = '''
(function() {
  var quotes = [
    { symbol: 'AAPL', name: 'Apple Inc.', price: 234.56, prev: 231.20, spark: [229,230,231,230.4,231.2,232.8,234.6] },
    { symbol: 'MSFT', name: 'Microsoft Corporation', price: 512.84, prev: 516.10, spark: [519,517,516.1,513,514.5,512.8] },
    { symbol: 'GOOGL', name: 'Alphabet Inc.', price: 198.42, prev: 195.90, spark: [194,195,195.9,196.4,197.5,198.4] },
    { symbol: 'NVDA', name: 'NVIDIA Corporation', price: 118.27, prev: 112.70, spark: [110,112,112.7,114,116,118.3] },
    { symbol: 'TSLA', name: 'Tesla, Inc.', price: 322.41, prev: 318.00, spark: [315,316,318,319,320,322.4] }
  ];
  function fmt(n, sign) {
    var s = n >= 0 ? (sign ? '+' : '') : '-';
    return s + Math.abs(n).toFixed(2);
  }
  var tick = 0;
  setInterval(function() {
    tick += 1;
    var q = quotes[tick % quotes.length];
    q.price = Math.round((q.price + 0.13) * 100) / 100;
    render();
  }, 900);
  function row(t, q) {
    var chgAbs = q.price - q.prev;
    var chgPct = q.prev > 0 ? (chgAbs / q.prev) * 100 : 0;
    var chgColor = chgPct >= 0 ? '#4ade80' : '#f87171';
    var bgColor = chgPct >= 0 ? '#052e16' : '#2d0a0a';
    return {type:'container',margin:[0,0,0,8],decoration:{color:'#1e293b',borderRadius:12,borderColor:'#334155',borderWidth:1},padding:[14,12,14,12],
      child:{type:'row',crossAxisAlignment:'center',children:[
        {type:'expanded',child:{type:'column',crossAxisAlignment:'start',mainAxisSize:'min',children:[
          {type:'text',data:q.symbol,style:{color:'#e2e8f0',fontWeight:'w700',fontSize:16}},
          {type:'text',data:q.name,style:{color:'#64748b',fontSize:11}}
        ]}},
        {type:'sizedBox',width:64,child:{type:'chart',data:q.spark,chartType:'line',color:chgColor,strokeWidth:1.5,height:26}},
        {type:'sizedBox',width:12},
        {type:'column',crossAxisAlignment:'end',mainAxisSize:'min',children:[
          {type:'text',data:'\$' + q.price.toFixed(2),style:{color:'#f1f5f9',fontWeight:'w700',fontSize:15}},
          {type:'container',decoration:{color:bgColor,borderRadius:5},padding:[4,3,4,3],
            child:{type:'text',data:fmt(chgAbs,true)+' ('+fmt(chgPct,true)+'%)',style:{color:chgColor,fontSize:10,fontWeight:'w600'}}}
        ]}
      ]}};
  }
  function render() {
    var t = jsr.theme;
    jsr.render({type:'safeArea',child:{type:'column',crossAxisAlignment:'stretch',children:[
      {type:'padding',padding:[16,12,16,10],child:{type:'row',children:[
        {type:'expanded',child:{type:'column',crossAxisAlignment:'start',mainAxisSize:'min',children:[
          {type:'text',data:'Watchlist',style:{color:t.text,fontSize:16,fontWeight:'w700'}},
          {type:'text',data:'live · just now',style:{color:t.muted,fontSize:11}}
        ]}},
        {type:'container',padding:[10,6,10,6],decoration:{color:t.surfaceAlt,borderRadius:14},
          child:{type:'text',data:'NASDAQ',style:{color:t.accent,fontSize:11,fontWeight:'w700'}}}
      ]}},
      {type:'padding',padding:[14,2,14,0],child:{type:'column',crossAxisAlignment:'stretch',
        children:quotes.map(function(q) { return row(t, q); })}}
    ]}});
  }
  jsr.onEvent(function() {});
  render();
})();
''';

JsAppInfo _app(Map<String, Object?> manifest, String fallbackId) =>
    JsAppInfo.fromManifest(manifest, bundled: true, fallbackId: fallbackId);

Future<void> _capture(
  WidgetTester tester, {
  required String appId,
  required String golden,
  required String? expectText,
  ThemeData? theme,
  String? chromeOverride,
  String? widgetOverride,
  int waitFrames = 40,
}) async {
  await tester.runAsync(() async {
    final manifest =
        (jsonDecode(
                  await File('assets/apps/$appId/manifest.json').readAsString(),
                )
                as Map)
            .cast<String, Object?>();
    if (chromeOverride != null) manifest['chrome'] = chromeOverride;
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/$appId/manifest.json', jsonEncode(manifest));
    await env.writeFile(
      'apps/$appId/widget.js',
      await File('assets/apps/$appId/widget.js').readAsString(),
    );
    final iconFile = File('assets/apps/$appId/icon.svg');
    if (iconFile.existsSync()) {
      await env.writeFile(
        'apps/$appId/icon.svg',
        await iconFile.readAsString(),
      );
    }
    if (widgetOverride != null) {
      await env.writeFile('apps/$appId/widget.js', widgetOverride);
    }
    final permissions = await AppPermissionsStore.load(env);

    tester.view.physicalSize = _promoSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme ?? buildFahTheme(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: JsAppView(
          app: _app(manifest, appId),
          env: env,
          permissionsStore: permissions,
          onSendToAgent: (message) async => null,
        ),
      ),
    );
    // The engine boots on the real event loop; wait real time and flush
    // frames manually until the app's signature text appears.
    for (var i = 0; i < waitFrames; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      if (expectText != null && find.text(expectText).evaluate().isNotEmpty) {
        break;
      }
    }
    if (expectText != null) expect(find.text(expectText), findsWidgets);
    await tester.pump(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await expectGolden(tester, golden);
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('promo captures (PROMO_CAPTURE only)', skip: !_enabled, () {
    testWidgets('fitness trainer (light)', (tester) async {
      await _capture(
        tester,
        appId: 'fitness-trainer',
        golden: 'promo_fitness_light',
        expectText: 'Goblet Squat',
        theme: buildFahThemeLight(),
      );
    });

    testWidgets('english teacher (light)', (tester) async {
      await _capture(
        tester,
        appId: 'english-teacher',
        golden: 'promo_teacher_light',
        expectText: 'Daily English',
        theme: buildFahThemeLight(),
      );
    });

    testWidgets('stocks ticker (dark)', (tester) async {
      await _capture(
        tester,
        appId: 'stocks',
        golden: 'promo_stocks_dark',
        expectText: 'Watchlist',
        widgetOverride: _promoTickerWidget,
      );
    });

    testWidgets('3d game (dark)', (tester) async {
      await _capture(
        tester,
        appId: '3d-game',
        golden: 'promo_game_dark',
        expectText: 'SCORE',
        widgetOverride: _promoGameWidget,
        waitFrames: 60,
      );
    });
  });
}
