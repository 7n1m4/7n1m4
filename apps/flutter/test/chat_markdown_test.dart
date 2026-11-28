// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

Future<void> _pumpChat(WidgetTester tester, FakeChatClient client) async {
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ChatScreen(client: client)),
    ),
  );
  await tester.pump();
}

/// Returns the Markdown-rendered `Text` widgets inside the assistant bubble.
Iterable<Text> _bubbleTexts(WidgetTester tester) => tester.widgetList<Text>(
  find.descendant(of: find.byType(MarkdownBody), matching: find.byType(Text)),
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

/// Replays one literal user bubble so display-time balancing can be tested
/// without the GenUI parser rewriting the assistant transcript.
class _UserHistoryChatClient extends FakeChatClient {
  _UserHistoryChatClient(this.text) {
    onCall = (action, payload) {
      switch (action) {
        case 'chat.history':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'content': text},
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

  final String text;
}

Future<void> _pumpUserBubble(
  WidgetTester tester,
  _UserHistoryChatClient client,
) async {
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatScreen(client: client, initialSessionId: 's1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _bubblePlain(WidgetTester tester) =>
    _bubbleTexts(tester)
        .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
        .join();

/// Tag of the paragraph/code element holding [needle] after parsing with the
/// same extension set the app uses. `p` means visible prose; `pre` means the
/// text was swallowed into a code block.
String? _tagContaining(String markdown, String needle) {
  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  String? found;
  void visit(md.Node node) {
    if (found != null) return;
    if (node is md.Element) {
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Text && child.text.contains(needle)) {
          found = node.tag;
          return;
        }
        visit(child);
      }
    }
  }

  for (final node in document.parseLines(
    const LineSplitter().convert(markdown),
  )) {
    visit(node);
  }
  return found;
}

/// The displayed markdown source of the single bubble under test.
String _bubbleSource(WidgetTester tester) =>
    tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data!;

/// Captures `Clipboard.setData` payloads without a platform clipboard.
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
  testWidgets('**bold** renders as bold text with no literal markers', (
    tester,
  ) async {
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

  testWidgets('marker + markdown stream hides the marker and keeps GenUI', (
    tester,
  ) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    const catalogId =
        'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json';
    const stream =
        '<|ACTOR|>\n'
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

  testWidgets('stray fence with trailing text keeps that text visible', (
    tester,
  ) async {
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

  testWidgets(
    'balanced fence shows code without literal markers and keeps trailing prose',
    (tester) async {
      final client = FakeChatClient();
      await _pumpChat(tester, client);

      // Tilde fences are not consumed by GenUI's A2UI extraction, so the
      // markdown renderer (not the GenUI parser) is what must handle them.
      const stream =
          'Here is the payload:\n'
          '~~~dart\n'
          'final answer = 42;\n'
          'print(answer);\n'
          '~~~\n'
          'and that is all.';
      for (var i = 0; i < stream.length; i += 41) {
        client.emitEvent(
          tokenDelta(
            delta: stream.substring(i, (i + 41).clamp(0, stream.length)),
          ),
        );
        await tester.pump();
      }
      client.emitEvent(tokenDelta(delta: '', isFinal: true));
      await _settleParse(tester);

      expect(tester.takeException(), isNull);
      final texts = _bubbleTexts(tester);
      expect(texts, isNotEmpty);
      final plain = texts
          .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
          .join();
      expect(
        plain,
        isNot(contains('~~~')),
        reason: 'fence markers must not be rendered as literal text',
      );
      expect(
        plain,
        contains('final answer = 42;\nprint(answer);'),
        reason: 'code content must remain visible as a code block',
      );
      expect(
        find.textContaining('and that is all.'),
        findsOneWidget,
        reason: 'trailing prose after a balanced fence must stay visible',
      );
    },
  );

  testWidgets(
    'unterminated backtick fence keeps prose across a streaming replay',
    (tester) async {
      final client = FakeChatClient();
      await _pumpChat(tester, client);

      const stream = 'before\n```json\n{"a":1}\nafter';
      for (var i = 0; i < stream.length; i += 7) {
        client.emitEvent(
          tokenDelta(
            delta: stream.substring(i, (i + 7).clamp(0, stream.length)),
          ),
        );
        await tester.pump();
      }
      client.emitEvent(tokenDelta(delta: '', isFinal: true));
      await _settleParse(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('after'), findsOneWidget);
      final plain = _bubblePlain(tester);
      expect(plain, contains('{"a":1}'));
      expect(plain, isNot(contains('```')));
      expect(_tagContaining(_bubbleSource(tester), 'after'), 'p');
    },
  );

  testWidgets('user paste with an unterminated fence keeps trailing prose', (
    tester,
  ) async {
    final client = _UserHistoryChatClient(
      'see this\n```python\nprint(1)\nand thats it',
    );
    await _pumpUserBubble(tester, client);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('and thats it'), findsOneWidget);
    expect(_tagContaining(_bubbleSource(tester), 'and thats it'), 'p');
  });

  testWidgets(
    'backtick in fence info is not a fence and cannot swallow prose',
    (tester) async {
      // markdown 7.3.1 only treats ``` as a fence when its info string has no
      // backticks. Treating this line as an opener makes the real ```` fence
      // look like its closer, leaving the prose swallowed by that real fence.
      final client = _UserHistoryChatClient(
        '``` foo`bar\nnot a fence\n````\ntrailing secret prose',
      );
      await _pumpUserBubble(tester, client);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('trailing secret prose'), findsOneWidget);
      expect(
        _tagContaining(_bubbleSource(tester), 'trailing secret prose'),
        'p',
      );
    },
  );

  testWidgets('CRLF unterminated fence keeps trailing prose', (tester) async {
    final client = _UserHistoryChatClient(
      'before\r\n```python\r\nprint(1)\r\nafter crlf',
    );
    await _pumpUserBubble(tester, client);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('after crlf'), findsOneWidget);
    expect(_tagContaining(_bubbleSource(tester), 'after crlf'), 'p');
  });

  testWidgets('every stray fence gets its own closer', (tester) async {
    final client = _UserHistoryChatClient(
      'A\n```one\nb\n```two\nfinal tail visible',
    );
    await _pumpUserBubble(tester, client);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('final tail visible'), findsOneWidget);
    expect(_tagContaining(_bubbleSource(tester), 'final tail visible'), 'p');
  });

  testWidgets('blockquoted unterminated fence keeps quoted prose', (
    tester,
  ) async {
    final client = _UserHistoryChatClient(
      '> ```js\n> code\n> after quoted prose',
    );
    await _pumpUserBubble(tester, client);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('after quoted prose'), findsOneWidget);
    expect(_tagContaining(_bubbleSource(tester), 'after quoted prose'), 'p');
  });

  testWidgets('Copy writes source text without injected fence lines', (
    tester,
  ) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);
    final clipboard = _mockClipboard();

    const raw = 'Hello<|ACT|>, world\n```python\nprint(1)\ncopied trail';
    client.emitEvent(tokenDelta(delta: raw));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('chat-copy-0'));
    expect(button, findsOneWidget);
    tester.widget<IconButton>(button).onPressed!();
    await tester.pumpAndSettle();

    // Markers stay stripped for the clipboard, but no synthetic closer is
    // presented as if the model had authored it.
    expect(clipboard, <String>[
      'Hello, world\n```python\nprint(1)\ncopied trail',
    ]);
  });

  testWidgets('one-space fence closer still pairs with its opener', (
    tester,
  ) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    // Markdown allows a closer indented 0-3 spaces regardless of the opener's
    // indentation. A 1-space closer must not be treated as a stray opener.
    const stream = '```dart\n  let x = 1;\n ```\nafter';
    for (var i = 0; i < stream.length; i += 5) {
      client.emitEvent(
        tokenDelta(delta: stream.substring(i, (i + 5).clamp(0, stream.length))),
      );
      await tester.pump();
    }
    client.emitEvent(tokenDelta(delta: '', isFinal: true));
    await _settleParse(tester);

    expect(tester.takeException(), isNull);
    final source = _bubbleSource(tester);
    expect(_tagContaining(source, 'let x = 1;'), 'code');
    expect(_tagContaining(source, 'after'), 'p');
  });
}
