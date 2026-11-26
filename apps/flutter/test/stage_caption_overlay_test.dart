// SPDX-License-Identifier: GPL-3.0-or-later

// Focused, hermetic coverage of the caption overlay and its accumulator.
// No daemon client, sockets, assets or platform channels are involved: the
// widget renders a snapshot and the accumulator consumes plain maps.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_expression.dart';
import 'package:anima_control/features/stage/stage_background.dart';
import 'package:anima_control/features/stage/stage_caption_overlay.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';
import 'support/fakes.dart';

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

    LipSyncRmsData frame(int seq) => LipSyncRmsData(
      actorId: 'pet-1',
      level: 0.5,
      seq: seq,
      tsMs: 1700000000000 + seq * 50,
    );

    test('the final marker splits buffered text into sentences, first active', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'Hello. 世界！How?',
        'seq': 1,
      });
      expect(
        controller.snapshot.segments.single.text,
        'Hello. 世界！How?',
        reason: 'per-delta splitting would flicker as punctuation arrives',
      );
      expect(controller.snapshot.segments.single.isActive, isFalse);

      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      expect(
        controller.snapshot.segments.map((segment) => segment.text).toList(),
        <String>['Hello.', '世界！', 'How?'],
      );
      expect(
        controller.snapshot.segments.map((segment) => segment.isActive).toList(),
        <bool>[true, false, false],
      );
    });

    test('an unterminated tail is still a sentence', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'One! two',
        'seq': 1,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      expect(
        controller.snapshot.segments.map((segment) => segment.text).toList(),
        <String>['One!', 'two'],
      );
    });

    test('accepted RMS frames advance the active sentence', () {
      final state = StageRenderState(actorId: 'pet-1');
      addTearDown(state.dispose);
      state.captions.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'One. Two. Three.',
        'seq': 1,
      });
      state.captions.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      // Equal phonetic weights: 1.3 units * 50ms = 65ms per sentence.
      state.applyFrame(frame(10)); // 50ms
      expect(
        state.caption.segments.map((segment) => segment.isActive).toList(),
        <bool>[true, false, false],
      );
      state.applyFrame(frame(11)); // 100ms
      expect(
        state.caption.segments.map((segment) => segment.isActive).toList(),
        <bool>[false, true, false],
      );
      state.applyFrame(frame(12)); // 150ms
      expect(
        state.caption.segments.map((segment) => segment.isActive).toList(),
        <bool>[false, false, true],
      );
    });

    test('CJK sentences hold the first highlight longer than Latin ones', () {
      StageCaptionController caption(String text) {
        final controller = StageCaptionController();
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': text,
          'seq': 1,
        });
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': '',
          'final': true,
          'seq': 2,
        });
        return controller;
      }

      final cjk = caption('你好！世界？');
      final latin = caption('One. Two.');
      // Same real elapsed time for both: the Latin pair has moved on while
      // the CJK pair is still on its first sentence. This pins the relative
      // weighting without hardcoding the heuristic constants.
      for (final controller in <StageCaptionController>[cjk, latin]) {
        controller.advanceCaptionPlayback(frame(10));
        controller.advanceCaptionPlayback(frame(11));
      }
      expect(
        cjk.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[true, false],
      );
      expect(
        latin.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[false, true],
      );
    });

    test('consecutive terminators stay inside one sentence', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'Wow!!! Really?',
        'seq': 1,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      expect(
        controller.snapshot.segments.map((s) => s.text).toList(),
        <String>['Wow!!!', 'Really?'],
      );
    });

    test('cancelled and error finals drop the partial turn', () {
      for (final reason in <String>['cancelled', 'error']) {
        final controller = StageCaptionController();
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': 'Partial.',
          'seq': 1,
        });
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': '',
          'final': true,
          'reason': reason,
          'seq': 2,
        });
        expect(controller.snapshot.segments, isEmpty, reason: reason);
      }
    });

    test('a new message id or clear resets the frame baseline', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'One. Two. Three.',
        'seq': 1,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      controller.advanceCaptionPlayback(frame(1));
      controller.advanceCaptionPlayback(frame(3));
      expect(
        controller.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[false, false, true],
      );

      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm2',
        'delta': 'Alpha. Beta.',
        'seq': 4,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm2',
        'delta': '',
        'final': true,
        'seq': 5,
      });
      expect(
        controller.snapshot.segments.map((s) => s.text).toList(),
        <String>['Alpha.', 'Beta.'],
      );
      controller.advanceCaptionPlayback(frame(100));
      expect(
        controller.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[true, false],
        reason: 'a new turn must not inherit the previous playback clock',
      );

      controller.clear();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm3',
        'delta': 'Gamma. Delta.',
        'seq': 6,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm3',
        'delta': '',
        'final': true,
        'seq': 7,
      });
      controller.advanceCaptionPlayback(frame(500));
      expect(
        controller.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[true, false],
      );
    });

    test('without RMS frames the first sentence stays highlighted', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'First. Second.',
        'seq': 1,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': '',
        'final': true,
        'seq': 2,
      });
      expect(
        controller.snapshot.segments.map((s) => s.isActive).toList(),
        <bool>[true, false],
      );
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

    test('the captions enabled switch hides the overlay independently', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'enabled': false,
        'docking': 'top',
      });
      expect(style.enabled, isFalse);
      expect(style.isVisible, isFalse);
      expect(
        StageCaptionStyle.fromSettings(<String, dynamic>{'enabled': true})
            .isVisible,
        isTrue,
      );
      expect(
        StageCaptionStyle.fromSettings(<String, dynamic>{'enabled': 'false'})
            .enabled,
        isTrue,
        reason: 'a malformed switch must not hide captions',
      );
    });

    test('the daemon enabled flag hides captions even when docking is set', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'enabled': false,
        'docking': 'bottom',
        'opacity': 50,
      });
      expect(style.enabled, isFalse);
      expect(style.isVisible, isFalse);
      expect(style.alpha, 0.5);
    });

    test('a missing enabled flag leaves captions on', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'bottom',
      });
      expect(style.enabled, isTrue);
      expect(style.isVisible, isTrue);
    });

    test('malformed and unimplemented docking values fall back to bottom', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'nonsense',
        'font_size': 'big',
        'fontSize': 'big',
        'opacity': null,
      });
      expect(style.docking, StageCaptionDocking.bottom);
      expect(style.scale, 1.0);
      expect(style.alpha, 0.2, reason: 'the shared caption opacity default');
      for (final value in <String>['head', 'nonsense']) {
        expect(
          StageCaptionStyle.dockingFrom(value),
          StageCaptionDocking.bottom,
          reason: '$value has no renderer in this client',
        );
      }
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

  group('StageRenderStateBinding disconnect cleanup', () {
    test(
      'a mid-turn caption, cue and frame clear on disconnect while settings survive',
      () async {
        final client = FakeChatClient();
        final style = StageCaptionStyle.fromSettings(<String, dynamic>{
          'docking': 'top',
          'fontSize': 150,
          'opacity': 40,
        });
        final background = StageBackground.tintFromHex('#123456');
        final state = StageRenderState(
          actorId: 'pet-1',
          captions: style,
          background: background,
        );
        final binding = StageRenderStateBinding(client: client, state: state);
        addTearDown(state.dispose);
        addTearDown(binding.dispose);
        addTearDown(client.dispose);

        client.emitStatus(DaemonConnectionState.connected);

        // The caption and cue arrive on the daemon event lane; the frame comes
        // from the local audio tap, as it does in the real stage.
        client.emitEvent(tokenDelta(messageId: 'm1', delta: 'Hel'));
        client.emitEvent(
          GatewayEventFrame(
            topic: EventTopic.emotionTag,
            rawTopic: EventTopic.emotionTag.wireName,
            data: <String, dynamic>{
              'tag': 'happy',
              'kind': 'emotion',
              'intensity': 0.8,
              'actor_id': 'pet-1',
              'seq': 3,
              'ts_ms': 1700000000003,
            },
          ),
        );
        expect(
          state.applyFrame(
            const LipSyncRmsData(
              actorId: 'pet-1',
              level: 0.6,
              seq: 7,
              tsMs: 1700000000007,
            ),
          ),
          isTrue,
        );

        expect(state.caption.segments.single.text, 'Hel');
        expect(state.cue?.tag, 'happy');
        expect(state.frame?.seq, 7);

        var notifications = 0;
        state.addListener(() => notifications++);
        client.emitStatus(DaemonConnectionState.disconnected);
        // The fake's status stream is broadcast (async delivery).
        await Future<void>.delayed(Duration.zero);

        expect(notifications, 1, reason: 'one notification covers the clear');
        expect(state.caption.isEmpty, isTrue);
        expect(state.cue, isNull);
        expect(state.frame, isNull);
        expect(state.captionStyle, same(style));
        expect(state.background, same(background));

        // Dedupe baselines survive the clear: a replay cannot resurrect data.
        expect(
          state.applyFrame(
            const LipSyncRmsData(actorId: 'pet-1', level: 0.9, seq: 7, tsMs: 1),
          ),
          isFalse,
        );
        expect(
          state.applyCue(
            const StageExpressionCue(
              tag: 'happy',
              kind: 'emotion',
              intensity: 0.8,
              actorId: 'pet-1',
              seq: 3,
              tsMs: 1,
            ),
          ),
          isFalse,
        );
        expect(state.cue, isNull);
        expect(state.frame, isNull);
      },
    );
  });

  group('StageRenderStateBinding session filtering', () {
    test('a bound session drops foreign token.delta frames', () {
      final client = FakeChatClient();
      final state = StageRenderState();
      final binding = StageRenderStateBinding(
        client: client,
        state: state,
        boundSessionId: 's1',
      );
      addTearDown(binding.dispose);
      addTearDown(state.dispose);
      addTearDown(client.dispose);

      final before = state.caption;
      client.emitEvent(tokenDelta(sessionId: 's2', delta: 'foreign'));
      expect(state.caption, same(before), reason: 's2 must not clobber captions');

      client.emitEvent(tokenDelta(sessionId: 's1', delta: 'mine'));
      expect(state.caption.segments.single.text, 'mine');
    });

    test('an unbound binding learns from the stream without locking forever', () {
      final client = FakeChatClient();
      final state = StageRenderState();
      final binding = StageRenderStateBinding(client: client, state: state);
      addTearDown(binding.dispose);
      addTearDown(state.dispose);
      addTearDown(client.dispose);

      // Self-learn from the first delta so production works without shell
      // plumbing (mirrors chat_screen.dart:191-192).
      client.emitEvent(tokenDelta(sessionId: 's1', delta: 'hello '));
      expect(state.caption.segments.single.text, 'hello ');

      client.emitEvent(tokenDelta(sessionId: 's2', delta: 'intruder'));
      expect(
        state.caption.segments.single.text,
        'hello ',
        reason: 'a learned session must still filter foreign streams',
      );

      // A terminal frame ends the learned turn; the next turn may self-learn
      // a different session instead of being stuck on the first one seen.
      client.emitEvent(
        tokenDelta(sessionId: 's1', messageId: 'm1', delta: '', isFinal: true),
      );
      expect(state.caption.segments, isEmpty);
      client.emitEvent(tokenDelta(sessionId: 's2', delta: 'now mine'));
      expect(state.caption.segments.single.text, 'now mine');
    });
  });
}
