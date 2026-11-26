// SPDX-License-Identifier: GPL-3.0-or-later

// Focused regression: the home status card must never render a raw daemon
// error. RPC handler messages may carry URLs, config paths or credentials.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/home/home_screen.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('home screen shows a safe message, never the raw error',
      (tester) async {
    const secret = 'rpc failed: /etc/shadow token=abc123 at wss://user:pw@host/x';
    final client = ErrorStatusClient(const DaemonStatus(
      state: DaemonConnectionState.failed,
      error: DaemonClientException(
        kind: DaemonFailureKind.rpc,
        code: 'rpc_actions_disabled',
        message: secret,
      ),
    ));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: HomeScreen(client: client)),
    ));

    expect(find.textContaining('/etc/shadow'), findsNothing);
    expect(find.textContaining('token=abc123'), findsNothing);
    expect(find.textContaining('wss://user:pw@host'), findsNothing);
    expect(
      find.text('The daemon refused this action. Ask the operator to enable it.'),
      findsOneWidget,
    );
  });
}
