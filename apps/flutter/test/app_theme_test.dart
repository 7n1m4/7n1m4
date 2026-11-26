// SPDX-License-Identifier: GPL-3.0-or-later

// ROOT CAUSE:
// AnimaApp used AppTheme.dark() unconditionally, so a daemon theme section
// with dark=false (or a different hue) had no effect on Flutter. The daemon
// owns settings/theme; the client must read it and build ThemeData from the
// returned values, falling back only to the daemon's own serde defaults.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/app.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/theme/app_theme.dart';

import 'support/fakes.dart';

ThemeData appTheme(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;

RpcReply themeReply(Map<String, dynamic> settings) => RpcReply(
      action: 'settings.get',
      ok: true,
      data: <String, dynamic>{
        'section': 'theme',
        'settings': settings,
      },
    );

void main() {
  group('AppTheme parsing', () {
    test('missing fields use daemon serde defaults, not invented values', () {
      final parsed = AppThemeSettings.fromSettings(const <String, dynamic>{});
      expect(parsed, AppThemeSettings.daemonDefaults);
      expect(AppTheme.fromParsed(parsed).colorScheme.brightness, Brightness.dark);
    });

    test('partial fields keep the daemon defaults for the others', () {
      final parsed = AppThemeSettings.fromSettings(const <String, dynamic>{
        'dark': false,
        'chromaMultiplier': 0.5,
      });
      expect(parsed.dark, isFalse);
      expect(parsed.chromaMultiplier, 0.5);
      expect(parsed.hue, AppThemeSettings.daemonDefaults.hue);
      expect(parsed.hueDynamic, isFalse);
    });

    test('malformed values never override the daemon defaults', () {
      final parsed = AppThemeSettings.fromSettings(const <String, dynamic>{
        'hue': 'not-a-number',
        'hueDynamic': 'yes',
        'chromaMultiplier': double.nan,
        'dark': 1,
      });
      expect(parsed, AppThemeSettings.daemonDefaults);
    });

    test('hue drives the seed colour while chroma scales its saturation', () {
      final blue = AppThemeSettings.fromSettings(const <String, dynamic>{'hue': 220.44});
      final red = AppThemeSettings.fromSettings(const <String, dynamic>{'hue': 10.0});
      final dull = AppThemeSettings.fromSettings(const <String, dynamic>{
        'hue': 220.44,
        'chromaMultiplier': 0.0,
      });

      expect(
        HSLColor.fromColor(AppTheme.seedColor(blue.hue, blue.chromaMultiplier)).hue,
        closeTo(220.44, 1.0),
      );
      expect(
        HSLColor.fromColor(AppTheme.seedColor(red.hue, red.chromaMultiplier)).hue,
        closeTo(10.0, 1.0),
      );
      expect(
        HSLColor.fromColor(AppTheme.seedColor(dull.hue, dull.chromaMultiplier))
            .saturation,
        0.0,
      );
    });
  });

  group('AnimaApp', () {
    testWidgets('loads the theme section from the daemon at startup',
        (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      final sections = <String>[];
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          sections.add(payload?['section'] as String);
          return themeReply(const <String, dynamic>{
            'hue': 220.44,
            'hueDynamic': false,
            'chromaMultiplier': 1.0,
            'dark': false,
          });
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(AnimaApp(client: client));
      await tester.pump();

      expect(sections, contains('theme'));
      expect(appTheme(tester).colorScheme.brightness, Brightness.light);
    });

    testWidgets('uses daemon defaults until the section arrives', (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      final pending = Completer<Map<String, dynamic>>();
      client.deferredSettings = pending;

      await tester.pumpWidget(AnimaApp(client: client));
      await tester.pump();

      expect(appTheme(tester).colorScheme.brightness, Brightness.dark);

      pending.complete(const <String, dynamic>{'dark': false});
      await tester.pump();
      await tester.pump();

      expect(appTheme(tester).colorScheme.brightness, Brightness.light);
    });

    testWidgets('a reconnect reloads the daemon theme', (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      var dark = false;
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return themeReply(<String, dynamic>{'dark': dark});
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(AnimaApp(client: client));
      await tester.pump();
      expect(appTheme(tester).colorScheme.brightness, Brightness.light);

      dark = true;
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();
      await tester.pump();

      expect(appTheme(tester).colorScheme.brightness, Brightness.dark);
    });

    testWidgets('a failed theme read keeps the daemon defaults', (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (_, __) {
        throw const DaemonClientException(
          kind: DaemonFailureKind.notConnected,
          message: 'Not connected to the daemon.',
        );
      };

      await tester.pumpWidget(AnimaApp(client: client));
      await tester.pump();
      await tester.pump();

      expect(appTheme(tester).colorScheme.brightness, Brightness.dark);
    });
  });
}
