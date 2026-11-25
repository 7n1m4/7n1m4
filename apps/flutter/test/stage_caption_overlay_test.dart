// SPDX-License-Identifier: GPL-3.0-or-later

// Focused, hermetic coverage of the caption overlay and its accumulator.
// No daemon client, sockets, assets or platform channels are involved: the
// widget renders a snapshot and the accumulator consumes plain maps.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/stage_caption_overlay.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';

void main() {
  group('StageCaptionController', () {
    test(
      'deltas accumulate per message id and the final marker keeps text',
      () {
        final controller = StageCaptionController();
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': 'Hello ',
          'seq': 1,
        });
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': 'world',
          'seq': 2,
        });
        expect(controller.snapshot.segments.single.text, 'Hello world');

        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': '',
          'final': true,
          'seq': 3,
        });
        expect(controller.snapshot.segments.single.text, 'Hello world');
      },
    );

    test('a new turn replaces the buffer; replays and junk are ignored', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'old',
        'seq': 4,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'old',
        'seq': 4,
      });
      expect(controller.snapshot.segments.single.text, 'old');
      controller.applyTokenDelta(<String, dynamic>{'delta': 7, 'seq': 5});
      expect(controller.snapshot.segments.single.text, 'old');

      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm2',
        'delta': 'new',
        'seq': 6,
      });
      expect(controller.snapshot.segments.single.text, 'new');
      controller.clear();
      expect(controller.snapshot.isEmpty, isTrue);
    });

    test('every public mutation notifies listeners', () {
      final controller = StageCaptionController();
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'text',
        'seq': 1,
      });
      controller.setSpeaker('Anima');
      controller.setSegments(const <CaptionSegment>[
        CaptionSegment(text: 'one'),
        CaptionSegment(text: 'two'),
      ]);
      controller.setActiveSentence(1);
      controller.clear();
      expect(notifications, 5);
    });
  });

  group('StageCaptionStyle', () {
    test('daemon camelCase caption settings map to scale, alpha and docking', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'top',
        'fontSize': 150,
        'opacity': 40,
      });
      expect(style.docking, StageCaptionDocking.top);
      expect(style.isTop, isTrue);
      expect(style.scale, 1.5);
      expect(style.alpha, 0.4);
    });

    test('legacy snake_case caption settings still map when camelCase is absent', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'top',
        'font_size': 150,
        'opacity': 40,
      });
      expect(style.scale, 1.5);
      expect(style.alpha, 0.4);
      expect(style.isTop, isTrue);
      expect(
        StageCaptionStyle.fromSettings(<String, dynamic>{
          'fontSize': 90,
          'font_size': 150,
        }).scale,
        0.9,
      );
    });

    test('malformed settings fall back to defaults; head aliases bottom', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'nonsense',
        'font_size': 'big',
        'fontSize': 'big',
        'opacity': null,
      });
      expect(style.docking, StageCaptionDocking.bottom);
      expect(style.scale, 1.0);
      expect(style.alpha, 0.7);
      expect(StageCaptionStyle.dockingFrom('head'), StageCaptionDocking.head);
      expect(
        const StageCaptionStyle(docking: StageCaptionDocking.head).isTop,
        isFalse,
      );
      expect(
        const StageCaptionStyle(docking: StageCaptionDocking.none).isVisible,
        isFalse,
      );
    });
  });

  group('StageCaptionOverlay widget', () {
    Future<void> pumpOverlay(
      WidgetTester tester, {
      required StageCaptionSnapshot caption,
      StageCaptionStyle style = const StageCaptionStyle(),
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageCaptionOverlay(caption: caption, style: style),
        ),
      ),
    );

    testWidgets('hidden or empty captions paint nothing', (tester) async {
      await pumpOverlay(
        tester,
        caption: const StageCaptionSnapshot(speakerText: 'Anima'),
        style: const StageCaptionStyle(docking: StageCaptionDocking.none),
      );
      expect(find.byType(Text), findsNothing);

      await pumpOverlay(tester, caption: const StageCaptionSnapshot());
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('speaker nameplate renders when there are no segments', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        caption: const StageCaptionSnapshot(speakerText: 'Anima'),
      );
      // The nameplate and the (speaker-only) body both render the name.
      expect(find.text('Anima'), findsNWidgets(2));
    });

    testWidgets('active segment is bold and takes a valid accent', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        caption: const StageCaptionSnapshot(
          segments: <CaptionSegment>[
            CaptionSegment(text: 'first'),
            CaptionSegment(text: 'second', color: '#FF0000', isActive: true),
          ],
        ),
      );
      final first = tester.widget<Text>(find.text('first'));
      final active = tester.widget<Text>(find.text('second'));
      expect(first.style?.fontWeight, FontWeight.w500);
      expect(active.style?.fontWeight, FontWeight.w700);
      expect(active.style?.color, const Color(0xFFFF0000));
    });

    testWidgets('a malformed accent is never invented', (tester) async {
      await pumpOverlay(
        tester,
        caption: const StageCaptionSnapshot(
          segments: <CaptionSegment>[
            CaptionSegment(text: 'bad', color: 'not-a-color', isActive: true),
          ],
        ),
      );
      final text = tester.widget<Text>(find.text('bad'));
      final scheme = Theme.of(tester.element(find.byType(StageCaptionOverlay)))
          .colorScheme;
      expect(text.style?.color, scheme.onPrimary);
    });

    testWidgets('docking edge and font scale come from the style', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        caption: const StageCaptionSnapshot(
          segments: <CaptionSegment>[CaptionSegment(text: 'hello')],
        ),
        style: const StageCaptionStyle(
          docking: StageCaptionDocking.top,
          fontSize: 150,
        ),
      );
      final align = tester.widget<Align>(
        find.descendant(
          of: find.byType(StageCaptionOverlay),
          matching: find.byType(Align),
        ),
      );
      expect(align.alignment, Alignment.topCenter);
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byType(StageCaptionOverlay),
          matching: find.byType(Transform),
        ),
      );
      expect(transform.transform, isA<Matrix4>());
      expect(transform.transform.getMaxScaleOnAxis(), closeTo(1.5, 1e-9));
    });
  });
}
