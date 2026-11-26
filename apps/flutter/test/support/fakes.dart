// SPDX-License-Identifier: GPL-3.0-or-later

// Shared in-memory doubles for the focused daemon-client / screen tests.
// No socket and no daemon: every frame and status is delivered explicitly.

import 'dart:async';
import 'dart:convert';

import 'package:anima_control/daemon_client/daemon_client.dart';

class ScriptedTransport implements DaemonTransport {
  ScriptedTransport({this.connectError});

  final Object? connectError;
  final StreamController<String> _messages = StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final List<String> sent = <String>[];
  bool connected = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect(Uri endpoint) async {
    if (connectError != null) throw connectError!;
    connected = true;
  }

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async => connected = false;

  @override
  void dispose() {
    _messages.close();
    _errors.close();
  }

  void receive(String frame) => _messages.add(frame);

  void fail(Object error) => _errors.add(error);
}

/// Screen-facing double. Overrides only the surface the screens consume so a
/// widget test can drive acks, deltas, statuses and settings deterministically.
class FakeChatClient extends DaemonClient {
  FakeChatClient() : super(transportFactory: () => throw StateError('no transport'));

  final StreamController<DaemonStatus> _status = StreamController<DaemonStatus>.broadcast();
  final List<void Function(GatewayEventFrame event)> listeners =
      <void Function(GatewayEventFrame event)>[];

  DaemonStatus _state = const DaemonStatus(state: DaemonConnectionState.disconnected);

  @override
  Stream<DaemonStatus> get statusStream => _status.stream;

  @override
  DaemonStatus get snapshot => _state;

  @override
  void Function() onEvent(void Function(GatewayEventFrame event) listener) {
    listeners.add(listener);
    return () => listeners.remove(listener);
  }

  /// Handler returning the RPC reply for each action. May throw.
  RpcReply Function(String action, Map<String, dynamic>? payload)? onCall;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    final handler = onCall;
    if (handler == null) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.notConnected,
        message: 'no RPC handler',
      );
    }
    return handler(action, payload);
  }

  List<String> cancelledSessions = <String>[];

  @override
  Future<bool> cancelChat(String sessionId) async {
    cancelledSessions.add(sessionId);
    return true;
  }

  Map<String, dynamic> settingsToLoad = const <String, dynamic>{};
  Completer<Map<String, dynamic>>? deferredSettings;
  int settingsLoads = 0;
  Map<String, dynamic>? lastSettingsWritten;
  void Function(String section, Map<String, dynamic> settings)? onSet;

  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    settingsLoads++;
    final handler = onCall;
    if (handler != null) {
      try {
        final reply = handler('settings.get', {'section': section});
        final data = reply.data;
        if (data is Map<String, dynamic>) {
          return data['settings'] as Map<String, dynamic>;
        }
        final decoded = jsonDecode(data as String);
        return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    final deferred = deferredSettings;
    if (deferred != null) return deferred.future;
    return settingsToLoad;
  }

  @override
  Future<bool> settingsSet(String section, Map<String, dynamic> settings) async {
    final setHandler = onSet;
    if (setHandler != null) {
      setHandler(section, settings);
    }
    lastSettingsWritten = settings;
    return true;
  }

  void emitEvent(GatewayEventFrame event) {
    for (final listener in listeners.toList()) {
      listener(event);
    }
  }

  void emitStatus(DaemonConnectionState state) {
    _state = DaemonStatus(state: state);
    _status.add(_state);
  }

  @override
  void dispose() {
    _status.close();
    super.dispose();
  }
}

GatewayEventFrame tokenDelta({
  String sessionId = 's1',
  String messageId = '',
  required String delta,
  bool isFinal = false,
  String? reason,
}) {
  final data = <String, dynamic>{
    'session_id': sessionId,
    'message_id': messageId,
    'delta': delta,
    'final': isFinal,
  };
  if (reason != null) data['reason'] = reason;
  return GatewayEventFrame(
    topic: EventTopic.tokenDelta,
    rawTopic: 'token.delta',
    data: data,
  );
}
