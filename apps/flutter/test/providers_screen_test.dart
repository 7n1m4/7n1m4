// SPDX-License-Identifier: GPL-3.0-or-later

// Widget tests for the providers form: save/delete must go through the
// daemon RPCs, validate required fields before any call, preserve daemon
// validation state, and show RPC errors instead of optimistic success.
// Secrets are never part of a list reply, so the tiles below assert that only
// metadata is rendered and no key is ever sent back on list/delete.

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
}

RpcReply _ok(String action, Object? data) =>
    RpcReply(action: action, ok: true, data: data);
RpcReply _err(String action, String message) => RpcReply(
      action: action,
      ok: false,
      error: RpcError(code: 'actions_disabled', message: message),
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
}) async {
  final client = _RecordingProviderClient();
  addTearDown(client.dispose);
  client.handler = (action, _) {
    if (action == 'providers.list') {
      return _ok(action, <String, dynamic>{'providers': providers});
    }
    if (action == 'providers.delete') {
      return _ok(action, <String, dynamic>{'ok': true, 'deleted': true});
    }
    return _ok(action, <String, dynamic>{'ok': true, 'id': 'p1'});
  };
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))));
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('save writes through providers.save and refreshes the list',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'Provider ID'), 'p-new');
    await tester.enterText(find.widgetWithText(TextField, 'Kind'), 'llama-cpp');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'qwen');
    await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'), 'http://localhost:11434/v1');
    await tester.enterText(
        find.widgetWithText(TextField, 'API key (write-only)'), 'TOP-SECRET');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    expect(saveCall.payload, <String, dynamic>{
      'id': 'p-new',
      'kind': 'llama-cpp',
      'model': 'qwen',
      'baseUrl': 'http://localhost:11434/v1',
      'enabled': true,
      'apiKey': 'TOP-SECRET',
    });
    // The daemon returns its canonical id in the reply; the screen shows that.
    expect(find.text('Saved provider p1'), findsOneWidget);
    // Only the write path carries the key: never re-listed or echoed.
    expect(
      client.calls
          .where((c) => c.action != 'providers.save')
          .every((c) => !c.payload.toString().contains('TOP-SECRET')),
      isTrue,
    );
    expect(find.textContaining('TOP-SECRET'), findsNothing);
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
    await tester.pumpAndSettle();

    expect(find.text('actions disabled'), findsOneWidget);
    expect(find.textContaining('Saved provider'), findsNothing);
  });

  testWidgets('delete writes through providers.delete and refreshes the list',
      (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[
      _seededProvider(),
    ]);

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
    await tester.pumpAndSettle();

    expect(find.text('actions disabled'), findsOneWidget);
    expect(find.textContaining('Deleted provider'), findsNothing);
  });

  testWidgets('enable toggle saves a partial update without credentials',
      (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[
      _seededProvider(),
    ]);

    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Disable'))
        .onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    // The daemon preserves the stored key on a partial update; sending an
    // empty key here would rotate or clear a managed credential.
    expect(saveCall.payload, <String, dynamic>{
      'id': 'p-openai',
      'kind': 'open-ai-compatible',
      'enabled': false,
    });
    expect(find.text('Disabled provider p-openai'), findsOneWidget);
  });

  testWidgets('daemon validation state survives save and list round-trips',
      (tester) async {
    final client = _RecordingProviderClient();
    addTearDown(client.dispose);
    client.handler = (action, payload) {
      if (action == 'providers.list') {
        return _ok(action, <String, dynamic>{
          'providers': <Map<String, dynamic>>[
            <String, dynamic>{
              ..._seededProvider(),
              'validation': <String, dynamic>{
                'state': 'invalid',
                'message': 'bad key',
              },
            },
          ],
        });
      }
      if (action == 'providers.save') {
        return _ok(action, <String, dynamic>{
          'ok': true,
          'id': 'p-openai',
          'validation': <String, dynamic>{
            'state': 'valid',
            'message': 'checked',
          },
        });
      }
      return _ok(action, <String, dynamic>{'ok': true, 'deleted': true});
    };
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))));
    await tester.pumpAndSettle();

    expect(find.text('Validation: invalid: bad key'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    await tester.enterText(find.widgetWithText(TextField, 'Kind'), 'openai');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('Saved provider p-openai · Validation: valid: checked'),
        findsOneWidget);
  });

  testWidgets('provider tiles never render secret material', (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[
      <String, dynamic>{
        ..._seededProvider(),
        // Even if a buggy daemon echoes a secret, the screen projects only
        // allowlisted metadata and never sends it on a subsequent RPC.
        'apiKey': 'sk-LEAKED',
      },
    ]);

    expect(find.textContaining('sk-'), findsNothing);
    expect(
      client.calls
          .every((c) => c.action != 'providers.list' || c.payload == null),
      isTrue,
    );
    expect(
      client.calls.where((c) => c.action != 'providers.list').every(
            (c) => !(c.payload?.toString().contains('sk-LEAKED') ?? false),
          ),
      isTrue,
    );
  });
}
