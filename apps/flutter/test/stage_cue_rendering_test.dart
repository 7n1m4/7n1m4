// SPDX-License-Identifier: GPL-3.0-or-later

// Focused, hermetic coverage of cue parsing, cue-channel routing and the cue
// readout widget. Only plain event maps and local render state are involved;
// no daemon, platform channel, native backend or asset is used.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_expression.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_overlays.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';

StageExpressionCue _cue({
  String tag = 'happy',
  String kind = 'emotion',
  double intensity = 0.8,
  String actorId = 'pet-1',
  int seq = 1,
}) => StageExpressionCue(
  tag: tag,
  kind: kind,
  intensity: intensity,
  actorId: actorId,
  seq: seq,
  tsMs: 1700000000000 + seq,
);

void main() {
  group('cue parsing and channels', () {
    test('emotion, motion and vfx cues parse with their channels', () {
      for (final kind in <String>['emotion', 'motion', 'vfx']) {
        final cue = parseExpressionCue(<String, dynamic>{
          'tag': 'wave',
          'kind': kind,
          'intensity': 0.5,
          'actor_id': 'pet-1',
          'seq': 1,
          'ts_ms': 1700000000001,
        });
        // `intensity` must be a num: a missing one is a malformed frame.
        expect(
          parseExpressionCue(<String, dynamic>{
            'tag': 'wave',
            'kind': kind,
            'actor_id': 'pet-1',
            'seq': 1,
            'ts_ms': 1700000000001,
          }),
          isNull,
          reason: kind,
        );
        expect(cue, isNotNull, reason: kind);
        expect(cue!.kind, kind);
        expect(
          stageCueChannel(cue),
          switch (kind) {
            'emotion' => StageCueChannel.emotion,
            'motion' => StageCueChannel.motion,
            _ => StageCueChannel.vfx,
          },
        );
      }
    });

    test('a vfx cue parses to its own channel, never a facial expression', () {
      final cue = parseExpressionCue(<String, dynamic>{
        'tag': 'sparkle',
        'kind': 'vfx',
        'intensity': 0.5,
        'actor_id': 'pet-1',
        'seq': 1,
        'ts_ms': 1700000000001,
      });
      expect(cue, isNotNull);
      expect(cue!.isMotion, isFalse);
      expect(cue.isNonFacial, isTrue);
      expect(stageCueChannel(cue), StageCueChannel.vfx);
    });

    test('malformed and wrong-actor cues are ignored', () {
      expect(
        parseExpressionCue(<String, dynamic>{
          'tag': 42,
          'kind': 'emotion',
          'seq': 1,
        }),
        isNull,
      );
      expect(
        parseExpressionCue(<String, dynamic>{
          'tag': 'happy',
          'kind': 'emotion',
          'actor_id': 'other',
          'seq': 1,
        }, actorId: 'pet-1'),
        isNull,
      );
    });

    test('an unknown cue kind has no render channel', () {
      expect(stageCueChannel(_cue(kind: 'unknown')), isNull);
    });
  });

  group('StageRenderState cue routing', () {
    test('stale and wrong-actor cues are dropped', () {
      final state = StageRenderState(actorId: 'pet-1');
      expect(state.applyCue(_cue(actorId: 'other')), isFalse);
      expect(state.applyCue(_cue(seq: 3)), isTrue);
      expect(state.applyCue(_cue(seq: 2)), isFalse);
      expect(state.applyCue(_cue(seq: 3)), isFalse);
      expect(state.cue?.seq, 3);
    });

    test('frames are filtered by actor and sequence independently', () {
      final state = StageRenderState(actorId: 'pet-1');
      LipSyncRmsData frame(int seq, String actor) => LipSyncRmsData(
        actorId: actor,
        level: 0.5,
        seq: seq,
        tsMs: 1700000000000 + seq,
      );
      expect(state.applyFrame(frame(1, 'other')), isFalse);
      expect(state.applyFrame(frame(1, 'pet-1')), isTrue);
      expect(state.applyFrame(frame(1, 'pet-1')), isFalse);
      expect(state.applyFrame(frame(2, 'pet-1')), isTrue);
    });

    test('re-following an actor clears both dedupe baselines', () {
      final state = StageRenderState(actorId: 'pet-1');
      expect(state.applyCue(_cue(seq: 1)), isTrue);
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'pet-1', level: 0.2, seq: 1, tsMs: 1),
        ),
        isTrue,
      );
      state.beginFollowing(actorId: 'pet-1');
      expect(state.applyCue(_cue(seq: 1)), isTrue);
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'pet-1', level: 0.2, seq: 1, tsMs: 1),
        ),
        isTrue,
      );
    });

    test('cue mutations notify listeners; filtered ones do not', () {
      final state = StageRenderState(actorId: 'pet-1');
      var notifications = 0;
      state.addListener(() => notifications++);
      state.applyCue(_cue(actorId: 'other'));
      expect(notifications, 0);
      state.applyCue(_cue(seq: 1));
      expect(notifications, 1);
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'pet-1', level: 0.4, seq: 1, tsMs: 1),
        ),
        isTrue,
      );
      expect(notifications, 2);
      state.dispose();
    });
  });

  group('StageCueBadge widget', () {
    // The badge is a pure readout; its host (StageScreen) rebuilds it when the
    // render state notifies. Mirror that listener so pumps observe real cues.
    Future<void> pumpBadge(WidgetTester tester, StageRenderState state) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AnimatedBuilder(
                animation: state,
                builder: (context, _) => SizedBox(
                  width: 800,
                  height: 600,
                  child: Stack(children: <Widget>[StageCueBadge(state: state)]),
                ),
              ),
            ),
          ),
        );

    testWidgets('without a cue the badge shows the real mouth level', (
      tester,
    ) async {
      final state = StageRenderState(actorId: 'pet-1');
      await pumpBadge(tester, state);
      expect(find.text('mouth 0%'), findsOneWidget);
    });

    testWidgets('emotion and motion cues are labelled by channel', (
      tester,
    ) async {
      final state = StageRenderState(actorId: 'pet-1');
      await pumpBadge(tester, state);
      var seq = 1;
      for (final entry in <MapEntry<String, String>>[
        const MapEntry<String, String>('emotion', 'happy'),
        const MapEntry<String, String>('motion', 'wave'),
      ]) {
        expect(
          state.applyCue(_cue(tag: entry.value, kind: entry.key, seq: seq++)),
          isTrue,
        );
        await tester.pump();
        expect(find.text('${entry.key} ${entry.value}'), findsOneWidget);
        expect(
          find.textContaining('emotion'),
          findsNWidgets(entry.key == 'emotion' ? 1 : 0),
        );
      }
    });

    testWidgets('a vfx cue is never presented as a facial expression', (
      tester,
    ) async {
      final state = StageRenderState(actorId: 'pet-1');
      await pumpBadge(tester, state);
      // A vfx cue is not an expression frame: `applyCue` accepts it (the
      // sequence is fresh) and the badge labels its channel, never 'emotion'.
      expect(state.applyCue(_cue(tag: 'sparkle', kind: 'vfx')), isTrue);
      await tester.pump();
      expect(find.text('vfx sparkle'), findsOneWidget);
      expect(find.textContaining('emotion'), findsNothing);
      expect(find.text('mouth 0%'), findsNothing);
    });

    testWidgets('emotion tag wire data drives the badge through the state', (
      tester,
    ) async {
      final state = StageRenderState(actorId: 'pet-1');
      await pumpBadge(tester, state);
      final data = <String, dynamic>{
        'tag': 'surprise',
        'kind': 'emotion',
        'intensity': 0.9,
        'actor_id': 'pet-1',
        'seq': 9,
        'ts_ms': 1700000000009,
      };
      expect(EventTopic.emotionTag.wireName, 'emotion.tag');
      final cue = parseExpressionCue(data, actorId: 'pet-1');
      expect(cue, isNotNull);
      state.applyCue(cue!);
      await tester.pump();
      expect(find.text('emotion surprise'), findsOneWidget);
    });
  });
}
