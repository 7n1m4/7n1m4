// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';

import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

Future<void> _pumpChat(WidgetTester tester, FakeChatClient client) async {
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
  );
  await tester.pump();
}

/// Returns the Markdown-rendered `Text` widgets inside the assistant bubble.
Iterable<Text> _bubbleTexts(WidgetTester tester) => tester.widgetList<Text>(
      find.descendant(
        of: find.byType(MarkdownBody),
        matching: find.byType(Text),
      ),
    );

bool _hasBoldSpan(InlineSpan span, String needle) {
  if (span is TextSpan) {
    if (span.text?.contains(needle) == true &&
        span.style?.fontWeight == FontWeight.bold) {
      return true;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (_hasBoldSpan(child, needle)) return true;
    }
  }
  return false;
}

Future<void> _settleParse(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('**bold** renders as bold text with no literal markers',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    client.emitEvent(tokenDelta(delta: '**bold**'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await tester.pumpAndSettle();

    final texts = _bubbleTexts(tester);
    expect(texts, isNotEmpty);
    final plain = texts
        .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
        .join();
    expect(plain, 'bold');
    expect(plain, isNot(contains('**')));
    expect(
      texts.any((w) => w.textSpan != null && _hasBoldSpan(w.textSpan!, 'bold')),
      isTrue,
      reason: 'no bold TextSpan covering "bold" was rendered',
    );
  });

  testWidgets('marker + markdown stream hides the marker and keeps GenUI',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    const catalogId =
        'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json';
    const stream = '<|ACTOR|>\n'
        '**Bold intro**\n'
        '```json\n'
        '{"version":"v0.9","createSurface":'
        '{"surfaceId":"md-card","catalogId":"$catalogId"}}\n'
        '```\n'
        '```json\n'
        '{"version":"v0.9","updateComponents":{"surfaceId":"md-card",'
        '"components":[{"id":"root","component":"Text",'
        '"text":"Marker widget"}]}}\n'
        '```\n';
    for (var i = 0; i < stream.length; i += 37) {
      client.emitEvent(
        tokenDelta(
          delta: stream.substring(i, (i + 37).clamp(0, stream.length)),
        ),
      );
      await tester.pump();
    }
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await _settleParse(tester);

    // The unstripped stream still fed GenUI, so the surface renders.
    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('Marker widget'), findsOneWidget);

    // The displayed bubble hides the marker and parses the markdown.
    expect(find.textContaining('<|ACTOR|>'), findsNothing);
    final texts = _bubbleTexts(tester);
    expect(texts, isNotEmpty);
    final plain = texts
        .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
        .join();
    expect(plain, contains('Bold intro'));
    expect(plain, isNot(contains('**')));
    expect(
      texts.any(
        (w) => w.textSpan != null && _hasBoldSpan(w.textSpan!, 'Bold intro'),
      ),
      isTrue,
      reason: 'no bold TextSpan covering "Bold intro" was rendered',
    );
  });

  testWidgets('stray fence with trailing text keeps that text visible',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    client.emitEvent(tokenDelta(delta: 'before\n'));
    await tester.pump();
    // A line-start fence with no closing fence must not swallow the prose
    // that follows it (the default GitHub extension set would).
    client.emitEvent(tokenDelta(delta: '```json\n{"version":"v0.9",'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '"createSurface": nope}'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '\nafter', isFinal: true));
    await _settleParse(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(Surface), findsNothing);
    expect(find.textContaining('before'), findsOneWidget);
    // An exact paragraph match: a substring finder also matches the clipped
    // `pre` text of an unterminated fence rendered by the default extension
    // set, so it would pass even if the custom set were reverted.
    // With the default GitHub extension set the trailing paragraph is
    // swallowed by the unterminated fence; this finder fails in that case.
    expect(find.textContaining('after'), findsOneWidget);
  });
}
