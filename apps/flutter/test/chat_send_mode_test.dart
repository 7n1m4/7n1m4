// SPDX-License-Identifier: GPL-3.0-or-later

// Send-mode parity with `basic-text-area.vue`: which Enter keystroke commits a
// turn is daemon-owned. Flutter reads settings/chat/send-mode and never writes
// it back. The 350 ms double-Enter window uses an injected clock so the
// boundary is asserted exactly (349 ms sends, 351 ms does not).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_composer_controller.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

FakeChatClient _client(
  String mode,
  List<String> sends, {
  List<String> writes = const <String>[],
}) {
  final client = FakeChatClient();
  client.emitStatus(DaemonConnectionState.connected);
  client.onCall = (action, payload) {
    if (action == 'settings.get') {
      final settings = payload?['section'] == 'chat'
          ? <String, dynamic>{'sendMode': mode}
          : <String, dynamic>{};
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'settings': settings},
      );
    }
    if (action == 'chat.send') {
      sends.add((payload?['content'] as String?) ?? '');
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'},
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  };
  client.onSet = (section, settings) => writes.add(section);
  return client;
}

class _FakeClock {
  DateTime current = DateTime(2025, 1, 1);

  DateTime now() => current;

  void advance(Duration by) => current = current.add(by);
}

Future<TextEditingController> _pump(
  WidgetTester tester,
  FakeChatClient client, {
  DateTime Function()? now,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ChatScreen(client: client, now: now))),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(TextField));
  await tester.pump();
  return tester.widget<TextField>(find.byType(TextField)).controller!;
}

Future<void> _enter(
  WidgetTester tester, {
  Set<LogicalKeyboardKey> modifiers = const <LogicalKeyboardKey>{},
}) async {
  for (final key in modifiers) {
    await tester.sendKeyDownEvent(key);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  for (final key in modifiers) {
    await tester.sendKeyUpEvent(key);
  }
  await tester.pumpAndSettle();
}

void main() {
  test('sendMode reads the daemon verb and falls back to enter', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final controller = ChatComposerController(client: client);
    addTearDown(controller.dispose);

    expect(controller.sendMode, 'enter');
    for (final mode in ChatComposerController.validSendModes) {
      client.settingsToLoad = <String, dynamic>{'sendMode': mode};
      await controller.loadContextSettings();
      expect(controller.sendMode, mode);
    }
    for (final invalid in <Object?>['nonsense', 42, null]) {
      client.settingsToLoad = <String, dynamic>{'sendMode': invalid};
      await controller.loadContextSettings();
      expect(controller.sendMode, 'enter');
    }
  });

  testWidgets('enter mode: plain Enter sends, Ctrl+Enter does not', (tester) async {
    final sends = <String>[];
    final client = _client('enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, isNull);
    input.text = 'hello';

    await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.controlLeft});
    expect(sends, isEmpty);
    await _enter(tester);
    expect(sends, <String>['hello']);
  });

  testWidgets('ctrl-enter mode: Ctrl/Cmd+Enter sends, plain Enter does not',
      (tester) async {
    final sends = <String>[];
    final client = _client('ctrl-enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    input.text = 'hello';

    await _enter(tester);
    expect(sends, isEmpty);
    await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.metaLeft});
    expect(sends, <String>['hello']);
  });

  testWidgets('ctrl-enter mode: Ctrl+Enter sends too', (tester) async {
    final sends = <String>[];
    final client = _client('ctrl-enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    input.text = 'hello';

    await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.controlLeft});
    expect(sends, <String>['hello']);
  });

  testWidgets('double-enter mode: two plain Enters within 350ms send',
      (tester) async {
    final sends = <String>[];
    final client = _client('double-enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    input.text = 'hello';

    await _enter(tester);
    expect(sends, isEmpty);
    await _enter(tester);
    expect(sends, <String>['hello']);
  });

  testWidgets('double-enter mode: an Enter at 349ms sends', (tester) async {
    final sends = <String>[];
    final client = _client('double-enter', sends);
    addTearDown(client.dispose);
    final clock = _FakeClock();
    final input = await _pump(tester, client, now: clock.now);
    input.text = 'hello';

    await _enter(tester);
    clock.advance(const Duration(milliseconds: 349));
    await _enter(tester);
    expect(sends, <String>['hello']);
  });

  testWidgets('double-enter mode: an Enter at 351ms does not send',
      (tester) async {
    final sends = <String>[];
    final client = _client('double-enter', sends);
    addTearDown(client.dispose);
    final clock = _FakeClock();
    final input = await _pump(tester, client, now: clock.now);
    input.text = 'hello';

    await _enter(tester);
    clock.advance(const Duration(milliseconds: 351));
    await _enter(tester);
    expect(sends, isEmpty);
  });

  testWidgets('a button send clears a pending double-Enter window',
      (tester) async {
    final sends = <String>[];
    final client = _client('double-enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);

    input.text = 'first';
    await _enter(tester);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();
    input.text = 'second';
    await _enter(tester);

    expect(sends, <String>['first']);
  });

  testWidgets('an IME confirmation Enter does not send', (tester) async {
    final sends = <String>[];
    final client = _client('enter', sends);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    input.value = input.value.copyWith(
      text: 'draft',
      composing: const TextRange(start: 0, end: 5),
      selection: const TextSelection.collapsed(offset: 5),
    );
    await tester.pump();

    await _enter(tester);
    expect(sends, isEmpty);
    // Newline insertion is delegated to the editing shortcuts; widget tests
    // only pin the observable contract that an IME confirm never sends.
  });

  testWidgets('Shift+Enter never sends in any mode', (tester) async {
    for (final mode in ChatComposerController.validSendModes) {
      final sends = <String>[];
      final client = _client(mode, sends);
      addTearDown(client.dispose);
      final input = await _pump(tester, client);
      input.text = 'hello';

      await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.shiftLeft});
      await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.shiftLeft});
      expect(sends, isEmpty, reason: '$mode mode sent on Shift+Enter');
    }
  });

  testWidgets('sendMode is read-only from Flutter', (tester) async {
    final writes = <String>[];
    final sends = <String>[];
    final client = _client('ctrl-enter', sends, writes: writes);
    addTearDown(client.dispose);
    final input = await _pump(tester, client);
    input.text = 'hello';

    await _enter(tester, modifiers: <LogicalKeyboardKey>{LogicalKeyboardKey.controlLeft});
    expect(sends, <String>['hello']);
    expect(writes, isEmpty);
  });
}
