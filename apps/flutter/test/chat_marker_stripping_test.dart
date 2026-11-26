// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/chat/chat_message_display.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

Future<void> _pumpChat(WidgetTester tester, FakeChatClient client) async {
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
  );
  await tester.pump();
}

/// Captures `Clipboard.setData` payloads without a real platform clipboard.
List<String> _mockClipboard() {
  final written = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      written.add(call.arguments['text'] as String);
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return written;
}

void main() {
  group('stripMarkers', () {
    test('strips closed ACT/ACTOR markers, including multiline blocks', () {
      expect(
        stripMarkers('Hello<|ACT|>, world<|ACTOR|>\nnext line'),
        'Hello, world\nnext line',
      );
      expect(
        stripMarkers('a<|thinking\nacross lines|>b'),
        'ab',
      );
    });

    test('strips legacy plain-> markers case-insensitively', () {
      expect(stripMarkers('a<|ACT>b'), 'ab');
      expect(stripMarkers('a<|ACTOR name>b'), 'ab');
      expect(stripMarkers('a<|DELAY 500>b'), 'ab');
      expect(stripMarkers('a<|STICKER>b'), 'ab');
      expect(stripMarkers('a<|LLM_custom:x-y>b'), 'ab');
      expect(stripMarkers('x<|act>y'), 'xy');
    });

    test('keeps the Vue helper span behavior when a later |> closes an earlier tag',
        () {
      // Mirrors response-categoriser.ts: the first pass spans lazily from the
      // first `<|` to the first `|>`, even across an intervening legacy tag.
      expect(stripMarkers('a<|ACT>b<|LLM:x|>c'), 'ac');
    });

    test('preserves all other text exactly', () {
      const raw = 'Hi <b>there</b>!\nA < B > C  <|NOT_A_MARKER> stays.';
      expect(stripMarkers(raw), raw);
    });
  });

  group('ChatScreen display', () {
    testWidgets('ACT markers are stripped from the bubble', (tester) async {
      final client = FakeChatClient();
      await _pumpChat(tester, client);

      client.emitEvent(tokenDelta(delta: 'Hello<|ACT|>, world'));
      await tester.pump();
      client.emitEvent(tokenDelta(delta: '', isFinal: true));
      await tester.pumpAndSettle();

      expect(find.text('Hello, world'), findsOneWidget);
      expect(find.textContaining('<|ACT|>'), findsNothing);
    });

    testWidgets('legacy plain-> markers are stripped from the bubble',
        (tester) async {
      final client = FakeChatClient();
      await _pumpChat(tester, client);

      client.emitEvent(tokenDelta(delta: 'Hi <|ACT>there'));
      await tester.pump();
      client.emitEvent(tokenDelta(delta: '', isFinal: true));
      await tester.pumpAndSettle();

      expect(find.text('Hi there'), findsOneWidget);
      expect(find.textContaining('<|'), findsNothing);
    });

    testWidgets('Copy writes the marker-stripped text to the clipboard',
        (tester) async {
      final client = FakeChatClient();
      await _pumpChat(tester, client);
      final clipboard = _mockClipboard();

      client.emitEvent(tokenDelta(delta: 'Hello<|ACT|>, world'));
      await tester.pump();
      client.emitEvent(tokenDelta(delta: '', isFinal: true));
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('chat-copy-0'));
      expect(button, findsOneWidget);
      tester.widget<IconButton>(button).onPressed!();
      await tester.pumpAndSettle();

      expect(clipboard, <String>['Hello, world']);
    });
  });
}
