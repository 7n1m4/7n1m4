// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';
import 'package:anima_control/features/chat/genui_catalog.dart';
import 'package:genui/genui.dart';

import 'support/fakes.dart';

class _HistoryChatClient extends FakeChatClient {
  _HistoryChatClient(this.history);

  final List<Map<String, dynamic>> history;

  @override
  Future<List<Map<String, dynamic>>> chatHistory(String sessionId) async => history;
}

const _catalogId = 'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json';
const _fallback = 'A dynamic widget could not be displayed.';

Future<void> _pumpChat(WidgetTester tester, FakeChatClient client) async {
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
  );
  await tester.pump();
}

String _a2uiStream({
  required String surfaceId,
  required String text,
  String component = 'Text',
}) =>
    '''
```json
{"version":"v0.9","createSurface":{"surfaceId":"$surfaceId","catalogId":"$_catalogId"}}
```
```json
{"version":"v0.9","updateComponents":{"surfaceId":"$surfaceId","components":[{"id":"root","component":"$component","text":"$text"}]}}
```
''';

Future<void> _emitStreamed(
  WidgetTester tester,
  FakeChatClient client,
  String stream, {
  String messageId = 'm-genui',
}) async {
  final chunks = <String>[
    for (var i = 0; i < stream.length; i += 37)
      stream.substring(i, (i + 37).clamp(0, stream.length)),
  ];
  for (final chunk in chunks) {
    client.emitEvent(tokenDelta(delta: chunk, messageId: messageId));
    await tester.pump();
  }
}

Future<void> _settleParse(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  test('catalog does not expose the openUrl function', () {
    final catalog = airiGenUiCatalog();
    expect(catalog.functions.map((function) => function.name),
        isNot(contains('openUrl')));
  });

  testWidgets('chat.send opts into A2UI with genUi: true', (tester) async {
    final client = FakeChatClient();
    Map<String, dynamic>? sentPayload;
    client.onCall = (action, payload) {
      if (action == 'chat.send') sentPayload = payload;
      return RpcReply(
        action: action,
        ok: true,
        data: action == 'chat.send'
            ? <String, dynamic>{
                'sessionId': 's1',
                'messageId': 'm-1',
                'accepted': true,
              }
            : <String, dynamic>{},
      );
    };
    client.emitStatus(DaemonConnectionState.connected);
    await _pumpChat(tester, client);
    await tester.enterText(find.byType(TextField), 'make a widget');

    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pumpAndSettle();

    expect(sentPayload, isNotNull);
    expect(sentPayload!['genUi'], isTrue);
    expect(sentPayload!['content'], 'make a widget');
    expect(sentPayload!.keys, <String>{'sessionId', 'content', 'genUi'});
  });

  testWidgets('replayed history rehydrates A2UI widgets', (tester) async {
    final client = _HistoryChatClient(<Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': 'make a widget'},
      <String, dynamic>{
        'role': 'assistant',
        'content': _a2uiStream(surfaceId: 'replayed', text: 'Replayed widget'),
      },
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(client: client, initialSessionId: 's-history'),
      ),
    ));
    await _settleParse(tester);

    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('Replayed widget'), findsOneWidget);
    expect(find.textContaining('createSurface'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('streamed A2UI messages render a GenUI surface', (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(surfaceId: 'airi-card', text: 'Airi widget'),
    );
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-genui', isFinal: true));
    await _settleParse(tester);

    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('Airi widget'), findsOneWidget);
    // No A2UI JSON or fences leak into the ordinary text bubble.
    expect(find.textContaining('createSurface'), findsNothing);
  });

  testWidgets('malformed A2UI payload keeps ordinary text visible',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    client.emitEvent(tokenDelta(delta: 'before '));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '```json\n{"version":"v0.9",'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: '"createSurface": nope}\n```'));
    await tester.pump();
    client.emitEvent(tokenDelta(delta: ' after', isFinal: true));
    await _settleParse(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(Surface), findsNothing);
    expect(find.textContaining('before'), findsOneWidget);
    expect(find.textContaining('after'), findsOneWidget);
  });

  testWidgets('unsupported A2UI component shows a safe fallback',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(
        surfaceId: 'unsupported',
        text: 'Invisible',
        component: 'DefinitelyNotAnAiriComponent',
      ),
    );
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-genui', isFinal: true));
    await _settleParse(tester);

    expect(find.byType(Surface), findsNothing);
    expect(find.byType(FallbackWidget), findsNothing);
    expect(find.text(_fallback), findsOneWidget);
    expect(find.textContaining('Catalog item'), findsNothing);
    expect(find.textContaining('not found'), findsNothing);
  });

  testWidgets('two sequential widget turns render both surfaces',
      (tester) async {
    final client = FakeChatClient();
    await _pumpChat(tester, client);

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(surfaceId: 'turn-one', text: 'First widget'),
      messageId: 'm-1',
    );
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-1', isFinal: true));
    await _settleParse(tester);
    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('First widget'), findsOneWidget);

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(surfaceId: 'turn-two', text: 'Second widget'),
      messageId: 'm-2',
    );
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-2', isFinal: true));
    await _settleParse(tester);

    expect(find.byType(Surface), findsNWidgets(2));
    expect(find.text('First widget'), findsOneWidget);
    expect(find.text('Second widget'), findsOneWidget);
  });

  testWidgets('late GenUI parse does not overwrite a newer user bubble',
      (tester) async {
    final client = FakeChatClient();
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: action == 'chat.send'
              ? <String, dynamic>{
                  'sessionId': 's1',
                  'messageId': 'm-2',
                  'accepted': true,
                }
              : <String, dynamic>{},
        );
    client.emitStatus(DaemonConnectionState.connected);
    await _pumpChat(tester, client);
    await tester.enterText(find.byType(TextField), 'next turn');

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(surfaceId: 'late', text: 'Stale widget'),
      messageId: 'm-1',
    );
    // Emitting the final delta starts _finishGenUiTurn; send before its parse
    // future completes so the stale result cannot target the newer bubble.
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-1', isFinal: true));
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pump();
    await _settleParse(tester);

    expect(find.byType(Surface), findsNothing);
    expect(find.text('next turn'), findsOneWidget);
    expect(find.text('Stale widget'), findsNothing);
    expect(find.text('…'), findsNothing);
  });
}
