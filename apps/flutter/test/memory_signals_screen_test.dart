// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/memory_signals_screen.dart';
import 'package:anima_control/features/settings/settings_catalog.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

class _PatchHarness {
  _PatchHarness() {
    client.onCall = (action, payload) {
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
            data: <String, dynamic>{'card': card},
          );
        case 'cards.update':
          writtenId = payload?['id'] as String?;
          writtenDocument = Map<String, dynamic>.from(
            payload?['document'] as Map<String, dynamic>? ??
                const <String, dynamic>{},
          );
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'id': writtenId,
              'name': writtenDocument?['name'] ?? '',
              'updated': true,
            },
          );
        default:
          throw StateError('unexpected action $action');
      }
    };
  }

  final FakeChatClient client = FakeChatClient();
  String? writtenId;
  Map<String, dynamic>? writtenDocument;

  final Map<String, dynamic> card = <String, dynamic>{
    'id': 'card-1',
    'name': 'Test Card',
    'description': 'keep the root sibling',
    'extensions': <String, dynamic>{
      'other': 'keep the extension sibling',
      'airi': <String, dynamic>{
        'modules': <String, dynamic>{
          'speech': <String, dynamic>{'enabled': true},
        },
        'dreamState': <String, dynamic>{
          'enabled': false,
          'journalingThreshold': 'balanced',
          'maxSessionsPerDay': 4,
          'sessionTimeoutMinutes': 60,
          'minConversationTurns': 4,
          'strictAfkGating': true,
        },
      },
    },
  };
}

Map<String, dynamic> _dreamStateOf(Map<String, dynamic> document) =>
    (((document['extensions'] as Map<String, dynamic>)['airi']
            as Map<String, dynamic>)['dreamState'] as Map<String, dynamic>);

void _expectSiblingsPreserved(Map<String, dynamic> written) {
  expect(written['name'], 'Test Card');
  expect(written['description'], 'keep the root sibling');
  final extensions = written['extensions'] as Map<String, dynamic>;
  expect(extensions['other'], 'keep the extension sibling');
  final airi = extensions['airi'] as Map<String, dynamic>;
  final modules = airi['modules'] as Map<String, dynamic>;
  expect(
    (modules['speech'] as Map<String, dynamic>)['enabled'],
    isTrue,
    reason: 'a literal leaf of the sibling modules tree survives',
  );
}

Future<_PatchHarness> _pumpScreen(WidgetTester tester) async {
  final harness = _PatchHarness();
  addTearDown(harness.client.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: MemorySignalsScreen(client: harness.client)),
  ));
  await tester.pumpAndSettle();
  return harness;
}

/// The numeric fields debounce on change; advance the fake clock past it.
Future<void> _settleDebounce(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

class _PatchCase {
  const _PatchCase(this.label, this.field, this.expected, this.act);

  final String label;
  final String field;
  final Object expected;
  final Future<void> Function(WidgetTester tester) act;
}

/// A client whose replies differ between the pre-save read, the write, and
/// the post-save refresh, so a save failure and a sync failure are distinct.
class _SyncOutcomesClient extends FakeChatClient {
  _SyncOutcomesClient({required this.failUpdate, required this.failRefresh}) {
    // FakeChatClient.settingsGet reads this field rather than going through call().
    settingsToLoad = const <String, dynamic>{'activeCardId': 'card-1'};
  }

  static const String secret = '/home/user/.config/anima/token=abc123?key=secret';

  final bool failUpdate;
  final bool failRefresh;
  int _getCalls = 0;

  final Map<String, dynamic> card = <String, dynamic>{
    'id': 'card-1',
    'name': 'Test Card',
    'extensions': <String, dynamic>{
      'airi': <String, dynamic>{
        'dreamState': <String, dynamic>{'enabled': false},
      },
    },
  };

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
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
        _getCalls++;
        // #1 is the initial load, #2 the pre-save re-read, #3 the refresh.
        if (failRefresh && _getCalls >= 3) {
          throw DaemonClientException(
            kind: DaemonFailureKind.transport,
            message: secret,
          );
        }
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'card': card},
        );
      case 'cards.update':
        if (failUpdate) {
          throw DaemonClientException(
            kind: DaemonFailureKind.transport,
            message: secret,
          );
        }
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
  }
}

void main() {
  testWidgets('dream-state catalog node under memory opens the signals screen',
      (tester) async {
    final node = settingsCatalogTopology.nodesById['mem-dream-signals'];
    expect(node, isNotNull, reason: 'the dream-state node is in the catalog');
    expect(node!.parentId, 'area-memory');
    expect(
      settingsCatalogTopology.orderedChildren('area-memory').map((n) => n.id),
      contains('mem-dream-signals'),
    );

    final client = FakeChatClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(client: client, onOpenConnections: () {}),
      ),
    ));
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('settings-search-field'));
    await tester.tap(search);
    await tester.enterText(search, 'dream');
    await tester.pumpAndSettle();

    final result = find.byKey(
      const ValueKey<String>('settings-search-result-mem-dream-signals'),
    );
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();

    expect(find.byType(MemorySignalsScreen), findsOneWidget);
  });

  testWidgets('toggling enabled patches dreamState without dropping siblings',
      (tester) async {
    final harness = await _pumpScreen(tester);

    final toggle = find.byKey(const Key('dream-state-enabled'));
    expect(toggle, findsOneWidget);
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(harness.writtenId, 'card-1');
    expect(harness.writtenDocument, isNotNull);
    final written = harness.writtenDocument!;
    _expectSiblingsPreserved(written);
    final dreamState = _dreamStateOf(written);
    expect(dreamState['enabled'], isTrue);
    expect(dreamState['journalingThreshold'], 'balanced');
    expect(dreamState['maxSessionsPerDay'], 4);
    expect(dreamState['sessionTimeoutMinutes'], 60);
    expect(dreamState['minConversationTurns'], 4);
    expect(dreamState['strictAfkGating'], isTrue);
  });

  final remainingFields = <_PatchCase>[
    _PatchCase('journalingThreshold', 'journalingThreshold', 'lush',
        (tester) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('dream-journaling-threshold-balanced')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lush — most sessions').last);
      await tester.pumpAndSettle();
    }),
    _PatchCase('maxSessionsPerDay', 'maxSessionsPerDay', 9, (tester) async {
      await tester.enterText(find.byKey(const Key('dream-max-sessions')), '9');
      await _settleDebounce(tester);
    }),
    _PatchCase('sessionTimeoutMinutes', 'sessionTimeoutMinutes', 90,
        (tester) async {
      await tester.enterText(find.byKey(const Key('dream-timeout')), '90');
      await _settleDebounce(tester);
    }),
    _PatchCase('minConversationTurns', 'minConversationTurns', 7,
        (tester) async {
      await tester.enterText(find.byKey(const Key('dream-min-turns')), '7');
      await _settleDebounce(tester);
    }),
    _PatchCase('strictAfkGating', 'strictAfkGating', false, (tester) async {
      final toggle = find.byKey(const Key('dream-strict-afk'));
      await tester
          .tap(find.descendant(of: toggle, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
    }),
  ];

  for (final testCase in remainingFields) {
    testWidgets('${testCase.label} patch preserves the card', (tester) async {
      final harness = await _pumpScreen(tester);
      await testCase.act(tester);

      expect(harness.writtenId, 'card-1');
      expect(harness.writtenDocument, isNotNull);
      final written = harness.writtenDocument!;
      _expectSiblingsPreserved(written);
      expect(_dreamStateOf(written)[testCase.field], testCase.expected);
    });
  }

  testWidgets('zero falls back and out-of-range values are clamped',
      (tester) async {
    final harness = await _pumpScreen(tester);

    await tester.enterText(find.byKey(const Key('dream-max-sessions')), '0');
    await _settleDebounce(tester);
    expect(_dreamStateOf(harness.writtenDocument!)['maxSessionsPerDay'], 4);

    await tester.enterText(find.byKey(const Key('dream-max-sessions')), '999');
    await _settleDebounce(tester);
    expect(_dreamStateOf(harness.writtenDocument!)['maxSessionsPerDay'], 24);
  });

  testWidgets('a failed post-save refresh warns without a save error',
      (tester) async {
    final client = _SyncOutcomesClient(failUpdate: false, failRefresh: true);
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MemorySignalsScreen(client: client)),
    ));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('dream-state-enabled'));
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dream-save-error')), findsNothing);
    expect(find.byKey(const Key('dream-save-status')), findsOneWidget);
    expect(find.byKey(const Key('dream-sync-warning')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining(_SyncOutcomesClient.secret), findsNothing,
        reason: 'raw handler text is never rendered');
    // The committed values stay visible and the controls stay live.
    final switchWidget = tester.widget<Switch>(
      find.descendant(of: toggle, matching: find.byType(Switch)),
    );
    expect(switchWidget.value, isTrue);
    expect(switchWidget.onChanged, isNotNull);
  });

  testWidgets('a failed save shows a sanitized error, no sync warning',
      (tester) async {
    final client = _SyncOutcomesClient(failUpdate: true, failRefresh: false);
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MemorySignalsScreen(client: client)),
    ));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('dream-max-sessions'));
    await tester.enterText(field, '9');
    await _settleDebounce(tester);

    expect(find.byKey(const Key('dream-save-error')), findsOneWidget);
    expect(
      find.text('Could not reach the daemon. Check the host and port, then retry.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dream-sync-warning')), findsNothing);
    expect(find.byKey(const Key('dream-save-status')), findsNothing);
    expect(find.textContaining(_SyncOutcomesClient.secret), findsNothing);
    // Dirty input is kept: no successful write means no controller reset.
    expect(
      tester.widget<TextFormField>(field).controller!.text,
      '9',
      reason: 'a failed save never overwrites what the user typed',
    );
  });
}
