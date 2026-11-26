// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local speech intent queue (airi-w17j). Port of the priority,
// ordering and cancellation half of
// packages/pipelines-audio/src/speech-pipeline.ts + priority.ts. Flutter is a
// single process: there is no BroadcastChannel bus and no daemon state here,
// only one serialized local TTS sink.

import 'pcm_source.dart';

enum SpeechPriority { critical, high, normal, low }

enum IntentBehavior { queue, interrupt, replace }

/// Mirrors `createPriorityResolver`: named levels map to fixed weights and a
/// numeric priority is used verbatim. Unknown/absent values are `normal`.
int resolveSpeechPriority(Object? priority) {
  if (priority == null) return 100;
  if (priority is num) return priority.round();
  if (priority is SpeechPriority) {
    return switch (priority) {
      SpeechPriority.critical => 300,
      SpeechPriority.high => 200,
      SpeechPriority.normal => 100,
      SpeechPriority.low => 0,
    };
  }
  if (priority is String) {
    return switch (priority) {
      'critical' => 300,
      'high' => 200,
      'normal' => 100,
      'low' => 0,
      _ => 100,
    };
  }
  return 100;
}

/// One queued unit of local speech. [abort] is shared with the PCM tap: once
/// aborted the remaining samples are drained as silence, never replaced with
/// fabricated audio.
class IntentState {
  IntentState({
    required this.intentId,
    required this.streamId,
    this.ownerId,
    required this.priority,
    required this.behavior,
    required this.createdAt,
    required this.abort,
    required this.text,
  });

  final String intentId;
  final String streamId;
  final String? ownerId;
  final int priority;
  final IntentBehavior behavior;
  final int createdAt;
  final AbortHandle abort;
  final String text;
  bool canceled = false;
}

/// One synthesis call. The queue serializes these so only one local TTS
/// process (e.g. Piper) runs at a time.
typedef SpeechSynthesisSink = Future<void> Function(String text,
    {AbortHandle? abort});

/// Orders local speech intents and feeds them one at a time into [sink].
/// Replacement/interruption cancel the active source; cancellation aborts the
/// intent's handle so the tap drains the rest of its PCM as silence.
class SpeechIntentQueue {
  SpeechIntentQueue({
    required this.sink,
    this.onError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SpeechSynthesisSink sink;
  /// Reports synthesis failures instead of silently dropping a turn.
  final void Function(Object error, IntentState intent)? onError;
  final DateTime Function() _now;

  final Map<String, IntentState> _intents = <String, IntentState>{};
  final List<IntentState> _urgent = <IntentState>[];
  final List<IntentState> _pending = <IntentState>[];
  IntentState? _active;
  Future<void>? _running;
  bool _pumping = false;
  int _id = 0;

  static String _defaultId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  /// Open an intent. With no active speech it starts immediately; `replace`
  /// always cancels active speech; `interrupt` does so only when the new
  /// priority is at least the active one. Everything else is queued.
  IntentState openIntent({
    required String text,
    String? intentId,
    String? streamId,
    String? ownerId,
    Object? priority,
    IntentBehavior behavior = IntentBehavior.queue,
  }) {
    final intent = IntentState(
      intentId: intentId ?? _defaultId('intent-$_id'),
      streamId: streamId ?? _defaultId('stream-$_id'),
      ownerId: ownerId,
      priority: resolveSpeechPriority(priority),
      behavior: behavior,
      createdAt: _now().millisecondsSinceEpoch,
      abort: AbortHandle(),
      text: text,
    );
    _id++;
    _intents[intent.intentId] = intent;

    final active = _active ?? (_urgent.isNotEmpty ? _urgent.last : null);
    if (active == null && _pending.isEmpty) {
      _urgent.add(intent);
    } else if (behavior == IntentBehavior.replace ||
        (behavior == IntentBehavior.interrupt &&
            active != null &&
            intent.priority >= active.priority)) {
      // Cancel the resolved active intent, which may still be queued in
      // _urgent while the previous sink call is in flight.
      if (active != null) _cancel(active);
      // Jumps ahead of ordinary pending work, but still waits for the
      // current sink call to finish so synthesis stays serialized.
      _urgent.add(intent);
    } else {
      _pending.add(intent);
    }
    _pump();
    return intent;
  }

  void cancelIntent(String intentId) {
    final intent = _intents[intentId];
    if (intent != null) _cancel(intent);
  }

  /// Cancel only the active intent (the `interrupt(reason)` seam in TS).
  void interrupt() {
    final active = _active ?? (_urgent.isNotEmpty ? _urgent.last : null);
    if (active != null) _cancel(active);
  }

  void stopAll() {
    for (final intent in _intents.values.toList()) {
      intent.canceled = true;
      intent.abort.abort();
    }
    _intents.clear();
    _urgent.clear();
    _pending.clear();
    _active = null;
  }

  void _cancel(IntentState intent) {
    if (intent.canceled) return;
    intent.canceled = true;
    intent.abort.abort();
    // A caller-supplied duplicate id may now point at a newer intent.
    if (identical(_intents[intent.intentId], intent)) {
      _intents.remove(intent.intentId);
    }
    if (identical(_active, intent)) {
      _active = null;
    } else {
      _urgent.remove(intent);
      _pending.remove(intent);
    }
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    () async {
      while (true) {
        final running = _running;
        if (running != null) {
          await running;
          _running = null;
        }
        IntentState? next;
        if (_urgent.isNotEmpty) {
          next = _urgent.removeAt(0);
        } else if (_pending.isNotEmpty) {
          _pending.sort((a, b) {
            final byPriority = b.priority.compareTo(a.priority);
            return byPriority != 0
                ? byPriority
                : a.createdAt.compareTo(b.createdAt);
          });
          next = _pending.removeAt(0);
        }
        if (next == null) break;
        if (next.canceled) continue;
        _running = _run(next);
      }
      _pumping = false;
    }();
  }

  Future<void> _run(IntentState intent) async {
    _active = intent;
    try {
      await sink(intent.text, abort: intent.abort);
    } catch (error) {
      // Never fake PCM on failure; surface it so a failed turn is not silent.
      onError?.call(error, intent);
    } finally {
      if (identical(_active, intent)) _active = null;
      // A caller-supplied duplicate id must not unregister the newer intent.
      if (identical(_intents[intent.intentId], intent)) {
        _intents.remove(intent.intentId);
      }
    }
  }
}
