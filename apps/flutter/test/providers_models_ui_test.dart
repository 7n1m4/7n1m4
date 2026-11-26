// SPDX-License-Identifier: GPL-3.0-or-later

// Widget tests for the provider model browser: the screen calls the live
// `providers.models` daemon RPC with the selected provider id, renders only
// the daemon-returned `id` / `ownedBy` metadata, and surfaces a user-visible
// error for an unknown/omitted provider instead of faking a model list.
// Secrets never appear in a models reply, so no key is ever rendered.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/providers/providers_screen.dart';

import 'support/fakes.dart';

class _RecordingProviderClient extends FakeChatClient {
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  RpcReply Function(String action, Map<String, dynamic>? payload) handler =
      (action, payload) => RpcReply(action: action, ok: true, data: <String, dynamic>{});

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    return handler(action, payload);
  }

  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    calls.add((action: 'settings.get', payload: <String, dynamic>{'section': section}));
    final reply = handler('settings.get', <String, dynamic>{'section': section});
    final data = reply.data;
    if (data is Map<String, dynamic> && data['settings'] is Map<String, dynamic>) {
      return data['settings'] as Map<String, dynamic>;
    }
    return <String, dynamic>{};
  }
}

RpcReply _ok(String action, Object? data) =>
    RpcReply(action: action, ok: true, data: data);
RpcReply _err(String action, String message) => RpcReply(
      action: action,
      ok: false,
      error: RpcError(code: 'rpc_bad_payload', message: message),
    );

Map<String, dynamic> _seededProvider() => <String, dynamic>{
      'id': 'p-openai',
      'kind': 'open-ai-compatible',
      'model': 'gpt',
      'baseUrl': 'https://api.openai.com/v1',
      'enabled': true,
      'updatedAt': 1,
    };

Future<_RecordingProviderClient> _pump(
  tester, {
  List<Map<String, dynamic>> providers = const <Map<String, dynamic>>[],
  RpcReply Function(String action, Map<String, dynamic>? payload)? modelsHandler,
}) async {
  final client = _RecordingProviderClient();
  addTearDown(client.dispose);
  client.handler = (action, payload) {
    if (action == 'providers.list') {
      return _ok(action, <String, dynamic>{'providers': providers});
    }
    if (action == 'providers.models') {
      return modelsHandler?.call(action, payload) ??
          _ok(action, <String, dynamic>{
            'providerId': 'p-openai',
            'models': <Map<String, dynamic>>[],
          });
    }
    if (action == 'settings.get') {
      return _ok(action, <String, dynamic>{
        'section': payload?['section'],
        'settings': <String, dynamic>{},
      });
    }
    return _ok(action, <String, dynamic>{'ok': true, 'id': 'p1'});
  };
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))));
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('models button requests the selected provider and renders daemon models',
      (tester) async {
    final client = await _pump(
      tester,
      providers: <Map<String, dynamic>>[_seededProvider()],
      modelsHandler: (action, payload) => _ok(action, <String, dynamic>{
        'providerId': 'p-openai',
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'gpt-4o', 'ownedBy': 'openai'},
          <String, dynamic>{'id': 'gpt-4o-mini'},
        ],
      }),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Models'));
    await tester.pumpAndSettle();

    final modelsCall = client.calls.firstWhere((c) => c.action == 'providers.models');
    expect(modelsCall.payload, <String, dynamic>{'providerId': 'p-openai'});
    expect(find.text('gpt-4o'), findsOneWidget);
    expect(find.text('openai'), findsOneWidget);
    expect(find.text('gpt-4o-mini'), findsOneWidget);
  });

  testWidgets('unknown provider surfaces a user-visible error and no models',
      (tester) async {
    await _pump(
      tester,
      providers: <Map<String, dynamic>>[_seededProvider()],
      modelsHandler: (action, payload) =>
          _err(action, 'provider not found'),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Models'));
    await tester.pumpAndSettle();

    expect(find.text('The daemon could not complete the request.'), findsOneWidget);
    expect(find.text('gpt-4o'), findsNothing);
  });

  testWidgets('models reply never renders a secret', (tester) async {
    await _pump(
      tester,
      providers: <Map<String, dynamic>>[_seededProvider()],
      modelsHandler: (action, payload) => _ok(action, <String, dynamic>{
        'providerId': 'p-openai',
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'gpt-4o', 'ownedBy': 'openai'},
        ],
      }),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Models'));
    await tester.pumpAndSettle();

    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.textContaining('apiKey'), findsNothing);
  });
}
