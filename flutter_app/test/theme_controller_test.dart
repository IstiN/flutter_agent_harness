import 'package:fa/services/theme_controller.dart';
import 'package:fa_ui/fa_ui.dart' show FaFontPreset, FaVisualDirection;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThemeController', () {
    test('defaults to system mode', () {
      final controller = ThemeController.inMemory();
      expect(controller.mode, FahThemeMode.system);
      expect(controller.themeMode, ThemeMode.system);
    });

    test('maps every mode to its ThemeMode', () {
      final controller = ThemeController.inMemory();
      controller.setMode(FahThemeMode.light);
      expect(controller.themeMode, ThemeMode.light);
      controller.setMode(FahThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
      controller.setMode(FahThemeMode.system);
      expect(controller.themeMode, ThemeMode.system);
    });

    test('setMode notifies listeners', () async {
      final controller = ThemeController.inMemory();
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.setMode(FahThemeMode.light);
      expect(notified, 1);
      // Re-selecting the current mode is a no-op.
      await controller.setMode(FahThemeMode.light);
      expect(notified, 1);
    });

    test('missing file loads as the default mode', () async {
      final env = MemoryExecutionEnv();
      final controller = await ThemeController.load(env);
      expect(controller.mode, FahThemeMode.system);
    });

    test(
      'corrupt file loads as the default mode instead of crashing',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeFile('${env.cwd}/theme.json', 'not json {');
        final controller = await ThemeController.load(env);
        expect(controller.mode, FahThemeMode.system);
      },
    );

    test('wrong schema version loads as the default mode', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/theme.json',
        '{"version": 99, "mode": "light"}',
      );
      final controller = await ThemeController.load(env);
      expect(controller.mode, FahThemeMode.system);
    });

    test('unknown mode string parses as system', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/theme.json',
        '{"version": 1, "mode": "solarized"}',
      );
      final controller = await ThemeController.load(env);
      expect(controller.mode, FahThemeMode.system);
    });

    test('the mode round-trips through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final controller = await ThemeController.load(env);
      await controller.setMode(FahThemeMode.light);

      final reloaded = await ThemeController.load(env);
      expect(reloaded.mode, FahThemeMode.light);
      expect(reloaded.themeMode, ThemeMode.light);
    });

    test('E4: a colors-only pack keeps the current wallpaper choice', () async {
      final controller = ThemeController.inMemory();
      await controller.setPack('a', hasWallpaper: true);
      expect(controller.wallpaperPackId, 'a');

      // Switch to a colors-only pack: the wallpaper source stays 'a'.
      await controller.setPack('b', hasWallpaper: false);
      expect(controller.packId, 'b');
      expect(controller.wallpaperPackId, 'a');

      // Reverting to the stock look clears both (AC5 atomic revert).
      await controller.setPack(null);
      expect(controller.packId, isNull);
      expect(controller.wallpaperPackId, isNull);
    });

    test(
      'visual direction defaults to Liquid Glass and notifies once',
      () async {
        final controller = ThemeController.inMemory();
        expect(controller.visualDirection, FaVisualDirection.glass);
        var notified = 0;
        controller.addListener(() => notified++);
        await controller.setVisualDirection(FaVisualDirection.nebula);
        expect(controller.visualDirection, FaVisualDirection.nebula);
        expect(notified, 1);
        await controller.setVisualDirection(FaVisualDirection.nebula);
        expect(notified, 1);
      },
    );

    test('visual direction round-trips and unknown values are safe', () async {
      final env = MemoryExecutionEnv();
      final controller = await ThemeController.load(env);
      await controller.setVisualDirection(FaVisualDirection.porcelain);
      expect(
        (await ThemeController.load(env)).visualDirection,
        FaVisualDirection.porcelain,
      );
      await env.writeFile(
        '${env.cwd}/theme.json',
        '{"version": 1, "mode": "system", "direction": "unknown"}',
      );
      expect(
        (await ThemeController.load(env)).visualDirection,
        FaVisualDirection.glass,
      );
    });

    test(
      'font preset defaults, notifies once and round-trips safely',
      () async {
        final env = MemoryExecutionEnv();
        final controller = await ThemeController.load(env);
        expect(controller.fontPreset, FaFontPreset.system);
        var notified = 0;
        controller.addListener(() => notified++);

        await controller.setFontPreset(FaFontPreset.geist);
        expect(controller.fontPreset, FaFontPreset.geist);
        expect(notified, 1);
        await controller.setFontPreset(FaFontPreset.geist);
        expect(notified, 1);
        expect(
          (await ThemeController.load(env)).fontPreset,
          FaFontPreset.geist,
        );

        await env.writeFile(
          '${env.cwd}/theme.json',
          '{"version": 1, "mode": "system", "font": "unknown"}',
        );
        expect(
          (await ThemeController.load(env)).fontPreset,
          FaFontPreset.system,
        );
      },
    );

    test('the pack and wallpaper ids round-trip through the env', () async {
      final env = MemoryExecutionEnv();
      final controller = await ThemeController.load(env);
      await controller.setPack('forest-walk', hasWallpaper: true);
      await controller.setPack('mono', hasWallpaper: false);

      final reloaded = await ThemeController.load(env);
      expect(reloaded.packId, 'mono');
      expect(reloaded.wallpaperPackId, 'forest-walk');
    });
  });
}
