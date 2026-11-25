// SPDX-License-Identifier: GPL-3.0-or-later

// Thin orchestration layer. The daemon is the ONLY owner of core state; this
// client holds view state (connection status, last health snapshot) and nothing
// else. See docs/design-daemon-client.md decision 1 and
// docs/design-flutter-godot-pivot.md invariant 1.

import 'dart:async';
import 'dart:convert';

import '../connection/connection_settings.dart';
import 'direct_websocket_transport.dart';
import 'protocol.dart';
import 'reconnect_policy.dart';
import 'rpc.dart';
import 'transport.dart';

export 'protocol.dart'
    show
        EventTopic,
        GatewayEventFrame,
        ServerFrame,
        ServerFrameKind,
        encodeAuthFrame,
        encodeModuleAuthFrame,
        encodePingFrame,
        kProtocolId;
export 'reconnect_policy.dart' show ReconnectPolicy;
export 'rpc.dart' show CoreStatus, RpcError, RpcReply, RpcRequest;
export 'transport.dart' show DaemonTransport, DaemonTransportFactory, TransportClosed;

enum DaemonConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  failed,
}

enum DaemonFailureKind {
  none,
  transport,
  auth,
  timeout,
  rpc,
  protocol,
  notConnected,
}

class DaemonClientException implements Exception {
  const DaemonClientException({
    required this.kind,
    required this.message,
    this.code,
  });

  final DaemonFailureKind kind;
  final String message;
  final String? code;

  @override
  String toString() => 'DaemonClientException(${kind.name}): $message';
}

/// Immutable view state published to the UI after every transition.
class DaemonStatus {
  const DaemonStatus({
    required this.state,
    this.core,
    this.error,
    this.host,
    this.attempt = 0,
  });

  final DaemonConnectionState state;
  final CoreStatus? core;
  final DaemonClientException? error;
  final String? host;
  final int attempt;

  bool get isConnected => state == DaemonConnectionState.connected;
}

/// Connects, authenticates, correlates RPC replies, probes `core.status`, and
/// reconnects with bounded backoff. Transports are injected so every behaviour
/// can be tested with an in-memory fake — no live daemon required.
class DaemonClient {
  DaemonClient({
    DaemonTransportFactory? transportFactory,
    this.reconnectPolicy = const ReconnectPolicy(),
    this.authTimeout = const Duration(seconds: 5),
    this.rpcTimeout = const Duration(seconds: 15),
    this.heartbeatInterval = const Duration(seconds: 30),
  }) : _transportFactory = transportFactory ?? (() => DirectWebSocketTransport());

  final DaemonTransportFactory _transportFactory;
  final ReconnectPolicy reconnectPolicy;
  final Duration authTimeout;
  final Duration rpcTimeout;

  /// How often an authenticated client pings the gateway. The daemon reaps a
  /// peer with no inbound frame for `DEAD_PEER_TTL` (75 s, ~2× the SDK's 30 s
  /// cadence), so this must stay well under that TTL.
  final Duration heartbeatInterval;

  DaemonTransport? _transport;
  StreamSubscription<String>? _messageSub;
  StreamSubscription<Object>? _errorSub;
  ConnectionSettings? _settings;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  bool _wantsConnection = false;
  bool _authenticated = false;
  int _nextId = 0;
  int _attempt = 0;
  final Map<int, Completer<RpcReply>> _pending = <int, Completer<RpcReply>>{};
  Completer<void>? _authCompleter;
  final StreamController<DaemonStatus> _status = StreamController<DaemonStatus>.broadcast();

  DaemonStatus _snapshot = const DaemonStatus(state: DaemonConnectionState.disconnected);

  DaemonStatus get snapshot => _snapshot;
  Stream<DaemonStatus> get statusStream => _status.stream;

  /// Typed event listeners. The client owns the `token.delta` subscription and
  /// re-establishes it after every authenticated socket, so a daemon reconnect
  /// does not leave the chat surface deaf. Multiple screens may listen at once;
  /// callers must invoke the returned handle in `dispose` so a disposed screen
  /// does not consume events (the old single slot was silently overwritten).
  final Set<void Function(GatewayEventFrame event)> _eventSubscribers =
      <void Function(GatewayEventFrame event)>{};

  /// Registers [listener] and returns its unsubscribe handle.
  void Function() onEvent(void Function(GatewayEventFrame event) listener) {
    _eventSubscribers.add(listener);
    return () => _eventSubscribers.remove(listener);
  }

  void _emit({
    DaemonConnectionState? state,
    CoreStatus? core,
    DaemonClientException? error,
    int? attempt,
    bool clearCore = false,
    bool clearError = false,
  }) {
    _snapshot = DaemonStatus(
      state: state ?? _snapshot.state,
      core: clearCore ? null : core ?? _snapshot.core,
      error: clearError ? null : error ?? _snapshot.error,
      // Settings are cleared on disconnect, so the host clears with them.
      host: _settings?.host,
      attempt: attempt ?? _snapshot.attempt,
    );
    if (!_status.isClosed) _status.add(_snapshot);
  }

  /// Validate then open a connection. The first frame sent is always auth.
  Future<void> connect(ConnectionSettings settings) async {
    final errors = settings.validationErrors();
    if (errors.isNotEmpty) {
      throw DaemonClientException(kind: DaemonFailureKind.protocol, message: errors.first);
    }
    _wantsConnection = true;
    _settings = settings;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    await _open();
  }
  /// Instance variant: parse [uri] into [ConnectionSettings] and delegate to
  /// [connect]. Named to avoid the Dart static/instance name collision on
  /// `connect`.
  Future<void> connectUri(String uri, String token) async {
    await connect(_settingsFromUri(uri, token));
  }

  /// Static convenience factory: connect to [uri] with [token] and return an
  /// authenticated client. Dart forbids a static `connect` sharing a name
  /// with the instance `connect(ConnectionSettings)`, so this is named
  /// `fromUri` (see docs/daemon-client-connection.md).
  static Future<DaemonClient> fromUri(String uri, String token) async {
    final client = DaemonClient();
    await client.connectUri(uri, token);
    return client;
  }

  static ConnectionSettings _settingsFromUri(String uri, String token) {
    final parsed = Uri.parse(uri);
    final scheme = parsed.scheme.isEmpty ? ConnectionSettings.defaultScheme : parsed.scheme;
    final host = parsed.host.isEmpty ? ConnectionSettings.defaultHost : parsed.host;
    final port = parsed.hasPort ? parsed.port : ConnectionSettings.defaultPort;
    final path = parsed.path.isEmpty ? ConnectionSettings.defaultPath : parsed.path;
    return ConnectionSettings(
      host: host,
      port: port,
      scheme: scheme,
      path: path,
      authToken: token,
    );
  }


  Future<void> _open() async {
    final settings = _settings;
    if (settings == null || !_wantsConnection) return;

    _authenticated = false;
    _emit(state: DaemonConnectionState.connecting, clearCore: true, clearError: true, attempt: 0);
    await _teardownTransport();

    final transport = _transportFactory();
    _transport = transport;
    _messageSub = transport.messages.listen(
      _onMessage,
      onError: _onTransportSignal,
      onDone: () => _onTransportSignal(const TransportClosed()),
    );
    _errorSub = transport.errors.listen(_onTransportSignal);

    try {
      await transport.connect(settings.uri);
    } catch (e) {
      _onTransportSignal(DaemonClientException(
        kind: DaemonFailureKind.transport,
        message: 'Could not open WebSocket: $e',
      ));
      return;
    }

    // First message MUST be auth; the gateway closes with 1008 otherwise.
    _emit(state: DaemonConnectionState.authenticating);
    final auth = Completer<void>();
    _authCompleter = auth;
    transport.send(encodeAuthFrame(settings.authToken));

    try {
      await auth.future.timeout(
        authTimeout,
        onTimeout: () => throw DaemonClientException(
          kind: DaemonFailureKind.timeout,
          message: 'Authentication timed out after ${authTimeout.inSeconds}s.',
        ),
      );
    } catch (e) {
      _authCompleter = null;
      if (!_wantsConnection) return;
      final failure = e is DaemonClientException
          ? e
          : DaemonClientException(kind: DaemonFailureKind.protocol, message: 'Authentication failed: $e');
      _emit(state: DaemonConnectionState.failed, error: failure);
      // Auth/config failures are terminal: retrying a bad token is just noise.
      return;
    }

    if (!_wantsConnection) return;
    _authCompleter = null;
    _authenticated = true;
    _emit(state: DaemonConnectionState.connected, clearError: true);
    _startHeartbeat();

    // Best-effort health probe: a degraded core is surfaced as an error on an
    // otherwise connected snapshot, never as a dropped connection.
    try {
      final core = await probeCoreStatus();
      if (_wantsConnection) _emit(core: core);
    } on DaemonClientException catch (e) {
      if (_wantsConnection) _emit(error: e);
    }

    // Subscriptions are per-socket: a reconnect lands on a fresh peer with no
    // topics, so re-opt in to token.delta on every authenticated connection.
    unawaited(_subscribeTokenDeltas());
  }

  /// Best-effort re-subscription after auth (initial connect or reconnect).
  /// A daemon without event support degrades to an error on the status stream;
  /// chat itself remains usable.
  Future<void> _subscribeTokenDeltas() async {
    try {
      final reply = await call('event.subscribe', payload: <String, dynamic>{
        'topics': <String>['token.delta'],
      });
      if (!reply.ok && _wantsConnection) {
        _emit(error: DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: reply.error?.message ?? 'event.subscribe failed.',
          code: reply.error?.code,
        ));
      }
    } on DaemonClientException catch (e) {
      if (_wantsConnection) _emit(error: e);
    }
  }

  /// Pings the gateway on [heartbeatInterval] while authenticated. The daemon
  /// closes a peer that sends nothing for `DEAD_PEER_TTL` (75 s), so an idle
  /// client would otherwise be reaped mid-session.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      final transport = _transport;
      if (!_authenticated || !_wantsConnection || transport == null) return;
      try {
        transport.send(encodePingFrame());
      } on Object {
        // A send failure surfaces through the transport's error/done stream,
        // which drives the reconnect path; nothing to do here.
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _onMessage(String text) {
    final frame = ServerFrame.parse(text);
    switch (frame.kind) {
      case ServerFrameKind.authOk:
      case ServerFrameKind.authenticated:
        if (!_authenticated) _completeAuth();
        break;
      case ServerFrameKind.rpc:
        final reply = frame.reply;
        if (reply != null) _deliver(reply);
        break;
      case ServerFrameKind.error:
        final raw = frame.error;
        final failure = DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: raw?.message ?? 'Gateway reported an error.',
          code: raw?.code,
        );
        if (!_authenticated) {
          _failAuth(failure);
        } else {
          _emit(error: failure);
        }
        _failAllPending(failure);
        break;
      case ServerFrameKind.event:
        // Topic is typed (EventTopic) and unknown topics decode to `unknown`
        // rather than throwing. Callers subscribe through `event.subscribe`
        // (chat_screen.dart) and consume payloads via onEvent listeners.
        final event = frame.event;
        if (event != null) {
          // Snapshot: a listener may unsubscribe while we dispatch.
          for (final listener in _eventSubscribers.toList()) {
            listener(event);
          }
        }
        break;
      case ServerFrameKind.pong:
      case ServerFrameKind.heartbeat:
      case ServerFrameKind.unknown:
        break;
    }
  }

  void _completeAuth() {
    final pendingAuth = _authCompleter;
    _authCompleter = null;
    if (pendingAuth != null && !pendingAuth.isCompleted) pendingAuth.complete();
  }

  void _failAuth(Object error) {
    final pendingAuth = _authCompleter;
    _authCompleter = null;
    if (pendingAuth != null && !pendingAuth.isCompleted) pendingAuth.completeError(error);
  }

  void _deliver(RpcReply reply) {
    final id = reply.id;
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete(reply);
  }

  void _failAllPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void _onTransportSignal(Object signal) {
    final failure = signal is DaemonClientException
        ? signal
        : DaemonClientException(
            kind: DaemonFailureKind.transport,
            message: signal is TransportClosed
                ? 'Gateway connection closed.'
                : 'Transport error: $signal',
          );

    if (!_authenticated) {
      _failAuth(failure);
      if (!_wantsConnection) return;
      // A transport failure before auth is still a transient socket problem:
      // retry under the same bounded policy used after auth. A genuine auth
      // rejection arrives as an error frame, not here, and stays terminal.
      if (failure.kind == DaemonFailureKind.transport) {
        _emit(state: DaemonConnectionState.reconnecting, error: failure);
        _scheduleReconnect();
        return;
      }
      _emit(state: DaemonConnectionState.failed, error: failure);
      return;
    }

    _failAllPending(failure);
    _authenticated = false;
    if (!_wantsConnection) {
      _emit(state: DaemonConnectionState.disconnected, clearError: true);
      return;
    }
    _emit(state: DaemonConnectionState.reconnecting, error: failure);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!_wantsConnection) return;
    final next = _attempt + 1;
    if (!reconnectPolicy.shouldAttempt(next)) {
      _emit(state: DaemonConnectionState.failed, attempt: _attempt);
      return;
    }
    _attempt = next;
    final delay = reconnectPolicy.delayForAttempt(next);
    _emit(state: DaemonConnectionState.reconnecting, attempt: next);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_wantsConnection) unawaited(_open());
    });
  }

  /// Typed RPC with id correlation and a per-call timeout.
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    final transport = _transport;
    if (transport == null || !_authenticated || _snapshot.state != DaemonConnectionState.connected) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.notConnected,
        message: 'Not connected to the daemon.',
      );
    }
    final id = ++_nextId;
    final completer = Completer<RpcReply>();
    _pending[id] = completer;
    try {
      try {
        transport.send(RpcRequest(action: action, payload: payload, id: id).toWire());
      } catch (e) {
        throw DaemonClientException(
          kind: DaemonFailureKind.transport,
          message: 'Could not send RPC "$action": $e',
        );
      }
      return await completer.future.timeout(
        rpcTimeout,
        onTimeout: () => throw DaemonClientException(
          kind: DaemonFailureKind.timeout,
          message: 'RPC "$action" timed out after ${rpcTimeout.inSeconds}s.',
        ),
      );
    } finally {
      _pending.remove(id);
    }
  }

  /// Read-only health probe. Never writes daemon state.
  Future<CoreStatus> probeCoreStatus() async {
    final reply = await call('core.status');
    if (!reply.ok) {
      final error = reply.error;
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: error?.message ?? 'core.status failed.',
        code: error?.code,
      );
    }
    final data = reply.data;
    if (data is! Map<String, dynamic>) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'core.status reply did not contain an object payload.',
      );
    }
    return CoreStatus.fromJson(data);
  }

  // --- Typed wrappers for the daemon's action verbs -------------------------
  // Each maps 1:1 to a handler registered in crates/anima-daemon/src/gateway.rs.
  // A failed rpc reply is promoted to a DaemonClientException so callers do not
  // have to repeat error handling.

  Future<RpcReply> _callOk(String action, {Map<String, dynamic>? payload}) async {
    final reply = await call(action, payload: payload);
    if (!reply.ok) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: reply.error?.message ?? '$action failed.',
        code: reply.error?.code,
      );
    }
    return reply;
  }

  static List<Map<String, dynamic>> _objects(RpcReply reply, String key) {
    final data = reply.data;
    if (data is! Map<String, dynamic>) return const <Map<String, dynamic>>[];
    final raw = data[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  /// Stop an in-flight chat turn (`chat.cancel`).
  Future<bool> cancelChat(String sessionId) async {
    final reply = await _callOk('chat.cancel', payload: <String, dynamic>{
      'session_id': sessionId,
    });
    final data = reply.data;
    return data is Map<String, dynamic> && data['cancelled'] == true;
  }

  /// Prior persisted turns of a session (`chat.history`). An unregistered verb
  /// is promoted to a DaemonClientException; an empty history yields [].
  Future<List<Map<String, dynamic>>> chatHistory(String sessionId) async {
    final reply = await _callOk('chat.history', payload: <String, dynamic>{
      'session_id': sessionId,
    });
    final data = reply.data;
    if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    // Tolerate a wrapped `{ "messages": [...] }` reply as well as a bare array.
    if (data is Map<String, dynamic> && data['messages'] is List) {
      return (data['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  /// Read a typed settings section (`settings.get`). The daemon carries the
  /// section as a JSON string; decode it into a map for callers.
  Future<Map<String, dynamic>> settingsGet(String section) async {
    final reply = await _callOk('settings.get', payload: <String, dynamic>{
      'section': section,
    });
    final data = reply.data;
    if (data is! Map<String, dynamic>) return const <String, dynamic>{};
    final raw = data['settings'];
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        return const <String, dynamic>{};
      }
    }
    if (raw is Map<String, dynamic>) return raw;
    return const <String, dynamic>{};
  }

  /// Write a whole typed settings section (`settings.set`). Returns the
  /// daemon's `ok` flag; a failed write is promoted to an exception by _callOk.
  Future<bool> settingsSet(String section, Map<String, dynamic> settings) async {
    final reply = await _callOk('settings.set', payload: <String, dynamic>{
      'section': section,
      'settings': settings,
    });
    final data = reply.data;
    return data is Map<String, dynamic> && data['ok'] == true;
  }

  /// Recent short-term-memory summaries (`stmm.list`).
  Future<List<Map<String, dynamic>>> stmmList({int limit = 50}) async {
    final reply = await _callOk('stmm.list', payload: <String, dynamic>{
      'limit': limit,
    });
    return _objects(reply, 'summaries');
  }

  /// Prune/rebuild short-term memory (`stmm.rebuild`).
  Future<void> stmmRebuild() async {
    await _callOk('stmm.rebuild');
  }

  /// Append a long-term journal entry (`journal.append`).
  Future<String> journalAppend(String content, {String kind = 'note'}) async {
    final reply = await _callOk('journal.append', payload: <String, dynamic>{
      'content': content,
      'kind': kind,
    });
    final data = reply.data;
    return (data is Map<String, dynamic> ? data['id'] : null)?.toString() ?? '';
  }

  /// Search the long-term journal (`journal.search`).
  Future<List<Map<String, dynamic>>> journalSearch({
    String query = '',
    int limit = 50,
  }) async {
    final reply = await _callOk('journal.search', payload: <String, dynamic>{
      'query': query,
      'limit': limit,
    });
    return _objects(reply, 'entries');
  }

  /// Whether retrieval/augmented memory is available (`retrieval.status`).
  Future<bool> retrievalStatus() async {
    final reply = await _callOk('retrieval.status');
    final data = reply.data;
    return data is Map<String, dynamic> && data['available'] == true;
  }

  /// All character cards (`cards.list`).
  Future<List<Map<String, dynamic>>> cardsList() async {
    final reply = await _callOk('cards.list');
    return _objects(reply, 'cards');
  }

  /// One character card, or `null` when the daemon has no such card (`cards.get`).
  Future<Map<String, dynamic>?> cardsGet(String id) async {
    final reply = await _callOk('cards.get', payload: <String, dynamic>{
      'id': id,
    });
    final data = reply.data;
    if (data is! Map<String, dynamic>) return null;
    final card = data['card'];
    return card is Map<String, dynamic> ? card : null;
  }

  /// Daemon-owned local metadata (liked/bookmarked) for one card
  /// (`cards.metadata`).
  Future<({String id, bool liked, bool bookmarked})> cardsMetadata(
    String id,
  ) async {
    final reply = await _callOk(
      'cards.metadata',
      payload: <String, dynamic>{'id': id},
    );
    return _cardMetadata(reply);
  }

  /// Explicitly set both local metadata flags for one card
  /// (`cards.metadata.set`). Both flags are always sent: the daemon never
  /// flips a bit on its own, so a stale client cannot cause an unintended
  /// toggle.
  Future<({String id, bool liked, bool bookmarked})> cardsMetadataSet(
    String id, {
    required bool liked,
    required bool bookmarked,
  }) async {
    final reply = await _callOk(
      'cards.metadata.set',
      payload: <String, dynamic>{
        'id': id,
        'liked': liked,
        'bookmarked': bookmarked,
      },
    );
    return _cardMetadata(reply);
  }

  static ({String id, bool liked, bool bookmarked}) _cardMetadata(
    RpcReply reply,
  ) {
    final data = reply.data;
    if (data is! Map<String, dynamic>) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid cards.metadata reply.',
      );
    }
    final id = data['id'];
    final liked = data['liked'];
    final bookmarked = data['bookmarked'];
    if (id is! String || liked is! bool || bookmarked is! bool) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid cards.metadata reply.',
      );
    }
    return (id: id, liked: liked, bookmarked: bookmarked);
  }

  /// Import a character card (`cards.import`).
  Future<void> cardsImport(Map<String, dynamic> card) async {
    await _callOk('cards.import', payload: <String, dynamic>{
      'card': card,
    });
  }

  /// All chat sessions (`sessions.list`).
  Future<List<Map<String, dynamic>>> sessionsList() async {
    final reply = await _callOk('sessions.list');
    return _objects(reply, 'sessions');
  }

  /// JSONL export of one chat session (`sessions.export`).
  Future<String> sessionsExport(String sessionId) async {
    final reply = await _callOk('sessions.export', payload: <String, dynamic>{
      'session_id': sessionId,
    });
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['jsonl'] is! String) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid sessions.export reply.',
      );
    }
    return data['jsonl'] as String;
  }

  /// Explicit shutdown: no reconnect is scheduled.
  Future<void> disconnect() async {
    _wantsConnection = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _authenticated = false;
    _failAuth(const DaemonClientException(kind: DaemonFailureKind.notConnected, message: 'Disconnected.'));
    _failAllPending(const DaemonClientException(kind: DaemonFailureKind.notConnected, message: 'Disconnected.'));
    await _teardownTransport();
    _settings = null;
    _emit(state: DaemonConnectionState.disconnected, clearCore: true, clearError: true, attempt: 0);
  }

  Future<void> _teardownTransport() async {
    _stopHeartbeat();
    await _messageSub?.cancel();
    _messageSub = null;
    await _errorSub?.cancel();
    _errorSub = null;
    final transport = _transport;
    _transport = null;
    if (transport != null) await transport.close();
  }

  void dispose() {
    _wantsConnection = false;
    _eventSubscribers.clear();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _failAllPending(const DaemonClientException(kind: DaemonFailureKind.notConnected, message: 'Client disposed.'));
    final transport = _transport;
    _teardownTransport().whenComplete(() => transport?.dispose());
    _status.close();
  }
}
