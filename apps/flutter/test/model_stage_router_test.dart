// SPDX-License-Identifier: GPL-3.0-or-later

// Routing coverage for the stage shell's model-kind seam. Every test drives the
// production ModelStage through the production DaemonClient wrapper with the
// shared in-memory fake; no model asset is fabricated and no renderer is claimed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/l10n/app_localizations.dart';
import 'package:anima_control/navigation/navigation_shell.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

/// A card document as the daemon stores it: CCv3 envelope with the AIRI
/// extension under `data.extensions.airi`.
Map<String, dynamic> _card(Map<String, dynamic> airi) => <String, dynamic>{
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': <String, dynamic>{
        'name': 'Stage Card',
        'extensions': <String, dynamic>{'airi': airi},
      },
    };

Future<void> _pump(
  WidgetTester tester,
  FakeChatClient client,
  String? cardId,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ModelStage(client: client, cardId: cardId)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  group('DisplayModel.fromCard', () {
    test('a null card has no model', () {
      expect(DisplayModel.fromCard(null).kind, ModelKind.none);
      expect(DisplayModel.fromCard(null).problem, isNull);
    });

    test('a card without an airi extension has no model', () {
      final model = DisplayModel.fromCard(<String, dynamic>{'name': 'Bare'});
      expect(model.kind, ModelKind.none);
      expect(model.asset, isNull);
    });

    test('an inline vrm descriptor yields a vrm asset', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'vrm': <String, dynamic>{
          'source': 'url',
          'url': 'https://example.com/m.vrm',
        },
      }));
      expect(model.kind, ModelKind.vrm);
      expect(model.asset?.source, 'url');
      expect(model.asset?.value, 'https://example.com/m.vrm');
      expect(model.problem, isNull);
    });

    test('a displayModelId-only card is an unknown model kind', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'live2d-test',
      }));
      expect(model.kind, ModelKind.none);
      expect(model.problemCode, DisplayModel.unknownModelKindCode);
      expect(model.displayModelId, 'live2d-test');
    });

    test('a non-http url source is an invalid asset', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'live2d': <String, dynamic>{
          'source': 'url',
          'url': 'ftp://host/m.zip',
        },
      }));
      expect(model.problemCode, DisplayModel.invalidAssetCode);
    });
  });

  testWidgets('no card id renders the placeholder, never an error',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);

    await _pump(tester, client, null);

    expect(find.text('No display model'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('an empty card id renders the placeholder without an RPC',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    var calls = 0;
    client.onCall = (action, payload) {
      calls++;
      return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    };

    await _pump(tester, client, '');

    expect(find.text('No display model'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('cards.get returning null renders the placeholder',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) =>
        RpcReply(action: action, ok: true, data: <String, dynamic>{});

    await _pump(tester, client, 'card-1');

    expect(find.text('No display model'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('a valid vrm descriptor renders the kind placeholder',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'card': _card(<String, dynamic>{
              'vrm': <String, dynamic>{
                'source': 'url',
                'url': 'https://example.com/m.vrm',
              },
            }),
          },
        );

    await _pump(tester, client, 'card-1');

    expect(find.textContaining('VRM'), findsOneWidget);
    expect(find.text('No display model'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('a missing asset is a loud error, not a placeholder',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'card': _card(<String, dynamic>{
              'vrm': <String, dynamic>{'source': 'file', 'file': ''},
            }),
          },
        );

    await _pump(tester, client, 'card-1');

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Missing model asset'), findsOneWidget);
    expect(find.textContaining('missing-asset'), findsOneWidget);
    expect(find.textContaining('VRM model'), findsNothing);
    expect(find.text('No display model'), findsNothing);
  });

  testWidgets('a load failure is loud and carries the daemon message',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => throw const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: 'cards.get exploded',
        );

    await _pump(tester, client, 'card-1');

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('cards.get exploded'), findsOneWidget);
    expect(find.textContaining('load-failed'), findsOneWidget);
  });

  testWidgets('the stage is a shell destination rendering the placeholder',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NavigationShell(client: client),
    ));
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Stage'), findsOneWidget);

    await tester.tap(find.text('Stage'));
    await tester.pumpAndSettle();

    expect(find.byType(StageScreen), findsOneWidget);
    expect(find.text('No display model'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('displayModelId resolves through daemon catalog', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) {
      if (action == 'cards.get') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'card': _card(<String, dynamic>{'displayModelId': 'live2d-test'}),
          },
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'live2d-test',
          'name': 'Live2D Test',
          'format': 'live2d-zip',
          'source': 'url',
          'url': 'https://example.com/m.zip',
          'file': '',
        },
      );
    };

    await _pump(tester, client, 'card-1');

    expect(find.textContaining('LIVE2D'), findsOneWidget);
    expect(find.text('No display model'), findsNothing);
  });

}