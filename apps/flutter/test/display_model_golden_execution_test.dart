// SPDX-License-Identifier: GPL-3.0-or-later

// Round v32 real-execution Dart leg for the additive display-model.resolve
// trace. Boots a REAL DaemonClient over a ScriptedTransport, replays the
// UNCHANGED golden frames through the production ServerFrame.parse ->
// RpcReply.fromJson codec, and pumps the REAL ModelStage. The widget is
// constructed with backends == null && resolver == null, so it stops at the
// kind placeholder and makes no native method-channel call. ModelStage is
// import-only here: no production file is edited.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

/// Same fixture resolution as the other golden replay tests.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

Map<String, dynamic> _read(String name) {
  final file = File('$_fixturesDir/$name');
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _frame(Map<String, dynamic> fixture, int index) =>
    (fixture['frames'] as List)[index] as Map<String, dynamic>;

Map<String, dynamic> _body(Map<String, dynamic> frame, String key) =>
    frame[key] as Map<String, dynamic>;

class _Harness {
  _Harness(this.client, this.transport);

  final DaemonClient client;
  final ScriptedTransport transport;
}

/// Production handshake: auth -> core.status probe -> event.subscribe drain.
Future<_Harness> _connect(WidgetTester tester) async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 5),
    rpcTimeout: const Duration(seconds: 5),
    heartbeatInterval: const Duration(hours: 1),
  );
  addTearDown(client.dispose);

  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await tester.pump();
  transport.receive('{"type":"auth","ok":true}');
  await tester.pump();
  final probe = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  expect(probe['action'], 'core.status');
  transport.receive(
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': 'core.status',
      'ok': true,
      'data': <String, dynamic>{
        'app': 'anima-daemon',
        'version': '0.1.0',
        'coreAvailable': true,
        'storeAvailable': true,
        'storeHealth': 'ok',
        'protocol': 'airi-channel/1',
        'sessionCount': 0,
        'messageCount': 0,
      },
      'id': probe['id'],
    }),
  );
  await tester.pump();
  await connecting;

  final subscribeIds = <Object?>[];
  for (final frame in transport.sent) {
    final decoded = jsonDecode(frame) as Map<String, dynamic>;
    if (decoded['action'] == 'event.subscribe') subscribeIds.add(decoded['id']);
  }
  for (final id in subscribeIds) {
    transport.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'event.subscribe',
        'ok': true,
        'data': <String, dynamic>{'subscribed': true},
        'id': id,
      }),
    );
  }
  await tester.pump();
  return _Harness(client, transport);
}

/// Newest request frame sent for [action].
Map<String, dynamic> _request(_Harness harness, String action) {
  for (final frame in harness.transport.sent.reversed) {
    final decoded = jsonDecode(frame) as Map<String, dynamic>;
    if (decoded['action'] == action) return decoded;
  }
  fail('no $action request reached the wire');
}

/// Feed a whole golden reply frame, replacing only the correlation id with the
/// one the real client actually emitted (the daemon echoes it verbatim).
/// Everything else goes through the production codec untouched.
void _replyFrame(
  _Harness harness,
  Map<String, dynamic> goldenFrame,
  Object id,
) {
  final wire = <String, dynamic>{...goldenFrame, 'id': id};
  final parsed = ServerFrame.parse(jsonEncode(wire));
  expect(
    parsed.parseError,
    isNull,
    reason: '${goldenFrame['action']} reply must parse',
  );
  expect(parsed.kind, ServerFrameKind.rpc);
  expect(parsed.reply, isNotNull);
  expect(parsed.reply!.action, goldenFrame['action']);
  expect(parsed.reply!.ok, goldenFrame['ok']);
  harness.transport.receive(jsonEncode(parsed.raw));
}

void main() {
  testWidgets(
    'golden display-model descriptor drives a real DaemonClient and ModelStage',
    (tester) async {
      final fixture = _read('trace.display.model.resolve.json');
      expect(fixture['schema'], 'airi-channel-trace-v1');

      final cardRequest = _body(_frame(fixture, 0), 'payload');
      final resolveRequest = _body(_frame(fixture, 4), 'payload');
      final descriptor = _body(_frame(fixture, 5), 'data');

      // The golden descriptor survives the production codec byte-for-field.
      final codec = ServerFrame.parse(
        jsonEncode(<String, dynamic>{
          'type': 'rpc',
          'action': 'display-model.resolve',
          'ok': true,
          'id': 1,
          'data': descriptor,
        }),
      );
      expect(codec.parseError, isNull);
      expect(codec.kind, ServerFrameKind.rpc);
      expect(codec.reply!.data, descriptor);
      expect(jsonEncode(codec.reply!.data), jsonEncode(descriptor));

      final harness = await _connect(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelStage(
              client: harness.client,
              cardId: cardRequest['id'] as String,
              // backends == null && resolver == null: no native surface.
            ),
          ),
        ),
      );
      await tester.pump();

      final cardReq = _request(harness, 'cards.get');
      expect(cardReq['payload'], cardRequest);
      _replyFrame(harness, _frame(fixture, 1), cardReq['id'] as Object);
      await tester.pump();

      final resolveReq = _request(harness, 'display-model.resolve');
      expect(
        resolveReq['payload'],
        resolveRequest,
        reason: 'the real client emits the golden {"id": ...} payload',
      );

      // Feed the unchanged golden descriptor reply; the widget resolves to the
      // kind placeholder because no native backends/resolver were injected.
      _replyFrame(harness, _frame(fixture, 5), resolveReq['id'] as Object);
      await tester.pumpAndSettle();

      expect(find.text('LIVE2D model · renderer pending'), findsOneWidget);
      expect(find.text('No display model'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'an unknown catalog id yields a typed display-model-unresolved error',
    (tester) async {
      final fixture = _read('trace.display.model.resolve.json');
      final cardRequest = _body(_frame(fixture, 8), 'payload');
      final resolveRequest = _body(_frame(fixture, 6), 'payload');
      final errorFrame = _frame(fixture, 7);
      final error = _body(errorFrame, 'error');

      final harness = await _connect(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelStage(
              client: harness.client,
              cardId: cardRequest['id'] as String,
            ),
          ),
        ),
      );
      await tester.pump();

      final cardReq = _request(harness, 'cards.get');
      expect(cardReq['payload'], cardRequest);
      _replyFrame(harness, _frame(fixture, 9), cardReq['id'] as Object);
      await tester.pump();

      final resolveReq = _request(harness, 'display-model.resolve');
      expect(resolveReq['payload'], resolveRequest);
      _replyFrame(harness, errorFrame, resolveReq['id'] as Object);
      await tester.pumpAndSettle();

      // Loud typed error, never a fabricated model or a "no model" fallback.
      expect(find.text(error['code'] as String), findsOneWidget);
      expect(find.textContaining(error['message'] as String), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('No display model'), findsNothing);
      expect(find.textContaining('LIVE2D model'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
