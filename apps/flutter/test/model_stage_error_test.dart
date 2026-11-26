// SPDX-License-Identifier: GPL-3.0-or-later

// The stage's failure contract: a card naming an asset this thin client cannot
// resolve must produce a visible, loud error with a typed code. No placeholder
// widget, no asset and no renderer is invented here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

Map<String, dynamic> _cardWith(Map<String, dynamic> airi) => <String, dynamic>{
      'spec': 'chara_card_v3',
      'data': <String, dynamic>{
        'name': 'Stage Card',
        'extensions': <String, dynamic>{'airi': airi},
      },
    };

Future<FakeChatClient> _pumpCard(
  WidgetTester tester,
  Map<String, dynamic> card, {
  RpcReply Function(String action, Map<String, dynamic>? payload)? onCall,
}) async {
  final client = FakeChatClient();
  addTearDown(client.dispose);
  client.onCall = onCall ?? ((action, payload) => RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'card': card},
      ));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ModelStage(client: client, cardId: 'card-1')),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  return client;
}

void main() {
  testWidgets('a missing file asset is a loud, coded error', (tester) async {
    await _pumpCard(tester, _cardWith(<String, dynamic>{
      'live2d': <String, dynamic>{'source': 'file', 'file': ''},
    }));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Missing model asset'), findsOneWidget);
    expect(find.textContaining(DisplayModel.missingAssetCode), findsOneWidget);
    expect(find.text('No display model'), findsNothing);
  });

  testWidgets('a url source that is not http(s) is an invalid asset', (tester) async {
    await _pumpCard(tester, _cardWith(<String, dynamic>{
      'vrm': <String, dynamic>{'source': 'url', 'url': 'gopher://host/m.vrm'},
    }));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Invalid model asset'), findsOneWidget);
    expect(find.textContaining(DisplayModel.invalidAssetCode), findsOneWidget);
  });

  testWidgets('an id-only display model is an unknown model kind', (tester) async {
    final card = _cardWith(<String, dynamic>{
      'displayModelId': 'live2d-test',
    });
    await _pumpCard(tester, card, onCall: (action, payload) => action == 'display-model.resolve'
        ? RpcReply(action: action, ok: false, error: RpcError(code: DisplayModel.unknownModelKindCode, message: 'Model kind is unresolved: unknown format in catalog.'))
        : RpcReply(action: action, ok: true, data: <String, dynamic>{'card': card}));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Model kind is unresolved'), findsOneWidget);
    expect(find.textContaining(DisplayModel.unknownModelKindCode), findsOneWidget);
    expect(find.textContaining('No display model'), findsNothing);
  });

  testWidgets('the loud error carries a screen-reader label', (tester) async {
    await _pumpCard(tester, _cardWith(<String, dynamic>{
      'mmd': <String, dynamic>{'source': 'file', 'file': '  '},
    }));

    expect(find.bySemanticsLabel('Model stage error: Missing model asset: the card names a mmd model but no file or URL.'), findsOneWidget);
  });

  testWidgets('a well-formed mmd descriptor stays a kind placeholder', (tester) async {
    await _pumpCard(tester, _cardWith(<String, dynamic>{
      'mmd': <String, dynamic>{'source': 'url', 'url': 'https://example.com/m.pmx'},
    }));

    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.textContaining('MMD model'), findsOneWidget);
  });

  testWidgets('a non-daemon load failure is named by its type, never inlined',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => throw StateError('secret socket text');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelStage(client: client, cardId: 'card-1')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('StateError'), findsOneWidget);
    expect(find.textContaining('secret socket text'), findsNothing);
  });
}