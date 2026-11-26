// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/cards/cards_screen.dart';
import 'package:anima_control/features/providers/providers_screen.dart';
import 'package:anima_control/features/settings/settings_catalog.dart';
import 'package:anima_control/features/settings/settings_search.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

SettingsTopologyNode _node(
  String id,
  String label, {
  String? parentId,
  String? shortLabel,
  String? description,
  String? clusterGroup,
  String? route,
  CatalogNodeKind kind = CatalogNodeKind.page,
  bool hidden = false,
}) =>
    SettingsTopologyNode(
      id: id,
      label: label,
      shortLabel: shortLabel ?? label,
      order: 0,
      parentId: parentId,
      children: const <String>[],
      kind: kind,
      route: route ?? '/settings/$id',
      description: description,
      clusterGroup: clusterGroup,
      hidden: hidden,
    );

SettingsTopology _topology() => SettingsTopology(
      rootId: 'hub',
      nodesById: <String, SettingsTopologyNode>{
        'hub': _node('hub', 'Settings Hub', kind: CatalogNodeKind.root),
        'area-providers': _node('area-providers', 'Inference Providers',
            kind: CatalogNodeKind.area),
        'area-system': _node('area-system', 'System Preferences',
            kind: CatalogNodeKind.area),
        'sys-connection': _node('sys-connection', 'Connection & Downloads',
            parentId: 'area-system'),
        'area-card': _node('area-card', 'AIRI Card Editor',
            kind: CatalogNodeKind.area),
        // A hidden/deprecated node must never surface in the search index.
        'ghost': _node('ghost', 'Artistry (Deprecated)', hidden: true),
      },
    );

void main() {
  group('SettingsSearchIndex', () {
    test('excludes the hub root and hidden catalog nodes', () {
      final index = SettingsSearchIndex.build(topology: _topology());

      expect(
        index.search('settings').map((item) => item.id),
        isNot(contains('hub')),
      );
      expect(index.search('artistry'), isEmpty);
      expect(index.search('connection').single.title, 'Connection & Downloads');
    });

    test('ranks exact title hits above id, keyword and description hits', () {
      final topology = SettingsTopology(
        rootId: 'hub',
        nodesById: <String, SettingsTopologyNode>{
          'hub': _node('hub', 'Settings Hub', kind: CatalogNodeKind.root),
          'title': _node('title', 'OpenAI', description: 'chat provider'),
          'route': _node('route', 'Compat',
              route: '/settings/openai-compat', description: 'chat provider'),
          'keyword': _node('keyword', 'Bridge',
              shortLabel: 'openai', description: 'chat provider'),
          'description': _node('description', 'Streaming',
              description: 'offers openai-compatible endpoints'),
        },
      );

      final titles = SettingsSearchIndex.build(topology: topology)
          .search('openai')
          .map((item) => item.title)
          .toList();

      expect(
        titles,
        <String>['OpenAI', 'Compat', 'Bridge', 'Streaming'],
        reason:
            'exact title > route/id > keyword > description-only substring',
      );
    });

    test('deduplicates by route, keeping the first source', () {
      final index = SettingsSearchIndex.build(
        topology: _topology(),
        providers: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'dup', 'kind': 'openai', 'name': 'First'},
          <String, dynamic>{'id': 'dup', 'kind': 'openai', 'name': 'Second'},
        ],
        cards: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'c1', 'name': 'Kira'},
          <String, dynamic>{'id': 'c1', 'name': 'Kira Copy'},
        ],
      );

      final routes = index.items.map((item) => item.route).toList();
      expect(routes.where((route) => route == '/settings/providers/dup'),
          hasLength(1));
      expect(
        routes.where((route) => route == '/settings/airi-card?cardId=c1'),
        hasLength(1),
      );
      expect(index.search('kira').single.title, 'Kira');
    });

    test('caps results at the default limit of 12', () {
      final providers = <Map<String, dynamic>>[
        for (var i = 0; i < 20; i++)
          <String, dynamic>{'id': 'p$i', 'name': 'Provider $i'},
      ];
      final index =
          SettingsSearchIndex.build(topology: _topology(), providers: providers);

      expect(index.search('provider'), hasLength(12));
    });

    test('curated aliases flow from catalog nodes into the index', () {
      final node = settingsCatalogTopology.nodesById['area-providers']!;
      expect(node.keywords, contains('api key'));

      final index = SettingsSearchIndex.build();
      final item = index.items.singleWhere((i) => i.id == 'area-providers');
      expect(item.keywords, contains('api key'));
      expect(index.search('api key').single.id, 'area-providers');
    });

    test('a blank query offers the first eight suggestions', () {
      final index = SettingsSearchIndex.build();
      expect(index.search(''), orderedEquals(index.items.take(8).toList()));
      expect(index.search('   '), hasLength(8));
    });

    test('id/route-only terms do not create a match', () {
      final index = SettingsSearchIndex.build(
        topology: _topology(),
        providers: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'p1', 'name': 'Kira'},
        ],
      );

      // 'prov-' lives only in the synthetic id, never in a searchable field.
      expect(index.search('prov-'), isEmpty);
      expect(index.search('kira').single.id, 'prov-p1');
    });

    test('route-less catalog nodes dedupe by id', () {
      final topology = SettingsTopology(
        rootId: 'hub',
        nodesById: <String, SettingsTopologyNode>{
          'hub': _node('hub', 'Settings Hub', kind: CatalogNodeKind.root),
          'first': _node('first', 'First', route: ''),
          'second': _node('second', 'Second', route: ''),
        },
      );

      final ids = SettingsSearchIndex.build(topology: topology)
          .items
          .map((item) => item.id)
          .toList();
      expect(ids, containsAll(<String>['first', 'second']));
    });

    test('indexes live providers and cards with routable metadata', () {
      final index = SettingsSearchIndex.build(
        topology: _topology(),
        providers: const <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'openai',
            'kind': 'openai',
            'model': 'gpt-test',
            'enabled': true,
          },
        ],
        cards: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'c1', 'name': 'Kira'},
        ],
      );

      final card = index.search('kira').single;
      expect(card.kind, SettingsSearchKind.card);
      expect(card.route, '/settings/airi-card?cardId=c1');

      final provider = index.search('openai').first;
      expect(provider.kind, SettingsSearchKind.provider);
      expect(provider.route, '/settings/providers/openai');
    });

    test('deep-link routes percent-encode reserved characters in ids', () {
      final index = SettingsSearchIndex.build(
        topology: _topology(),
        providers: const <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'acme&?rival',
            'kind': 'acme',
            'name': 'Special Acme',
          },
        ],
        cards: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'kira/&alt', 'name': 'Kira Alt'},
        ],
      );

      final providerRoute = index.search('special').single.route;
      final cardRoute = index.search('kira').single.route;
      expect(providerRoute, '/settings/providers/acme%26%3Frival');
      expect(cardRoute, '/settings/airi-card?cardId=kira%2F%26alt');

      // The screen parses with Uri too: both ids must round-trip exactly.
      expect(Uri.parse(providerRoute).pathSegments.last, 'acme&?rival');
      expect(Uri.parse(cardRoute).queryParameters['cardId'], 'kira/&alt');
    });
  });

  group('SettingsScreen search', () {
    Widget screen(FakeChatClient client, {void Function()? onConnections}) =>
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              client: client,
              onOpenConnections: onConnections ?? () {},
            ),
          ),
        );

    FakeChatClient hydratedClient() {
      final client = FakeChatClient();
      client.onCall = (action, payload) => switch (action) {
            'cards.get' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'card': <String, dynamic>{'id': 'c1', 'name': 'Kira'},
                },
              ),
            'cards.metadata' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'id': 'c1',
                  'liked': false,
                  'bookmarked': false,
                },
              ),
            'cards.list' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'cards': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 'c1', 'name': 'Kira'},
                  ],
                  'truncated': false,
                },
              ),
            'providers.list' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'providers': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'openai',
                      'kind': 'openai',
                      'model': 'gpt-test',
                      'enabled': true,
                    },
                  ],
                },
              ),
            'runtime.status' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{'app': 'anima-daemon', 'version': 'test'},
              ),
            'settings.get' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'settings': <String, dynamic>{'language': 'en'},
                },
              ),
            _ => RpcReply(action: action, ok: true, data: <String, dynamic>{}),
          };
      return client;
    }

    /// A client whose `cards.get` echoes the requested id, so the open detail
    /// proves exactly which id the deep link resolved to.
    FakeChatClient deepLinkClient({
      required List<Map<String, dynamic>> providers,
      required List<Map<String, dynamic>> cards,
    }) {
      final client = FakeChatClient();
      client.onCall = (action, payload) => switch (action) {
            'cards.list' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{'cards': cards, 'truncated': false},
              ),
            'cards.get' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'card': cards.firstWhere(
                    (card) => card['id'] == payload?['id'],
                    orElse: () => <String, dynamic>{},
                  ),
                },
              ),
            'cards.metadata' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'id': payload?['id'] ?? '',
                  'liked': false,
                  'bookmarked': false,
                },
              ),
            'providers.list' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{'providers': providers},
              ),
            'runtime.status' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{'app': 'anima-daemon', 'version': 'test'},
              ),
            'settings.get' => RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'settings': <String, dynamic>{'language': 'en'},
                },
              ),
            _ => RpcReply(action: action, ok: true, data: <String, dynamic>{}),
          };
      return client;
    }

    testWidgets('a card result opens that exact card', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = hydratedClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'kira');
      await tester.pumpAndSettle();

      final tile =
          find.byKey(const ValueKey<String>('settings-search-result-card-c1'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardsScreen>(find.byType(CardsScreen)).initialCardId,
        'c1',
      );
      expect(
        find.byKey(const ValueKey<String>('card-detail-c1')),
        findsOneWidget,
        reason: 'the target card editor is open, not just the list',
      );
    });

    testWidgets('a provider result selects that exact provider', (tester) async {
      final client = hydratedClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'openai');
      await tester.pumpAndSettle();

      final tile = find.byKey(
          const ValueKey<String>('settings-search-result-prov-openai'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        tester.widget<ProvidersScreen>(find.byType(ProvidersScreen))
            .initialProviderId,
        'openai',
      );
      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Provider ID'),
      );
      expect(idField.controller!.text, 'openai');
      final modelField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Model'),
      );
      expect(modelField.controller!.text, 'gpt-test');
    });

    testWidgets('a provider id with reserved characters selects only that provider',
        (tester) async {
      const specialId = 'acme&?rival';
      const decoyId = 'acme&'; // what the unencoded route would resolve to
      final client = deepLinkClient(
        providers: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': specialId,
            'kind': 'open-ai-compatible',
            'model': 'special-model',
            'enabled': true,
          },
          <String, dynamic>{
            'id': decoyId,
            'kind': 'open-ai-compatible',
            'model': 'decoy-model',
            'enabled': true,
          },
        ],
        cards: const <Map<String, dynamic>>[],
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'acme');
      await tester.pumpAndSettle();

      final tile = find.byKey(
          const ValueKey<String>('settings-search-result-prov-acme&?rival'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        tester.widget<ProvidersScreen>(find.byType(ProvidersScreen))
            .initialProviderId,
        specialId,
      );
      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Provider ID'),
      );
      expect(idField.controller!.text, specialId);
      expect(idField.controller!.text, isNot(decoyId),
          reason: 'the truncated id from an unencoded path is never selected');
      final modelField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Model'),
      );
      expect(modelField.controller!.text, 'special-model');
    });

    testWidgets('a card id with reserved characters opens only that card',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const specialId = 'kira/&alt';
      const decoyId = 'kira/'; // what the unencoded query would resolve to
      final client = deepLinkClient(
        providers: const <Map<String, dynamic>>[],
        cards: <Map<String, dynamic>>[
          <String, dynamic>{'id': specialId, 'name': 'Special Kira'},
          <String, dynamic>{'id': decoyId, 'name': 'Decoy Kira'},
        ],
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'kira');
      await tester.pumpAndSettle();

      final tile = find.byKey(
          const ValueKey<String>('settings-search-result-card-kira/&alt'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardsScreen>(find.byType(CardsScreen)).initialCardId,
        specialId,
      );
      expect(
        find.byKey(const ValueKey<String>('card-detail-kira/&alt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('card-detail-kira/')),
        findsNothing,
        reason: 'the truncated id from an unencoded query is never opened',
      );
    });

    testWidgets('selecting a result returns to the hub without suggestions',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = hydratedClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      final field = find.byKey(const Key('settings-search-field'));
      await tester.tap(field);
      await tester.enterText(field, 'connection');
      await tester.pumpAndSettle();

      final resultTiles = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
                'settings-search-result-'),
        skipOffstage: false,
      );
      expect(resultTiles, findsWidgets);

      // This catalog entry only fires a callback, so the hub stays mounted.
      await tester.tap(find.byKey(
          const ValueKey<String>('settings-search-result-sys-connection')));
      await tester.pumpAndSettle();

      expect(resultTiles, findsNothing);
      expect(find.text('Search Results'), findsNothing);
    });

    testWidgets('a focused empty search shows eight suggestions',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = hydratedClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.tap(find.byKey(const Key('settings-search-field')));
      await tester.pumpAndSettle();

      final suggestionTiles = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
                'settings-search-result-'),
        skipOffstage: false,
      );
      expect(suggestionTiles.evaluate().length, 8);
    });

    testWidgets('a catalog result routes through the catalog handler',
        (tester) async {
      final client = hydratedClient();
      addTearDown(client.dispose);
      var openedConnections = false;
      await tester.pumpWidget(
        screen(client, onConnections: () => openedConnections = true),
      );

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'connection');
      await tester.pumpAndSettle();

      final tile = find.byKey(
          const ValueKey<String>('settings-search-result-sys-connection'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(openedConnections, isTrue);
    });

    testWidgets('hidden catalog nodes stay out of search results',
        (tester) async {
      final client = hydratedClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(screen(client));

      await tester.enterText(
          find.byKey(const Key('settings-search-field')), 'artistry');
      await tester.pumpAndSettle();

      expect(find.text('Artistry (Deprecated)'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('settings-search-result-ghost')),
        findsNothing,
      );
    });
  });
}
