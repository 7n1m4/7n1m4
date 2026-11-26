// SPDX-License-Identifier: GPL-3.0-or-later

// airi-w17j: client-local speech intent queue. Mirrors the ordering, priority
// and cancellation half of packages/pipelines-audio/src/speech-pipeline.ts.
// No daemon state and no cross-window bus: only local synthesis is serialized.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';

class _FakeClock {
  int _ms = 1000;

  DateTime next() => DateTime.fromMillisecondsSinceEpoch(_ms += 10);
}

class _RecordingSink {
  final List<String> texts = <String>[];
  final List<AbortHandle?> aborts = <AbortHandle?>[];
  Completer<void>? gate;
  void Function(int count)? onCall;

  Future<void> call(String text, {AbortHandle? abort}) async {
    texts.add(text);
    aborts.add(abort);
    onCall?.call(texts.length);
    final gate = this.gate;
    if (gate != null) await gate.future;
  }
}

Future<void> _waitForCalls(_RecordingSink sink, int count) async {
  if (sink.texts.length >= count) return;
  final done = Completer<void>();
  final previous = sink.onCall;
  sink.onCall = (n) {
    previous?.call(n);
    if (n >= count && !done.isCompleted) done.complete();
  };
  try {
    await done.future.timeout(const Duration(seconds: 2));
  } finally {
    sink.onCall = previous;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

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
  String get id => 'controlled-test';

  @override
  int get sampleRate => 100;

  @override
  Future<Float32List> synthesize(String text) async => Float32List(0);

  @override
  Future<PcmSource> synthesizeToSource(String text) async => source;

  @override
  void dispose() {}
}

void main() {
  group('SpeechIntentQueue priorities', () {
    test('levels resolve to numeric weights, normal is the default', () {
      expect(resolveSpeechPriority(null), 100);
      expect(resolveSpeechPriority(SpeechPriority.critical), 300);
      expect(resolveSpeechPriority(SpeechPriority.high), 200);
      expect(resolveSpeechPriority(SpeechPriority.normal), 100);
      expect(resolveSpeechPriority(SpeechPriority.low), 0);
      expect(resolveSpeechPriority('critical'), 300);
      expect(resolveSpeechPriority('unknown'), 100);
      expect(resolveSpeechPriority(42), 42);
    });
  });

  group('SpeechIntentQueue ordering', () {
    test('pending intents run priority desc then creation order', () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call, now: _FakeClock().next);

      queue.openIntent(text: 'high', priority: SpeechPriority.high);
      queue.openIntent(text: 'low', priority: SpeechPriority.low);
      queue.openIntent(text: 'normal-1');
      queue.openIntent(text: 'normal-2');

      // Serialized: the gated first intent is the only synthesis in flight.
      expect(sink.texts, <String>['high']);
      final done = _waitForCalls(sink, 4);
      sink.gate!.complete();
      await done;
      expect(sink.texts, <String>['high', 'normal-1', 'normal-2', 'low']);
    });
  });

  group('SpeechIntentQueue behaviors', () {
    test('replace cancels active and runs the replacement next', () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      final first = queue.openIntent(text: 'first');
      final replacement = queue.openIntent(
        text: 'replacement',
        priority: 0,
        behavior: IntentBehavior.replace,
      );

      expect(first.canceled, isTrue);
      expect(first.abort.isAborted, isTrue);
      expect(sink.texts, <String>['first']);

      final done = _waitForCalls(sink, 2);
      sink.gate!.complete();
      await done;
      expect(sink.texts, <String>['first', 'replacement']);
      expect(replacement.canceled, isFalse);
    });

    test('interrupt cancels active when new priority is at least equal',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      final active = queue.openIntent(text: 'active');
      queue.openIntent(
        text: 'strong',
        priority: 200,
        behavior: IntentBehavior.interrupt,
      );

      expect(active.canceled, isTrue);
      expect(sink.texts, <String>['active']);
      final done = _waitForCalls(sink, 2);
      sink.gate!.complete();
      await done;
      expect(sink.texts, <String>['active', 'strong']);
    });

    test('lower-priority interrupt is enqueued instead of cancelling',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      final active = queue.openIntent(text: 'active', priority: 200);
      queue.openIntent(
        text: 'weak',
        priority: 0,
        behavior: IntentBehavior.interrupt,
      );

      expect(active.canceled, isFalse);
      expect(sink.texts, <String>['active']);
      final done = _waitForCalls(sink, 2);
      sink.gate!.complete();
      await done;
      expect(sink.texts, <String>['active', 'weak']);
    });

    test('cancelIntent drops pending and stopAll aborts every intent',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      final active = queue.openIntent(text: 'active');
      final queued = queue.openIntent(text: 'queued', priority: 50);
      queue.cancelIntent(queued.intentId);
      expect(queued.canceled, isTrue);
      expect(queued.abort.isAborted, isTrue);

      queue.stopAll();
      expect(active.canceled, isTrue);
      expect(active.abort.isAborted, isTrue);

      sink.gate!.complete();
      await _settle();
      expect(sink.texts, <String>['active']);
    });
  });

  group('SpeechIntentQueue cancellation is silent', () {
    test('aborting an intent drains real PCM without emitting frames',
        () async {
      final samples = StreamController<double>();
      final controller = LipSyncController(
        actorId: 'pet',
        engine: _ControlledEngine(_ControlledPcmSource(samples.stream)),
      );
      final frames = <LipSyncRmsData>[];
      controller.frames.listen(frames.add);
      final queue = SpeechIntentQueue(sink: controller.speak);

      final intent = queue.openIntent(text: 'hello');
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 5; i++) {
        samples.add(1.0);
      }
      await Future<void>.delayed(Duration.zero);
      expect(frames, isNotEmpty);
      final before = frames.length;

      queue.cancelIntent(intent.intentId);
      for (var i = 0; i < 25; i++) {
        samples.add(1.0);
      }
      await samples.close();
      await _settle();

      expect(frames, hasLength(before));
      controller.dispose();
    });
  });

  group('SpeechIntentQueue review fixes', () {
    test('replace cancels a queued urgent intent behind a running sink',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call, now: _FakeClock().next);

      queue.openIntent(text: 'first');
      final stale = queue.openIntent(
        text: 'stale',
        behavior: IntentBehavior.replace,
      );
      final newest = queue.openIntent(
        text: 'newest',
        behavior: IntentBehavior.replace,
      );

      expect(stale.canceled, isTrue);
      expect(stale.abort.isAborted, isTrue);
      expect(newest.canceled, isFalse);

      final done = _waitForCalls(sink, 2);
      sink.gate!.complete();
      await done;
      await _settle();
      expect(sink.texts, <String>['first', 'newest']);
    });

    test('interrupt at exactly equal priority cancels the active intent',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      final active = queue.openIntent(text: 'active', priority: 200);
      final equal = queue.openIntent(
        text: 'equal',
        priority: 200,
        behavior: IntentBehavior.interrupt,
      );

      expect(active.canceled, isTrue);
      expect(equal.canceled, isFalse);
      final done = _waitForCalls(sink, 2);
      sink.gate!.complete();
      await done;
      expect(sink.texts, <String>['active', 'equal']);
    });

    test('sink failures are reported through onError', () async {
      final errors = <Object>[];
      final queue = SpeechIntentQueue(
        sink: (text, {abort}) async => throw StateError('engine down'),
        onError: (error, intent) => errors.add(error),
      );

      queue.openIntent(text: 'hello');
      await _settle();

      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });

    test('a caller-supplied duplicate id stays cancellable after the first settles',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      queue.openIntent(text: 'first', intentId: 'dup');
      final second = queue.openIntent(text: 'second', intentId: 'dup');

      // Gate the second call so the newer intent is still tracked when the
      // first one settles; without the identical-id guard it becomes
      // uncancellable here.
      final secondGate = Completer<void>();
      final secondStarted = _waitForCalls(sink, 2);
      sink.gate!.complete();
      sink.gate = secondGate;
      await secondStarted;

      queue.cancelIntent('dup');
      expect(second.canceled, isTrue);
      expect(second.abort.isAborted, isTrue);
      secondGate.complete();
      await _settle();
    });

    test('replace with a duplicate id keeps the newer intent cancellable',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      queue.openIntent(text: 'first', intentId: 'dup');
      final newer = queue.openIntent(
        text: 'newer',
        intentId: 'dup',
        behavior: IntentBehavior.replace,
      );

      // _cancel must not unregister the newer intent that shares the id.
      final secondGate = Completer<void>();
      final secondStarted = _waitForCalls(sink, 2);
      sink.gate!.complete();
      sink.gate = secondGate;
      await secondStarted;

      queue.cancelIntent('dup');
      expect(newer.canceled, isTrue);
      expect(newer.abort.isAborted, isTrue);
      secondGate.complete();
      await _settle();
    });

    test('interrupt cancels a queued urgent intent behind a running sink',
        () async {
      final sink = _RecordingSink()..gate = Completer<void>();
      final queue = SpeechIntentQueue(sink: sink.call);

      queue.openIntent(text: 'first');
      final replacement = queue.openIntent(
        text: 'replacement',
        behavior: IntentBehavior.replace,
      );
      expect(replacement.canceled, isFalse);

      queue.interrupt();
      expect(replacement.canceled, isTrue);
      expect(replacement.abort.isAborted, isTrue);

      sink.gate!.complete();
      await _settle();
      expect(sink.texts, <String>['first']);
    });
  });
}
