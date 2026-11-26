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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

final Finder _bubbles = find.byWidgetPredicate(
  (widget) => widget is Card && widget.child is Padding,
);

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

/// A client that holds `chat.history` open so events can be delivered mid-read.
class DeferredHistoryClient extends FakeChatClient {
  final Completer<RpcReply> pendingHistory = Completer<RpcReply>();

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'chat.history') return pendingHistory.future;
    return super.call(action, payload: payload);
  }
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
      MaterialApp(
        home: Scaffold(body: ChatScreen(client: client)),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    return client;
  }

  /// Answer the RPCs a reconnect issues: the send ack, the context settings
  /// FakeChatClient.settingsGet reads, and the supplied chat.history page.
  void installHistoryReply(FakeChatClient client, RpcReply historyReply) {
    client.onCall = (action, payload) => switch (action) {
      'chat.send' => RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessionId': 's1',
          'messageId': 'm-1',
          'accepted': true,
        },
      ),
      'chat.history' => historyReply,
      'settings.get' => RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'settings': <String, dynamic>{}},
      ),
      _ => RpcReply(action: action, ok: true, data: <String, dynamic>{}),
    };
  }

  RpcReply historyReply({
    required List<Map<String, dynamic>> messages,
    bool ok = true,
  }) => RpcReply(
    action: 'chat.history',
    ok: ok,
    data: <String, dynamic>{'messages': messages, 'truncated': false},
    error: ok
        ? null
        : const RpcError(code: 'history', message: 'history unavailable'),
  );

  testWidgets(
    'a lost final delta is reconciled from chat.history on reconnect',
    (tester) async {
      final client = await streamingScreen(tester);

      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'lo'));
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsOneWidget);

      // The socket drops before the terminal frame. The daemon persisted the
      // completed turn, but the client never saw the final delta.
      installHistoryReply(
        client,
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'role': 'assistant',
              'content': 'Hello world',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );

      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Hello'), findsNothing);
      expect(_bubbles, findsNWidgets(2));
    },
  );

  testWidgets(
    'reconnect leaves a live turn open when history cannot confirm it',
    (tester) async {
      final client = await streamingScreen(tester);

      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'lo'));
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);

      // A failed history read must not close a genuinely live turn.
      installHistoryReply(client, historyReply(messages: const [], ok: false));
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);

      // Neither must a history page with no completed assistant turn.
      installHistoryReply(
        client,
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
          ],
        ),
      );
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
    },
  );

  testWidgets('a delta after reconnect appends to the open assistant bubble', (
    tester,
  ) async {
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

  testWidgets('a new message id after reconnect still starts its own bubble', (
    tester,
  ) async {
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

  testWidgets(
    'stale/duplicate deltas do not double text and a replayed final cannot end a new turn',
    (tester) async {
      final client = await streamingScreen(tester);

      client.emitEvent(sequencedDelta(delta: 'Hel', seq: 10, index: 0));
      client.emitEvent(
        sequencedDelta(delta: 'Hel', seq: 10, index: 0),
      ); // replay
      await tester.pump();
      expect(find.text('Hel'), findsOneWidget);

      client.emitEvent(sequencedDelta(delta: 'lo', seq: 11, index: 1));
      client.emitEvent(sequencedDelta(delta: 'lo', seq: 10, index: 1)); // stale
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Hel'), findsNothing);

      // Terminal frames carry index 0 even after higher token indices; the
      // higher seq still lets it finalize.
      client.emitEvent(
        sequencedDelta(delta: '', seq: 12, index: 0, isFinal: true),
      );
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);

      // A new turn starts. Replaying the old final must not close it.
      client.emitEvent(
        sequencedDelta(messageId: 'm-2', delta: 'New', seq: 13, index: 0),
      );
      await tester.pump();
      expect(find.text('New'), findsOneWidget);

      client.emitEvent(
        sequencedDelta(delta: '', seq: 12, index: 0, isFinal: true),
      );
      client.emitEvent(
        sequencedDelta(messageId: 'm-2', delta: ' answer', seq: 14, index: 1),
      );
      await tester.pump();
      expect(find.text('New answer'), findsOneWidget);
      expect(find.text('answer'), findsNothing);

      client.emitEvent(
        sequencedDelta(
          messageId: 'm-2',
          delta: '',
          seq: 15,
          index: 0,
          isFinal: true,
        ),
      );
      await tester.pump();
      expect(find.text('New answer'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  testWidgets(
    'a prior identical user turn cannot close the live turn on reconnect',
    (tester) async {
      final client = await streamingScreen(tester);

      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      expect(find.text('Hel'), findsOneWidget);

      // Newest page: old identical user turn + its answer, then this turn's
      // user row with no persisted answer after it yet.
      installHistoryReply(
        client,
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'id': 'm-old',
              'role': 'assistant',
              'content': 'old answer',
              'createdAt': 1700000001000,
            },
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000002000,
            },
          ],
        ),
      );
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.text('Hel'), findsOneWidget);
      expect(find.text('old answer'), findsNothing);

      // The live turn still completes normally.
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'lo'));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: '', isFinal: true));
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  testWidgets(
    'a replayed terminal during the history read cannot duplicate the turn',
    (tester) async {
      final client = DeferredHistoryClient();
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
        MaterialApp(
          home: Scaffold(body: ChatScreen(client: client)),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
      await tester.pump();

      // No delta arrived before the drop; history is still in flight.
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();

      // Replayed terminal opens and closes its own bubble mid-read.
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: '', isFinal: true));
      await tester.pump();

      client.pendingHistory.complete(
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'id': 'm-1',
              'role': 'assistant',
              'content': 'Hello world',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);
    },
  );

  testWidgets(
    'a replayed terminal after reconciliation cannot open a second bubble',
    (tester) async {
      final client = await streamingScreen(tester);
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'lo'));
      await tester.pump();

      installHistoryReply(
        client,
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'id': 'm-1',
              'role': 'assistant',
              'content': 'Hello world',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pumpAndSettle();
      expect(find.text('Hello world'), findsOneWidget);
      expect(_bubbles, findsNWidgets(2));

      client.emitEvent(
        tokenDelta(messageId: 'm-1', delta: ' world', isFinal: true),
      );
      await tester.pump();
      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  testWidgets(
    'a late history reply cannot erase a turn started while it was in flight',
    (tester) async {
      final client = DeferredHistoryClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) => switch (action) {
        'settings.get' => RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'settings': <String, dynamic>{}},
        ),
        _ => RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'sessionId': 's1',
            'messageId': 'm-1',
            'accepted': true,
          },
        ),
      };
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(client: client, initialSessionId: 's1'),
          ),
        ),
      );
      await tester.pump();

      // initState's reload is still awaiting chat.history; send mid-read.
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Live'));
      await tester.pump();

      client.pendingHistory.complete(
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'old',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'role': 'assistant',
              'content': 'old answer',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Live'), findsOneWidget);
      expect(find.text('old answer'), findsNothing);
      expect(_bubbles, findsNWidgets(2));
    },
  );

  testWidgets(
    'the history row id alone suppresses a replay after an ack-only reconnect',
    (tester) async {
      final client = await streamingScreen(tester);
      // No delta before the drop: _activeMessageId is null and the ack id is
      // m-1, so only the history row id h-2 can key this turn.
      expect(find.byIcon(Icons.stop), findsOneWidget);

      installHistoryReply(
        client,
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'id': 'h-2',
              'role': 'assistant',
              'content': 'Hello world',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );
      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pumpAndSettle();

      expect(find.text('Hello world'), findsOneWidget);
      expect(_bubbles, findsNWidgets(2));

      client.emitEvent(tokenDelta(messageId: 'h-2', delta: ' world'));
      await tester.pump();
      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);

      client.emitEvent(tokenDelta(messageId: 'h-2', delta: '', isFinal: true));
      await tester.pump();
      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  testWidgets(
    'a terminal replay during the read fills the partial bubble with full text',
    (tester) async {
      final client = DeferredHistoryClient();
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
        MaterialApp(
          home: Scaffold(body: ChatScreen(client: client)),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
      await tester.pump();
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: 'Hel'));
      await tester.pump();
      expect(find.text('Hel'), findsOneWidget);

      client.emitStatus(DaemonConnectionState.reconnecting);
      await tester.pump();
      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();

      // Only the terminal was lost/replayed; the partial bubble stays open.
      client.emitEvent(tokenDelta(messageId: 'm-1', delta: '', isFinal: true));
      await tester.pump();
      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hel'), findsOneWidget);

      client.pendingHistory.complete(
        historyReply(
          messages: <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'hi',
              'createdAt': 1700000000000,
            },
            <String, dynamic>{
              'id': 'm-1',
              'role': 'assistant',
              'content': 'Hello world',
              'createdAt': 1700000001000,
            },
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(_bubbles, findsNWidgets(2));
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Hel'), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );
}
