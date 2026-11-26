// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local state of the stage's control strip (Vue
// `packages/stage-ui/src/stores/settings/control-strip.ts` +
// `ControlStrip.vue` + `ControlStripHost.vue`), reduced to what a thin client
// can own. The daemon owns the settings section (`settings/control-strip` via
// `settings.get`); this class holds only the button ids this build surfaces
// and the transient host state (collapsed, open panel). Nothing is written
// back automatically.

import 'stage_overlay_state.dart';

/// Edge the strip docks to (Rust `ControlStripDockedEdge`).
enum StageStripEdge { left, right, top, bottom }

/// Control-strip button ids this build surfaces, in catalog order.
///
/// Only ids with a real stage effect are advertised. Chat, actor, mic and
/// atmosphere buttons had no panel or daemon dispatch behind them; they stay
/// out until the dispatch exists instead of advertising dead controls. The
/// daemon's stored arrangement is still round-tripped by the settings screen.
const List<String> kStageStripCatalog = <String>['stage', 'caption'];

/// Default enabled ids (Rust `default_enabled_buttons`).
const Set<String> kDefaultStageStripButtons = <String>{'stage', 'caption'};

/// Transient host state of the strip.
class StageControlStripState {
  StageControlStripState({
    this.edge = StageStripEdge.right,
    this.collapsed = false,
    Set<String> enabledButtons = kDefaultStageStripButtons,
  }) : enabledButtons = Set<String>.of(enabledButtons);

  StageStripEdge edge;
  bool collapsed;
  Set<String> enabledButtons;

  /// The button id currently expanded into a panel, or null.
  String? openPanel;

  /// Enabled ids in catalog order (Vue `activeButtons`).
  List<String> get activeButtons =>
      kStageStripCatalog.where(enabledButtons.contains).toList(growable: false);

  bool isEnabled(String id) => enabledButtons.contains(id);

  void toggle(String id) {
    if (!enabledButtons.remove(id)) enabledButtons.add(id);
  }

  void setEdge(StageStripEdge value) => edge = value;

  void setCollapsed(bool value) => collapsed = value;

  /// Toggle the collapsed notch (Vue hover-expand).
  void toggleCollapsed() => collapsed = !collapsed;

  void togglePanel(String id) => openPanel = openPanel == id ? null : id;

  void closePanel() => openPanel = null;

  /// Restore the platform defaults (Vue `resetButtons`).
  void reset() {
    edge = StageStripEdge.right;
    collapsed = false;
    openPanel = null;
    enabledButtons = Set<String>.of(kDefaultStageStripButtons);
  }
}

/// Host state derived from the daemon's `control-strip` settings section
/// (`crates/anima-core/src/settings.rs` `ControlStripSettings`, camelCase
/// wire names).
class StageControlStripSettings {
  const StageControlStripSettings({
    required this.strip,
    required this.captionStyle,
    required this.backgroundTint,
  });

  final StageControlStripState strip;
  final StageCaptionStyle captionStyle;
  final String backgroundTint;

  static StageStripEdge _edge(Object? value) => switch (value) {
    'left' => StageStripEdge.left,
    'top' => StageStripEdge.top,
    'bottom' => StageStripEdge.bottom,
    _ => StageStripEdge.right,
  };

  static Set<String> _buttons(Object? raw) {
    if (raw is! List) return Set<String>.of(kDefaultStageStripButtons);
    final result = <String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      if (entry['enabled'] == false) continue;
      final id = entry['id'];
      if (id is! String || !kStageStripCatalog.contains(id)) continue;
      result.add(id);
    }
    return result.isEmpty ? Set<String>.of(kDefaultStageStripButtons) : result;
  }

  /// Build host state from a `settings.get('control-strip')` map. Missing or
  /// malformed fields fall back to the daemon defaults, never to invented
  /// values.
  factory StageControlStripSettings.fromSettings(
    Map<String, dynamic>? settings,
  ) {
    final map = settings ?? const <String, dynamic>{};
    final tint = map['backgroundTint'];
    return StageControlStripSettings(
      strip: StageControlStripState(
        edge: _edge(map['dockedEdge']),
        collapsed: map['collapsed'] == true,
        enabledButtons: _buttons(map['buttons']),
      ),
      captionStyle: map['captionOpen'] == false
          ? const StageCaptionStyle(docking: StageCaptionDocking.none)
          : const StageCaptionStyle(),
      backgroundTint: tint is String ? tint : '#171717',
    );
  }
}
