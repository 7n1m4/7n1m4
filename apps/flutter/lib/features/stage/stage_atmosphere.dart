// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local atmosphere particle presets, ported from the Vue reference
// (`packages/stage-ui/src/constants/atmosphere.ts` and the per-card /
// stage-vs-chat selection in `packages/stage-ui/src/stores/background.ts`).
// Ids, labels and descriptions are copied verbatim so the picker reads the
// same as the reference (`petals` shows as "Sakura", `notes` as "Melody").
//
// This is a CLIENT-LOCAL PREVIEW. The Vue store writes the id into the active
// card's `extensions.airi.modules.activeAtmosphereId` and into two localStorage
// keys; this client has no card-write verb and no daemon atmosphere field, so
// nothing here is persisted or claimed as daemon-owned. Persisting the
// selection (or giving the daemon a canonical field) is a separate decision.

import 'package:flutter/material.dart';

/// Particle atmosphere shown on a stage surface (Vue `StageAtmosphere`).
enum StageAtmosphere { none, hearts, petals, stars, bubbles, crosses, notes }

/// One entry of the Vue `ATMOSPHERE_PRESETS` catalog.
class AtmospherePresetMeta {
  const AtmospherePresetMeta({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
  });

  /// Store id from the Vue union, e.g. `petals`.
  final String id;

  /// Display label. `petals` and `notes` keep the reference's friendly names.
  final String name;

  final String description;

  /// Vue Iconify class. Kept for fidelity; the Flutter painter uses shapes.
  final String icon;
}

/// The full preset catalog, in the reference's order.
const List<AtmospherePresetMeta> kAtmospherePresets = <AtmospherePresetMeta>[
  AtmospherePresetMeta(
    id: 'none',
    name: 'None',
    icon: 'i-solar:close-circle-bold-duotone',
    description: 'Clean and static with no moving particles',
  ),
  AtmospherePresetMeta(
    id: 'hearts',
    name: 'Hearts',
    icon: 'i-solar:heart-bold-duotone',
    description: 'Pastel floating hearts drifting upward with gentle sway',
  ),
  AtmospherePresetMeta(
    id: 'petals',
    name: 'Sakura',
    icon: 'i-solar:leaf-bold-duotone',
    description: 'Soft pink cherry blossom petals drifting with the wind',
  ),
  AtmospherePresetMeta(
    id: 'stars',
    name: 'Stars',
    icon: 'i-solar:stars-bold-duotone',
    description: 'Twinkling 4-point diamond sparkles and star glints',
  ),
  AtmospherePresetMeta(
    id: 'bubbles',
    name: 'Bubbles',
    icon: 'i-solar:waterdrops-bold-duotone',
    description: 'Shimmering translucent bubbles floating upward',
  ),
  AtmospherePresetMeta(
    id: 'crosses',
    name: 'Crosses',
    icon: 'i-solar:widget-add-bold-duotone',
    description: 'Minimalist tech plus and cross stencils',
  ),
  AtmospherePresetMeta(
    id: 'notes',
    name: 'Melody',
    icon: 'i-solar:music-note-bold-duotone',
    description: 'Musical eighth notes drifting with rhythmic pulse',
  ),
];

/// The store id for [preset]; null for an unrecognized stored id.
StageAtmosphere? atmosphereFromId(String? id) => switch (id) {
  'none' => StageAtmosphere.none,
  'hearts' => StageAtmosphere.hearts,
  'petals' => StageAtmosphere.petals,
  'stars' => StageAtmosphere.stars,
  'bubbles' => StageAtmosphere.bubbles,
  'crosses' => StageAtmosphere.crosses,
  'notes' => StageAtmosphere.notes,
  _ => null,
};

/// The store id for [preset] (inverse of [atmosphereFromId]).
String atmosphereId(StageAtmosphere preset) => switch (preset) {
  StageAtmosphere.none => 'none',
  StageAtmosphere.hearts => 'hearts',
  StageAtmosphere.petals => 'petals',
  StageAtmosphere.stars => 'stars',
  StageAtmosphere.bubbles => 'bubbles',
  StageAtmosphere.crosses => 'crosses',
  StageAtmosphere.notes => 'notes',
};

/// Catalog entry for [preset]. The enum order mirrors the catalog order.
AtmospherePresetMeta atmosphereMeta(StageAtmosphere preset) {
  final meta = kAtmospherePresets[preset.index];
  assert(meta.id == atmosphereId(preset), 'atmosphere enum/catalog drift');
  return meta;
}

/// Minimal client-local picker. It reports intent only — the caller decides
/// whether to write the returned id anywhere; no persistence is implied.
class StageAtmosphereSelector extends StatelessWidget {
  const StageAtmosphereSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final StageAtmosphere selected;
  final ValueChanged<StageAtmosphere> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        for (final meta in kAtmospherePresets)
          ChoiceChip(
            label: Text(meta.name),
            tooltip: meta.description,
            selected: atmosphereId(selected) == meta.id,
            onSelected: (_) => onChanged(atmosphereFromId(meta.id)!),
          ),
      ],
    );
  }
}
