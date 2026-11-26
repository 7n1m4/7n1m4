// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import 'settings_catalog.dart';

/// Where a result goes when the user selects it.
enum SettingsSearchKind { catalog, provider, card }

/// One entry in the settings search index.
///
/// [route] is the deduplication key (mirroring Vue's `SearchItem.to`); the
/// screen does not navigate by route. Route-less catalog nodes fall back to
/// [id] so they are not collapsed into one entry. Catalog entries carry their
/// [node] so selection can reuse `_openCatalogNode`.
@immutable
class SettingsSearchItem {
  const SettingsSearchItem({
    required this.id,
    required this.title,
    required this.category,
    required this.route,
    required this.kind,
    this.description,
    this.keywords = const <String>[],
    this.node,
  });

  final String id;
  final String title;
  final String category;
  final String route;
  final SettingsSearchKind kind;
  final String? description;
  final List<String> keywords;
  final SettingsTopologyNode? node;
}

/// A bounded, in-memory index over the settings catalog plus hydrated cards
/// and providers. Mirrors `packages/stage-ui/src/constants/settings-search-index.ts`
/// and `SettingsSearchBar.vue`: dedupe by route (id fallback), title hits
/// first, at most 12 results.
@immutable
class SettingsSearchIndex {
  const SettingsSearchIndex._(this.items);

  factory SettingsSearchIndex.build({
    SettingsTopology? topology,
    Iterable<Map<String, dynamic>> providers = const <Map<String, dynamic>>[],
    Iterable<Map<String, dynamic>> cards = const <Map<String, dynamic>>[],
  }) {
    final settingsTopology = topology ?? settingsCatalogTopology;
    final items = <SettingsSearchItem>[];
    final seenRoutes = <String>{};

    void add(SettingsSearchItem item) {
      // Route-less catalog nodes would otherwise all collapse onto ''.
      final key = item.route.isEmpty ? item.id : item.route;
      if (seenRoutes.add(key)) items.add(item);
    }

    // Cards first, then catalog and providers — the same source order Vue
    // uses, so a duplicate route keeps the first (most specific) entry.
    for (final card in cards) {
      add(_cardItem(card));
    }
    for (final node in settingsTopology.nodesById.values) {
      if (node.id == settingsTopology.rootId ||
          node.kind == CatalogNodeKind.root ||
          !node.visible) {
        continue;
      }
      add(_catalogItem(node));
    }
    for (final provider in providers) {
      add(_providerItem(provider));
    }

    return SettingsSearchIndex._(
        List<SettingsSearchItem>.unmodifiable(items));
  }

  final List<SettingsSearchItem> items;

  List<SettingsSearchItem> search(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return const <SettingsSearchItem>[];
    }

    final matched = <({int index, SettingsSearchItem item})>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (_matches(item, query)) matched.add((index: i, item: item));
    }
    // Dart's List.sort is not stable; the index keeps same-tier source order.
    matched.sort((a, b) {
      final byTier = _tier(a.item, query).compareTo(_tier(b.item, query));
      return byTier != 0 ? byTier : a.index.compareTo(b.index);
    });
    return matched
        .take(12)
        .map((entry) => entry.item)
        .toList(growable: false);
  }

  /// Vue filters on title/category/description/keywords only: id and route
  /// may rank a hit but must not make a term match.
  static bool _matches(SettingsSearchItem item, String query) =>
      item.title.toLowerCase().contains(query) ||
      item.category.toLowerCase().contains(query) ||
      (item.description?.toLowerCase().contains(query) ?? false) ||
      item.keywords.any((keyword) => keyword.toLowerCase().contains(query));

  /// Vue's 0-3 tiers: title, id/route, keyword, then everything else.
  static int _tier(SettingsSearchItem item, String query) {
    if (item.title.toLowerCase().contains(query)) return 0;
    if (item.id.toLowerCase().contains(query) ||
        item.route.toLowerCase().contains(query)) {
      return 1;
    }
    if (item.keywords.any((keyword) => keyword.toLowerCase().contains(query))) {
      return 2;
    }
    return 3;
  }

  static SettingsSearchItem _catalogItem(SettingsTopologyNode node) {
    final route = node.route ?? '';
    final segments = route.split('/').where((part) => part.isNotEmpty);
    return SettingsSearchItem(
      id: node.id,
      title: node.label,
      category: _catalogCategory(node),
      description: node.description,
      route: route,
      kind: SettingsSearchKind.catalog,
      keywords: <String>[
        node.id,
        node.label,
        node.shortLabel,
        ...segments,
      ],
      node: node,
    );
  }

  static String _catalogCategory(SettingsTopologyNode node) {
    switch (node.kind) {
      case CatalogNodeKind.area:
        return 'Primary Page';
      case CatalogNodeKind.tool:
        return 'Developer Tools';
      default:
        break;
    }
    if (node.parentId != null) {
      final parent = switch (node.parentId) {
        'area-modules' => 'Modules',
        'area-system' => 'System Preferences',
        'area-models' => 'Companion Avatars',
        'area-memory' => 'Memory Systems',
        'area-card' => 'Character Cards',
        'prov-cat-chat' => 'Providers (Chat)',
        'prov-cat-speech' => 'Providers (Speech)',
        'prov-cat-stt' => 'Providers (Hearing)',
        'prov-cat-artistry' => 'Providers (Artistry)',
        'prov-cat-motion' => 'Providers (Motion)',
        'prov-cat-cloud' => 'Providers (Cloud)',
        _ => null,
      };
      if (parent != null) return parent;
    }
    final group = node.clusterGroup
        ?.replaceAll(RegExp(r'[\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF]'), '')
        .trim();
    return (group == null || group.isEmpty) ? 'Settings' : group;
  }

  static SettingsSearchItem _providerItem(Map<String, dynamic> provider) {
    final id = (provider['id'] ?? '').toString();
    final kind = (provider['name'] ?? provider['kind'] ?? id).toString();
    final title = kind.isEmpty ? 'Provider' : kind;
    final categoryKey = (provider['category'] ?? provider['kind'] ?? '').toString();
    final category = _providerCategories[categoryKey] ??
        (categoryKey.isEmpty ? 'Providers' : 'Providers ($categoryKey)');
    final description = provider['description']?.toString();
    final keywords = <String>[
      id,
      title,
      categoryKey,
      if (provider['model'] is String) provider['model'] as String,
      if (provider['deployment'] is String) provider['deployment'] as String,
      ...?switch (provider['tasks']) {
        final List tasks => tasks.map((task) => task.toString()).toList(),
        _ => null,
      },
    ];
    return SettingsSearchItem(
      id: 'prov-$id',
      title: title,
      category: category,
      description: description ?? '$title $category provider',
      route: '/settings/providers/$id',
      kind: SettingsSearchKind.provider,
      keywords: keywords,
    );
  }

  static const Map<String, String> _providerCategories = <String, String>{
    'chat': 'Providers (Chat)',
    'speech': 'Providers (Speech)',
    'transcription': 'Providers (Hearing)',
    'embed': 'Providers (Embedding)',
    'vision': 'Providers (Vision)',
    'artistry': 'Providers (Artistry)',
    'motion': 'Providers (Motion)',
    'cloud': 'Providers (Cloud)',
  };

  static SettingsSearchItem _cardItem(Map<String, dynamic> card) {
    final id = (card['id'] ?? '').toString();
    final name = (card['name'] ?? '').toString();
    final title = name.isEmpty ? 'Unnamed Character' : name;
    return SettingsSearchItem(
      id: 'card-$id',
      title: title,
      category: 'Character Card',
      description: 'Open $title\'s card editor',
      route: '/settings/airi-card?cardId=$id',
      kind: SettingsSearchKind.card,
      keywords: <String>['character', 'card', title.toLowerCase(), id],
    );
  }
}
