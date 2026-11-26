// SPDX-License-Identifier: GPL-3.0-or-later

// Tab activation and settings.changed are refresh triggers, not state writers:
// the daemon stays authoritative. These tests observe the reads behind the
// stage caches and the caption style the shell hands to StageScreen.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/l10n/app_localizations.dart';
import 'package:anima_control/navigation/navigation_shell.dart';

import 'support/fakes.dart';

class _RefreshClient extends FakeChatClient {
  final Map<String, int> counts = <String, int>{};
  final List<String> sectionReads = <String>[];
  Map<String, dynamic> captions = <String, dynamic>{'docking': 'none'};
  Completer<RpcReply>? deferredCaptions;

  int count(String action) => counts[action] ?? 0;
  int captionReads() => sectionReads.where((s) => s == 'captions').length;

  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    sectionReads.add(section);
    final deferred = section == 'captions' ? deferredCaptions : null;
    if (deferred != null) {
      final reply = await deferred.future;
      final data = reply.data;
      return data is Map<String, dynamic> && data['settings'] is Map
          ? Map<String, dynamic>.from(data['settings'] as Map)
          : <String, dynamic>{};
    }
    return section == 'captions' ? captions : const <String, dynamic>{};
  }

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    counts[action] = count(action) + 1;
    switch (action) {
      case 'cards.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'cards': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
            ],
            'truncated': false,
          },
        );
      case 'cards.get':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'card': null},
        );
      case 'sessions.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'sessions': <Map<String, dynamic>>[
              <String, dynamic>{'id': 's1', 'title': 'First session'},
            ],
          },
        );
      case 'cards.metadata':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'id': payload?['id'],
            'liked': false,
            'bookmarked': false,
          },
        );
      case 'chat.history':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'messages': <Map<String, dynamic>>[],
            'truncated': false,
          },
        );
      default:
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{},
        );
    }
  }
}

GatewayEventFrame _settingsChanged(String section) => GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': section},
    );

Future<void> _pumpShell(WidgetTester tester, _RefreshClient client) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NavigationShell(
        client: client,
        sceneStorageDirectory: Directory.current,
        sceneLibraryLoader: (store) async {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _tapDestination(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('activating the chat tab reloads chat context and stage caches', (
    tester,
  ) async {
    final client = _RefreshClient();
    addTearDown(client.dispose);
    await _pumpShell(tester, client);

    final sessionsBefore = client.count('sessions.list');
    final cardsBefore = client.count('cards.list');
    final captionsBefore = client.captionReads();

    await _tapDestination(tester, 'Chat');

    expect(client.count('sessions.list'), greaterThan(sessionsBefore),
        reason: 'chat context is re-read on activation');
    expect(client.count('cards.list'), greaterThan(cardsBefore),
        reason: 'the shell refreshes its card cache on chat activation');
    expect(client.captionReads(), greaterThan(captionsBefore),
        reason: 'the shell refreshes caption settings on chat activation');
  });

  testWidgets('settings.changed reloads only the caches its section feeds', (
    tester,
  ) async {
    final client = _RefreshClient();
    addTearDown(client.dispose);
    await _pumpShell(tester, client);
    await _tapDestination(tester, 'Stage');

    final cardsBefore = client.count('cards.list');
    final sessionsBefore = client.count('sessions.list');
    StageCaptionStyle style() => tester
        .widget<StageScreen>(find.byType(StageScreen))
        .captionStyle!;
    final initialDocking = style().docking;

    client.emitEvent(_settingsChanged('theme'));
    await tester.pumpAndSettle();
    expect(client.count('cards.list'), cardsBefore);
    expect(client.count('sessions.list'), sessionsBefore);
    expect(style().docking, initialDocking,
        reason: 'an unrelated section never rewrites the stage style');

    client.emitEvent(_settingsChanged('cards'));
    await tester.pumpAndSettle();
    expect(client.count('cards.list'), greaterThan(cardsBefore));

    client.captions = <String, dynamic>{'docking': 'top', 'enabled': true};
    client.emitEvent(_settingsChanged('captions'));
    await tester.pumpAndSettle();
    expect(style().docking, StageCaptionDocking.top);

    client.emitEvent(const GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': 42},
    ));
    await tester.pumpAndSettle();
    expect(style().docking, StageCaptionDocking.top);
  });

  testWidgets('a stale caption reply after dispose cannot write again', (
    tester,
  ) async {
    final client = _RefreshClient();
    addTearDown(client.dispose);
    final pending = Completer<RpcReply>();
    client.deferredCaptions = pending;

    await _pumpShell(tester, client);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    pending.complete(const RpcReply(
      action: 'settings.get',
      ok: true,
      data: <String, dynamic>{
        'settings': <String, dynamic>{'docking': 'top'},
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(tester.takeException(), isNull);
  });
}
