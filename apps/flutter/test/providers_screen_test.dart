// SPDX-License-Identifier: GPL-3.0-or-later

// Widget tests for the providers form: save/delete must go through the
// daemon RPCs, validate required fields before any call, render only daemon
// provider metadata, and show RPC errors instead of optimistic success.
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
    if (action == 'providers.models') {
      return _ok(action, <String, dynamic>{
        'providerId': 'p1',
        'models': <Map<String, dynamic>>[],
      });
    }
    return _ok(action, <String, dynamic>{'ok': true, 'id': 'p1'});
  };
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ProvidersScreen(client: client))));
  await tester.pumpAndSettle();
  return client;
}

Future<void> selectKind(WidgetTester tester, String value) async {
  final kind = find.widgetWithText(DropdownButtonFormField<String>, 'Kind');
  await reveal(tester, kind, dragOffset: const Offset(0, 400));
  await tester.ensureVisible(kind);
  await tester.pumpAndSettle();
  await tester.tap(kind);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}
/// The screen renders one ListView: rows below the fold are only built once
/// scrolled into view, so scroll until the target exists (as a user would).
Future<void> reveal(WidgetTester tester, Finder finder,
    {Offset dragOffset = const Offset(0, -400)}) async {
  final scroll = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.drag(scroll, dragOffset);
    await tester.pumpAndSettle();
  }
}
/// Status and error banners live at the top of the ListView; after the form
/// has been scrolled they are built but off-stage, so scroll back to them.
Future<void> revealStatus(WidgetTester tester, Finder finder) =>
    reveal(tester, finder, dragOffset: const Offset(0, 400));

void main() {
  testWidgets('save writes through providers.save and refreshes the list',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'Provider ID'), 'p-new');
    await selectKind(tester, 'anthropic');
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
      'kind': 'anthropic',
      'model': 'qwen',
      'baseUrl': 'http://localhost:11434/v1',
      'enabled': true,
      'apiKey': 'TOP-SECRET',
      'rotateSecrets': true, // a typed key is the rotation opt-in
    });
    // The daemon returns its canonical id in the reply; the screen shows that.
    final status = find.text('Saved provider p1');
    await revealStatus(tester, status);
    expect(status, findsOneWidget);
    // Only the write path carries the key: never re-listed or echoed.
    expect(
      client.calls
          .where((c) => c.action != 'providers.save')
          .every((c) => !c.payload.toString().contains('TOP-SECRET')),
      isTrue,
    );
    expect(find.textContaining('TOP-SECRET'), findsNothing);
  });

  testWidgets('save validates the provider id before calling the daemon',
      (tester) async {
    final client = await _pump(tester);

    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pump();

    expect(client.calls.where((c) => c.action == 'providers.save'), isEmpty);
    // The kind dropdown always holds a supported value, so only the id can be missing.
    expect(find.text('Provider id and kind are required.'), findsOneWidget);
  });

  testWidgets('save RPC failure shows a sanitized error, no success status',
      (tester) async {
    final client = await _pump(tester);
    client.handler = (action, _) {
      if (action == 'providers.list') {
        return _ok(
            action, <String, dynamic>{'providers': <Map<String, dynamic>>[]});
      }
      return _err(action, 'failed to POST https://api.openai.com/v1 (key sk-LEAKED)');
    };

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    await selectKind(tester, 'google-gemini');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final error = find.text('The daemon could not complete the request.');
    await revealStatus(tester, error);
    expect(error, findsOneWidget);
    expect(find.textContaining('sk-LEAKED'), findsNothing);
    expect(find.textContaining('https://api.openai.com'), findsNothing);
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

  testWidgets('delete RPC failure shows a sanitized error, no success status',
      (tester) async {
    final client = await _pump(tester);
    client.handler = (action, _) {
      if (action == 'providers.list') {
        return _ok(
            action, <String, dynamic>{'providers': <Map<String, dynamic>>[]});
      }
      return _err(action, 'failed to POST https://api.openai.com/v1 (key sk-LEAKED)');
    };

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('The daemon could not complete the request.'), findsOneWidget);
    expect(find.textContaining('sk-LEAKED'), findsNothing);
    expect(find.textContaining('https://api.openai.com'), findsNothing);
    expect(find.textContaining('Deleted provider'), findsNothing);
  });

  testWidgets('models RPC failure shows a sanitized error', (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[
      _seededProvider(),
    ]);
    client.handler = (action, _) {
      if (action == 'providers.models') {
        return _err(action, 'failed /etc/anima/config.toml key sk-LEAKED');
      }
      if (action == 'providers.list') {
        return _ok(
            action, <String, dynamic>{'providers': <Map<String, dynamic>>[
          _seededProvider(),
        ]});
      }
      return _ok(action, <String, dynamic>{'ok': true});
    };

    final modelsButton = find.widgetWithText(OutlinedButton, 'Models');
    await reveal(tester, modelsButton);
    await tester.ensureVisible(modelsButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Models'));
    await tester.pumpAndSettle();

    final error = find.text('The daemon could not complete the request.');
    await revealStatus(tester, error);
    expect(error, findsOneWidget);
    expect(find.textContaining('sk-LEAKED'), findsNothing);
    expect(find.textContaining('/etc/anima'), findsNothing);
  });

  testWidgets('enable toggle saves a partial update without credentials',
      (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[
      _seededProvider(),
    ]);

    final disableButton = find.widgetWithText(TextButton, 'Disable');
    await reveal(tester, disableButton);
    tester.widget<TextButton>(disableButton).onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    // The daemon preserves the stored key on a partial update; sending an
    // empty key here would rotate or clear a managed credential.
    // rotateSecrets must also be absent so the daemon does not rotate.
    expect(saveCall.payload, <String, dynamic>{
      'id': 'p-openai',
      'kind': 'open-ai-compatible',
      'enabled': false,
    });
    expect(saveCall.payload!.containsKey('rotateSecrets'), isFalse,
        reason: 'a toggle must not rotate a managed credential');
    final status = find.text('Disabled provider p-openai');
    await reveal(tester, status, dragOffset: const Offset(0, 400));
    expect(status, findsOneWidget);
  });

  testWidgets('renders exactly the metadata the daemon supplies',
      (tester) async {
    // The daemon's list reply is the only source of tile text: the screen
    // projects id/kind/model/baseUrl/enabled and invents no status, health,
    // or validation field of its own. Extra keys in the reply are ignored
    // rather than decoded into a claim the daemon never made.
    await _pump(tester, providers: <Map<String, dynamic>>[
      <String, dynamic>{
        ..._seededProvider(),
        'validation': <String, dynamic>{
          'state': 'invalid',
          'message': 'bad key',
        },
        'isValid': true,
      },
    ]);

    final metadata = find.text(
        'open-ai-compatible · gpt · https://api.openai.com/v1 · enabled');
    await reveal(tester, metadata);
    expect(metadata, findsOneWidget);
    expect(find.textContaining('invalid'), findsNothing);
    expect(find.textContaining('bad key'), findsNothing);

    // A save reports only what the daemon answered ({ok, id}) — the screen
    // adds no validation verdict of its own.
    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p1');
    await selectKind(tester, 'google-gemini');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final savedStatus = find.text('Saved provider p1');
    await reveal(tester, savedStatus, dragOffset: const Offset(0, 400));
    expect(savedStatus, findsOneWidget);
    expect(find.textContaining('invalid'), findsNothing);
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

  testWidgets('save without an API key omits the rotation opt-in', (tester) async {
    final client = await _pump(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p2');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    expect(saveCall.payload, <String, dynamic>{
      'id': 'p2',
      'kind': 'open-ai-compatible',
      'model': '',
      'baseUrl': '',
      'enabled': true,
    });
    expect(saveCall.payload!.containsKey('apiKey'), isFalse);
    expect(saveCall.payload!.containsKey('rotateSecrets'), isFalse);
  });

  testWidgets('only daemon-supported provider kinds can be selected', (tester) async {
    final client = await _pump(tester);

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Kind'));
    await tester.pumpAndSettle();
    for (final label in <String>[
      'open-ai-compatible',
      'anthropic',
      'google-gemini',
      'aws-bedrock',
      'local-server',
    ]) {
      // The closed dropdown shows the current value while the open menu lists every supported kind.
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('llama-cpp'), findsNothing);
    await tester.tap(find.text('aws-bedrock').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Provider ID'), 'p3');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    final saveCall = client.calls.firstWhere(
      (c) => c.action == 'providers.save',
    );
    expect(saveCall.payload!['kind'], 'aws-bedrock');
  });

  testWidgets('save does not report success when model validation fails',
      (tester) async {
    final client = await _pump(tester, providers: <Map<String, dynamic>>[]);
    client.handler = (action, payload) {
      if (action == 'providers.save')
        return _ok(action, <String, dynamic>{'id': 'p-invalid'});
      if (action == 'providers.models')
        return _err(action, 'provider model discovery failed');
      if (action == 'providers.list')
        return _ok(action, <String, dynamic>{'providers': <dynamic>[]});
      return _ok(action, <String, dynamic>{});
    };
    await tester.enterText(
        find.widgetWithText(TextField, 'Provider ID'), 'p-invalid');
    await selectKind(tester, 'anthropic');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'bad-model');
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(
      client.calls.any((c) => c.action == 'providers.models'),
      isTrue,
      reason: 'the saved provider must be checked before claiming success',
    );
    expect(find.textContaining('Saved provider'), findsNothing);
    final error = find.textContaining('The daemon could not complete the request.');
    await revealStatus(tester, error);
    expect(error, findsWidgets);
  });
}
