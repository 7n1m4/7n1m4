// SPDX-License-Identifier: GPL-3.0-or-later

// The stage's control strip (Vue `ControlStrip.vue` in `mode="mobile"`): a
// compact pill of stage actions docked to one edge. This build surfaces the
// subset of the catalog the daemon settings section already knows
// (`kStageStripCatalog`); actions are reported to [onAction] and never
// applied here, because the daemon owns the state they change.
//
// The host is intentionally dumb: it renders [StageControlStripState] and
// reports taps.

import 'package:flutter/material.dart';

import 'stage_control_strip_state.dart';

/// A control-strip action the user activated.
class StageStripAction {
  const StageStripAction(this.buttonId);

  final String buttonId;
}

/// The stage control strip.
class StageControlStrip extends StatelessWidget {
  const StageControlStrip({
    super.key,
    required this.state,
    required this.onAction,
    this.iconFor = _defaultIcon,
  });

  final StageControlStripState state;
  final ValueChanged<StageStripAction> onAction;

  /// Icon for a button id; overridable so the catalog can evolve without
  /// touching this widget.
  final IconData Function(String id) iconFor;

  static IconData _defaultIcon(String id) => switch (id) {
    'stage' => Icons.theater_comedy_outlined,
    'caption' => Icons.closed_caption_outlined,
    _ => Icons.circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final buttons = state.activeButtons;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final id in buttons)
            IconButton(
              tooltip: id,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              onPressed: () => onAction(StageStripAction(id)),
              icon: Icon(iconFor(id)),
            ),
        ],
      ),
    );

    return Align(
      alignment: _alignment(state.edge),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: state.collapsed
            ? Tooltip(
                message: 'Expand stage controls',
                child: TextButton(
                  onPressed: () => onAction(const StageStripAction('__expand')),
                  child: const Icon(Icons.expand_more),
                ),
              )
            : pill,
      ),
    );
  }

  static Alignment _alignment(StageStripEdge edge) => switch (edge) {
    StageStripEdge.left => Alignment.centerLeft,
    StageStripEdge.right => Alignment.centerRight,
    StageStripEdge.top => Alignment.topCenter,
    StageStripEdge.bottom => Alignment.bottomCenter,
  };
}
