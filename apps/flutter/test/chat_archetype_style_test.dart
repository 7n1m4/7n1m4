// SPDX-License-Identifier: GPL-3.0-or-later

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/chat/chat_archetype_style.dart';
import 'package:anima_control/theme/app_theme.dart';

void main() {
  group('styleFor (pure key -> style)', () {
    test('happy carries the exact border / bg / glow hexes', () {
      final style = styleFor('happy');
      expect(style.border, '#10b98180');
      expect(style.bg, '#10b98115');
      expect(style.glow, '#10b98130');
    });

    test('all seven keys keep the exact ported colors', () {
      const expected = <String, ({String border, String bg, String glow})>{
        'happy': (border: '#10b98180', bg: '#10b98115', glow: '#10b98130'),
        'sad': (border: '#3b82f680', bg: '#3b82f615', glow: '#3b82f630'),
        'angry': (border: '#f43f5e80', bg: '#f43f5e15', glow: '#f43f5e30'),
        'surprised': (border: '#a855f790', bg: '#a855f720', glow: '#a855f740'),
        'thinking': (border: '#f59e0b80', bg: '#f59e0b10', glow: '#f59e0b20'),
        'flustered': (border: '#f472b680', bg: '#f472b615', glow: '#f472b630'),
        'relaxed': (border: '#14b8a680', bg: '#14b8a615', glow: '#14b8a630'),
      };
      for (final entry in expected.entries) {
        final style = styleFor(entry.key);
        expect(style.border, entry.value.border, reason: '${entry.key} border');
        expect(style.bg, entry.value.bg, reason: '${entry.key} bg');
        expect(style.glow, entry.value.glow, reason: '${entry.key} glow');
      }
    });
  });

  group('bubbleDecorationFor', () {
    test(
      'null and unrecognized keys give byte-identical neutral decoration',
      () {
        final fromNull = bubbleDecorationFor(archetypeKey: null, isUser: false);
        final fromUnknown = bubbleDecorationFor(
          archetypeKey: 'not-an-archetype',
          isUser: false,
        );

        expect(fromNull, equals(fromUnknown));
        expect(fromNull, const BoxDecoration());
        expect(fromNull.border, isNull);
        expect(fromNull.color, isNull);
        expect(fromNull.boxShadow, isNull);
      },
    );

    test('isUser ignores the session key and keeps fixed user tokens', () {
      final decoration = bubbleDecorationFor(
        archetypeKey: 'happy',
        isUser: true,
      );

      expect(
        decoration,
        BoxDecoration(color: AppTheme.subtle.withValues(alpha: 0.2)),
      );
      expect(decoration.border, isNull);
      expect(decoration.boxShadow, isNull);
      expect(
        decoration,
        isNot(bubbleDecorationFor(archetypeKey: 'happy', isUser: false)),
      );
    });
  });

  group('ArchetypeStyledBubble', () {
    testWidgets(
      'spoof: text and sender claim happy, passed key says sad -> sad',
      (tester) async {
        // The bubble's text and sender label deliberately claim a different
        // archetype. Only the explicit key may decide the decoration; Flutter
        // never inspects text or sender names for styling.
        await tester.pumpWidget(
          const MaterialApp(
            home: Column(
              children: <Widget>[
                Text('sender: happy'),
                ArchetypeStyledBubble(
                  archetypeKey: 'sad',
                  isUser: false,
                  child: Text('[happy] <|ACT:{"name":"happy"}|> so glad!'),
                ),
              ],
            ),
          ),
        );

        final finder = find.byKey(const Key('archetype-styled-bubble'));
        expect(finder, findsOneWidget);
        final decoration =
            tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;

        expect(
          decoration.border,
          Border.all(color: const Color(0x803B82F6), width: 2),
        );
        expect(decoration.color, const Color(0x153B82F6));
        expect(decoration.boxShadow, const <BoxShadow>[
          BoxShadow(color: Color(0x303B82F6), blurRadius: 15),
        ]);
        // Explicitly not the spoofed archetype's tokens.
        expect(decoration.color, isNot(const Color(0x1510B981)));
        expect(
          decoration.border,
          isNot(Border.all(color: const Color(0x8010B981), width: 2)),
        );
      },
    );

    testWidgets('a keyed assistant bubble applies its 2px border, tint, glow', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArchetypeStyledBubble(
            archetypeKey: 'surprised',
            isUser: false,
            child: Text('oh!'),
          ),
        ),
      );

      final finder = find.byKey(const Key('archetype-styled-bubble'));
      final decoration =
          tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;

      expect(
        decoration.border,
        Border.all(color: const Color(0x90A855F7), width: 2),
      );
      expect(decoration.color, const Color(0x20A855F7));
      expect(decoration.boxShadow, const <BoxShadow>[
        BoxShadow(color: Color(0x40A855F7), blurRadius: 15),
      ]);
    });
  });
}
