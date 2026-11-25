// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/connection/connection_error.dart';
import 'package:anima_control/connection/connection_settings_screen.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

void main() {
  group('userSafeConnectionError', () {
    test('maps known failure kinds to short generic messages', () {
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.transport,
          message: 'wss://secret:token@host/x',
        )),
        'Could not reach the daemon. Check the host and port, then retry.',
      );
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.auth,
          message: 'invalid token: abc123',
        )),
        'The daemon rejected the connection. Check the auth token.',
      );
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.timeout,
          message: 'timeout at /home/user/.config/x',
        )),
        'The daemon did not respond in time. Please retry.',
      );
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.notConnected,
          message: 'disconnected',
        )),
        'Not connected to the daemon.',
      );
    });

    test('maps stable gateway codes without echoing handler text', () {
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          code: 'rpc_actions_disabled',
          message: 'path=/etc/secret key=abc',
        )),
        'The daemon refused this action. Ask the operator to enable it.',
      );
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          code: 'invalid_token',
          message: 'token=abcdef',
        )),
        'The daemon rejected the connection. Check the auth token.',
      );
      for (final code in <String>[
        'rpc_unknown_method',
        'rpc_not_implemented',
        'rpc_bad_payload',
        'rpc_bad_topics',
        'rpc_bad_topic',
      ]) {
        expect(
          userSafeConnectionError(DaemonClientException(
            kind: DaemonFailureKind.rpc,
            code: code,
            message: 'secret',
          )),
          'The daemon could not complete the request.',
          reason: code,
        );
      }
    });

    test('falls back to one generic message for any other error', () {
      for (final error in <Object>[
        'SocketException: URL https://user:pass@example.com/v1?key=abc',
        StateError('config at /home/vi/airi/config.json'),
        const DaemonClientException(
          kind: DaemonFailureKind.protocol,
          message: 'token=abc',
        ),
        const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          code: 'rpc_handler_panic',
          message: 'panic at /home/vi/secret.rs',
        ),
      ]) {
        final text = userSafeConnectionError(error);
        expect(text, 'Connection failed. Check the daemon and retry.');
        expect(text, isNot(contains('secret')));
        expect(text, isNot(contains('token=')));
        expect(text, isNot(contains('/home/')));
        expect(text.length, lessThan(80));
      }
    });

    test('empty and unknown kinds stay generic', () {
      expect(
        userSafeConnectionError(const DaemonClientException(
          kind: DaemonFailureKind.none,
          message: 'abc',
        )),
        'Connection failed. Check the daemon and retry.',
      );
      expect(userSafeConnectionError(''), 'Connection failed. Check the daemon and retry.');
    });
  });

  testWidgets('connection screen shows a safe message, never the raw error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConnectionSettingsScreen(
          onConnect: (_) async {},
          onDisconnect: () async => throw StateError(
            'SocketException: wss://user:secret-token@host/key=abc',
          ),
        ),
      ),
    ));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Connection failed. Check the daemon and retry.'), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(find.textContaining('key=abc'), findsNothing);
  });
}
