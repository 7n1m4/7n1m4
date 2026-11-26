// SPDX-License-Identifier: GPL-3.0-or-later

// airi-32xj: a cancelled/error terminal token.delta stops the client-local
// speech queue, including non-final terminals from the daemon publisher.
// Only local handles are aborted: no daemon state writer and no fabricated
// frames. Mirrors the bounded-wait pattern in speech_intent_queue_test.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/main.dart' show speakCompletedTurns;
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';

import 'support/fakes.dart';

class _ControlledPcmSource implements PcmSource {
  _ControlledPcmSource(this._stream);

  final Stream<double> _stream;

  @override
  int get sampleRate => 100;

  @override
  int get channels => 1;

  @override
  Stream<double> open() => _stream;
}

class _ControlledEngine extends TtsEngine {
  _ControlledEngine(this.source);

  final PcmSource source;

  @override
  String get id => 'controlled-stop-test';

  @override
  int get sampleRate => 100;

  @override
  Future<Float32List> synthesize(String text) async => Float32List(0);

  @override
  Future<PcmSource> synthesizeToSource(String text) async => source;

  @override
  void dispose() {}
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Harness {
  _Harness() {
    final listening = Completer<void>();
    samples = StreamController<double>(
      onListen: () {
        if (!listening.isCompleted) listening.complete();
      },
    );
    controller = LipSyncController(
      actorId: 'pet',
      engine: _ControlledEngine(_ControlledPcmSource(samples.stream)),
    );
    frames = <LipSyncRmsData>[];
    controller.frames.listen(frames.add);
    client = FakeChatClient();
    started = Completer<void>();
    gate = Completer<void>();
    queue = SpeechIntentQueue(
      sink: (text, {abort}) async {
        capturedAbort = abort;
        spoken.add(text);
        if (!started.isCompleted) started.complete();
        await gate.future;
        await controller.speak(text, abort: abort);
      },
    );
    speakCompletedTurns(client, controller, queue: queue);
    _listening = listening;
  }

  late final StreamController<double> samples;
  late final LipSyncController controller;
  late final List<LipSyncRmsData> frames;
  late final FakeChatClient client;
  late final Completer<void> started;
  late final Completer<void> gate;
  late final SpeechIntentQueue queue;
  Completer<void>? _listening;
  AbortHandle? capturedAbort;
  final List<String> spoken = <String>[];

  Future<void> startIntent({String text = 'hello', String sessionId = 's1'}) async {
    client.emitEvent(
      tokenDelta(
        delta: text,
        isFinal: true,
        reason: 'complete',
        sessionId: sessionId,
      ),
    );
    await started.future.timeout(const Duration(seconds: 2));
    gate.complete();
    await _listening!.future.timeout(const Duration(seconds: 2));
    for (var i = 0; i < 10; i++) {
      samples.add(1.0);
    }
    await _settle();
    expect(frames, isNotEmpty);
    expect(capturedAbort, isNotNull);
    expect(capturedAbort!.isAborted, isFalse);
  }

  Future<void> expectSilentAfter() async {
    final before = frames.length;
    for (var i = 0; i < 20; i++) {
      samples.add(1.0);
    }
    await _settle();
    expect(frames, hasLength(before));
  }

  void dispose() {
    controller.dispose();
    if (!samples.isClosed) samples.close();
  }
}

void main() {
  for (final isFinal in [true, false]) {
    for (final reason in ['cancelled', 'error']) {
      test('$reason terminal (final=$isFinal) aborts the in-flight intent',
          () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.startIntent();

        h.client.emitEvent(
          tokenDelta(
            delta: '',
            isFinal: isFinal,
            reason: reason,
            sessionId: 's1',
          ),
        );
        await _settle();

        expect(h.capturedAbort!.isAborted, isTrue);
        await h.expectSilentAfter();
      });
    }
  }

  test('a foreign-session cancel cannot stop another session speech', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.startIntent();

    h.client.emitEvent(
      tokenDelta(
        delta: '',
        isFinal: false,
        reason: 'cancelled',
        sessionId: 's2',
      ),
    );
    await _settle();
    expect(h.capturedAbort!.isAborted, isFalse);
    expect(h.spoken, hasLength(1));

    // Let the first intent finish, then a later complete turn for the bound
    // session still speaks (bounded settling, never a real-time sleep).
    await h.samples.close();
    await _settle();
    h.client.emitEvent(
      tokenDelta(
        delta: 'again',
        isFinal: true,
        reason: 'complete',
        sessionId: 's1',
      ),
    );
    for (var i = 0; i < 20 && h.spoken.length < 2; i++) {
      await _settle();
    }
    expect(h.spoken, ['hello', 'again']);
  });
}
