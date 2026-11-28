// SPDX-License-Identifier: GPL-3.0-or-later

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_archetype_style.dart';
import 'package:anima_control/features/chat/chat_screen.dart';
import 'package:anima_control/theme/app_theme.dart';

import 'support/fakes.dart';

/// Card envelope whose only relevant field is the explicit RWKV archetype key.
class _ArchetypeChatClient extends FakeChatClient {
  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    switch (action) {
      case 'sessions.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'sessions': <dynamic>[]},
        );
      case 'cards.list':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'cards': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'card-sad', 'name': 'Sad Card'},
            ],
            'truncated': false,
          },
        );
      case 'cards.get':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'card': <String, dynamic>{
              'spec': 'chara_card_v2',
              'data': <String, dynamic>{
                'name': 'Sad Card',
                'extensions': <String, dynamic>{
                  'airi': <String, dynamic>{
                    'rwkv': <String, dynamic>{'archetype': 'sad'},
                  },
                },
              },
            },
          },
        );
      case 'cards.metadata':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'id': payload?['id'] ?? 'card-sad',
            'liked': false,
            'bookmarked': false,
          },
        );
      case 'chat.send':
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'sessionId': 's1',
            'messageId': 'm-happy',
            'accepted': true,
          },
        );
      default:
        return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    }
  }
}

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

  group('archetypeKeyFromCard (pure card-envelope parser)', () {
    test('reads a bare card envelope', () {
      expect(
        archetypeKeyFromCard(<String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{
              'rwkv': <String, dynamic>{'archetype': 'happy'},
            },
          },
        }),
        'happy',
      );
    });

    test('reads a CCv2 data-wrapped card envelope', () {
      expect(
        archetypeKeyFromCard(<String, dynamic>{
          'spec': 'chara_card_v2',
          'data': <String, dynamic>{
            'extensions': <String, dynamic>{
              'airi': <String, dynamic>{
                'rwkv': <String, dynamic>{'archetype': 'sad'},
              },
            },
          },
        }),
        'sad',
      );
    });

    test('null, empty and missing envelopes fail closed to null', () {
      expect(archetypeKeyFromCard(null), isNull);
      expect(archetypeKeyFromCard(<String, dynamic>{}), isNull);
      expect(
        archetypeKeyFromCard(<String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{'rwkv': <String, dynamic>{}},
          },
        }),
        isNull,
      );
    });

    test('non-map envelope levels fail closed to null', () {
      for (final card in <Map<String, dynamic>?>[
        <String, dynamic>{'data': 'not a map'},
        <String, dynamic>{'extensions': 'not a map'},
        <String, dynamic>{
          'extensions': <String, dynamic>{'airi': 42},
        },
        <String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{'rwkv': <String>[]},
          },
        },
      ]) {
        expect(archetypeKeyFromCard(card), isNull);
      }
    });

    test('non-string and empty archetype values fail closed to null', () {
      for (final value in <Object?>[
        '',
        42,
        null,
        <String>[],
        <String, dynamic>{},
      ]) {
        expect(
          archetypeKeyFromCard(<String, dynamic>{
            'extensions': <String, dynamic>{
              'airi': <String, dynamic>{
                'rwkv': <String, dynamic>{'archetype': value},
              },
            },
          }),
          isNull,
          reason: 'value: $value',
        );
      }
    });

    test('bare root wins when both envelopes carry a key', () {
      expect(
        archetypeKeyFromCard(<String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{
              'rwkv': <String, dynamic>{'archetype': 'angry'},
            },
          },
          'data': <String, dynamic>{
            'extensions': <String, dynamic>{
              'airi': <String, dynamic>{
                'rwkv': <String, dynamic>{'archetype': 'sad'},
              },
            },
          },
        }),
        'angry',
      );
    });

    test('unknown non-empty strings are returned verbatim', () {
      expect(
        archetypeKeyFromCard(<String, dynamic>{
          'extensions': <String, dynamic>{
            'airi': <String, dynamic>{
              'rwkv': <String, dynamic>{'archetype': 'not-an-archetype'},
            },
          },
        }),
        'not-an-archetype',
      );
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

    testWidgets('paints the archetype bg tint over the opaque card surface', (
      tester,
    ) async {
      // chat_screen.dart wraps this bubble around an opaque
      // Card(color: AppTheme.surface). A background-only tint is hidden
      // behind that card, so the tint must also be painted in front of it.
      await tester.pumpWidget(
        const MaterialApp(
          home: ArchetypeStyledBubble(
            archetypeKey: 'sad',
            isUser: false,
            child: Card(
              key: Key('opaque-card'),
              color: AppTheme.surface,
              child: Text('assistant text'),
            ),
          ),
        ),
      );

      final tintFinder = find.byKey(const Key('archetype-bg-tint'));
      expect(tintFinder, findsOneWidget);
      final tintBox = tester.widget<DecoratedBox>(tintFinder);
      // A background-position DecoratedBox paints BEFORE its child, so an
      // opaque Card would still hide the tint. Foreground paint order is
      // the acceptance criterion, not just the decoration's presence.
      expect(tintBox.position, DecorationPosition.foreground);
      final tint = tintBox.decoration as BoxDecoration;
      expect(tint.color, const Color(0x153B82F6));
      expect(tint.border, isNull);
      expect(tint.boxShadow, isNull);

      // The foreground tint encloses both the opaque card and the
      // unchanged keyed background decoration.
      expect(
        find.descendant(
          of: tintFinder,
          matching: find.byKey(const Key('opaque-card')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tintFinder,
          matching: find.byKey(const Key('archetype-styled-bubble')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('neutral key adds no foreground tint decoration', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ArchetypeStyledBubble(
            archetypeKey: null,
            isUser: false,
            child: Text('plain'),
          ),
        ),
      );

      final background = find.byKey(const Key('archetype-styled-bubble'));
      expect(background, findsOneWidget);
      expect(
        tester.widget<DecoratedBox>(background).decoration,
        const BoxDecoration(),
      );
      expect(find.byKey(const Key('archetype-bg-tint')), findsNothing);
      expect(
        find.ancestor(of: background, matching: find.byType(DecoratedBox)),
        findsNothing,
      );
    });

    testWidgets(
      'keyed user bubble keeps subtle background with no tint overlay',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: ArchetypeStyledBubble(
              archetypeKey: 'happy',
              isUser: true,
              child: Text('mine'),
            ),
          ),
        );

        final background = find.byKey(const Key('archetype-styled-bubble'));
        expect(background, findsOneWidget);
        expect(
          tester.widget<DecoratedBox>(background).decoration,
          BoxDecoration(color: AppTheme.subtle.withValues(alpha: 0.2)),
        );
        expect(find.byKey(const Key('archetype-bg-tint')), findsNothing);
        expect(
          find.ancestor(of: background, matching: find.byType(DecoratedBox)),
          findsNothing,
        );
      },
    );
  });

  group('ChatScreen assistant archetype wiring', () {
    testWidgets(
      'spoofed happy text/sender cannot override the card archetype sad',
      (tester) async {
        final client = _ArchetypeChatClient();
        addTearDown(client.dispose);
        client.emitStatus(DaemonConnectionState.connected);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChatScreen(client: client)),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));

        await tester.enterText(find.byType(TextField), 'hello there');
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
            .onPressed!();
        await tester.pump();

        client.emitEvent(
          tokenDelta(
            messageId: 'm-happy',
            delta: '[sender: happy] <|ACT:{"name":"happy"}|> so glad!',
          ),
        );
        await tester.pump();
        client.emitEvent(
          tokenDelta(messageId: 'm-happy', delta: '', isFinal: true),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));

        final finder = find.byKey(const Key('archetype-styled-bubble'));
        expect(
          finder,
          findsOneWidget,
          reason: 'the assistant bubble must be wrapped with the card key',
        );
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
        // Explicitly not the spoofed happy tokens.
        expect(decoration.color, isNot(const Color(0x1510B981)));
        expect(
          decoration.border,
          isNot(Border.all(color: const Color(0x8010B981), width: 2)),
        );

        // The user bubble is not wrapped; only assistant content is.
        expect(find.text('hello there'), findsOneWidget);
        expect(
          find.descendant(of: finder, matching: find.text('hello there')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
