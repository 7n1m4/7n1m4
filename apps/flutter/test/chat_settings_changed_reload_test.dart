// SPDX-License-Identifier: GPL-3.0-or-later

// Chat view state is a cache of daemon-owned sessions/cards/settings. These
// tests pin the refresh triggers: tab activation via ChatScreen.reload(), and
// settings.changed for the sections that actually feed this surface.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class _ChatRefreshClient extends FakeChatClient {
  final Map<String, int> counts = <String, int>{};
  final List<String> sectionReads = <String>[];
  final List<Completer<RpcReply>> deferredHistory = <Completer<RpcReply>>[];
  final List<Completer<RpcReply>> deferredSessions = <Completer<RpcReply>>[];
  List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[
    <String, dynamic>{'id': 'fresh', 'title': 'Fresh session'},
  ];

  int count(String action) => counts[action] ?? 0;
  int reads(String section) =>
      sectionReads.where((s) => s == section).length;

  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    sectionReads.add(section);
    return const <String, dynamic>{};
  }

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    counts[action] = count(action) + 1;
    if (action == 'chat.history' && deferredHistory.isNotEmpty) {
      return deferredHistory.removeAt(0).future;
    }
    if (action == 'sessions.list' && deferredSessions.isNotEmpty) {
      return deferredSessions.removeAt(0).future;
    }
    switch (action) {
      case 'sessions.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'sessions': sessions},
        );
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
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'user',
                'content': 'old message',
                'createdAt': 20,
                'rowId': 7,
              },
            ],
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

/// A history client whose `chat.history` replies (including their cursors) can
/// be swapped between reads, so a stale page can be held and completed after a
/// reload has already installed a newer transcript.
class _PagingRefreshClient extends _ChatRefreshClient {
  List<Map<String, dynamic>> page = const <Map<String, dynamic>>[];
  Object? nextCursor;
  bool truncated = false;
  final List<Object?> requestedCursors = <Object?>[];

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'chat.history') {
      counts[action] = count(action) + 1;
      requestedCursors.add(payload?['cursor']);
      if (deferredHistory.isNotEmpty) {
        return deferredHistory.removeAt(0).future;
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'messages': page,
          'truncated': truncated,
          if (nextCursor != null) 'cursor': nextCursor,
        },
      );
    }
    return super.call(action, payload: payload);
  }
}

/// A `chat.send` ack binds the daemon-created session id directly in the
/// composer, without a history read or a generation bump. This makes a session
/// switch observable while an older session's history reply is still in flight.
class _SendCreatesSessionClient extends _ChatRefreshClient {
  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'chat.send') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessionId': 's2',
          'messageId': 'm-new',
          'accepted': true,
        },
      );
    }
    return super.call(action, payload: payload);
  }
}

GatewayEventFrame _settingsChanged(String section) => GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': section},
    );

Future<void> _pumpChat(
  WidgetTester tester,
  _ChatRefreshClient client, {
  GlobalKey<ChatScreenState>? key,
  String? initialSessionId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          key: key,
          client: client,
          initialSessionId: initialSessionId,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('reload re-reads context and history', (tester) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    final key = GlobalKey<ChatScreenState>();
    await _pumpChat(tester, client, key: key, initialSessionId: 's1');

    final contextBefore = client.count('sessions.list');
    final historyBefore = client.count('chat.history');
    await key.currentState!.reload();
    await tester.pump();

    expect(client.count('sessions.list'), greaterThan(contextBefore));
    expect(client.count('chat.history'), greaterThan(historyBefore));
  });

  testWidgets('settings.changed reloads matching caches and ignores others', (
    tester,
  ) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    await _pumpChat(tester, client, initialSessionId: 's1');

    final contextBefore = client.count('sessions.list');
    final historyBefore = client.count('chat.history');
    final chatBefore = client.reads('chat');

    client.emitEvent(_settingsChanged('theme'));
    await tester.pump();
    expect(client.count('sessions.list'), contextBefore);
    expect(client.count('chat.history'), historyBefore);
    expect(client.reads('chat'), chatBefore);

    client.emitEvent(const GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': 42},
    ));
    await tester.pump();
    expect(client.count('sessions.list'), contextBefore);

    client.emitEvent(_settingsChanged('cards'));
    await tester.pump();
    expect(client.count('sessions.list'), greaterThan(contextBefore),
        reason: 'cards feed the character dropdown');

    client.emitEvent(_settingsChanged('chat'));
    await tester.pump();
    expect(client.reads('chat'), greaterThan(chatBefore),
        reason: 'the composer mirrors the chat section');

    client.emitEvent(_settingsChanged('chat-provider'));
    await tester.pump();
    expect(client.reads('chat-provider'), greaterThan(0));
  });

  testWidgets('an older context reply cannot overwrite a newer reload', (
    tester,
  ) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    final stale = Completer<RpcReply>();
    client.deferredSessions.add(stale);
    final key = GlobalKey<ChatScreenState>();
    await _pumpChat(tester, client, key: key);

    final reloading = key.currentState!.reload();
    await tester.pump();
    stale.complete(const RpcReply(
      action: 'sessions.list',
      ok: true,
      data: <String, dynamic>{
        'sessions': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'stale', 'title': 'Stale session'},
        ],
      },
    ));
    await reloading;
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    expect(find.text('Stale session'), findsNothing);
    expect(find.text('Fresh session'), findsOneWidget);
  });

  testWidgets('starting a new session invalidates an in-flight history read', (
    tester,
  ) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    final pending = Completer<RpcReply>();
    client.deferredHistory.add(pending);
    await _pumpChat(tester, client, initialSessionId: 'old');

    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-new-session')));
    await tester.pump();
    pending.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'old message',
            'createdAt': 20,
            'rowId': 7,
          },
        ],
        'truncated': false,
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('old message'), findsNothing);
  });

  testWidgets('reload while a turn streams does not replay history', (
    tester,
  ) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    final key = GlobalKey<ChatScreenState>();
    await _pumpChat(tester, client, key: key, initialSessionId: 'fresh');
    final historyReads = client.count('chat.history');

    client.emitEvent(tokenDelta(sessionId: 'fresh', delta: 'streaming now'));
    await tester.pump();

    await key.currentState!.reload();
    await tester.pump();

    expect(client.count('chat.history'), historyReads);
    expect(find.text('streaming now'), findsOneWidget);
  });

  testWidgets('a stale history reply after dispose cannot write again', (
    tester,
  ) async {
    final client = _ChatRefreshClient();
    addTearDown(client.dispose);
    final pending = Completer<RpcReply>();
    client.deferredHistory.add(pending);
    await _pumpChat(tester, client, initialSessionId: 's1');

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    pending.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[],
        'truncated': false,
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(client.listeners, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale older page after reload cannot replace the fresh transcript or cursor', (
    tester,
  ) async {
    final client = _PagingRefreshClient();
    addTearDown(client.dispose);
    final key = GlobalKey<ChatScreenState>();
    client.page = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': 'fresh newest',
        'createdAt': 30,
      },
    ];
    client.truncated = true;
    client.nextCursor = 2;
    await _pumpChat(tester, client, key: key, initialSessionId: 's1');
    await tester.pumpAndSettle();

    expect(find.text('fresh newest'), findsOneWidget);
    expect(find.byKey(const Key('chat-load-older-history')), findsOneWidget);

    // Start an older-page read with the current cursor, but hold its reply.
    final stalePage = Completer<RpcReply>();
    client.deferredHistory.add(stalePage);
    await tester.tap(find.byKey(const Key('chat-load-older-history')));
    await tester.pump();

    // A reload bumps the generation and installs a newer transcript/cursor.
    client.page = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'user',
        'content': 'reloaded newest',
        'createdAt': 40,
      },
    ];
    client.nextCursor = 4;
    final reloading = key.currentState!.reload();
    await tester.pump();
    await reloading;
    await tester.pumpAndSettle();

    expect(find.text('reloaded newest'), findsOneWidget);
    expect(find.text('fresh newest'), findsNothing);

    // The stale page finally lands; its text and cursor must be discarded.
    stalePage.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'STALE OLDER TEXT',
            'createdAt': 10,
          },
        ],
        'truncated': true,
        'cursor': 6,
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('STALE OLDER TEXT'), findsNothing);

    // Fresh cursor wins: the next older read carries 4.
    client.requestedCursors.clear();
    final nextPage = Completer<RpcReply>();
    client.deferredHistory.add(nextPage);
    await tester.tap(find.byKey(const Key('chat-load-older-history')));
    await tester.pump();
    expect(client.requestedCursors, contains(4));
    expect(client.requestedCursors, isNot(contains(6)));
    nextPage.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[],
        'truncated': false,
      },
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late history reply for the previous session cannot wipe a newly created transcript', (
    tester,
  ) async {
    final client = _SendCreatesSessionClient();
    addTearDown(client.dispose);
    final stale = Completer<RpcReply>();
    client.deferredHistory.add(stale);
    await _pumpChat(tester, client, initialSessionId: 's1');
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();

    // The ack binds s2 without a history read, so the generation is unchanged;
    // only the session half of _readStillCurrent can reject the s1 reply.
    await tester.enterText(find.byType(TextField), 'live message');
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pumpAndSettle();

    stale.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'STALE OLD MESSAGE',
            'createdAt': 20,
          },
        ],
        'truncated': false,
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('STALE OLD MESSAGE'), findsNothing);
    expect(find.text('live message'), findsOneWidget);
    expect(find.text('Session s2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
