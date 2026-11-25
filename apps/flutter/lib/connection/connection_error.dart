// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:developer' as developer;

import '../daemon_client/daemon_client.dart';

/// One short, fixed message per known failure. Never interpolate a transport
/// exception or a gateway handler message: RPC handler errors may carry URLs,
/// config paths or credential-shaped text (airi-cpq).
const String _generic = 'Connection failed. Check the daemon and retry.';

/// Message shown by connection UI. The original error goes to the local
/// developer log only, never into a widget or a project log.
String userSafeConnectionError(Object error, {String? context}) {
  final String text;
  if (error is DaemonClientException) {
    text = switch (error.code) {
      'invalid_token' || 'auth_rejected' =>
        'The daemon rejected the connection. Check the auth token.',
      'rpc_actions_disabled' =>
        'The daemon refused this action. Ask the operator to enable it.',
      'rpc_unknown_method' ||
      'rpc_not_implemented' ||
      'rpc_bad_payload' ||
      'rpc_bad_topics' ||
      'rpc_bad_topic' =>
        'The daemon could not complete the request.',
      _ => switch (error.kind) {
          DaemonFailureKind.auth =>
            'The daemon rejected the connection. Check the auth token.',
          DaemonFailureKind.transport =>
            'Could not reach the daemon. Check the host and port, then retry.',
          DaemonFailureKind.timeout =>
            'The daemon did not respond in time. Please retry.',
          DaemonFailureKind.notConnected => 'Not connected to the daemon.',
          _ => _generic,
        },
    };
  } else {
    text = _generic;
  }
  developer.log('${context ?? 'connection'} $error', name: 'anima.connection');
  return text;
}
