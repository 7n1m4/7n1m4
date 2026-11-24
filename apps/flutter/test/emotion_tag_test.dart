// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

GatewayEventFrame emotionTag({
  required String tag,
  required String kind,
  num intensity = 0.8,
  String actorId = 'character-7',
  int seq = 42,
  int tsMs = 1700000000200,
}) {
  return GatewayEventFrame(
    topic: EventTopic.emotionTag,
    rawTopic: 'emotion.tag',
    data: <String, dynamic>{
      'tag': tag,
      'intensity': intensity,
      'kind': kind,
      'actor_id': actorId,
      'seq': seq,
      'ts_ms': tsMs,
    },
  );
}

void main() {
  testWidgets('emotion.tag cue is visible; unrelated and malformed events do not spoof it',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
    );
    await tester.pump();

    expect(find.byKey(const Key('emotion-cue')), findsNothing);

    // A token delta carries no cue even if it looks emotion-ish.
    client.emitEvent(tokenDelta(delta: 'hello'));
    await tester.pump();
    expect(find.byKey(const Key('emotion-cue')), findsNothing);

    client.emitEvent(emotionTag(tag: 'happy', kind: 'emotion', intensity: 0.8));
    await tester.pump();
    expect(find.text('Emotion cue: happy · character-7'), findsOneWidget);
    expect(find.text('Intensity 80% · seq 42 · ts 1700000000200'), findsOneWidget);

    // Motion/VFX kinds are cues, but never presented as facial emotions.
    client.emitEvent(emotionTag(
      tag: 'wave',
      kind: 'motion',
      intensity: 0.6,
      seq: 43,
      tsMs: 1700000000300,
    ));
    await tester.pump();
    expect(find.text('Motion cue: wave · character-7'), findsOneWidget);
    expect(find.text('Intensity 60% · seq 43 · ts 1700000000300'), findsOneWidget);
    expect(find.textContaining('Emotion cue: happy'), findsNothing);

    // A malformed payload on the right topic cannot overwrite a real cue.
    client.emitEvent(const GatewayEventFrame(
      topic: EventTopic.emotionTag,
      rawTopic: 'emotion.tag',
      data: <String, dynamic>{
        'tag': 7,
        'kind': 'emotion',
        'intensity': 1,
      },
    ));
    await tester.pump();
    expect(find.text('Motion cue: wave · character-7'), findsOneWidget);

    // An unrelated topic with emotion-shaped data cannot spoof a cue either.
    client.emitEvent(const GatewayEventFrame(
      topic: EventTopic.tokenDelta,
      rawTopic: 'token.delta',
      data: <String, dynamic>{
        'tag': 'happy',
        'kind': 'emotion',
        'intensity': 1,
      },
    ));
    await tester.pump();
    expect(find.text('Motion cue: wave · character-7'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    expect(client.listeners, isEmpty);
  });

}
