// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

/// Raised when a `wss://` endpoint is used but no usable CA certificate was
/// configured. Verification is never relaxed instead: a client that cannot
/// verify the daemon's locally minted CA must not connect at all.
class GatewayCaException implements Exception {
  const GatewayCaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Local/LAN WebSocket transport: `ws://127.0.0.1:6121/ws` on loopback,
/// `wss://…` beyond loopback (the daemon forces TLS for non-loopback binds).
///
/// The daemon mints its own CA (`GetGatewayConfig.caCertPath`), so a TLS
/// connection trusts exactly that PEM via [SecurityContext] — never the
/// platform store, and never with verification disabled.
///
/// TODO(airi-wxp.3.5): remote mobile transports are a SEAM, not hard-wired here.
/// Planned implementations of [DaemonTransport]:
///   * libp2p (peer identity replaces/augments the shared token),
///   * Cloudflare Tunnel (HTTPS/WSS tunnel to the desktop daemon),
///   * tunnel + libp2p.
/// A Termux-hosted daemon is another valid endpoint for this same interface.
/// There is deliberately NO embedded `flutter_rust_bridge` core and NO local
/// mobile daemon — the UI stays thin in every topology for battery life.
class DirectWebSocketTransport implements DaemonTransport {
  DirectWebSocketTransport({this.caCertPath});

  /// `caCertPath` from the daemon's `GetGatewayConfig` reply. Null on loopback
  /// (`ws://`) where no CA is needed.
  final String? caCertPath;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  bool _connected = false;

  /// First handshake failure seen on the stream; [connect] rethrows it typed.
  WebSocketChannelException? _handshakeFailure;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(Uri endpoint) async {
    await close();
    // Plain `ws://` (loopback) needs no CA. A remote `wss://` endpoint MUST
    // have the daemon-minted CA: without it a fallback to the default
    // platform-trusted channel could leak the auth token to an impostor.
    SecurityContext? context;
    if (endpoint.scheme == 'wss') {
      final pemPath = caCertPath;
      if (pemPath?.trim().isEmpty ?? true) {
        throw const GatewayCaException(
          'No CA certificate is configured for wss. Get the daemon CA path '
          'from GetGatewayConfig and retry.',
        );
      }
      context = gatewaySecurityContext(pemPath);
    }
    final channel = context == null
        ? WebSocketChannel.connect(endpoint)
        : IOWebSocketChannel.connect(
            endpoint,
            customClient: HttpClient(context: context)
              ..connectionTimeout = const Duration(seconds: 10),
          );
    _channel = channel;
    _subscription = channel.stream.listen(
      (event) {
        if (event is String) {
          if (!_messages.isClosed) _messages.add(event);
        } else {
          _errors.add(
            'Binary frame ignored: the gateway speaks JSON text frames only.',
          );
        }
      },
      onError: (Object error) {
        _connected = false;
        if (error is WebSocketChannelException &&
            error.inner is HandshakeException &&
            _handshakeFailure == null) {
          _handshakeFailure = error;
        }
        if (!_errors.isClosed) _errors.add(error);
      },
      onDone: () {
        _connected = false;
        if (!_errors.isClosed) _errors.add(const TransportClosed());
      },
    );

    // `connect` returns before the handshake finishes. Publishing connected
    // here would make the client send auth into a dead socket and report a
    // healthy status until the 5s auth timeout expires.
    try {
      await channel.ready;
    } on WebSocketChannelException catch (e) {
      if (e.inner is! HandshakeException) rethrow;
      _handshakeFailure ??= e;
    }
    // A locally minted CA the client does not trust is a pairing problem, not
    // a broken network: say so instead of "could not reach the daemon".
    final handshake = _handshakeFailure;
    if (handshake != null) {
      _handshakeFailure = null;
      final inner = handshake.inner;
      throw GatewayCaException(
        'The daemon\'s TLS certificate was not trusted. Re-check the CA '
        'certificate path from GetGatewayConfig (the handshake failed: '
        '${inner is HandshakeException ? inner.message : inner}).',
      );
    }
    if (!identical(_channel, channel)) return; // closed while awaiting ready
    _connected = true;
  }

  @override
  void send(String frame) {
    final channel = _channel;
    if (channel == null || !_connected) {
      throw StateError(
        'DirectWebSocketTransport.send called while not connected.',
      );
    }
    channel.sink.add(frame);
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _connected = false;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    close(); // ignore returned future: disposal is terminal
    _messages.close();
    _errors.close();
  }
}

/// Builds the TLS trust context for [pemPath], the daemon's minted CA.
/// Returns null when no CA is configured (loopback `ws://`).
/// Throws [GatewayCaException] when the CA is missing or unreadable.
SecurityContext? gatewaySecurityContext(String? pemPath) {
  if (pemPath == null || pemPath.trim().isEmpty) return null;
  final file = File(pemPath);
  if (!file.existsSync()) {
    throw GatewayCaException(
      'CA certificate not found at $pemPath. Copy it from the daemon host '
      '(GetGatewayConfig.caCertPath) and retry.',
    );
  }
  // Trust only the daemon-minted PEM: platform roots must not be able to
  // vouch for a remote `wss://` gateway.
  final SecurityContext context = SecurityContext(withTrustedRoots: false);
  try {
    context.setTrustedCertificatesBytes(file.readAsBytesSync());
  } on Object catch (e) {
    throw GatewayCaException(
      'CA certificate at $pemPath could not be read: $e',
    );
  }
  return context;
}
