// SPDX-License-Identifier: GPL-3.0-or-later

// Sticky-bottom autoscroll: an appended message or a finished turn follows the
// viewport to the bottom only when the user was pinned there when it began.
// A viewport scrolled into history must keep its position.

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

/// A tall transcript so the viewport has room to be pinned or unpinned.
class _TallHistoryChatClient extends FakeChatClient {
  _TallHistoryChatClient() {
    onCall = (action, payload) {
      switch (action) {
        case 'chat.history':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'messages': <Map<String, dynamic>>[
                for (var i = 0; i < 16; i++)
                  <String, dynamic>{
                    'role': 'user',
                    'content': 'row-$i',
                    'createdAt': 100 + i,
                  },
              ],
              'truncated': false,
            },
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
    };
  }
}

Future<ScrollController> _pumpScreen(
  WidgetTester tester,
  FakeChatClient client,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatScreen(client: client, initialSessionId: 's1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final controller = tester.widget<ListView>(find.byType(ListView)).controller!;
  expect(
    controller.position.maxScrollExtent,
    greaterThan(0),
    reason: 'the initial transcript must be tall enough to scroll',
  );
  return controller;
}

void main() {
  testWidgets('pinned viewport follows a new streamed bubble to the bottom', (
    tester,
  ) async {
    final client = _TallHistoryChatClient();
    addTearDown(client.dispose);
    final controller = await _pumpScreen(tester, client);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 1.0),
    );

    client.emitEvent(tokenDelta(delta: 'new reply'));
    await tester.pumpAndSettle();

    expect(find.text('new reply'), findsOneWidget);
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent, 1.0),
      reason: 'a pinned viewport must follow the appended bubble',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unpinned viewport stays put when a bubble is appended', (
    tester,
  ) async {
    final client = _TallHistoryChatClient();
    addTearDown(client.dispose);
    final controller = await _pumpScreen(tester, client);

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pump();
    final oldOffset = controller.offset;
    expect(oldOffset, greaterThan(0));

    client.emitEvent(tokenDelta(delta: 'new reply'));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      closeTo(oldOffset, 1.0),
      reason: 'an unpinned viewport must not be dragged down',
    );

    // The new bubble is off-screen while unpinned; visit the bottom to prove
    // the append really happened before the offset assertion above.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('new reply'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a scroll before the post-frame callback cancels the follow', (
    tester,
  ) async {
    final client = _TallHistoryChatClient();
    addTearDown(client.dispose);
    final controller = await _pumpScreen(tester, client);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();

    // The append captures a pinned snapshot, then the user scrolls away
    // before the post-frame callback runs. The listener has cleared the flag.
    client.emitEvent(tokenDelta(delta: 'new reply'));
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      closeTo(0.0, 1.0),
      reason: 'an interleaved scroll must cancel the captured pin',
    );

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(
      find.text('new reply'),
      findsOneWidget,
      reason: 'the append still happened',
    );
    expect(tester.takeException(), isNull);
  });
}
