// SPDX-License-Identifier: GPL-3.0-or-later

// Low-level JSON frame codec for the protocol spoken by anima-channel.
// Shapes are hand-written from crates/anima-channel/src/wire.rs and kept in
// sync with the Rust golden fixtures (test/golden_fixtures_test.dart); the
// protocol id remains the literal carve-out `airi-channel/1` (do not rename
// to `anima-*`). Event topics are decoded into [EventTopic]; subscriptions are
// issued by callers (the chat surface subscribes to `token.delta`). Payload
// parsers for daemon-published presence/status events live here too.

import 'dart:convert';

import 'rpc.dart';

/// Literal protocol identifier from `dispatch::PROTOCOL` (wire version 1).
const String kProtocolId = 'airi-channel/1';

/// Gateway WS path (`crates/anima-channel/src/client.rs:27`).
const String kDefaultWsPath = '/ws';

const int kDefaultPort = 6121;

/// First frame on every connection MUST be an auth frame. Anything else before
/// auth is rejected by the gateway (close 1008).
String encodeAuthFrame(String token) => jsonEncode(<String, dynamic>{
      'type': 'auth',
      'authToken': token,
    });

/// Alternate handshake shape used by the server-runtime mirror.
String encodeModuleAuthFrame(String token) => jsonEncode(<String, dynamic>{
      'type': 'module:authenticate',
      'data': <String, dynamic>{'token': token},
    });

String encodePingFrame() => jsonEncode(<String, dynamic>{'type': 'ping'});

enum ServerFrameKind {
  authOk, // {"type":"auth","ok":true}
  authenticated, // {"type":"module:authenticated","data":{"authenticated":true}}
  pong,
  heartbeat,
  rpc,
  error,
  event, // Server-initiated event lane; post-auth only.
  unknown,
}

/// Stable `event` topic name from `EventTopic` in
/// crates/anima-channel/src/wire.rs. The version-1 vocabulary is fixed;
/// [unknown] absorbs anything newer so frame decoding stays total.
enum EventTopic {
  lipSyncRms('lip_sync.rms'),
  emotionTag('emotion.tag'),
  tokenDelta('token.delta'),
  presenceChanged('presence.changed'),
  statusChanged('status.changed'),
  settingsChanged('settings.changed'),
  unknown('');

  const EventTopic(this.wireName);

  /// Canonical dotted wire name (`unknown` carries an empty string).
  final String wireName;

  /// Decode a wire topic without throwing. Unexpected values become [unknown].
  static EventTopic fromWire(String value) {
    for (final topic in values) {
      if (topic != unknown && topic.wireName == value) return topic;
    }
    return unknown;
  }
}

/// Typed envelope of a server-initiated `event` frame.
///
/// [topic] is the validated [EventTopic]; [rawTopic] preserves the unmodified
/// wire string (identical to `topic.wireName` for known topics). [data] stays a
/// plain map: payload shapes are selected by topic and are intentionally left
/// to callers, but the topic itself is now typed. Chat subscribes to
/// `token.delta` via `event.subscribe` (see chat_screen.dart).
class GatewayEventFrame {
  const GatewayEventFrame({
    required this.topic,
    required this.rawTopic,
    required this.data,
    this.id,
  });

  final EventTopic topic;
  final String rawTopic;
  final Map<String, dynamic> data;
  final Object? id;

  factory GatewayEventFrame.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    final rawTopicValue = json['topic'];
    final rawTopic = rawTopicValue is String ? rawTopicValue : '';
    return GatewayEventFrame(
      topic: EventTopic.fromWire(rawTopic),
      rawTopic: rawTopic,
      data: rawData is Map<String, dynamic> ? rawData : const <String, dynamic>{},
      id: json['id'],
    );
  }
}

/// One daemon-published `presence.changed` payload (`PresenceChangedData` in
/// crates/anima-channel/src/wire.rs). Wire keys stay snake_case.
class PresenceChangedData {
  const PresenceChangedData({
    required this.subject,
    required this.state,
    required this.seq,
    required this.tsMs,
  });

  final String subject;
  final String state;
  final int seq;
  final int tsMs;

  /// Returns null unless every required wire field has the expected type.
  /// Missing payloads must not be turned into fabricated presence values.
  static PresenceChangedData? fromJson(Map<String, dynamic> json) {
    final subject = json['subject'];
    final state = json['state'];
    final seq = json['seq'];
    final tsMs = json['ts_ms'];
    if (subject is! String || state is! String) return null;
    if (seq is! int || tsMs is! int) return null;
    return PresenceChangedData(
      subject: subject,
      state: state,
      seq: seq,
      tsMs: tsMs,
    );
  }
}

/// One daemon-published `status.changed` payload (`StatusChangedData` in
/// crates/anima-channel/src/wire.rs). Wire keys stay snake_case. The payload
/// is coarse health only; it never carries credentials or other secrets.
class StatusChangedData {
  const StatusChangedData({
    required this.coreAvailable,
    required this.storeAvailable,
    required this.storeHealth,
    required this.seq,
    required this.tsMs,
  });

  final bool coreAvailable;
  final bool storeAvailable;
  final String storeHealth;
  final int seq;
  final int tsMs;

  /// Returns null unless every required wire field has the expected type.
  /// Missing payloads must not be turned into fabricated health values.
  static StatusChangedData? fromJson(Map<String, dynamic> json) {
    final coreAvailable = json['core_available'];
    final storeAvailable = json['store_available'];
    final storeHealth = json['store_health'];
    final seq = json['seq'];
    final tsMs = json['ts_ms'];
    if (coreAvailable is! bool || storeAvailable is! bool) return null;
    if (storeHealth is! String || seq is! int || tsMs is! int) return null;
    return StatusChangedData(
      coreAvailable: coreAvailable,
      storeAvailable: storeAvailable,
      storeHealth: storeHealth,
      seq: seq,
      tsMs: tsMs,
    );
  }
}

/// Decoded server text frame. Parsing is total: malformed frames become
/// [ServerFrameKind.unknown] with a [parseError] instead of throwing.
class ServerFrame {
  const ServerFrame({
    required this.kind,
    this.raw = const <String, dynamic>{},
    this.reply,
    this.error,
    this.event,
    this.parseError,
  });

  final ServerFrameKind kind;
  final Map<String, dynamic> raw;
  final RpcReply? reply;
  final RpcError? error;
  final GatewayEventFrame? event;
  final String? parseError;

  static ServerFrame parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      return ServerFrame(kind: ServerFrameKind.unknown, parseError: 'invalid JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      return const ServerFrame(kind: ServerFrameKind.unknown, parseError: 'frame is not a JSON object');
    }

    switch (decoded['type']) {
      case 'auth':
        return ServerFrame(kind: ServerFrameKind.authOk, raw: decoded);
      case 'module:authenticated':
        return ServerFrame(kind: ServerFrameKind.authenticated, raw: decoded);
      case 'pong':
        return ServerFrame(kind: ServerFrameKind.pong, raw: decoded);
      case 'transport:connection:heartbeat':
        return ServerFrame(kind: ServerFrameKind.heartbeat, raw: decoded);
      case 'rpc':
        return ServerFrame(kind: ServerFrameKind.rpc, raw: decoded, reply: RpcReply.fromJson(decoded));
      case 'error':
        final rawError = decoded['error'];
        return ServerFrame(
          kind: ServerFrameKind.error,
          raw: decoded,
          error: rawError is Map<String, dynamic> ? RpcError.fromJson(rawError) : null,
        );
      case 'event':
        return ServerFrame(
          kind: ServerFrameKind.event,
          raw: decoded,
          event: GatewayEventFrame.fromJson(decoded),
        );
      default:
        return ServerFrame(
          kind: ServerFrameKind.unknown,
          raw: decoded,
          parseError: 'unknown frame type: ${decoded['type']}',
        );
    }
  }
}

/// Parse one event frame's payload by topic. Unknown topics and malformed
/// payloads yield null; state holders must leave stale values untouched.
Object? parseEventPayload(GatewayEventFrame frame) => switch (frame.topic) {
      EventTopic.presenceChanged => PresenceChangedData.fromJson(frame.data),
      EventTopic.statusChanged => StatusChangedData.fromJson(frame.data),
      _ => null,
    };
