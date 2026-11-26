// SPDX-License-Identifier: GPL-3.0-or-later

// Provider selection parity: the screen reads and writes the daemon-owned
// `settings/chat-provider` section through settings.get/settings.set. The
// client holds only transient UI state; no selection is stored locally.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/providers/providers_screen.dart';

import 'support/fakes.dart';

class _SelectionClient extends FakeChatClient {
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  late final RpcReply Function(String action, Map<String, dynamic>? payload) handler;
  Map<String, dynamic>? saved;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    return handler(action, payload);
  }

  @override
  Future<bool> settingsSet(String section, Map<String, dynamic> settings) async {
    calls.add((
      action: 'settings.set',
      payload: <String, dynamic>{'section': section, 'settings': settings},
    ));
    saved?.addAll(<String, dynamic>{'section': section, ...settings});
    final reply = handler('settings.set', <String, dynamic>{
      'section': section,
      'settings': settings,
    });
    final data = reply.data;
    return reply.ok && data is Map<String, dynamic> && data['ok'] == true;
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

Future<_SelectionClient> _pump(
  tester, {
  required Map<String, dynamic> active,
  Map<String, dynamic>? saved,
}) async {
  final client = _SelectionClient();
  client.saved = saved;
  addTearDown(client.dispose);
  client.handler = (action, payload) {
    if (action == 'providers.list') {
      return _ok(action, <String, dynamic>{
        'providers': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'p-openai',
            'kind': 'open-ai-compatible',
            'model': 'gpt',
            'enabled': true,
          },
          <String, dynamic>{
            'id': 'p-anthropic',
            'kind': 'anthropic',
            'model': 'claude',
            'enabled': true,
          },
        ],
      });
    }
    if (action == 'settings.get') {
      return _ok(action, <String, dynamic>{
        'section': payload?['section'],
        'settings': active,
      });
    }
    if (action == 'settings.set') {
      saved?.addAll(payload ?? const <String, dynamic>{});
      return _ok(action, <String, dynamic>{'ok': true});
    }
    if (action == 'providers.models') {
      return _ok(action, <String, dynamic>{
        'providerId': payload?['providerId'],
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'picked-model'},
        ],
      });
    }
    return _ok(action, <String, dynamic>{});
  };
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('saved active provider/model is read from the daemon', (tester) async {
    final client = await _pump(
      tester,
      active: <String, dynamic>{
        'activeProvider': 'p-anthropic',
        'activeModel': 'claude-3',
      },
    );
    final read = client.calls.firstWhere((c) => c.action == 'settings.get');
    expect(read.payload, <String, dynamic>{'section': 'chat-provider'});
    expect(find.text('Active chat provider'), findsOneWidget);
    expect(find.text('p-anthropic'), findsWidgets);
    expect(find.text('claude-3'), findsOneWidget);
  });

  testWidgets('Use for chat writes the selection through settings.set', (tester) async {
    final saved = <String, dynamic>{};
    final client = await _pump(
      tester,
      active: const <String, dynamic>{},
      saved: saved,
    );

    // Invoke the screen's actual dropdown and button callbacks: overlay hit
    // testing is unreliable for off-screen widgets in the headless tester.
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).at(1),
    );
    dropdown.onChanged!('p-anthropic');
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use for chat'),
    );
    button.onPressed!();
    await tester.pumpAndSettle();

    final write = client.calls.lastWhere((c) => c.action == 'settings.set');
    expect(write.payload!['section'], 'chat-provider');
    final settings = write.payload!['settings'] as Map<String, dynamic>;
    expect(settings['activeProvider'], 'p-anthropic');
    expect(saved['section'], 'chat-provider');
  });

  testWidgets('model dropdown for the active provider comes from providers.models',
      (tester) async {
    final client = await _pump(
      tester,
      active: <String, dynamic>{'activeProvider': 'p-openai', 'activeModel': 'picked-model'},
    );
    final modelsCall = client.calls.firstWhere((c) => c.action == 'providers.models');
    expect(modelsCall.payload, <String, dynamic>{'providerId': 'p-openai'});
    expect(find.text('picked-model'), findsWidgets);
  });
}
