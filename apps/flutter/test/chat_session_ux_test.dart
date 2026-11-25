// SPDX-License-Identifier: GPL-3.0-or-later

// Chat session/character parity: the chat surface lists persisted sessions,
// starts a new (client-view-only) chat, opens a session through chat.history,
// and exposes the character context from cards.list. No state is written by
// the client: starting a new chat only clears the local transcript until the
// daemon assigns a session id on the next chat.send.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class _ChatContextClient extends FakeChatClient {
  final List<String> actions = <String>[];
  final List<String> openedSessions = <String>[];
  bool contextFails = false;
  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    actions.add(action);
    if (contextFails) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: 'context unavailable',
      );
    }
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 's1', 'title': 'First session'},
            <String, dynamic>{'id': 's2', 'title': 'Second session'},
          ],
        },
      );
    }
    if (action == 'cards.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'cards': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
          ],
        },
      );
    }
    if (action == 'settings.get') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'settings': <String, dynamic>{'sendMode': 'enter'},
        },
      );
    }
    if (action == 'chat.history') {
      openedSessions.add((payload?['session_id'] as String?) ?? '');
      return RpcReply(
        action: action,
        ok: true,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'old message'},
        ],
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_ChatContextClient> _pump(tester, {String? initialSessionId}) async {
  final client = _ChatContextClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatScreen(client: client, initialSessionId: initialSessionId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  testWidgets('chat loads session and character context from the daemon', (
    tester,
  ) async {
    final client = await _pump(tester);

    expect(client.actions, contains('sessions.list'));
    expect(client.actions, contains('cards.list'));
    expect(find.byKey(const Key('chat-sessions-button')), findsOneWidget);
    expect(find.byKey(const Key('chat-character-dropdown')), findsOneWidget);
  });

  testWidgets('session panel starts a new chat without deleting daemon state',
      (tester) async {
    final client = await _pump(tester, initialSessionId: 's1');
    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-new-session')));
    await tester.pump();

    expect(client.actions, isNot(contains('sessions.delete')));
    expect(find.textContaining('Session s1'), findsNothing);
    expect(find.text('New chat'), findsWidgets);
  });

  testWidgets('opening a session replays its history via chat.history', (
    tester,
  ) async {
    final client = await _pump(tester);
    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(ListTile, 'First session'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'First session'));
    await tester.pump();
    await tester.pump();

    expect(client.openedSessions, contains('s1'));
    expect(find.text('old message'), findsOneWidget);
  });

  testWidgets('loaded cards remain visible when later context refresh fails', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.contextFails = true;
    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-new-session')));
    await tester.pump();
    // No cards list was injected, so the dropdown has no fabricated entries.
    expect(
      tester
          .widget<DropdownButton<String?>>(
            find.byKey(const Key('chat-character-dropdown')),
          )
          .items!
          .length,
      2,
    );
  });

  testWidgets('chat exposes session panel with manage-sessions action', (tester) async {
    await _pump(tester, initialSessionId: 's1');
    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pump();
    expect(find.byKey(const Key('chat-new-session')), findsOneWidget);
  });
}
