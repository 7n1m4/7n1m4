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

    test('the Vue modules.displayModelId assignment resolves', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'modules': <String, dynamic>{'displayModelId': 'model-in-modules'},
      }));
      expect(model.kind, ModelKind.none);
      expect(model.displayModelId, 'model-in-modules');
      expect(model.problemCode, DisplayModel.unknownModelKindCode);
    });

    test('a top-level displayModelId still resolves when modules is empty', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'top-level-model',
        'modules': <String, dynamic>{},
      }));
      expect(model.displayModelId, 'top-level-model');
    });

    test('a non-string nested id never masks a valid top-level id', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'top-level-model',
        'modules': <String, dynamic>{'displayModelId': 42},
      }));
      expect(model.displayModelId, 'top-level-model');
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

    test('a Vue active_state-only displayModelId resolves', () {
      // ROOT CAUSE: Vue's ControlStrip avatar assignment writes both
      // `active_state.displayModelId` and `modules.displayModelId`, but
      // cards authored/synced with only `active_state` restore no model in
      // Flutter because DisplayModel.fromCard reads only modules/top-level.
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'active_state': <String, dynamic>{'displayModelId': 'model-in-state'},
      }));
      expect(model.kind, ModelKind.none);
      expect(model.displayModelId, 'model-in-state');
      expect(model.problemCode, DisplayModel.unknownModelKindCode);
    });

    test('active_state wins over modules and legacy top-level ids', () {
      final model = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'legacy-model',
        'modules': <String, dynamic>{'displayModelId': 'module-model'},
        'active_state': <String, dynamic>{'displayModelId': 'state-model'},
      }));
      expect(model.displayModelId, 'state-model');
    });

    test('an empty active_state id falls back to modules and legacy ids', () {
      final fromModules = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'legacy-model',
        'modules': <String, dynamic>{'displayModelId': 'module-model'},
        'active_state': <String, dynamic>{'displayModelId': ''},
      }));
      expect(fromModules.displayModelId, 'module-model');

      final fromLegacy = DisplayModel.fromCard(_card(<String, dynamic>{
        'displayModelId': 'legacy-model',
        'active_state': <String, dynamic>{'displayModelId': 42},
      }));
      expect(fromLegacy.displayModelId, 'legacy-model');
    });

    test('active_state under root extensions is read for bare cards', () {
      final model = DisplayModel.fromCard(<String, dynamic>{
        'extensions': <String, dynamic>{
          'airi': <String, dynamic>{
            'active_state': <String, dynamic>{'displayModelId': 'root-state'},
          },
        },
      });
      expect(model.displayModelId, 'root-state');
    });

    test('root active_state wins over a data-only module mirror', () {
      final model = DisplayModel.fromCard(<String, dynamic>{
        'extensions': <String, dynamic>{
          'airi': <String, dynamic>{
            'active_state': <String, dynamic>{'displayModelId': 'root-state'},
          },
        },
        'data': <String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{
              'modules': <String, dynamic>{'displayModelId': 'data-module'},
            },
          },
        },
      });
      expect(model.displayModelId, 'root-state');
    });

    test('data active_state is read when the root active_state is empty', () {
      final model = DisplayModel.fromCard(<String, dynamic>{
        'extensions': <String, dynamic>{
          'airi': <String, dynamic>{
            'active_state': <String, dynamic>{'displayModelId': ''},
          },
        },
        'data': <String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{
              'active_state': <String, dynamic>{'displayModelId': 'data-state'},
            },
          },
        },
      });
      expect(model.displayModelId, 'data-state');
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

  testWidgets('a Vue active_state-only model resolves through the catalog', (
    tester,
  ) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) {
      if (action == 'cards.get') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'card': _card(<String, dynamic>{
              'active_state': <String, dynamic>{'displayModelId': 'state-model'},
            }),
          },
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'state-model',
          'name': 'State Model',
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