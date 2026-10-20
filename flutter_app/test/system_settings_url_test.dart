// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOsPrivacyPaneForPermission', () {
    test('calendar maps to the Calendars privacy pane', () {
      expect(macOsPrivacyPaneForPermission('calendar'), 'Privacy_Calendars');
    });

    test('contacts maps to the Contacts privacy pane', () {
      expect(macOsPrivacyPaneForPermission('contacts'), 'Privacy_Contacts');
    });

    test('home and homekit map to the HomeKit privacy pane', () {
      expect(macOsPrivacyPaneForPermission('home'), 'Privacy_HomeKit');
      expect(macOsPrivacyPaneForPermission('homekit'), 'Privacy_HomeKit');
    });

    test('microphone maps to the Microphone privacy pane', () {
      expect(macOsPrivacyPaneForPermission('microphone'), 'Privacy_Microphone');
    });

    test('notifications resolve to the dedicated pane (null anchor)', () {
      expect(macOsPrivacyPaneForPermission('notification'), isNull);
      expect(macOsPrivacyPaneForPermission('notifications'), isNull);
    });

    test('unknown permissions fall back to the Calendars pane', () {
      expect(macOsPrivacyPaneForPermission('health'), 'Privacy_Calendars');
      expect(macOsPrivacyPaneForPermission(''), 'Privacy_Calendars');
    });

    test('matching is case-insensitive', () {
      expect(macOsPrivacyPaneForPermission('Microphone'), 'Privacy_Microphone');
      expect(macOsPrivacyPaneForPermission('NOTIFICATIONS'), isNull);
    });
  });

  group('systemSettingsUrlForPermission', () {
    test('non-macOS platforms open the app settings page', () {
      for (final permission in [
        'calendar',
        'contacts',
        'home',
        'microphone',
        'notifications',
        'health',
      ]) {
        expect(
          systemSettingsUrlForPermission(permission, isMacOS: false),
          'app-settings:',
          reason: permission,
        );
      }
    });

    test('macOS privacy panes deep-link into Privacy & Security', () {
      expect(
        systemSettingsUrlForPermission('calendar', isMacOS: true),
        'x-apple.systempreferences:'
        'com.apple.preference.security?Privacy_Calendars',
      );
      expect(
        systemSettingsUrlForPermission('contacts', isMacOS: true),
        'x-apple.systempreferences:'
        'com.apple.preference.security?Privacy_Contacts',
      );
      expect(
        systemSettingsUrlForPermission('homekit', isMacOS: true),
        'x-apple.systempreferences:'
        'com.apple.preference.security?Privacy_HomeKit',
      );
      expect(
        systemSettingsUrlForPermission('microphone', isMacOS: true),
        'x-apple.systempreferences:'
        'com.apple.preference.security?Privacy_Microphone',
      );
    });

    test('macOS notifications use the dedicated notifications pane', () {
      expect(
        systemSettingsUrlForPermission('notifications', isMacOS: true),
        'x-apple.systempreferences:com.apple.preference.notifications',
      );
    });

    test('macOS unknown permission falls back to the Calendars pane', () {
      expect(
        systemSettingsUrlForPermission('health', isMacOS: true),
        'x-apple.systempreferences:'
        'com.apple.preference.security?Privacy_Calendars',
      );
    });
  });
}
