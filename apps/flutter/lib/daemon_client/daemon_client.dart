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
export 'transport.dart'
    show DaemonTransport, DaemonTransportFactory, TransportClosed;

class CardWriteResult {
  const CardWriteResult({
    required this.id,
    required this.name,
    this.updated = false,
  });
  final String id;
  final String name;
  final bool updated;
}

class CardImportResult {
  const CardImportResult({
    required this.id,
    required this.name,
    this.renamed = false,
  });
  final String id;
  final String name;
  final bool renamed;
}


/// Metadata of `vault.archive.collect`: a base64 ZIP and the domains the daemon
/// actually included. Never contains provider credentials.
class VaultArchive {
  const VaultArchive({
    required this.archive,
    required this.bytes,
    required this.domains,
  });
  final String archive;
  final int bytes;
  final List<String> domains;
}

/// Metadata-only report from `vault.archive.inspect`. No entry contents are
/// decoded into this object.
class VaultArchiveInspection {
  const VaultArchiveInspection({
    required this.format,
    required this.version,
    this.createdAt,
    required this.includesSecrets,
    required this.domains,
    required this.sessionCount,
    required this.messageCount,
    required this.companionCount,
  });
  final String format;
  final int version;
  final int? createdAt;
  final bool includesSecrets;
  final List<Map<String, dynamic>> domains;
  final int sessionCount;
  final int messageCount;

  /// Count only: companion names are user data and are not shown by the UI.
  final int companionCount;
}

/// Counts returned by `vault.archive.apply`.
class VaultArchiveApplyResult {
  const VaultArchiveApplyResult({
    required this.sessionsInserted,
    required this.sessionsSkipped,
    required this.messagesInserted,
    required this.messagesSkipped,
    required this.summariesInserted,
    required this.journalEntriesInserted,
    required this.applied,
    required this.notApplied,
  });
  final int sessionsInserted;
  final int sessionsSkipped;
  final int messagesInserted;
  final int messagesSkipped;
  final int summariesInserted;
  final int journalEntriesInserted;
  final List<String> applied;
  final List<String> notApplied;
}

/// Counts returned by `sessions.media.scrub`.
class SessionMediaScrubResult {
  const SessionMediaScrubResult({
    required this.imagesFound,
    required this.bytesExtracted,
    required this.sessionsScanned,
    this.backupPath,
  });
  final int imagesFound;
  final int bytesExtracted;
  final int sessionsScanned;
  final String? backupPath;
}
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
    this.caAwareTransportFactory,
    this.reconnectPolicy = const ReconnectPolicy(),
    this.authTimeout = const Duration(seconds: 5),
    this.rpcTimeout = const Duration(seconds: 15),
    this.heartbeatInterval = const Duration(seconds: 30),
  }) {
    final injectedFactory = transportFactory;
    _transportFactory =
        injectedFactory ??
        (() => DirectWebSocketTransport(caCertPath: _caCertPath));
  }

  late final DaemonTransportFactory _transportFactory;
  final CaAwareDaemonTransportFactory? caAwareTransportFactory;
  String? _caCertPath;
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
  final StreamController<DaemonStatus> _status =
      StreamController<DaemonStatus>.broadcast();

  DaemonStatus _snapshot = const DaemonStatus(
    state: DaemonConnectionState.disconnected,
  );

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
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: errors.first,
      );
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
  /// `fromUri`.
  static Future<DaemonClient> fromUri(String uri, String token) async {
    final client = DaemonClient();
    await client.connectUri(uri, token);
    return client;
  }

  static ConnectionSettings _settingsFromUri(String uri, String token) {
    final parsed = Uri.parse(uri);
    final scheme = parsed.scheme.isEmpty
        ? ConnectionSettings.defaultScheme
        : parsed.scheme;
    final host = parsed.host.isEmpty
        ? ConnectionSettings.defaultHost
        : parsed.host;
    final port = parsed.hasPort ? parsed.port : ConnectionSettings.defaultPort;
    final path = parsed.path.isEmpty
        ? ConnectionSettings.defaultPath
        : parsed.path;
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
    _emit(
      state: DaemonConnectionState.connecting,
      clearCore: true,
      clearError: true,
      attempt: 0,
    );
    _caCertPath = settings.caCertPath;
    await _teardownTransport();

    final transport = caAwareTransportFactory != null
        ? caAwareTransportFactory!(caCertPath: _caCertPath)
        : _transportFactory();
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
      _onTransportSignal(
        DaemonClientException(
          kind: DaemonFailureKind.transport,
          message: 'Could not open WebSocket: $e',
        ),
      );
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
          : DaemonClientException(
              kind: DaemonFailureKind.protocol,
              message: 'Authentication failed: $e',
            );
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
      final reply = await call(
        'event.subscribe',
        payload: <String, dynamic>{
          'topics': <String>['token.delta'],
        },
      );
      if (!reply.ok && _wantsConnection) {
        _emit(
          error: DaemonClientException(
            kind: DaemonFailureKind.rpc,
            message: reply.error?.message ?? 'event.subscribe failed.',
            code: reply.error?.code,
          ),
        );
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
    if (pendingAuth != null && !pendingAuth.isCompleted)
      pendingAuth.completeError(error);
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
    if (transport == null ||
        !_authenticated ||
        _snapshot.state != DaemonConnectionState.connected) {
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
        transport.send(
          RpcRequest(action: action, payload: payload, id: id).toWire(),
        );
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

  Future<RpcReply> _callOk(
    String action, {
    Map<String, dynamic>? payload,
  }) async {
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

  static Object? _field(RpcReply reply, String key) {
    final data = reply.data;
    if (data is! Map<String, dynamic>) return null;
    return data[key];
  }

  static String _requiredString(RpcReply reply, String key) {
    final v = _field(reply, key);
    if (v is! String) {
      final action = reply.action.isEmpty ? key : reply.action;
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid $key in $action reply.',
      );
    }
    return v;
  }

  static int _requiredInt(RpcReply reply, String key) {
    final v = _field(reply, key);
    if (v is int || (v is num && v.isFinite && v.truncate() == v)) {
      return (v as num).toInt();
    }
    throw DaemonClientException(
      kind: DaemonFailureKind.protocol,
      message: 'Invalid $key in ${reply.action} reply.',
    );
  }

  static bool _requiredBool(RpcReply reply, String key) {
    final v = _field(reply, key);
    if (v is! bool) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid $key in ${reply.action} reply.',
      );
    }
    return v;
  }

  static List<String> _strings(RpcReply reply, String key) {
    final raw = _field(reply, key);
    if (raw is! List || raw.any((item) => item is! String)) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid $key in ${reply.action} reply.',
      );
    }
    return raw.cast<String>().toList(growable: false);
  }

  static List<Map<String, dynamic>> _requiredObjects(RpcReply reply, String key) {
    final raw = _field(reply, key);
    if (raw is! List || raw.any((item) => item is! Map<String, dynamic>)) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid $key in ${reply.action} reply.',
      );
    }
    return raw.cast<Map<String, dynamic>>().toList(growable: false);
  }

  /// Stop an in-flight chat turn (`chat.cancel`).
  Future<bool> cancelChat(String sessionId) async {
    final reply = await _callOk(
      'chat.cancel',
      payload: <String, dynamic>{'session_id': sessionId},
    );
    final data = reply.data;
    return data is Map<String, dynamic> && data['cancelled'] == true;
  }

  /// Prior persisted turns of a session (`chat.history`). An unregistered verb
  /// is promoted to a DaemonClientException; an empty history yields [].
  Future<List<Map<String, dynamic>>> chatHistory(String sessionId) async {
    final reply = await _callOk(
      'chat.history',
      payload: <String, dynamic>{'session_id': sessionId},
    );
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
    final reply = await _callOk(
      'settings.get',
      payload: <String, dynamic>{'section': section},
    );
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
  Future<bool> settingsSet(
    String section,
    Map<String, dynamic> settings,
  ) async {
    final reply = await _callOk(
      'settings.set',
      payload: <String, dynamic>{'section': section, 'settings': settings},
    );
    final data = reply.data;
    return data is Map<String, dynamic> && data['ok'] == true;
  }

  /// List models for a provider (`providers.models`).
  Future<(String providerId, List<Map<String, dynamic>> models)> providersModels(
    String providerId,
  ) async {
    final reply = await _callOk(
      'providers.models',
      payload: <String, dynamic>{'providerId': providerId},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic>) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'providers.models returned invalid shape',
      );
    }
    final id = data['providerId'] as String?;
    final models = data['models'];
    if (id == null || id.isEmpty || models is! List) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'providers.models returned invalid shape',
      );
    }
    return (
      id,
      models.whereType<Map<String, dynamic>>().toList(),
    );
  }

  /// List provider metadata (`providers.list`). The daemon never puts
  /// credentials on the wire, so each row is allowlisted metadata only.
  Future<List<Map<String, dynamic>>> providersList() async {
    final reply = await _callOk('providers.list');
    return _objects(reply, 'providers');
  }

  /// Create or update a provider (`providers.save`). Returns the daemon's
  /// canonical provider id. The payload is forwarded unchanged so callers keep
  /// full control over credential rotation (`apiKey` / `rotateSecrets`).
  Future<String> providersSave(Map<String, dynamic> payload) async {
    final reply = await _callOk('providers.save', payload: payload);
    return _requiredString(reply, 'id');
  }

  /// Delete a provider (`providers.delete`). Returns whether a row was removed;
  /// a missing id is `false`, not an error, so a stale row is an idempotent
  /// delete.
  Future<bool> providersDelete(String id) async {
    final reply = await _callOk(
      'providers.delete',
      payload: <String, dynamic>{'id': id},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['deleted'] is! bool) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid providers.delete reply.',
      );
    }
    return data['deleted'] as bool;
  }

  /// Recent short-term-memory summaries (`stmm.list`).
  Future<List<Map<String, dynamic>>> stmmList({int limit = 50}) async {
    final reply = await _callOk(
      'stmm.list',
      payload: <String, dynamic>{'limit': limit},
    );
    return _objects(reply, 'summaries');
  }

  /// Prune/rebuild short-term memory (`stmm.rebuild`).
  Future<void> stmmRebuild() async {
    await _callOk('stmm.rebuild');
  }

  /// Append a long-term journal entry (`journal.append`).
  Future<String> journalAppend(String content, {String kind = 'note'}) async {
    final reply = await _callOk(
      'journal.append',
      payload: <String, dynamic>{'content': content, 'kind': kind},
    );
    final data = reply.data;
    return (data is Map<String, dynamic> ? data['id'] : null)?.toString() ?? '';
  }

  /// Search the long-term journal (`journal.search`).
  Future<List<Map<String, dynamic>>> journalSearch({
    String query = '',
    int limit = 50,
  }) async {
    final reply = await _callOk(
      'journal.search',
      payload: <String, dynamic>{'query': query, 'limit': limit},
    );
    return _objects(reply, 'entries');
  }

  /// Whether retrieval/augmented memory is available (`retrieval.status`).
  Future<bool> retrievalStatus() async {
    final reply = await _callOk('retrieval.status');
    final data = reply.data;
    return data is Map<String, dynamic> && data['available'] == true;
  }

  /// Typed `vault.status` payload (availability flag plus vault statistics), or
  /// `null` when the daemon replies without an object payload. Mirrors
  /// [`retrievalStatus`] as a thin wrapper over the raw verb.
  Future<Map<String, dynamic>?> vaultStatus() async {
    final reply = await _callOk('vault.status');
    final data = reply.data;
    return data is Map<String, dynamic> ? data : null;
  }

  /// Content domains the gateway accepts for a vault archive. `providers`
  /// carries API credentials and must never be sent over this wire.
  static const Set<String> vaultArchiveDomains = <String>{
    'characters',
    'chats',
    'memory',
    'backgrounds',
  };

  /// Collect a ZIP archive of the selected vault domains
  /// (`vault.archive.collect`). The reply carries base64 bytes; the daemon
  /// itself refuses unknown domains, and the client rejects them before the
  /// request reaches the socket.
  Future<VaultArchive> vaultArchiveCollect(List<String> domains) async {
    if (domains.isEmpty || domains.any((d) => !vaultArchiveDomains.contains(d))) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Unsupported vault archive domains.',
      );
    }
    final reply = await _callOk(
      'vault.archive.collect',
      payload: <String, dynamic>{'domains': domains},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['archive'] is! String) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid vault.archive.collect reply.',
      );
    }
    return VaultArchive(
      archive: data['archive'] as String,
      bytes: _requiredInt(reply, 'bytes'),
      domains: _strings(reply, 'domains'),
    );
  }

  /// Inspect an archive without decoding its contents (`vault.archive.inspect`).
  /// Companions are reduced to a count: names are user data and are never
  /// rendered by the UI.
  Future<VaultArchiveInspection> vaultArchiveInspect(String archive) async {
    final reply = await _callOk(
      'vault.archive.inspect',
      payload: <String, dynamic>{'archive': archive},
    );
    final rawNames = _field(reply, 'companionNames');
    if (rawNames is! List || rawNames.any((name) => name is! String)) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid companionNames in ${reply.action} reply.',
      );
    }
    final createdAt = _field(reply, 'createdAt');
    if (createdAt != null &&
        !(createdAt is num && createdAt.isFinite && createdAt.truncate() == createdAt)) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid createdAt in ${reply.action} reply.',
      );
    }
    return VaultArchiveInspection(
      format: _requiredString(reply, 'format'),
      version: _requiredInt(reply, 'version'),
      createdAt: (createdAt as num?)?.toInt(),
      includesSecrets: _requiredBool(reply, 'includesSecrets'),
      domains: _requiredObjects(reply, 'domains'),
      sessionCount: _requiredInt(reply, 'sessionCount'),
      messageCount: _requiredInt(reply, 'messageCount'),
      companionCount: rawNames.length,
    );
  }

  /// Apply a verified, secret-free archive (`vault.archive.apply`). This verb
  /// is action-gated on the daemon; a denial is promoted to an exception.
  Future<VaultArchiveApplyResult> vaultArchiveApply(String archive) async {
    final reply = await _callOk(
      'vault.archive.apply',
      payload: <String, dynamic>{'archive': archive},
    );
    return VaultArchiveApplyResult(
      sessionsInserted: _requiredInt(reply, 'sessionsInserted'),
      sessionsSkipped: _requiredInt(reply, 'sessionsSkipped'),
      messagesInserted: _requiredInt(reply, 'messagesInserted'),
      messagesSkipped: _requiredInt(reply, 'messagesSkipped'),
      summariesInserted: _requiredInt(reply, 'summariesInserted'),
      journalEntriesInserted: _requiredInt(reply, 'journalEntriesInserted'),
      applied: _strings(reply, 'applied'),
      notApplied: _strings(reply, 'notApplied'),
    );
  }

  /// Extract inline media and scrub it from messages (`sessions.media.scrub`).
  /// A pre-scrub backup is written only when [createBackup] is true.
  Future<SessionMediaScrubResult> sessionsMediaScrub({
    required bool createBackup,
  }) async {
    final reply = await _callOk(
      'sessions.media.scrub',
      payload: <String, dynamic>{'createBackup': createBackup},
    );
    final backupPath = _field(reply, 'backupPath');
    if (backupPath != null && backupPath is! String) {
      throw DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid backupPath in ${reply.action} reply.',
      );
    }
    return SessionMediaScrubResult(
      imagesFound: _requiredInt(reply, 'imagesFound'),
      bytesExtracted: _requiredInt(reply, 'bytesExtracted'),
      sessionsScanned: _requiredInt(reply, 'sessionsScanned'),
      backupPath: backupPath as String?,
    );
  }

  /// All character cards (`cards.list`).
  Future<List<Map<String, dynamic>>> cardsList({int limit = 50}) async {
    final reply = await _callOk(
      'cards.list',
      payload: <String, dynamic>{'limit': limit},
    );
    return _objects(reply, 'cards');
  }

  /// One character card, or `null` when the daemon has no such card (`cards.get`).
  Future<Map<String, dynamic>?> cardsGet(String id) async {
    final reply = await _callOk(
      'cards.get',
      payload: <String, dynamic>{'id': id},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic>) return null;
    final card = data['card'];
    return card is Map<String, dynamic> ? card : null;
  }

  /// Create a character card (`cards.create`).
  Future<CardWriteResult> cardsCreate(Map<String, dynamic> document) async {
    final reply = await _callOk(
      'cards.create',
      payload: <String, dynamic>{
        'name': document['name'],
        'document': document,
      },
    );
    return _cardWriteResult(
      reply,
      fallbackName: document['name'] is String
          ? document['name'] as String
          : '',
    );
  }

  /// Update a character card (`cards.update`).
  Future<CardWriteResult> cardsUpdate(
    String id,
    Map<String, dynamic> document,
  ) async {
    final reply = await _callOk(
      'cards.update',
      payload: <String, dynamic>{'id': id, 'document': document},
    );
    return _cardWriteResult(
      reply,
      fallbackName: document['name'] is String
          ? document['name'] as String
          : '',
      requireUpdated: true,
    );
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
  Future<CardImportResult> cardsImport({
    Map<String, dynamic>? card,
    String? pngBase64,
  }) async {
    if (card == null && pngBase64 == null) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'cards.import needs either a card document or pngBase64.',
      );
    }
    final payload = <String, dynamic>{
      if (card != null) 'card': card,
      if (pngBase64 != null) 'pngBase64': pngBase64,
    };
    final reply = await _callOk('cards.import', payload: payload);
    final data = reply.data;
    if (data is! Map<String, dynamic>) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid cards.import reply.',
      );
    }
    return CardImportResult(
      id: _requiredString(reply, 'id'),
      name: _requiredString(reply, 'name'),
      renamed: data['renamed'] == true,
    );
  }

  /// Delete a character card (`cards.delete`).
  Future<bool> cardsDelete(String id) async {
    final reply = await _callOk(
      'cards.delete',
      payload: <String, dynamic>{'id': id},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['deleted'] is! bool) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid cards.delete reply.',
      );
    }
    return data['deleted'] as bool;
  }

  static CardWriteResult _cardWriteResult(
    RpcReply reply, {
    required String fallbackName,
    bool requireUpdated = false,
  }) {
    final rawUpdated = _field(reply, 'updated');
    final updated = rawUpdated is bool ? rawUpdated : false;
    if (requireUpdated && !updated) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid cards.update reply.',
      );
    }
    return CardWriteResult(
      id: _requiredString(reply, 'id'),
      name: _field(reply, 'name') is String
          ? _field(reply, 'name') as String
          : fallbackName,
      updated: updated,
    );
  }

  /// All chat sessions (`sessions.list`).
  Future<List<Map<String, dynamic>>> sessionsList() async {
    final reply = await _callOk('sessions.list');
    return _objects(reply, 'sessions');
  }

  /// JSONL export of one chat session (`sessions.export`).
  Future<String> sessionsExport(String sessionId) async {
    final reply = await _callOk(
      'sessions.export',
      payload: <String, dynamic>{'session_id': sessionId},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['jsonl'] is! String) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid sessions.export reply.',
      );
    }
    return data['jsonl'] as String;
  }

  /// Delete one chat session and its messages (`sessions.delete`).
  ///
  /// Returns whether the session existed. A missing session is `false`, not an
  /// error, so callers can treat a stale row as an idempotent delete.
  Future<bool> sessionsDelete(String sessionId) async {
    final reply = await _callOk(
      'sessions.delete',
      payload: <String, dynamic>{'sessionId': sessionId},
    );
    final data = reply.data;
    if (data is! Map<String, dynamic> || data['deleted'] is! bool) {
      throw const DaemonClientException(
        kind: DaemonFailureKind.protocol,
        message: 'Invalid sessions.delete reply.',
      );
    }
    return data['deleted'] as bool;
  }

  /// Explicit shutdown: no reconnect is scheduled.
  Future<void> disconnect() async {
    _wantsConnection = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _authenticated = false;
    _failAuth(
      const DaemonClientException(
        kind: DaemonFailureKind.notConnected,
        message: 'Disconnected.',
      ),
    );
    _failAllPending(
      const DaemonClientException(
        kind: DaemonFailureKind.notConnected,
        message: 'Disconnected.',
      ),
    );
    await _teardownTransport();
    _settings = null;
    _emit(
      state: DaemonConnectionState.disconnected,
      clearCore: true,
      clearError: true,
      attempt: 0,
    );
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
    _failAllPending(
      const DaemonClientException(
        kind: DaemonFailureKind.notConnected,
        message: 'Client disposed.',
      ),
    );
    final transport = _transport;
    _teardownTransport().whenComplete(() => transport?.dispose());
    _status.close();
  }
}
