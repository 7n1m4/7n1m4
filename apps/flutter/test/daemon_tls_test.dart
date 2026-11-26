// SPDX-License-Identifier: GPL-3.0-or-later

// Real TLS handshake tests for the daemon CA trust path. A self-signed cert is
// generated once per run and used as both the server cert and the client's
// trusted CA, so the handshake either verifies against the configured PEM or
// fails — nothing is stubbed and no socket leaves loopback.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/direct_websocket_transport.dart';

void main() {
  late TlsStandIn ca;
  late TlsStandInServer server;

  setUpAll(() async {
    ca = await TlsStandIn.generate();
    server = await TlsStandInServer.start(ca);
  });

  tearDownAll(() async {
    await server.close();
    ca.delete();
  });

  test('wss connects when the configured CA matches the server cert', () async {
    final transport = DirectWebSocketTransport(caCertPath: ca.caFile.path);
    addTearDown(transport.dispose);

    await transport.connect(server.uri);

    expect(transport.isConnected, isTrue);
    transport.send('{"type":"auth","authToken":"tok"}');
    await server.firstFrame; // the frame reached the server
  });

  for (final caPath in <String?>[null, '  ']) {
    test('wss fails closed when no CA is configured (${caPath ?? "unset"})', () async {
      // The old code fell back to WebSocketChannel.connect (platform roots)
      // when the CA was missing. A plain handshake failure looks identical to
      // a rejected cert, so pin the CA-specific refusal: the old path could
      // only produce the generic 'TLS certificate was not trusted' message.
      final transport = DirectWebSocketTransport(caCertPath: caPath);
      addTearDown(transport.dispose);

      await expectLater(
        transport.connect(server.uri),
        throwsA(
          isA<GatewayCaException>().having(
            (e) => e.message,
            'message',
            contains('No CA certificate is configured for wss'),
          ),
        ),
      );
      expect(transport.isConnected, isFalse);
    });
  }

  test('wss fails closed when the CA file is missing', () async {
    final transport = DirectWebSocketTransport(
      caCertPath: '${ca.dir.path}/does-not-exist.pem',
    );
    addTearDown(transport.dispose);

    await expectLater(
      transport.connect(server.uri),
      throwsA(isA<GatewayCaException>()),
    );
    expect(transport.isConnected, isFalse);
  });

  test('wss fails closed when the CA does not sign the server cert', () async {
    final other = await TlsStandIn.generate();
    addTearDown(other.delete);
    final transport = DirectWebSocketTransport(caCertPath: other.caFile.path);
    addTearDown(transport.dispose);

    await expectLater(
      transport.connect(server.uri),
      throwsA(
        predicate<Object>(
          (Object e) =>
              e is GatewayCaException && e.message.contains('not trusted'),
          'untrusted-CA handshake failure',
        ),
      ),
    );
    expect(transport.isConnected, isFalse);
  });


  test('gatewaySecurityContext builds no context without a CA path', () {
    expect(gatewaySecurityContext(null), isNull);
    expect(gatewaySecurityContext('  '), isNull);
  });

  test('gatewaySecurityContext rejects a missing CA file', () {
    expect(
      () => gatewaySecurityContext('${ca.dir.path}/does-not-exist.pem'),
      throwsA(isA<GatewayCaException>()),
    );
  });

  test('gatewaySecurityContext builds a context from the configured CA', () {
    expect(gatewaySecurityContext(ca.caFile.path), isNotNull);
  });

  test('plain ws on loopback still connects with no CA', () async {
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => plain.close(force: true));
    final accepted = Completer<void>();
    plain.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!accepted.isCompleted) accepted.complete();
      socket.listen((_) {});
    });

    final transport = DirectWebSocketTransport();
    addTearDown(transport.dispose);

    await transport.connect(Uri.parse('ws://127.0.0.1:${plain.port}/ws'));
    await accepted.future;

    expect(transport.isConnected, isTrue);
  });
}

/// A generated self-signed cert/key pair on disk, usable as the client's
/// trusted CA and as the server's own certificate.
class TlsStandIn {
  TlsStandIn(this.dir, this.caFile, this.keyFile);

  static Future<TlsStandIn> generate() async {
    final dir = Directory.systemTemp.createTempSync('anima-ca-gen-');
    final caFile = File('${dir.path}/ca.pem');
    final keyFile = File('${dir.path}/ca-key.pem');
    final result = await Process.run('openssl', <String>[
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      keyFile.path,
      '-out',
      caFile.path,
      '-days',
      '1',
      '-subj',
      '/CN=anima-test-ca',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1',
    ]);
    if (result.exitCode != 0) {
      dir.deleteSync(recursive: true);
      throw StateError('openssl req failed: ${result.stderr}');
    }
    return TlsStandIn(dir, caFile, keyFile);
  }

  final Directory dir;
  final File caFile;
  final File keyFile;

  void delete() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Minimal TLS `wss` server standing in for the daemon.
class TlsStandInServer {
  TlsStandInServer(this._server, this._firstFrame);

  static Future<TlsStandInServer> start(TlsStandIn ca) async {
    final context = SecurityContext()
      ..usePrivateKeyBytes(ca.keyFile.readAsBytesSync())
      ..useCertificateChainBytes(ca.caFile.readAsBytesSync());
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final firstFrame = Completer<String>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((event) {
        if (event is String && !firstFrame.isCompleted) {
          firstFrame.complete(event);
        }
      });
    });
    return TlsStandInServer(server, firstFrame);
  }

  final HttpServer _server;
  final Completer<String> _firstFrame;

  Uri get uri => Uri.parse('wss://localhost:${_server.port}/ws');
  Future<String> get firstFrame => _firstFrame.future;

  Future<void> close() => _server.close(force: true);
}
