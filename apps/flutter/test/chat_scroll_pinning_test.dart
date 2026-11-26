// SPDX-License-Identifier: GPL-3.0-or-later

// Prepending older history grows the content above the viewport. The chat
// transcript must compensate the scroll offset by exactly that growth so the
// rows under the user's eyes do not shift (history.vue loadMore:145-177).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class _PagingChatClient extends FakeChatClient {
  _PagingChatClient() {
    onCall = (action, payload) {
      switch (action) {
        case 'chat.history':
          if (payload?['cursor'] == 9) {
            return RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{
                'messages': <Map<String, dynamic>>[
                  for (var i = 0; i < 6; i++)
                    <String, dynamic>{
                      'role': 'user',
                      'content': 'older-$i',
                      'createdAt': 10 + i,
                    },
                ],
                'truncated': true,
                'cursor': 8,
              },
            );
          }
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'messages': <Map<String, dynamic>>[
                for (var i = 0; i < 12; i++)
                  <String, dynamic>{
                    'role': 'user',
                    'content': 'fresh-$i',
                    'createdAt': 100 + i,
                  },
              ],
              'truncated': true,
              'cursor': 9,
            },
          );
        case 'sessions.list':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'sessions': <Map<String, dynamic>>[],
            },
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
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{},
          );
      }
    };
  }
}

void main() {
  testWidgets('prepending older history keeps the viewport pinned to the same rows',
      (tester) async {
    final client = _PagingChatClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(client: client, initialSessionId: 's1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Capture the callback while the button is still built: ListView.builder
    // recycles off-screen children once we scroll to the middle.
    final loadOlder = tester
        .widget<TextButton>(find.byKey(const Key('chat-load-older-history')))
        .onPressed;
    expect(loadOlder, isNotNull);

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0),
        reason: 'the initial page must be tall enough to scroll');

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pump();
    final oldOffset = controller.offset;
    final oldExtent = controller.position.maxScrollExtent;
    expect(oldOffset, greaterThan(0));

    loadOlder!();
    await tester.pumpAndSettle();

    final delta = controller.position.maxScrollExtent - oldExtent;
    expect(delta, greaterThan(0), reason: 'older turns were prepended');
    expect(controller.offset, closeTo(oldOffset + delta, 1.0),
        reason: 'the viewport shifts by the prepended height, not back to top');

    // ListView.builder recycles off-screen rows; visit both ends to prove the
    // prepended page and the original page are both still in the transcript.
    controller.jumpTo(0);
    await tester.pump();
    expect(find.text('older-0'), findsOneWidget);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('fresh-11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
