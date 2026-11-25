// SPDX-License-Identifier: GPL-3.0-or-later

// Narrow regression tests for DirectWebSocketTransport's `isConnected` flag.
// A local HTTP server stands in for the gateway: the upgrade can be held back
// so the test observes the exact moment the WebSocket handshake succeeds.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/daemon_client/direct_websocket_transport.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<Uri> _endpoint(HttpServer server) async =>
    Uri.parse('ws://127.0.0.1:${server.port}/ws');

void main() {
  test('connected is published only after the handshake completes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));
    final allowUpgrade = Completer<void>();
    server.listen((request) async {
      await allowUpgrade.future;
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {}); // drain client frames
    });

    final endpoint = await _endpoint(server);
    final transport = DirectWebSocketTransport();
    addTearDown(transport.dispose);
    final connecting = transport.connect(endpoint);

    await _pump();
    expect(transport.isConnected, isFalse);
    expect(() => transport.send('{}'), throwsA(isA<StateError>()));

    allowUpgrade.complete();
    await connecting;

    expect(transport.isConnected, isTrue);
    transport.send('{"type":"auth","authToken":"tok"}');
  });

  test('a rejected handshake fails connect and stays disconnected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
    });

    final endpoint = await _endpoint(server);
    final transport = DirectWebSocketTransport();
    addTearDown(transport.dispose);

    await expectLater(
      transport.connect(endpoint),
      throwsA(isA<WebSocketChannelException>()),
    );
    expect(transport.isConnected, isFalse);
    expect(() => transport.send('{}'), throwsA(isA<StateError>()));
  });

  test('a closed gateway drops connected and signals TransportClosed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));
    final upgraded = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
      upgraded.complete(socket);
    });

    final endpoint = await _endpoint(server);
    final transport = DirectWebSocketTransport();
    addTearDown(transport.dispose);
    await transport.connect(endpoint);
    expect(transport.isConnected, isTrue);

    final closed = transport.errors.first;
    await (await upgraded.future).close();

    expect(await closed.timeout(const Duration(seconds: 2)), isA<TransportClosed>());
    expect(transport.isConnected, isFalse);
  });
}
