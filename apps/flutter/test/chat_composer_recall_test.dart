// SPDX-License-Identifier: GPL-3.0-or-later

// View-local ArrowUp/ArrowDown recall of sent composer text. No RPC, no
// persisted key: the history lives in ChatComposerController and is cleared on
// dispose.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_composer_controller.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

FakeChatClient _client({bool sendOk = true}) {
  final client = FakeChatClient();
  client.emitStatus(DaemonConnectionState.connected);
  client.onCall = (action, payload) {
    if (action == 'chat.send') {
      return sendOk
          ? RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{
                'sessionId': 's1',
                'messageId': 'm-1',
              },
            )
          : RpcReply(
              action: action,
              ok: false,
              error: const RpcError(code: 'internal', message: 'boom'),
            );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  };
  return client;
}

Future<ChatComposerController> _controllerWithHistory(
  FakeChatClient client,
  List<String> texts,
) async {
  final controller = ChatComposerController(client: client);
  for (final text in texts) {
    controller.input.text = text;
    await controller.handleSend();
    controller.finishTurn();
  }
  return controller;
}

void main() {
  test('up from -1 recalls the newest text, down walks forward then clears',
      () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller =
        await _controllerWithHistory(client, ['first', 'second', 'third']);
    addTearDown(controller.dispose);

    expect(controller.input.text, isEmpty);
    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'third');
    expect(controller.input.selection.baseOffset, 'third'.length);

    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'second');
    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'first');

    // Already at the oldest entry.
    expect(controller.recallPrevious(), isFalse);
    expect(controller.input.text, 'first');

    expect(controller.recallNext(), isTrue);
    expect(controller.input.text, 'second');
    expect(controller.recallNext(), isTrue);
    expect(controller.input.text, 'third');

    // Past the newest: clear the draft and reset the index.
    expect(controller.recallNext(), isTrue);
    expect(controller.input.text, isEmpty);
    expect(controller.input.selection.baseOffset, 0);
    expect(controller.recallNext(), isFalse);

    // Reset means the next ArrowUp starts from the newest again.
    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'third');
  });

  test('history is bounded to the newest 50 sends', () async {
    final client = _client();
    addTearDown(client.dispose);
    final texts = List<String>.generate(52, (i) => 'm$i');
    final controller = await _controllerWithHistory(client, texts);
    addTearDown(controller.dispose);

    for (var i = 0; i < 50; i++) {
      expect(controller.recallPrevious(), isTrue);
    }
    expect(controller.input.text, 'm2');
    expect(controller.recallPrevious(), isFalse);
  });

  test('consecutive identical sends are deduped', () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller = await _controllerWithHistory(client, ['same', 'same']);
    addTearDown(controller.dispose);

    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'same');
    expect(controller.recallPrevious(), isFalse);
  });

  test('a repeated send after recall resets the recall index', () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller = await _controllerWithHistory(client, ['same', 'other']);
    addTearDown(controller.dispose);

    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'other');
    controller.input.text = 'same';
    await controller.handleSend();
    controller.finishTurn();

    // The send deduped, but recall must still start at the newest entry.
    expect(controller.recallPrevious(), isTrue);
    expect(controller.input.text, 'same');
  });

  test('empty history is a no-op', () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller = ChatComposerController(client: client);
    addTearDown(controller.dispose);

    expect(controller.recallPrevious(), isFalse);
    expect(controller.recallNext(), isFalse);
    expect(controller.input.text, isEmpty);
  });

  test('a failed send does not append to recall history', () async {
    final client = _client(sendOk: false);
    addTearDown(client.dispose);
    final controller = ChatComposerController(client: client);
    addTearDown(controller.dispose);

    controller.input.text = 'bad';
    expect(await controller.handleSend(), isNull);
    expect(controller.input.text, 'bad');
    expect(controller.error, 'boom');
    expect(controller.recallPrevious(), isFalse);
  });

  test('a malformed success reply restores the draft and recall state', () async {
    final client = _client();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: 'not-an-object',
        );
    final controller = ChatComposerController(client: client);
    addTearDown(controller.dispose);

    controller.input.text = 'bad';
    expect(await controller.handleSend(), isNull);
    expect(controller.input.text, 'bad');
    expect(controller.error, 'Malformed chat.send reply.');
    expect(controller.recallPrevious(), isFalse);
  });

  test('an RPC exception does not append to recall history', () async {
    final client = _client();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => throw StateError('transport');
    final controller = ChatComposerController(client: client);
    addTearDown(controller.dispose);

    controller.input.text = 'bad';
    expect(await controller.handleSend(), isNull);
    expect(controller.input.text, 'bad');
    expect(controller.recallPrevious(), isFalse);
  });

  testWidgets('ArrowUp/ArrowDown in the focused composer recall sent text',
      (tester) async {
    final client = _client();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    TextEditingController input() =>
        tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(input().text, isEmpty);

    // The early ack keeps the composer locked until a terminal delta arrives.
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(input().text, 'hello');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(input().text, isEmpty);
  });
}
