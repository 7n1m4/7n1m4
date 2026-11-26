// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

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
  Future<ListPage<Map<String, dynamic>>> chatHistoryPage(
    String sessionId, {
    int limit = 50,
    Object? cursor,
  }) async =>
      ListPage(
        items: history,
        truncated: false,
      );
}

/// Session-switch client: s1 replays an empty history, while s2's history read
/// can be held open so a freshly streamed s2 bubble survives long enough for a
/// stale parse from s1 to (incorrectly) target it if the guards are missing.
class _SessionSwitchChatClient extends FakeChatClient {
  Completer<RpcReply>? deferredS2History;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'chat.history' &&
        payload?['session_id'] == 's2' &&
        deferredS2History != null) {
      return deferredS2History!.future;
    }
    return super.call(action, payload: payload);
  }

  _SessionSwitchChatClient() {
    onCall = (action, payload) {
      switch (action) {
        case 'sessions.list':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'sessions': <Map<String, dynamic>>[
                <String, dynamic>{'id': 's2', 'title': 'Session Two'},
              ],
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
        case 'chat.history':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'messages': <Map<String, dynamic>>[],
              'truncated': false,
            },
          );
        case 'chat.send':
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'sessionId': 's1',
              'messageId': 'm-1',
              'accepted': true,
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

    await _emitStreamed(
      tester,
      client,
      _a2uiStream(surfaceId: 'late', text: 'Stale widget'),
      messageId: 'm-1',
    );
    // Type after the first delta: that delta binds composer.sessionId, and the
    // setter parks/clears any draft typed before the session was known.
    await tester.enterText(find.byType(TextField), 'next turn');
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pumpAndSettle();

    // Finalizing the stale turn starts _finishGenUiTurn; its parse must not
    // overwrite the bubble that was just committed.
    client.emitEvent(tokenDelta(delta: '', messageId: 'm-1', isFinal: true));
    await _settleParse(tester);

    expect(find.byType(Surface), findsNothing);
    expect(find.text('Stale widget'), findsNothing);
    expect(find.text('…'), findsNothing);

    // The newer user bubble sits below the long raw A2UI text; scroll to it
    // because ListView.builder only builds visible rows.
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('next turn'), findsOneWidget);
  });

  testWidgets('a late GenUI parse after a session switch cannot add a stale surface', (
    tester,
  ) async {
    final client = _SessionSwitchChatClient();
    addTearDown(client.dispose);
    final s2History = Completer<RpcReply>();
    client.deferredS2History = s2History;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(client: client, initialSessionId: 's1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-sessions-button')));
    await tester.pumpAndSettle();
    final s2Tile = find.widgetWithText(ListTile, 'Session Two');
    expect(s2Tile, findsOneWidget);

    final stream = _a2uiStream(
      surfaceId: 'stale-session',
      text: 'Stale session widget',
    );
    client.emitEvent(tokenDelta(sessionId: 's1', delta: stream, messageId: 'm-1'));
    await tester.pump();
    client.emitEvent(tokenDelta(
      sessionId: 's1',
      delta: '',
      messageId: 'm-1',
      isFinal: true,
    ));

    // Switch before the parse completes. s2's history read stays deferred and
    // an unfinalized s2 turn holds the identical raw output, so without the
    // generation/session guard the stale parse would attach its surface here.
    tester.widget<ListTile>(s2Tile).onTap!();
    client.emitEvent(tokenDelta(sessionId: 's2', delta: stream, messageId: 'm-2'));
    await _settleParse(tester);

    expect(find.byType(Surface), findsNothing);
    expect(find.text('Stale session widget'), findsNothing);
    expect(find.text('Session s2'), findsOneWidget);

    s2History.complete(const RpcReply(
      action: 'chat.history',
      ok: true,
      data: <String, dynamic>{
        'messages': <Map<String, dynamic>>[],
        'truncated': false,
      },
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reload with no active session keeps an in-flight GenUI parse', (
    tester,
  ) async {
    final client = FakeChatClient();
    final key = GlobalKey<ChatScreenState>();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(key: key, client: client)),
      ),
    );
    await tester.pump();

    // Empty session_id keeps the composer session null: this is a New chat, so
    // reload() has no history to read and must not bump the generation while
    // the turn that just finalized is still being parsed.
    final stream = _a2uiStream(
      surfaceId: 'no-session',
      text: 'No session widget',
    );
    for (var i = 0; i < stream.length; i += 37) {
      client.emitEvent(tokenDelta(
        sessionId: '',
        delta: stream.substring(i, (i + 37).clamp(0, stream.length)),
        messageId: 'm-genui',
      ));
      await tester.pump();
    }
    client.emitEvent(tokenDelta(
      sessionId: '',
      delta: '',
      messageId: 'm-genui',
      isFinal: true,
    ));
    // Called synchronously: _finishGenUiTurn is suspended on its parse here.
    final reloading = key.currentState!.reload();
    await reloading;
    await _settleParse(tester);

    expect(key.currentState!.activeSessionId, isNull);
    expect(find.byType(Surface), findsOneWidget);
    expect(find.text('No session widget'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
