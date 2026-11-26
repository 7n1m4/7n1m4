// SPDX-License-Identifier: GPL-3.0-or-later

// ROOT CAUSE:
//
// ChatScreen treated every regained connection as "the in-flight turn is
// gone": the status listener cleared _activeMessageId and _deltaBuffer, so the
// first delta after a reconnect started a brand-new assistant bubble even
// though the daemon kept streaming the same message_id. A client that
// reconnects mid-turn (two windows on one session, a socket drop) ended up with
// duplicated assistant bubbles for one reply.
//
// FIXED BY: keeping the open turn across a reconnect and reconciling deltas by
// message_id, so a later delta with the same id appends to the existing bubble.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

final Finder _bubbles = find.byWidgetPredicate((widget) => widget is Card && widget.child is Padding);

/// A `token.delta` carrying the bus `seq` and per-turn `index` fields that
/// older fakes omit. These are the fields used to drop replayed frames.
GatewayEventFrame sequencedDelta({
  String messageId = 'm-1',
  required String delta,
  required int seq,
  required int index,
  bool isFinal = false,
}) {
  return GatewayEventFrame(
    topic: EventTopic.tokenDelta,
    rawTopic: 'token.delta',
    data: <String, dynamic>{
      'session_id': 's1',
      'message_id': messageId,
      'delta': delta,
      'seq': seq,
      'index': index,
      'final': isFinal,
    },
  );
}

void main() {
  /// A screen whose session is already streaming when the test starts, the way
  /// a second client of the same session looks after it reconnects.
  Future<FakeChatClient> streamingScreen(WidgetTester tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'sessionId': 's1',
            'messageId': 'm-1',
            'accepted': true,
          },
        );
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    return client;
  }

  testWidgets('a delta after reconnect appends to the open assistant bubble',
      (tester) async {
    final client = await streamingScreen(tester);

    client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
    await tester.pump();
    client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'lo'));
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);

    // The socket drops and comes back mid-turn.
    client.emitStatus(DaemonConnectionState.reconnecting);
    await tester.pump();
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsOneWidget);

    // Same message id: the open bubble is reused, not duplicated.
    client.emitEvent(tokenDelta(messageId: 'm-1', delta: ' world'));
    await tester.pump();

    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    client.emitEvent(tokenDelta(messageId: 'm-1', delta: '', isFinal: true));
    await tester.pump();
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('a new message id after reconnect still starts its own bubble',
      (tester) async {
    final client = await streamingScreen(tester);

    client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
    await tester.pump();
    client.emitEvent(tokenDelta(messageId: 'm-1', delta: '', isFinal: true));
    await tester.pump();

    client.emitStatus(DaemonConnectionState.reconnecting);
    await tester.pump();
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();

    client.emitEvent(tokenDelta(messageId: 'm-2', delta: 'Hi'));
    await tester.pump();

    expect(_bubbles, findsNWidgets(3));
    expect(find.text('Hel'), findsOneWidget);
    expect(find.text('Hi'), findsOneWidget);
  });

  testWidgets('stale/duplicate deltas do not double text and a replayed final cannot end a new turn',
      (tester) async {
    final client = await streamingScreen(tester);

    client.emitEvent(sequencedDelta(delta: 'Hel', seq: 10, index: 0));
    client.emitEvent(sequencedDelta(delta: 'Hel', seq: 10, index: 0)); // replay
    await tester.pump();
    expect(find.text('Hel'), findsOneWidget);

    client.emitEvent(sequencedDelta(delta: 'lo', seq: 11, index: 1));
    client.emitEvent(sequencedDelta(delta: 'lo', seq: 10, index: 1)); // stale
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Hel'), findsNothing);

    // Terminal frames carry index 0 even after higher token indices; the
    // higher seq still lets it finalize.
    client.emitEvent(sequencedDelta(delta: '', seq: 12, index: 0, isFinal: true));
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);

    // A new turn starts. Replaying the old final must not close it.
    client.emitEvent(
      sequencedDelta(messageId: 'm-2', delta: 'New', seq: 13, index: 0),
    );
    await tester.pump();
    expect(find.text('New'), findsOneWidget);

    client.emitEvent(sequencedDelta(delta: '', seq: 12, index: 0, isFinal: true));
    client.emitEvent(
      sequencedDelta(messageId: 'm-2', delta: ' answer', seq: 14, index: 1),
    );
    await tester.pump();
    expect(find.text('New answer'), findsOneWidget);
    expect(find.text('answer'), findsNothing);

    client.emitEvent(
      sequencedDelta(messageId: 'm-2', delta: '', seq: 15, index: 0, isFinal: true),
    );
    await tester.pump();
    expect(find.text('New answer'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });
}