// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('ChatScreen renders with a disconnected client', (tester) async {
    final client = DaemonClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('empty message_id still yields one assistant bubble per turn',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();

    client.emitEvent(tokenDelta(delta: 'Hel'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: 'lo'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await tester.pump();

    expect(find.byType(Card), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  });

  /// Pumps a screen, sends a turn, and replies with the daemon's camelCase
  /// `chat.send` ack (sessionId/messageId/accepted).
  Future<FakeChatClient> sentScreen(tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: action == 'chat.send'
              ? <String, dynamic>{
                  'sessionId': 's1',
                  'messageId': 'm-1',
                  'accepted': true,
                }
              : <String, dynamic>{},
        );
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    // Invoke the callback directly: a real tap loads the ink shader, which
    // cannot be decoded in this headless test environment.
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pump();
    return client;
  }

  testWidgets('chat.send camelCase ack ids reach chat.cancel', (tester) async {
    final client = await sentScreen(tester);

    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.stop)).onPressed!();
    await tester.pump();

    expect(client.cancelledSessions, <String>['s1']);
  });

  testWidgets('early chat.send ack does not kill the Stop button', (tester) async {
    final client = await sentScreen(tester);

    expect(find.byIcon(Icons.stop), findsOneWidget);
    client.emitEvent(tokenDelta(delta: 'Hel'));
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);

    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('a real reconnect keeps the active mid-turn bubble',
      (tester) async {
    final client = await sentScreen(tester);
    client.emitEvent(tokenDelta(delta: 'Hel'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: 'lo'));
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);

    // Status is re-emitted for unrelated updates while still connected: the
    // accumulated buffer must survive so the next token appends to it.
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    client.emitEvent(tokenDelta(delta: ' world'));
    await tester.pump();
    expect(find.text('Hello world'), findsOneWidget);

    // A genuine disconnect -> reconnect keeps the open turn; the daemon still streams the same message id.
    client.emitStatus(DaemonConnectionState.reconnecting);
    await tester.pump();
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    client.emitEvent(tokenDelta(delta: '!'));
    await tester.pump();
    expect(find.text('Hello world!'), findsOneWidget);
    expect(find.text('!'), findsNothing);
  });

  testWidgets('ChatScreen unregisters its event listener on dispose', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final actions = <String, Map<String, dynamic>?>{};
    client.onCall = (action, payload) {
      actions[action] = payload;
      return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    };
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    expect(client.listeners, hasLength(1));
    expect(actions['event.subscribe']?['topics'], <String>['emotion.tag']);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    expect(client.listeners, isEmpty);
    expect(actions['event.unsubscribe']?['topics'], <String>['emotion.tag']);

    // A later screen can subscribe without going deaf on a stale listener.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    expect(client.listeners, hasLength(1));
  });
}
