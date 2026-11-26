// SPDX-License-Identifier: GPL-3.0-or-later

// History bubbles carry the daemon's createdAt (ms epoch) as a subtle,
// localized hour/minute label. Live/streamed bubbles stay timestamp-free.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class _TimestampClient extends FakeChatClient {
  List<Map<String, dynamic>> turns = const <Map<String, dynamic>>[];

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    switch (action) {
      case 'chat.history':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'messages': turns, 'truncated': false},
        );
      case 'sessions.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'sessions': <Map<String, dynamic>>[]},
        );
      case 'cards.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'cards': <Map<String, dynamic>>[],
            'truncated': false,
          },
        );
      default:
        return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    }
  }
}

Future<void> _pumpChat(WidgetTester tester, _TimestampClient client) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en', 'US'),
      home: Scaffold(body: ChatScreen(client: client, initialSessionId: 's1')),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('history timestamps render only for turns with createdAt', (
    tester,
  ) async {
    final createdMs = DateTime(2024, 3, 15, 15, 5).millisecondsSinceEpoch;
    final expected = DateFormat.jm('en_US').format(
      DateTime.fromMillisecondsSinceEpoch(createdMs),
    );
    final client = _TimestampClient()
      ..turns = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': 'timestamped reply',
          'createdAt': createdMs,
        },
        <String, dynamic>{
          'role': 'user',
          'content': 'plain reply',
        },
      ];
    addTearDown(client.dispose);
    await _pumpChat(tester, client);

    expect(find.text('timestamped reply'), findsOneWidget);
    expect(find.text('plain reply'), findsOneWidget);

    final stamped = find.byKey(const Key('chat-timestamp-0'));
    expect(stamped, findsOneWidget);
    expect(tester.widget<Text>(stamped).data, expected);
    // The turn without createdAt renders no timestamp at all.
    expect(find.byKey(const Key('chat-timestamp-1')), findsNothing);
  });

  // Empty content skips the GenUI parser, which does not settle under the
  // widget-test fake async; it isolates the assistant branch of
  // _messageFromHistory, which must carry createdAt just like user turns.
  testWidgets('assistant history turns carry createdAt too', (tester) async {
    final createdMs = DateTime(2024, 3, 15, 9, 7).millisecondsSinceEpoch;
    final expected = DateFormat.jm('en_US').format(
      DateTime.fromMillisecondsSinceEpoch(createdMs),
    );
    final client = _TimestampClient()
      ..turns = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'assistant',
          'content': '',
          'createdAt': createdMs,
        },
      ];
    addTearDown(client.dispose);
    await _pumpChat(tester, client);

    final stamped = find.byKey(const Key('chat-timestamp-0'));
    expect(stamped, findsOneWidget);
    expect(tester.widget<Text>(stamped).data, expected);
  });
}
