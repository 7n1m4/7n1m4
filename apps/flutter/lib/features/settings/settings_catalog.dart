// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

enum CatalogNodeKind { root, area, category, page, tool }

@immutable
class CatalogNodeItem {
  const CatalogNodeItem({
    required this.id,
    required this.label,
    required this.order,
    required this.parentId,
    this.shortLabel,
    this.titleKey,
    this.description,
    this.descriptionKey,
    this.glyph,
    this.clusterGroup,
    this.route,
    this.icon,
    this.kind,
    this.desktopOnly,
    this.hidden,
    this.deprecated,
    this.keywords = const <String>[],
  });

  final String id;
  final String label;
  final String? shortLabel;
  final String? titleKey;
  final String? description;
  final String? descriptionKey;
  final String? glyph;
  final String? clusterGroup;
  final String? route;
  final String? icon;
  final num order;
  final String? parentId;
  final CatalogNodeKind? kind;
  final bool? desktopOnly;
  final bool? hidden;
  final bool? deprecated;
  final List<String> keywords;
}

@immutable
class SettingsTopologyNode {
  const SettingsTopologyNode({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.order,
    required this.parentId,
    required this.children,
    this.titleKey,
    this.description,
    this.descriptionKey,
    this.glyph,
    this.route,
    this.kind,
    this.icon,
    this.desktopOnly,
    this.hidden,
    this.deprecated,
    this.clusterGroup,
  });

  final String id;
  final String label;
  final String shortLabel;
  final String? titleKey;
  final String? description;
  final String? descriptionKey;
  final String? glyph;
  final String? route;
  final String? parentId;
  final List<String> children;
  final num order;
  final CatalogNodeKind? kind;
  final String? icon;
  final bool? desktopOnly;
  final bool? hidden;
  final bool? deprecated;
  final String? clusterGroup;

  bool get visible => hidden != true && deprecated != true;
}

@immutable
class SettingsTopology {
  const SettingsTopology({
    required this.rootId,
    required this.nodesById,
  });

  final String rootId;
  final Map<String, SettingsTopologyNode> nodesById;

  Iterable<SettingsTopologyNode> orderedChildren(String parentId) {
    final children = nodesById[parentId]?.children;
    if (children == null) return const <SettingsTopologyNode>[];
    final nodes = <SettingsTopologyNode>[
      for (final id in children)
        if (nodesById[id] case final node?) node,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return nodes;
  }
}

const List<CatalogNodeItem> _catalogItems = <CatalogNodeItem>[
  CatalogNodeItem(
    id: 'hub',
    label: 'Settings Hub',
    shortLabel: 'Hub',
    titleKey: 'settings.title',
    glyph: '設定',
    route: '/settings',
    icon: 'i-solar:settings-bold-duotone',
    order: 0,
    parentId: null,
    kind: CatalogNodeKind.root,
  ),
  CatalogNodeItem(
    id: 'area-card',
    label: 'AIRI Card Editor',
    shortLabel: 'Cards',
    titleKey: 'settings.pages.card.title',
    descriptionKey: 'settings.pages.card.description',
    description: 'Create, edit, and manage character cards, import custom presets, or discover new ones online.',
    glyph: '姿',
    clusterGroup: 'CHARACTER & SCENE 姿',
    route: '/settings/airi-card',
    icon: 'i-solar:emoji-funny-square-bold-duotone',
    order: 1,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-models',
    label: 'Companion Avatars',
    shortLabel: 'Avatars',
    titleKey: 'settings.pages.models.title',
    descriptionKey: 'settings.pages.models.description',
    description: 'Manage physical assets, animations, and motion mappings for Live2D, VRM, Spine, and MMD. Hidden because no model-asset/animation surface is implemented in this client.',
    glyph: '体',
    clusterGroup: 'CHARACTER & SCENE 姿',
    route: '/settings/models',
    icon: 'i-solar:people-nearby-bold-duotone',
    order: 2,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
    hidden: true,
  ),
  CatalogNodeItem(
    id: 'area-scene',
    label: 'Stage Backgrounds',
    shortLabel: 'Backgrounds',
    titleKey: 'settings.pages.scene.title',
    descriptionKey: 'settings.pages.scene.description',
    description: 'Customize virtual backdrops and stage wallpaper images for your characters. Hidden because backgrounds are client-local state with no settings screen.',
    glyph: '景',
    clusterGroup: 'CHARACTER & SCENE 姿',
    route: '/settings/scene',
    icon: 'i-solar:gallery-bold-duotone',
    order: 3,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
    hidden: true,
  ),
  CatalogNodeItem(
    id: 'area-memory',
    label: 'Memory Systems',
    shortLabel: 'Memory',
    titleKey: 'settings.pages.memory.title',
    descriptionKey: 'settings.pages.memory.description',
    description: 'Review short-term summaries, text journals, lifetime archives, and echo chips.',
    glyph: '憶',
    clusterGroup: 'INTELLIGENCE 知',
    route: '/settings/memory',
    icon: 'i-solar:leaf-bold-duotone',
    order: 4,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-modules',
    label: 'Companion Connectors',
    shortLabel: 'Connectors',
    titleKey: 'settings.pages.modules.title',
    descriptionKey: 'settings.pages.modules.description',
    description: 'Configure perception sensors, speech, hearing, consciousness, and integrations.',
    glyph: '部',
    clusterGroup: 'INTELLIGENCE 知',
    route: '/settings/modules',
    icon: 'i-solar:layers-bold-duotone',
    order: 5,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-providers',
    label: 'Inference Providers',
    shortLabel: 'Providers',
    titleKey: 'settings.pages.providers.title',
    descriptionKey: 'settings.pages.providers.description',
    description: 'Set up LLM brains, speech synthesis engines, and transcription providers.',
    glyph: '供',
    clusterGroup: 'INTELLIGENCE 知',
    route: '/settings/providers',
    icon: 'i-solar:box-minimalistic-bold-duotone',
    order: 6,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-sessions',
    label: 'Sessions',
    shortLabel: 'Sessions',
    titleKey: 'settings.pages.sessions.title',
    descriptionKey: 'settings.pages.sessions.description',
    description: 'Browse, import, and export chats.',
    glyph: '談',
    clusterGroup: 'INTELLIGENCE 知',
    route: '/settings/sessions',
    icon: 'i-solar:chat-round-bold-duotone',
    order: 6,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-data',
    label: 'Data Management',
    shortLabel: 'Data',
    titleKey: 'settings.pages.data.title',
    descriptionKey: 'settings.pages.data.description',
    description: 'Backup, restore, and manage cached assets or IndexedDB persistence stores through the externally supplied data screen.',
    glyph: '庫',
    clusterGroup: 'INTELLIGENCE 知',
    route: '/settings/data',
    icon: 'i-solar:database-bold-duotone',
    order: 7,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-system',
    label: 'System Preferences',
    shortLabel: 'System',
    titleKey: 'settings.pages.system.title',
    descriptionKey: 'settings.pages.system.description',
    description: 'Customize app language, 24-color theme palette, vibrancy, and user identity.',
    glyph: '系',
    clusterGroup: 'SYSTEM 系',
    route: '/settings/system',
    icon: 'i-solar:filters-bold-duotone',
    order: 8,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-stage',
    label: 'Floating Controls',
    shortLabel: 'Controls',
    titleKey: 'settings.pages.stage.title',
    descriptionKey: 'settings.pages.stage.description',
    description: 'Customize floating action strip slots, docking edge, and quick triggers.',
    glyph: '盤',
    clusterGroup: 'SYSTEM 系',
    route: '/settings/stage',
    icon: 'i-solar:widget-2-bold-duotone',
    order: 9,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
  ),
  CatalogNodeItem(
    id: 'area-docs',
    label: 'Documentation',
    shortLabel: 'Docs',
    titleKey: 'settings.pages.docs.title',
    descriptionKey: 'settings.pages.docs.description',
    description: 'Access tutorials, architectural overviews, API guides, and manual reference. Hidden because no bundled docs screen is available.',
    glyph: '書',
    clusterGroup: 'SYSTEM 系',
    route: '/settings/docs',
    icon: 'i-solar:book-bookmark-bold-duotone',
    order: 10,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
    hidden: true,
  ),
  CatalogNodeItem(
    id: 'area-about',
    label: 'About AIRI',
    shortLabel: 'About',
    titleKey: 'settings.pages.about.title',
    descriptionKey: 'settings.pages.about.description',
    description: 'Application version, release changelog, open source credits, and community links. Hidden because About is a separate navigation destination.',
    glyph: '誌',
    clusterGroup: 'SYSTEM 系',
    route: '/settings/about',
    icon: 'i-solar:info-circle-bold-duotone',
    order: 11,
    parentId: 'hub',
    kind: CatalogNodeKind.area,
    hidden: true,
  ),
  CatalogNodeItem(
    id: 'mod-artistry',
    label: 'Artistry (Deprecated)',
    shortLabel: 'Art',
    titleKey: 'settings.pages.modules.artistry.title',
    descriptionKey: 'settings.pages.modules.artistry.description',
    description: 'Image generation is deprecated.',
    glyph: '画',
    clusterGroup: 'PERCEPTION & FACULTIES 感',
    route: '/settings/modules/artistry',
    icon: 'i-iconify-heroicons:photo',
    order: 5,
    parentId: 'area-modules',
    kind: CatalogNodeKind.page,
    hidden: true,
    deprecated: true,
  ),
  CatalogNodeItem(
    id: 'sys-connection',
    label: 'Connection & Downloads',
    shortLabel: 'Network',
    titleKey: 'settings.pages.connection.title',
    descriptionKey: 'settings.pages.connection.description',
    description: 'Configure server endpoints, local channel gateway, and model download credentials.',
    glyph: '網',
    clusterGroup: 'NETWORK 網',
    route: '/settings/system/connection',
    icon: 'i-solar:wi-fi-router-bold-duotone',
    order: 1,
    parentId: 'area-system',
    kind: CatalogNodeKind.page,
  ),
  CatalogNodeItem(
    id: 'sys-general',
    label: 'General Preferences',
    shortLabel: 'General',
    titleKey: 'settings.pages.system.general.title',
    descriptionKey: 'settings.pages.system.general.description',
    description: 'Interface language, date formats, fallback localization, and application startup defaults.',
    glyph: '通',
    clusterGroup: 'PREFERENCES 設',
    route: '/settings/system/general',
    icon: 'i-solar:tuning-square-2-bold-duotone',
    order: 3,
    parentId: 'area-system',
    kind: CatalogNodeKind.page,
  ),
];

SettingsTopology _buildSettingsCatalogTopology() {
  final nodesById = <String, SettingsTopologyNode>{};
  for (final item in _catalogItems) {
    nodesById[item.id] = SettingsTopologyNode(
      id: item.id,
      label: item.label,
      shortLabel: item.shortLabel ?? _shortLabel(item.label),
      titleKey: item.titleKey,
      description: item.description,
      descriptionKey: item.descriptionKey,
      glyph: item.glyph,
      route: item.route,
      parentId: item.parentId,
      children: <String>[],
      order: item.order,
      kind: item.kind ?? CatalogNodeKind.page,
      icon: item.icon,
      desktopOnly: item.desktopOnly,
      hidden: item.hidden,
      deprecated: item.deprecated,
      clusterGroup: item.clusterGroup,
    );
  }

  for (final entry in nodesById.entries.toList()) {
    final node = entry.value;
    final parentId = node.parentId;
    if (parentId == null) continue;
    final parent = nodesById[parentId];
    if (parent == null ||
        node.hidden == true ||
        node.deprecated == true ||
        parent.hidden == true ||
        parent.deprecated == true) {
      continue;
    }
    if (!parent.children.contains(entry.key)) parent.children.add(entry.key);
  }

  return SettingsTopology(rootId: 'hub', nodesById: Map<String, SettingsTopologyNode>.unmodifiable(nodesById));
}

String _shortLabel(String label) => label.length <= 6 ? label : label.substring(0, 6);

final SettingsTopology settingsCatalogTopology = _buildSettingsCatalogTopology();

List<String> resolveSettingsPath(SettingsTopology topology, String activeId) {
  if (!topology.nodesById.containsKey(activeId)) {
    return topology.rootId.isEmpty ? const <String>[] : <String>[topology.rootId];
  }

  final path = <String>[];
  final visited = <String>{};
  String? currentId = activeId;
  while (currentId != null) {
    if (!visited.add(currentId)) break;
    path.insert(0, currentId);
    currentId = topology.nodesById[currentId]?.parentId;
  }

  if (path.isNotEmpty && path.first != topology.rootId && topology.nodesById.containsKey(topology.rootId)) {
    path.insert(0, topology.rootId);
  }
  return path;
}