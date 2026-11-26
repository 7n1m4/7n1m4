// SPDX-License-Identifier: GPL-3.0-or-later

// Card CRUD on the real cards screen: create, import (JSON and pngBase64),
// update and delete all go through the production DaemonClient wrappers, so
// these tests fail if a payload shape or a UI transition drifts.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/cards/cards_screen.dart';

import 'support/fakes.dart';

/// One recorded RPC: the verb and the exact payload the client sent.
typedef _Call = ({String action, Map<String, dynamic>? payload});

class _DeferredReply implements Exception {
  const _DeferredReply(this.future);
  final Future<RpcReply> future;
}

class _RecordingCardsClient extends FakeChatClient {
  final List<_Call> calls = <_Call>[];
  final List<Map<String, dynamic>> cards = <Map<String, dynamic>>[
    <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
  ];

  bool deleteFails = false;
  bool updateLies = false;
  bool truncatedList = false;


  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    final handler = onCall;
    if (handler != null) {
      try {
        return handler(action, payload);
      } on _DeferredReply catch (deferred) {
        return await deferred.future;
      }
    }

    calls.add((action: action, payload: payload));
    final data = _replyData(action, payload);
    if (data == null) {
      return const RpcReply(
        action: 'cards.delete',
        ok: false,
        error: RpcError(code: 'actions_disabled', message: 'actions off'),
      );
    }
    return RpcReply(action: action, ok: true, data: data);
  }

  /// The `data` object each verb replies with, or null for a failed reply.
  Map<String, dynamic>? _replyData(String action, Map<String, dynamic>? p) {
    switch (action) {
      case 'cards.list':
        if (!truncatedList) {
          return <String, dynamic>{'cards': cards, 'truncated': false};
        }
        final cursor = p?['cursor'] as int?;
        if (cursor != null) {
          return <String, dynamic>{
            'cards': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'card-2', 'name': 'Card Two'},
            ],
            'truncated': false,
          };
        }
        return <String, dynamic>{
          'cards': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
          ],
          'truncated': true,
        };
      case 'cards.get':
        final id = (p?['id'] as String?) ?? '';
        final found = cards.where((c) => c['id'] == id);
        return <String, dynamic>{
          'card': found.isEmpty ? null : found.first,
        };
      case 'cards.metadata':
      case 'cards.metadata.set':
        return <String, dynamic>{
          'id': (p?['id'] as String?) ?? '',
          'liked': p?['liked'] == true,
          'bookmarked': p?['bookmarked'] == true,
        };
      case 'cards.create':
        final name = (p?['name'] as String?) ?? '';
        final id = 'card-${cards.length + 1}';
        cards.add(<String, dynamic>{
          ...(p?['document'] as Map<String, dynamic>? ??
              const <String, dynamic>{}),
          'id': id,
          'name': name,
        });
        return <String, dynamic>{'id': id, 'name': name};
      case 'cards.update':
        final id = (p?['id'] as String?) ?? '';
        final document = <String, dynamic>{
          ...(p?['document'] as Map<String, dynamic>? ??
              const <String, dynamic>{}),
          'id': id,
        };
        final index = cards.indexWhere((c) => c['id'] == id);
        if (index >= 0) {
          cards[index] = document;
        } else {
          cards.add(document);
        }
        return <String, dynamic>{
          'id': id,
          'name': (document['name'] as String?) ?? '',
          'updated': !updateLies,
        };
      case 'cards.import':
        final card = p?['card'];
        final name = card is Map<String, dynamic>
            ? (card['name'] as String?) ?? 'Imported'
            : 'Imported';
        final id = 'card-${cards.length + 1}';
        cards.add(<String, dynamic>{'id': id, 'name': name});
        return <String, dynamic>{'id': id, 'name': name, 'renamed': false};
      case 'cards.delete':
        if (deleteFails) return null;
        final id = (p?['id'] as String?) ?? '';
        final before = cards.length;
        cards.removeWhere((c) => c['id'] == id);
        return <String, dynamic>{'deleted': cards.length < before};
      default:
        return const <String, dynamic>{};
    }
  }

  List<Map<String, dynamic>?> payloadsFor(String action) => calls
      .where((c) => c.action == action)
      .map((c) => c.payload)
      .toList(growable: false);
}

Future<_RecordingCardsClient> _pump(tester) async {
  final client = _RecordingCardsClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: CardsScreen(client: client)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  return client;
}

/// The import field, addressed by its stable label.
Finder _importField() =>
    find.widgetWithText(TextField, 'Card JSON (object or envelope)');

/// The create form's name field. The create and detail forms share one
/// controller, so once a card is open both are mounted and a bare `Name`
/// finder is ambiguous; this keys the create form via its ancestor card
/// (ancestor of the Create button).
Finder _createNameField() => find.descendant(
      of: find.ancestor(
        of: find.widgetWithText(FilledButton, 'Create'),
        matching: find.byType(Card),
      ),
      matching: find.widgetWithText(TextField, 'Name'),
    );

/// The create form's document field, scoped the same way.
Finder _createDocumentField() => find.descendant(
      of: find.ancestor(
        of: find.widgetWithText(FilledButton, 'Create'),
        matching: find.byType(Card),
      ),
      matching: find.widgetWithText(TextField, 'Card JSON document'),
    );

/// The open detail form's name field. Scoped by the detail card's Save
/// button's ancestor card so the create form's shared-controller Name field
/// is excluded.
Finder _detailNameField() => find.descendant(
      of: find.ancestor(
        of: find.widgetWithText(FilledButton, 'Save'),
        matching: find.byType(Card),
      ),
      matching: find.widgetWithText(TextField, 'Name'),
    );

/// The open detail form's document field.
Finder _detailDocumentField() => find.descendant(
      of: find.ancestor(
        of: find.widgetWithText(FilledButton, 'Save'),
        matching: find.byType(Card),
      ),
      matching: find.widgetWithText(TextField, 'Card JSON document'),
    );

/// Brings [finder] into view (scrolling the cards list if needed) and pumps a
/// frame so a following tap/enterText lands on a laid-out, on-screen widget.
Future<void> _reveal(tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Scrolls the list to the bottom to reveal off-screen widgets.
Future<void> _scrollTo(tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, -4000));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, 4000));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _openCard(tester) async {
  final row = find.widgetWithText(ListTile, 'Card One');
  await _reveal(tester, row);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('create sends {name, document} and opens the new card', (
    tester,
  ) async {
    final client = await _pump(tester);

    await tester.enterText(_createNameField(), 'Card Two');
    await tester.enterText(
      _createDocumentField(),
      '{"spec":"chara_card_v2","data":{"description":"hi"}}',
    );
    await _reveal(tester, find.widgetWithText(FilledButton, 'Create'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.create'), <Map<String, dynamic>?>[
      <String, dynamic>{
        'name': 'Card Two',
        'document': <String, dynamic>{
          'spec': 'chara_card_v2',
          'data': <String, dynamic>{'description': 'hi'},
          'name': 'Card Two',
        },
      },
    ]);
    // The create form clears, so the detail form owns the only `Name` field.
    expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);
    await _scrollToTop(tester, find.text('Created "Card Two" as card-2'));
    expect(find.text('Created "Card Two" as card-2'), findsOneWidget);
    // The new card opens, so its metadata surface is live.
    await _reveal(tester, find.widgetWithText(CheckboxListTile, 'Liked'));
    expect(find.widgetWithText(CheckboxListTile, 'Liked'), findsOneWidget);
    expect(
      client.payloadsFor('cards.metadata'),
      isNotEmpty,
      reason: 'the new card detail loads its metadata',
    );
  });

  testWidgets('import sends {card} and reports the daemon name', (
    tester,
  ) async {
    final client = await _pump(tester);

    await tester.enterText(
      _importField(),
      '{"name":"Imported One","spec":"chara_card_v2"}',
    );
    await _reveal(tester, find.widgetWithText(FilledButton, 'Import'));
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.import'), <Map<String, dynamic>?>[
      <String, dynamic>{
        'card': <String, dynamic>{
          'name': 'Imported One',
          'spec': 'chara_card_v2',
        },
      },
    ]);
    await _scrollToTop(tester, find.text('Imported "Imported One" as card-2'));
    expect(find.text('Imported "Imported One" as card-2'), findsOneWidget);
    final imported = find.widgetWithText(ListTile, 'Imported One');
    await _reveal(tester, imported);
    expect(
      imported,
      findsOneWidget,
      reason: 'the list refreshes from cards.list after import',
    );
  });

  testWidgets('import accepts a pngBase64 envelope', (tester) async {
    final client = await _pump(tester);

    await tester.enterText(_importField(), '{"pngBase64":"aGk="}');
    await _reveal(tester, find.widgetWithText(FilledButton, 'Import'));
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.import'), <Map<String, dynamic>?>[
      <String, dynamic>{'pngBase64': 'aGk='},
    ]);
  });

  testWidgets('a malformed import never reaches the daemon', (tester) async {
    final client = await _pump(tester);

    await tester.enterText(_importField(), 'not json');
    await _reveal(tester, find.widgetWithText(FilledButton, 'Import'));
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();

    expect(client.payloadsFor('cards.import'), isEmpty);
    await _scrollToTop(tester, find.text('Paste a JSON card object to import.'));
    expect(find.text('Paste a JSON card object to import.'), findsOneWidget);
  });

  testWidgets('create rejects a non-object document before the wire', (
    tester,
  ) async {
    final client = await _pump(tester);

    await tester.enterText(_createNameField(), 'Card Two');
    await tester.enterText(_createDocumentField(), '[1,2,3]');
    await _reveal(tester, find.widgetWithText(FilledButton, 'Create'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();

    expect(client.payloadsFor('cards.create'), isEmpty);
    await _scrollToTop(tester, find.text('The document must be a JSON object.'));
    expect(find.text('The document must be a JSON object.'), findsOneWidget);
  });

  testWidgets('update sends {id, document} for the open card', (tester) async {
    final client = await _pump(tester);
    await _openCard(tester);

    await _scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
    await tester.enterText(
      _detailDocumentField(),
      '{"name":"Card One","data":{"description":"updated"}}',
    );
    await _reveal(tester, find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.update'), <Map<String, dynamic>?>[
      <String, dynamic>{
        'id': 'card-1',
        'document': <String, dynamic>{
          'name': 'Card One',
          'data': <String, dynamic>{'description': 'updated'},
        },
      },
    ]);
    await _scrollToTop(tester, find.text('Saved "Card One" (card-1)'));
    expect(find.text('Saved "Card One" (card-1)'), findsOneWidget);
  });

  testWidgets('save rejects an empty name before the wire', (tester) async {
    final client = await _pump(tester);
    await _openCard(tester);

    await _scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
    await tester.enterText(_detailNameField(), '');
    await _reveal(tester, find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(client.payloadsFor('cards.update'), isEmpty);
    await _scrollToTop(tester, find.text('A name is required.'));
    expect(find.text('A name is required.'), findsOneWidget);
  });

  testWidgets('a lying cards.update reply surfaces instead of a false save', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.updateLies = true;
    await _openCard(tester);

    await _scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    await _scrollToTop(tester, find.text('Invalid cards.update reply.'));
    expect(find.text('Invalid cards.update reply.'), findsOneWidget);
    expect(find.textContaining('Saved "Card One"'), findsNothing);
  });

  testWidgets('delete confirms, then removes the card from the list', (
    tester,
  ) async {
    final client = await _pump(tester);

    final delete = find.byTooltip('Delete card');
    await _reveal(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete card?'), findsOneWidget);
    expect(client.payloadsFor('cards.delete'), isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.delete'), <Map<String, dynamic>?>[
      <String, dynamic>{'id': 'card-1'},
    ]);
    await _scrollToTop(tester, find.text('Deleted "Card One"'));
    expect(find.text('Deleted "Card One"'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Card One'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('No cards available'), findsOneWidget);
  });

  testWidgets('cancelling a delete leaves the card alone', (tester) async {
    final client = await _pump(tester);

    final delete = find.byTooltip('Delete card');
    await _reveal(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.delete'), isEmpty);
    expect(find.widgetWithText(ListTile, 'Card One'), findsOneWidget);
  });

  testWidgets('an idempotent delete of a missing card is not an error', (
    tester,
  ) async {
    final client = await _pump(tester);
    // The daemon reports deleted:false when the row is already gone.
    client.cards.removeWhere((c) => c['id'] == 'card-1');

    final delete = find.byTooltip('Delete card');
    await _reveal(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(client.payloadsFor('cards.delete'), <Map<String, dynamic>?>[
      <String, dynamic>{'id': 'card-1'},
    ]);
    await _scrollToTop(tester, find.text('"Card One" was already gone'));
    expect(find.text('"Card One" was already gone'), findsOneWidget);
  });

  testWidgets('a failed delete surfaces the daemon error', (tester) async {
    final client = await _pump(tester);
    client.deleteFails = true;

    final delete = find.byTooltip('Delete card');
    await _reveal(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    await _scrollToTop(tester, find.text('actions off'));
    expect(find.text('actions off'), findsOneWidget);
    await _reveal(tester, find.widgetWithText(ListTile, 'Card One'));
    expect(find.widgetWithText(ListTile, 'Card One'), findsOneWidget);
  });

  testWidgets('a failed refresh surfaces the daemon error', (tester) async {
    final client = await _pump(tester);
    client.onCall = (action, payload) => throw const DaemonClientException(
          kind: DaemonFailureKind.notConnected,
          message: 'Not connected to the daemon.',
        );

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pump();
    expect(find.text('Not connected to the daemon.'), findsOneWidget);
    await _reveal(tester, find.widgetWithText(ListTile, 'Card One'));
    expect(find.widgetWithText(ListTile, 'Card One'), findsOneWidget);
  });

  testWidgets('an unreachable daemon keeps the cards list honest', (
    tester,
  ) async {
    final client = _RecordingCardsClient();
    client.onCall = (action, payload) => throw const DaemonClientException(
          kind: DaemonFailureKind.notConnected,
          message: 'Not connected to the daemon.',
        );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CardsScreen(client: client)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pump();
    expect(find.text('Not connected to the daemon.'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('No cards available'), findsOneWidget);
    expect(
      find.text('Card management is not available on the local daemon.'),
      findsNothing,
    );
  });

  testWidgets('card documents round-trip through jsonEncode unchanged', (
    tester,
  ) async {
    final client = await _pump(tester);
    final document = <String, dynamic>{
      'spec': 'chara_card_v2',
      'name': 'Card One',
      'data': <String, dynamic>{
        'description': 'first',
        'extensions': <String, dynamic>{
          'airi': <String, dynamic>{'liked': false},
        },
      },
      'unknownTopLevelKey': <String, dynamic>{'keep': true},
    };
    client.cards
      ..clear()
      ..add(<String, dynamic>{...document, 'id': 'card-9'});

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    await _openCard(tester);
    await _scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));

    // Two `Card JSON document` fields are mounted (create + detail share a
    // controller); read the detail one deterministically.
    final field = tester.widget<TextField>(_detailDocumentField());
    final decoded = jsonDecode(field.controller!.text) as Map<String, dynamic>;
    expect(decoded['id'], 'card-9');
    expect(Map<String, dynamic>.from(decoded)..remove('id'), document);
  });
  testWidgets('truncated cards list offers a load-more page', (tester) async {
    final client = _RecordingCardsClient()..truncatedList = true;
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CardsScreen(client: client))),
    );
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final more = find.byKey(const Key('cards-load-more'));
    expect(more, findsOneWidget);

    tester.widget<TextButton>(more).onPressed!();
    await tester.pump();
    await tester.pump();

    expect(client.payloadsFor('cards.list').last?['cursor'], 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'Card Two'), findsOneWidget);
    expect(more, findsNothing);
  });
  testWidgets('older cards append after newer rows', (tester) async {
    final client = _RecordingCardsClient()..truncatedList = true;
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CardsScreen(client: client))),
    );
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    tester.widget<TextButton>(find.byKey(const Key('cards-load-more'))).onPressed!();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final loaded = tester.widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title as Text).data)
        .toList();
    expect(loaded.indexOf('Card One'), lessThan(loaded.indexOf('Card Two')));
  });
  testWidgets('a refresh during load-more discards the stale page', (
    tester,
  ) async {
    final client = _RecordingCardsClient()..truncatedList = true;
    addTearDown(client.dispose);
    final oldPage = Completer<RpcReply>();
    client.onCall = (action, payload) {
      if (action == 'cards.list' && payload?['cursor'] != null) {
        throw _DeferredReply(oldPage.future);
      }
      client.calls.add((action: action, payload: payload));
      final data = client._replyData(action, payload);
      return RpcReply(
        action: action,
        ok: data != null,
        data: data ?? <String, dynamic>{},
      );
    };
    addTearDown(() {
      if (!oldPage.isCompleted) oldPage.complete(const RpcReply(action: 'cards.list', ok: true, data: <String, dynamic>{}));
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CardsScreen(client: client))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    tester.widget<TextButton>(find.byKey(const Key('cards-load-more'))).onPressed!();
    await tester.pump();

    tester.widget<IconButton>(find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(IconButton),
    )).onPressed!();
    await tester.pump();
    await tester.pump();
    oldPage.complete(RpcReply(
      action: 'cards.list',
      ok: true,
      data: <String, dynamic>{
        'cards': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'card-2', 'name': 'Card Two'},
        ],
        'truncated': false,
      },
    ));
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(ListTile, 'Card Two'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Card One'), findsOneWidget);
  });
}
