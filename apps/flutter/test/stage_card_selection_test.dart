// SPDX-License-Identifier: GPL-3.0-or-later

// The stage destination must receive a card id loaded from the daemon and
// refresh that choice when the user returns to the tab. No native renderer is
// involved: cards here name no display model, so the assertions stay on the
// card id actually handed to StageScreen and on the cards.get read behind it.

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/stage_background.dart';
import 'package:anima_control/features/stage/stage_caption_overlay.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_scene_manager.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/l10n/app_localizations.dart';
import 'package:anima_control/navigation/navigation_shell.dart';

import 'support/fakes.dart';

class _CardClient extends FakeChatClient {
  List<Map<String, dynamic>> cards;
  final List<String> getIds = <String>[];
  int listCalls = 0;
  bool listFails = false;

  _CardClient(this.cards);

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    switch (action) {
      case 'cards.list':
        listCalls++;
        if (listFails) {
          throw const DaemonClientException(
            kind: DaemonFailureKind.rpc,
            message: 'cards.list unavailable',
          );
        }
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'cards': cards, 'truncated': false},
        );
      case 'cards.get':
        final id = payload?['id'] as String? ?? '';
        getIds.add(id);
        final found = cards.where((card) => card['id'] == id);
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'card': found.isEmpty ? null : found.first},
        );
      default:
        return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    }
  }
}

Map<String, dynamic> _card(String id) => <String, dynamic>{
  'id': id,
  'name': 'Card $id',
};

Future<void> _pumpShell(
  WidgetTester tester,
  _CardClient client, {
  Directory? sceneStorageDirectory,
  SceneStorageDirectoryProvider? sceneStorageDirectoryProvider,
  SceneLibraryLoader? sceneLibraryLoader,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NavigationShell(
        client: client,
        sceneStorageDirectory: sceneStorageDirectory,
        sceneStorageDirectoryProvider: sceneStorageDirectoryProvider,
        sceneLibraryLoader:
            sceneLibraryLoader ?? ((store) => tester.runAsync(store.load)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _openStage(WidgetTester tester) async {
  await tester.tap(find.text('Stage'));
  await tester.pumpAndSettle();
}

Future<void> _leaveStage(WidgetTester tester) async {
  await tester.tap(find.text('Control'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-card-selection-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  testWidgets('no cards means no selected id and the no-model placeholder', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, isNull);
    expect(client.getIds, isEmpty);
    expect(find.text('No display model'), findsOneWidget);
    expect(find.text('No card'), findsOneWidget);
  });

  testWidgets('one imported card is selected and read through cards.get', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, 'card-1');
    expect(client.getIds, contains('card-1'));
  });

  testWidgets('returning to the tab refreshes the card list and selection', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);
    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).cardId,
      'card-1',
    );
    final callsAfterFirstVisit = client.listCalls;

    await _leaveStage(tester);
    client.cards = <Map<String, dynamic>>[_card('card-2')];
    await _openStage(tester);

    expect(client.listCalls, greaterThan(callsAfterFirstVisit));
    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, 'card-2');
    expect(client.getIds, contains('card-2'));
  });

  testWidgets('a cards.list failure keeps the placeholder and reports it', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')])
      ..listFails = true;
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, isNull);
    expect(find.textContaining('cards.list unavailable'), findsOneWidget);
    expect(find.text('No display model'), findsOneWidget);
  });

  testWidgets('the user can choose "No card" explicitly', (tester) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No card').last);
    await tester.pumpAndSettle();

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, isNull);
    expect(find.text('No display model'), findsOneWidget);
  });

  testWidgets('an explicit "No card" survives returning to the tab', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No card').last);
    await tester.pumpAndSettle();

    await _leaveStage(tester);
    client.cards = <Map<String, dynamic>>[_card('card-1'), _card('card-2')];
    await _openStage(tester);

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.cardId, isNull);
    expect(find.text('No display model'), findsOneWidget);
  });

  testWidgets('the stage pauses its ticker when the tab is hidden', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).paused,
      isFalse,
    );
    await _leaveStage(tester);
    final stageContext = tester.element(
      find.byType(StageScreen, skipOffstage: false),
    );
    expect(TickerMode.of(stageContext), isFalse);
  });

  testWidgets('the stage uses the active scene for the selected card', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);
    final store = StageSceneStore(storageDirectory: temp);
    final entry = await tester.runAsync(() => store.add(tint: '#123456'));
    await tester.runAsync(() => store.activate(entry!.id, cardId: 'card-1'));

    final loaded = Completer<void>();
    await _pumpShell(
      tester,
      client,
      sceneStorageDirectory: temp,
      sceneLibraryLoader: (store) async {
        await tester.runAsync(store.load);
        loaded.complete();
      },
    );
    await loaded.future;
    await tester.pump();
    await _openStage(tester);

    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).background?.tint,
      0xFF123456,
    );
  });

  testWidgets('daemon caption settings reach the stage', (tester) async {
    final client = _CardClient(<Map<String, dynamic>>[_card('card-1')]);
    addTearDown(client.dispose);
    client.onCall = (action, payload) {
      if (action == 'settings.get' && payload?['section'] == 'captions') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'settings': <String, dynamic>{
              'enabled': false,
              'fontSize': 150,
              'opacity': 20,
              'docking': 'top',
            },
          },
        );
      }
      final found = client.cards.where((card) => card['id'] == payload?['id']);
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'card': found.isEmpty ? null : found.first,
          'cards': client.cards,
        },
      );
    };

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);

    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(stage.captionStyle?.enabled, isFalse);
    expect(stage.captionStyle?.scale, 1.5);
    expect(stage.captionStyle?.alpha, closeTo(0.2, 1e-9));
    expect(stage.captionStyle?.docking, StageCaptionDocking.top);
    expect(find.byType(StageCaptionOverlay), findsNothing);
  });

  testWidgets('caption settings are refreshed when re-entering the stage', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    var captured = <String, dynamic>{'docking': 'bottom'};
    client.onCall = (action, payload) {
      if (action == 'settings.get' && payload?['section'] == 'captions') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'settings': captured},
        );
      }
      return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    };

    await _pumpShell(tester, client, sceneStorageDirectory: temp);
    await _openStage(tester);
    captured = <String, dynamic>{'docking': 'top', 'enabled': true};
    await _leaveStage(tester);
    await _openStage(tester);

    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).captionStyle?.docking,
      StageCaptionDocking.top,
    );
  });

  testWidgets('the scene library is loaded at startup', (tester) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    final payload = jsonEncode(<String, dynamic>{
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'bg-1',
          'kind': 'tint',
          'tint': 0xFF345678,
          'label': 'Tint',
        },
      ],
      'activeId': 'bg-1',
    });
    File('${temp.path}/scenes.json').writeAsStringSync(payload);

    final loaded = Completer<Object?>();
    await _pumpShell(
      tester,
      client,
      sceneStorageDirectory: temp,
      sceneLibraryLoader: (store) async {
        final pending = tester.runAsync(store.load);
        await pending;
        loaded.complete();
      },
    );
    await loaded.future;
    await tester.pump();
    await _openStage(tester);
    final stage = tester.widget<StageScreen>(find.byType(StageScreen));
    expect(
      stage.background,
      isA<StageBackground>()
          .having(
            (background) => background.kind,
            'kind',
            StageBackgroundKind.tint,
          )
          .having((background) => background.tint, 'tint', 0xFF345678),
    );
  });

  testWidgets('the scene library loads without a directory override', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    File('${temp.path}/scenes.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'bg-1',
            'kind': 'tint',
            'tint': 0xFF123456,
            'label': 'Tint',
          },
        ],
        'activeId': 'bg-1',
      }),
    );

    final loaded = Completer<void>();
    await _pumpShell(
      tester,
      client,
      sceneStorageDirectoryProvider: () async => temp,
      sceneLibraryLoader: (store) async {
        await tester.runAsync(store.load);
        loaded.complete();
      },
    );
    await loaded.future;
    await tester.pump();
    await _openStage(tester);

    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).background!.tint,
      0xFF123456,
    );
  });

  testWidgets('a scene lookup failure is surfaced in the stage', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavigationShell(
          client: client,
          sceneStorageDirectoryProvider: () async {
            throw const FileSystemException('no application support');
          },
          sceneLibraryLoader: (store) => tester.runAsync(store.load),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await _openStage(tester);

    expect(find.textContaining('no application support'), findsOneWidget);
  });

  testWidgets('a scene load failure is surfaced in the stage', (tester) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    final loaded = Completer<void>();
    await _pumpShell(
      tester,
      client,
      sceneStorageDirectory: temp,
      sceneLibraryLoader: (store) async {
        loaded.complete();
        throw const StageSceneException(
          'load-failed',
          'The scene library could not be read (FormatException).',
        );
      },
    );
    await loaded.future;
    await tester.pump();
    await _openStage(tester);

    expect(
      find.textContaining('The scene library could not be read'),
      findsOneWidget,
    );
  });

  testWidgets('changing the injected directory reloads the scene store', (
    tester,
  ) async {
    final client = _CardClient(<Map<String, dynamic>>[]);
    addTearDown(client.dispose);
    final other = Directory.systemTemp.createTempSync('stage-scenes-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    for (final entry in <MapEntry<Directory, int>>[
      MapEntry<Directory, int>(temp, 0xFF111111),
      MapEntry<Directory, int>(other, 0xFF222222),
    ]) {
      File('${entry.key.path}/scenes.json').writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'bg-1',
              'kind': 'tint',
              'tint': entry.value,
              'label': 'Tint',
            },
          ],
          'activeId': 'bg-1',
        }),
      );
    }

    final initialLoaded = Completer<void>();
    await _pumpShell(
      tester,
      client,
      sceneStorageDirectory: temp,
      sceneLibraryLoader: (store) async {
        await tester.runAsync(store.load);
        initialLoaded.complete();
      },
    );
    await initialLoaded.future;
    await tester.pump();
    await _openStage(tester);
    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).background!.tint,
      0xFF111111,
    );

    final switched = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavigationShell(
          client: client,
          sceneStorageDirectory: other,
          sceneLibraryLoader: (store) async {
            await tester.runAsync(store.load);
            switched.complete();
          },
        ),
      ),
    );
    await switched.future;
    await tester.pump();

    expect(
      tester.widget<StageScreen>(find.byType(StageScreen)).background!.tint,
      0xFF222222,
    );
  });
}
