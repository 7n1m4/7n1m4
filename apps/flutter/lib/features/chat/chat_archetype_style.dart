// SPDX-License-Identifier: GPL-3.0-or-later

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Bubble tokens for one archetype key, ported verbatim from
/// `assistant-item.vue` `MOOD_ARCHETYPE_COLORS` (lines 449-457).
///
/// The values stay as CSS `#RRGGBBAA` strings so the exact ported hexes are
/// asserted in tests and converted to Flutter colors in exactly one place.
class ArchetypeStyle {
  const ArchetypeStyle({
    required this.border,
    required this.bg,
    required this.glow,
  });

  final String border;
  final String bg;
  final String glow;

  bool get isNeutral => border.isEmpty;
}

/// Fixed neutral tokens: no border, no tint, no glow. Shared by `null` and
/// unrecognised keys so both paths produce an identical decoration.
const ArchetypeStyle _neutral = ArchetypeStyle(border: '', bg: '', glow: '');

const Map<String, ArchetypeStyle> _styles = <String, ArchetypeStyle>{
  'happy': ArchetypeStyle(
    border: '#10b98180',
    bg: '#10b98115',
    glow: '#10b98130',
  ),
  'sad': ArchetypeStyle(
    border: '#3b82f680',
    bg: '#3b82f615',
    glow: '#3b82f630',
  ),
  'angry': ArchetypeStyle(
    border: '#f43f5e80',
    bg: '#f43f5e15',
    glow: '#f43f5e30',
  ),
  'surprised': ArchetypeStyle(
    border: '#a855f790',
    bg: '#a855f720',
    glow: '#a855f740',
  ),
  'thinking': ArchetypeStyle(
    border: '#f59e0b80',
    bg: '#f59e0b10',
    glow: '#f59e0b20',
  ),
  'flustered': ArchetypeStyle(
    border: '#f472b680',
    bg: '#f472b615',
    glow: '#f472b630',
  ),
  'relaxed': ArchetypeStyle(
    border: '#14b8a680',
    bg: '#14b8a615',
    glow: '#14b8a630',
  ),
};

/// Resolves an explicit archetype key (the persona/session key carried by the
/// daemon card's `AiriRwkv.archetype`) to its style.
///
/// NOTICE: the key is the ONLY input. Message text, sender names and the
/// `categorization.mood` wire fallback are deliberately never consulted, and
/// no new wire field is invented (airi-6anh froze the schema).
ArchetypeStyle styleFor(String? key) => _styles[key] ?? _neutral;

Color _colorFromHex(String hex) {
  final digits = hex.replaceFirst('#', '');
  final r = int.parse(digits.substring(0, 2), radix: 16);
  final g = int.parse(digits.substring(2, 4), radix: 16);
  final b = int.parse(digits.substring(4, 6), radix: 16);
  final a = int.parse(digits.substring(6, 8), radix: 16);
  return Color.fromARGB(a, r, g, b);
}

/// Decoration for a chat bubble.
///
/// [archetypeKey] is supplied explicitly by the caller from the active card /
/// session; [isUser] keeps the fixed user-bubble token and ignores the key.
/// Neither message content nor sender identity is an input to styling.
BoxDecoration bubbleDecorationFor({
  required String? archetypeKey,
  required bool isUser,
}) {
  if (isUser) {
    // Same fixed token as chat_screen.dart's user Card.color.
    return BoxDecoration(color: AppTheme.subtle.withValues(alpha: 0.2));
  }

  final style = styleFor(archetypeKey);
  if (style.isNeutral) return const BoxDecoration();

  return BoxDecoration(
    color: _colorFromHex(style.bg),
    border: Border.all(color: _colorFromHex(style.border), width: 2),
    boxShadow: <BoxShadow>[
      BoxShadow(color: _colorFromHex(style.glow), blurRadius: 15),
    ],
  );
}

/// A decorated bubble whose style comes solely from [archetypeKey] and
/// [isUser]. [child] is display content only; it is never inspected for style.
class ArchetypeStyledBubble extends StatelessWidget {
  const ArchetypeStyledBubble({
    super.key,
    required this.archetypeKey,
    required this.isUser,
    required this.child,
  });

  final String? archetypeKey;
  final bool isUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('archetype-styled-bubble'),
      decoration: bubbleDecorationFor(
        archetypeKey: archetypeKey,
        isUser: isUser,
      ),
      child: child,
    );
  }
}
