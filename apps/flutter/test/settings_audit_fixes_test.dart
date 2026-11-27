// SPDX-License-Identifier: GPL-3.0-or-later

// Regression tests for three code-grounded audit findings:
// F5 legacy snake_case caption size, F7 per-field numeric debounce, and
// F8 overlapping load/save draft safety in the settings hub.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/captions_values.dart';
import 'package:anima_control/features/settings/memory_signals_screen.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

/// A complete valid captions blob. [key] picks the wire spelling of the size
/// field so the legacy `font_size` shape can be tested against the current one.
Map<String, dynamic> _captionsBlob(Object? size, {String key = 'fontSize'}) =>
    <String, dynamic>{
      'enabled': true,
      key: size,
      'opacity': 20,
      'docking': 'none',
      'followStageVisibility': true,
      'followStagePosition': true,
      'layoutMode': 'single',
      'resetTrigger': 0,
      'headTetheredCaptionEnabled': false,
      'headTetheredCaptionOffset': <String, dynamic>{'x': 0.0, 'y': -15.0},
      'headTetheredCaptionFollowStrength': 100.0,
    };

Widget _settingsScreen(FakeChatClient client) => MaterialApp(
  home: Scaffold(
    body: SettingsScreen(client: client, onOpenConnections: () {}),
  ),
);

Map<String, dynamic> _dreamStateOf(Map<String, dynamic> document) =>
    (((document['extensions'] as Map<String, dynamic>)['airi']
            as Map<String, dynamic>)['dreamState']
        as Map<String, dynamic>);

/// Records every whole-card document the numeric fields write.
class _RecordingDreamClient extends FakeChatClient {
  _RecordingDreamClient() {
    onCall = (action, payload) {
      switch (action) {
        case 'settings.get':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{'activeCardId': 'card-1'},
            },
          );
        case 'cards.get':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'card': <String, dynamic>{
                'id': 'card-1',
                'name': 'Test Card',
                'extensions': <String, dynamic>{
                  'airi': <String, dynamic>{
                    'dreamState': <String, dynamic>{
                      'enabled': false,
                      'journalingThreshold': 'balanced',
                      'maxSessionsPerDay': 4,
                      'sessionTimeoutMinutes': 60,
                      'minConversationTurns': 4,
                    },
                  },
                },
              },
            },
          );
        case 'cards.update':
          writes.add(
            Map<String, dynamic>.from(
              payload?['document'] as Map<String, dynamic>? ??
                  const <String, dynamic>{},
            ),
          );
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'id': payload?['id'],
              'name': 'Test Card',
              'updated': true,
            },
          );
        default:
          throw StateError('unexpected action $action');
      }
    };
  }

  final List<Map<String, dynamic>> writes = <Map<String, dynamic>>[];
}

/// Lets a save and a reload overlap: the first write waits on [writeGate] and
/// every settings.get made while [reloadGate] is set waits on that gate.
class _OverlapSettingsClient extends FakeChatClient {
  Completer<bool>? writeGate;
  Completer<void>? reloadGate;
  int writeCalls = 0;
  final List<Map<String, dynamic>> captures = <Map<String, dynamic>>[];

  @override
  Future<bool> settingsSet(
    String section,
    Map<String, dynamic> settings,
  ) async {
    writeCalls++;
    captures.add(Map<String, dynamic>.from(settings));
    if (writeCalls == 1 && writeGate != null) {
      return writeGate!.future;
    }
    return true;
  }

  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    final gate = reloadGate;
    if (gate != null) {
      await gate.future;
      if (section == 'captions') {
        return _captionsBlob(180);
      }
    }
    return super.settingsGet(section);
  }
}

Future<void> _enterFontSize(WidgetTester tester, String text) async {
  final field = find.widgetWithText(TextField, 'Font size (%)');
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
}

Future<void> _saveCaptions(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  tester.widget<FilledButton>(button).onPressed!();
  await tester.pump();
}

void main() {
  group('F5 legacy caption size', () {
    test('normalizeCaptions migrates font_size before applying defaults', () {
      final normalized = normalizeCaptions(
        _captionsBlob(150, key: 'font_size'),
      );
      expect(normalized['fontSize'], 150);
      expect(normalized.containsKey('font_size'), isFalse);
      expect(validateCaptions(normalized).isValid, isTrue);

      // An invalid legacy value migrates unchanged so validation fails closed.
      final invalid = normalizeCaptions(_captionsBlob(250, key: 'font_size'));
      expect(invalid['fontSize'], 250);
      expect(validateCaptions(invalid).isValid, isFalse);
    });

    testWidgets('legacy font_size survives an unrelated save', (tester) async {
      final client = FakeChatClient()
        ..settingsToLoad = _captionsBlob(150, key: 'font_size');
      addTearDown(client.dispose);
      await tester.pumpWidget(_settingsScreen(client));
      await tester.pumpAndSettle();

      final tile = find.ancestor(
        of: find.text('Follow stage visibility'),
        matching: find.byType(SwitchListTile),
      );
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      await _saveCaptions(tester, 'Save captions');

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['fontSize'], 150, reason: 'legacy size is not reset');
      expect(written.containsKey('font_size'), isFalse);
      expect(written['followStageVisibility'], isFalse);
    });
  });

  group('F7 per-field numeric debounce', () {
    testWidgets('two edits in one debounce window both save', (tester) async {
      final client = _RecordingDreamClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MemorySignalsScreen(client: client)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('dream-max-sessions')), '9');
      await tester.enterText(find.byKey(const Key('dream-timeout')), '90');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(client.writes, hasLength(2), reason: 'neither keystroke is lost');
      final patches = client.writes.map(_dreamStateOf).toList();
      expect(patches.any((d) => d['maxSessionsPerDay'] == 9), isTrue);
      expect(patches.any((d) => d['sessionTimeoutMinutes'] == 90), isTrue);
    });

    testWidgets('a pending edit is flushed when the screen is disposed', (
      tester,
    ) async {
      final client = _RecordingDreamClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MemorySignalsScreen(client: client)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('dream-max-sessions')), '9');
      // Leave before the 150ms timer fires.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(client.writes, hasLength(1));
      expect(_dreamStateOf(client.writes.single)['maxSessionsPerDay'], 9);
    });
  });

  group('F8 overlapping load and save', () {
    testWidgets('a reload during a save keeps busy and the saved draft', (
      tester,
    ) async {
      final client = _OverlapSettingsClient()
        ..settingsToLoad = _captionsBlob(100)
        ..writeGate = Completer<bool>(); // ignore: prefer_const_constructors
      addTearDown(client.dispose);
      await tester.pumpWidget(_settingsScreen(client));
      await tester.pumpAndSettle();
      // ignore: prefer_const_constructors — Completer's factory is not const.
      client.reloadGate = Completer<void>();

      await _enterFontSize(tester, '150');
      final button = find.widgetWithText(FilledButton, 'Save captions');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(button).onPressed!;
      save();
      save(); // a double-tap must not start a second write
      expect(client.writeCalls, 1);

      client.emitEvent(
        const GatewayEventFrame(
          topic: EventTopic.settingsChanged,
          rawTopic: 'settings.changed',
          data: <String, dynamic>{'section': 'captions'},
        ),
      );
      await tester.pump();

      client.writeGate!.complete(true);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(button).onPressed,
        isNull,
        reason: 'the in-flight reload keeps Save disabled after the save ends',
      );

      client.reloadGate!.complete();
      await tester.pumpAndSettle();
      save();
      await tester.pump();
      expect(
        client.captures.last['fontSize'],
        150,
        reason: 'the reload did not clobber the section being saved',
      );
    });

    testWidgets('a reload skips a dirty draft', (tester) async {
      final client = _OverlapSettingsClient()
        ..settingsToLoad = _captionsBlob(100);
      addTearDown(client.dispose);
      await tester.pumpWidget(_settingsScreen(client));
      await tester.pumpAndSettle();

      await _enterFontSize(tester, '150');
      client.emitEvent(
        const GatewayEventFrame(
          topic: EventTopic.settingsChanged,
          rawTopic: 'settings.changed',
          data: <String, dynamic>{'section': 'captions'},
        ),
      );
      await tester.pumpAndSettle();

      await _saveCaptions(tester, 'Save captions');
      expect(
        client.captures.single['fontSize'],
        150,
        reason: 'an uncommitted edit is never overwritten by a reload',
      );
    });
  });
}
