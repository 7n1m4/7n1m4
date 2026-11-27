// SPDX-License-Identifier: GPL-3.0-or-later

// UI-owned vertical slice over already-decoded frames. Nothing here builds,
// parses or mints a wire envelope; the quarantined chat_transport seam is not
// imported.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/chat/feed/chat_feed_controller.dart';
import 'package:anima_control/features/chat/feed/chat_feed_event.dart';
import 'package:anima_control/features/chat/feed/chat_feed_gap_indicator.dart';

import 'support/scripted_chat_feed_adapter.dart';

Widget _harness(ChatFeedController controller) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Column(
      children: <Widget>[
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) =>
              ChatFeedGapIndicator(gap: controller.gap),
        ),
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) =>
              Text(controller.renderedText),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('gap indicator and ordered text follow the scripted feed', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    // seq 1 and seq 2 are contiguous: no gap, text grows in order.
    expect(adapter.emitNext(), isTrue); // seq 1 -> 'Hello '
    await tester.pump();
    expect(controller.gap, isNull);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);
    expect(find.text('Hello '), findsOneWidget);

    expect(adapter.emitNext(), isTrue); // seq 2 -> 'brave '
    await tester.pump();
    expect(controller.renderedText, 'Hello brave ');
    expect(controller.gap, isNull);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);
    expect(find.text('Hello brave '), findsOneWidget);

    // Jump to seq 4: seq 3 is missing, so the gap opens and seq 4 is buffered
    // rather than rendered out of order.
    expect(adapter.emitNext(), isTrue); // seq 4 -> '!'
    await tester.pump();
    expect(controller.gap, isNotNull);
    expect(controller.gap!.isOpen, isTrue);
    expect(controller.gap!.missingSeqs, <int>[3]);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsOneWidget);
    expect(find.text('Hello brave '), findsOneWidget);
    expect(find.textContaining('!'), findsNothing);

    // Replay of seq 3 fills the gap and flushes the buffered seq 4.
    expect(adapter.emitNext(), isTrue); // seq 3 -> 'world'
    await tester.pump();
    expect(controller.gap, isNull);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);
    expect(controller.renderedText, 'Hello brave world!');
    expect(find.text('Hello brave world!'), findsOneWidget);

    expect(adapter.emitNext(), isFalse); // script exhausted
  });

  testWidgets(
    'malformed, duplicate and late frames never corrupt order or fabricate text',
    (WidgetTester tester) async {
      final adapter = ScriptedChatFeedAdapter();
      final controller = ChatFeedController(adapter);
      addTearDown(controller.dispose);
      addTearDown(() async => adapter.close());

      await tester.pumpWidget(_harness(controller));

      // Malformed: non-positive seq is ignored.
      adapter.emit(const ChatFeedFrame(seq: 0, text: 'BAD'));
      adapter.emit(const ChatFeedFrame(seq: -1, text: 'BAD'));
      await tester.pump();
      expect(controller.renderedText, '');
      expect(controller.gap, isNull);

      adapter.emit(const ChatFeedFrame(seq: 1, text: 'A'));
      await tester.pump();
      expect(controller.renderedText, 'A');

      // Duplicate of an already-rendered seq is ignored.
      adapter.emit(const ChatFeedFrame(seq: 1, text: 'DUP'));
      await tester.pump();
      expect(controller.renderedText, 'A');

      // An empty delta is a no-op token: it advances the expected seq but
      // contributes no text and opens no gap.
      adapter.emit(const ChatFeedFrame(seq: 2, text: ''));
      await tester.pump();
      expect(controller.renderedText, 'A');
      expect(controller.gap, isNull);

      // seq 4 with seq 3 still missing opens a gap at 3 and buffers seq 4.
      adapter.emit(const ChatFeedFrame(seq: 4, text: 'D'));
      await tester.pump();
      expect(controller.gap!.missingSeqs, <int>[3]);
      expect(controller.renderedText, 'A');

      // A late replay of an already-rendered seq fabricates no text and does
      // not close or move the gap.
      adapter.emit(const ChatFeedFrame(seq: 1, text: 'LATE'));
      await tester.pump();
      expect(controller.renderedText, 'A');
      expect(controller.gap!.missingSeqs, <int>[3]);

      // Filling the missing seq flushes the buffered one in order.
      adapter.emit(const ChatFeedFrame(seq: 3, text: 'C'));
      await tester.pump();
      expect(controller.gap, isNull);
      expect(controller.renderedText, 'ACD');
    },
  );

  testWidgets(
    'an implausible forward jump is dropped without touching text or gap',
    (WidgetTester tester) async {
      final adapter = ScriptedChatFeedAdapter();
      final controller = ChatFeedController(adapter);
      addTearDown(controller.dispose);
      addTearDown(() async => adapter.close());

      await tester.pumpWidget(_harness(controller));

      adapter.emit(const ChatFeedFrame(seq: 1, text: 'A'));
      await tester.pump();
      expect(controller.renderedText, 'A');
      expect(controller.gap, isNull);

      // A billion-seq jump would otherwise make the gap scanner walk 1e9 slots.
      adapter.emit(const ChatFeedFrame(seq: 1000000000, text: 'x'));
      await tester.pump();
      expect(controller.renderedText, 'A');
      expect(controller.gap, isNull);
      expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);

      // Contiguous traffic still works after the rejected jump.
      adapter.emit(const ChatFeedFrame(seq: 2, text: 'B'));
      await tester.pump();
      expect(controller.renderedText, 'AB');
      expect(controller.gap, isNull);
    },
  );

  testWidgets('an error clears an open gap without fabricating text', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'A'));
    adapter.emit(const ChatFeedFrame(seq: 3, text: 'C'));
    await tester.pump();
    expect(controller.gap!.missingSeqs, <int>[2]);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsOneWidget);
    expect(controller.renderedText, 'A');

    adapter.fail(StateError('feed broke'));
    await tester.pump();
    expect(controller.isTerminal, isTrue);
    expect(controller.gap, isNull);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);
    expect(controller.renderedText, 'A');

    // Frames arriving after the terminal signal cannot reopen the gap.
    adapter.emit(const ChatFeedFrame(seq: 2, text: 'B'));
    await tester.pump();
    expect(controller.renderedText, 'A');
    expect(controller.gap, isNull);
  });

  testWidgets('a closed stream clears an open gap without fabricating text', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'A'));
    adapter.emit(const ChatFeedFrame(seq: 3, text: 'C'));
    await tester.pump();
    expect(controller.gap!.missingSeqs, <int>[2]);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsOneWidget);

    unawaited(adapter.close());
    await tester.pump();
    expect(controller.isTerminal, isTrue);
    expect(controller.gap, isNull);
    expect(find.byKey(const Key('chat-feed-gap-indicator')), findsNothing);
    expect(controller.renderedText, 'A');
  });

  testWidgets('an empty delta is a no-op token that still advances the seq', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'Hel'));
    await tester.pump();
    expect(controller.renderedText, 'Hel');

    adapter.emit(const ChatFeedFrame(seq: 2, text: ''));
    await tester.pump();
    expect(controller.renderedText, 'Hel');
    expect(controller.gap, isNull);

    adapter.emit(const ChatFeedFrame(seq: 3, text: 'lo'));
    await tester.pump();
    expect(controller.renderedText, 'Hello');
    expect(controller.gap, isNull);
    expect(controller.orderedTokens.length, 3);
  });

  testWidgets('isFinal buffered behind a gap never finalizes out of order', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'Hel'));
    await tester.pump();
    expect(controller.renderedText, 'Hel');

    // seq 3 is final but sits behind the missing seq 2: buffer it only, never
    // finalize a truncated message.
    adapter.emit(const ChatFeedFrame(seq: 3, text: 'lo', isFinal: true));
    await tester.pump();
    expect(controller.renderedText, 'Hel');
    expect(controller.gap!.missingSeqs, <int>[2]);
    expect(controller.isTerminal, isFalse);

    // Filling seq 2 drains seq 3 in order, which then finalizes.
    adapter.emit(const ChatFeedFrame(seq: 2, text: ''));
    await tester.pump();
    expect(controller.renderedText, 'Hello');
    expect(controller.gap, isNull);
    expect(controller.isTerminal, isTrue);
  });

  testWidgets('frames after an in-order isFinal are ignored', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'Hel', isFinal: true));
    await tester.pump();
    expect(controller.renderedText, 'Hel');
    expect(controller.isTerminal, isTrue);
    expect(controller.gap, isNull);

    // Late frames after the terminal frame cannot extend the message.
    adapter.emit(const ChatFeedFrame(seq: 2, text: 'lo'));
    adapter.emit(const ChatFeedFrame(seq: 3, text: '!', isFinal: true));
    await tester.pump();
    expect(controller.renderedText, 'Hel');
    expect(controller.gap, isNull);
    expect(controller.isTerminal, isTrue);
  });

  testWidgets('a first frame above seq 1 opens a gap, not a mid-turn start', (
    WidgetTester tester,
  ) async {
    final adapter = ScriptedChatFeedAdapter();
    final controller = ChatFeedController(adapter);
    addTearDown(controller.dispose);
    addTearDown(() async => adapter.close());

    await tester.pumpWidget(_harness(controller));

    // First observed frame is seq 3: seqs 1 and 2 are genuinely missing.
    adapter.emit(const ChatFeedFrame(seq: 3, text: 'world'));
    await tester.pump();
    expect(controller.renderedText, '');
    expect(controller.gap!.missingSeqs, <int>[1, 2]);

    adapter.emit(const ChatFeedFrame(seq: 1, text: 'Hello '));
    await tester.pump();
    expect(controller.renderedText, 'Hello ');
    expect(controller.gap!.missingSeqs, <int>[2]);

    adapter.emit(const ChatFeedFrame(seq: 2, text: 'brave '));
    await tester.pump();
    expect(controller.renderedText, 'Hello brave world');
    expect(controller.gap, isNull);
  });

  group('immutable feed value objects', () {
    test('frames, tokens and gaps compare by value', () {
      expect(
        const ChatFeedFrame(seq: 1, text: 'a'),
        const ChatFeedFrame(seq: 1, text: 'a'),
      );
      expect(
        const ChatFeedFrame(seq: 1, text: 'a'),
        isNot(const ChatFeedFrame(seq: 1, text: 'b')),
      );
      expect(const ChatFeedToken(2, 'b'), const ChatFeedToken(2, 'b'));

      final first = ChatFeedGap(<int>[3, 2]);
      final second = ChatFeedGap(<int>[2, 3]);
      expect(first.missingSeqs, <int>[2, 3]);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.isOpen, isTrue);
      expect(ChatFeedGap(<int>[]).isOpen, isFalse);
    });
  });
}
