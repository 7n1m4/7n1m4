// SPDX-License-Identifier: GPL-3.0-or-later

// ROOT CAUSE:
//
// DaemonClient.call registered a pending RPC and invoked transport.send before
// entering its try/finally. A transport throwing on send (for example a closed
// WebSocket raising StateError) escaped as an untyped error, left the pending
// entry behind, and skipped ChatScreen's DaemonClientException handler. The
// screen kept _sending=true, replacing Send with an inert Stop button.
//
// FIXED BY: wrapping send failures as DaemonClientException(kind: transport)
// inside DaemonClient.call, cleaning up the pending entry, and catching any
// remaining Object in ChatScreen._send so the send state is always reset.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class SendFailureTransport implements DaemonTransport {
  final StreamController<String> _messages = StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final List<String> sent = <String>[];

  /// Invoked for every frame; throwing simulates a closed socket.
  void Function(String frame)? onSend;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect(Uri endpoint) async {}

  @override
  void send(String frame) {
    sent.add(frame);
    onSend?.call(frame);
  }

  @override
  Future<void> close() async {}

  @override
  void dispose() {
    _messages.close();
    _errors.close();
  }

  void receive(String frame) => _messages.add(frame);
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<DaemonClient> _connectedClient(SendFailureTransport transport) async {
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 2),
    rpcTimeout: const Duration(seconds: 2),
  );
  addTearDown(client.dispose);

  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await _pump();
  transport.receive('{"type":"auth","ok":true}');
  await _pump();
  final probe = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  transport.receive(jsonEncode(<String, dynamic>{
    'type': 'rpc',
    'action': 'core.status',
    'ok': true,
    'data': <String, dynamic>{
      'app': 'anima-daemon',
      'version': '0.1.0',
      'coreAvailable': true,
      'storeAvailable': true,
      'storeHealth': 'ok',
      'protocol': 'airi-channel/1',
      'sessionCount': 0,
      'messageCount': 0,
    },
    'id': probe['id'],
  }));
  await connecting;
  return client;
}

void main() {
  test('a throwing transport.send becomes a typed transport failure', () async {
    final transport = SendFailureTransport();
    final client = await _connectedClient(transport);
    var sends = 0;
    transport.onSend = (frame) {
      final decoded = jsonDecode(frame) as Map<String, dynamic>;
      if (decoded['action'] == 'chat.send' && sends++ == 0) {
        throw StateError('Cannot send on a closed socket');
      }
    };

    await expectLater(
      client.call('chat.send', payload: <String, dynamic>{'content': 'hi'}),
      throwsA(isA<DaemonClientException>()
          .having((e) => e.kind, 'kind', DaemonFailureKind.transport)
          .having((e) => e.message, 'message', contains('closed socket'))),
    );

    // The failed send must not strand a pending entry: the next call resolves.
    final retry = client.call('chat.send', payload: <String, dynamic>{'content': 'hi'});
    await _pump();
    final second = jsonDecode(transport.sent.last) as Map<String, dynamic>;
    transport.receive(jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': 'chat.send',
      'ok': true,
      'data': <String, dynamic>{},
      'id': second['id'],
    }));
    expect((await retry).ok, isTrue);
  });

  testWidgets('chat recovers the Send button when an RPC throws untyped', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) {
      if (action == 'chat.send') throw StateError('Cannot send on a closed socket');
      return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    };
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed!();
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.send), findsOneWidget, reason: 'sending state is reset');
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(find.textContaining('closed socket'), findsOneWidget, reason: 'the error is visible');
  });
}
