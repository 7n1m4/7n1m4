// SPDX-License-Identifier: GPL-3.0-or-later

// Widget tests for the providers form: save/delete must go through the
// daemon RPCs, validate required fields before any call, and show RPC errors
// instead of optimistic success. Secrets are never part of a list reply, so
// the tiles below assert that only metadata is rendered.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/providers/providers_screen.dart';

import 'support/fakes.dart';

class _RecordingProviderClient extends FakeChatClient {
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  RpcReply Function(String action, Map<String, dynamic>? payload) handler =
      (action, payload) => RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{},
          );

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    return handler(action, payload);
  }

  @override
  Future<String> providersSave({
    required String id,
    required String kind,
    String? model,
    String? baseUrl,
    String? apiKey,
    bool? enabled,
  }) async {
    final reply = await call('providers.save', payload: <String, dynamic>{
      'id': id,
      'kind': kind,
      if (model != null) 'model': model,
      if (baseUrl != null) 'baseUrl': baseUrl,
      if (apiKey != null) 'apiKey': apiKey,
      if (enabled != null) 'enabled': enabled,
    });
    if (!reply.ok) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: reply.error?.message ?? 'providers.save failed',
      );
    }
    final data = reply.data;
    return (data is Map<String, dynamic> ? data['id'] : null)?.toString() ?? id;
  }

  @override
  Future<bool> providersDelete(String id) async {
    final reply =
        await call('providers.delete', payload: <String, dynamic>{'id': id});
    if (!reply.ok) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: reply.error?.message ?? 'providers.delete failed',
      );
    }
    final data = reply.data;
    return data is Map<String, dynamic> && data['deleted'] == true;
  }
}

RpcReply _ok(String action, Object? data) =>
    RpcReply(action: action, ok: true, data: data);
RpcReply _err(String action, String message) => RpcReply(
      action: action,
      ok: false,
      error: RpcError(code: 'actions_disabled', message: message),
    );

Future<_RecordingProviderClient> _pump(tester) async {
  final client = _RecordingProviderClient();
  addTearDown(client.dispose);
  client.handler = (action, _) {
    if (action == 'providers.list') {
      return _ok(action, <String, dynamic>{
        'providers': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'p-openai',
            'kind': 'openai',
            'model': 'gpt',
            'baseUrl': 'https://api.openai.com/v1',
            'enabled': true,
            'updatedAt': 1,
          },
        ],
      });
    }
    if (action == 'providers.delete') {
      return _ok(action, <String, dynamic>{'ok': true, 'deleted': true});
    }
    return _ok(action, <String, dynamic>{'ok': true, 'id': 'p1'});
  };
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))));
  await tester.pump();
  return client;
}

void main() {
  testWidgets('save writes through providers.save and refreshes the list',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'Provider ID'), 'p-new');
    await tester.enterText(find.widgetWithText(TextField, 'Kind'), 'llama-cpp');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    expect(saveCall.payload, isNotNull);
    expect(saveCall.payload!['id'], 'p-new');
    expect(saveCall.payload!['kind'], 'llama-cpp');
    // The daemon returns its canonical id in the reply; the screen shows that.
    expect(find.text('Saved provider p1'), findsOneWidget);
    expect(find.text('p-openai'), findsOneWidget);
  });

  testWidgets('save validates required fields before calling the daemon',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pump();

    expect(client.calls.where((c) => c.action == 'providers.save'), isEmpty);
    expect(find.text('Provider id and kind are required.'), findsOneWidget);
    expect(find.text('Saved provider p1'), findsNothing);
  });

  testWidgets('save RPC failure shows the daemon error, no success status',
      (tester) async {
    final client = await _pump(tester);
    client.handler = (action, _) {
      if (action == 'providers.list') {
        return _ok(
            action, <String, dynamic>{'providers': <Map<String, dynamic>>[]});
      }
      return _err(action, 'actions disabled');
    };

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    await tester.enterText(find.widgetWithText(TextField, 'Kind'), 'openai');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    expect(find.text('actions disabled'), findsOneWidget);
    expect(find.textContaining('Saved provider'), findsNothing);
  });

  testWidgets('delete writes through providers.delete and refreshes the list',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(
      client.calls.firstWhere((c) => c.action == 'providers.delete').payload,
      <String, dynamic>{'id': 'p1'},
    );
    expect(find.text('Deleted provider p1'), findsOneWidget);
  });

  testWidgets('delete RPC failure shows the daemon error, no success status',
      (tester) async {
    final client = await _pump(tester);
    client.handler = (action, _) {
      if (action == 'providers.list') {
        return _ok(
            action, <String, dynamic>{'providers': <Map<String, dynamic>>[]});
      }
      return _err(action, 'actions disabled');
    };

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    expect(find.text('actions disabled'), findsOneWidget);
    expect(find.textContaining('Deleted provider'), findsNothing);
  });

  testWidgets('provider tiles never render secret material', (tester) async {
    final client = await _pump(tester);

    expect(find.textContaining('sk-'), findsNothing);
    expect(
        client.calls
            .every((c) => c.action != 'providers.list' || c.payload == null),
        isTrue);
  });
}
