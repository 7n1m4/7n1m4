// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

void main() {
  testWidgets('ChatScreen renders with a disconnected client', (tester) async {
    final client = DaemonClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(client: client))));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });
}
