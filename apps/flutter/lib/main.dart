// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'daemon_client/daemon_client.dart';
import 'navigation/navigation_shell.dart';
import 'speech/speech.dart';
import 'ui/lip_sync_controller.dart';
import 'ui/lipsync_renderer.dart';

/// App entry point. The lip-sync renderer is mounted here so it is visible on
/// every tab; the controller only produces frames from real local TTS PCM.
void main() {
  // One daemon client for the whole app. It holds view state only; all core
  // state lives in anima-daemon, so closing this window never stops the pet.
  final client = DaemonClient();
  final controller = _localLipSync();
  if (controller != null) _speakCompletedTurns(client, controller);
  runApp(
    AnimaApp(
      client: client,
      sceneStorageDirectoryProvider: defaultSceneStorageDirectory,
      lipSyncFrames: controller?.frames,
      lipSync: controller == null
          ? const SizedBox.shrink()
          : LipSyncRenderer(frames: controller.frames),
    ),
  );
}

/// Opt-in local TTS bridge. Without a user-supplied voice model no engine is
/// constructed: no process is spawned, no synthetic frames are produced.
LipSyncController? _localLipSync() {
  final model = Platform.environment['PIPER_MODEL'];
  if (model == null || model.trim().isEmpty) return null;
  return LipSyncController(
    actorId: 'pet',
    engine: PiperTtsEngine(modelPath: model),
  );
}

/// Speak completed assistant turns from the daemon event lane. No frames are
/// produced until a real turn arrives and Piper yields real PCM.
void _speakCompletedTurns(DaemonClient client, LipSyncController controller) =>
    speakCompletedTurns(client, controller);

/// Testable seam for the token.delta -> local TTS bridge. A terminal frame
/// carries `reason: complete|cancelled|error`. Only a successful turn is
/// spoken: cancelled and failed replies must never become audio. An absent
/// reason is treated as complete so an older daemon without the field keeps
/// working; intermediate deltas are buffered until `final: true`.
void speakCompletedTurns(
  DaemonClient client,
  LipSyncController controller, {
  SpeechIntentQueue? queue,
}) {
  // One client-local queue per bridge: it serializes synthesis and aborts the
  // in-flight source on replace/interrupt. No daemon state is duplicated here.
  final speechQueue = queue ?? SpeechIntentQueue(
    sink: controller.speak,
    onError: (error, intent) =>
        debugPrint('speech failed for ${intent.intentId}: $error'),
  );
  final buffer = StringBuffer();
  client.onEvent((event) {
    if (event.topic != EventTopic.tokenDelta) return;
    final delta = event.data['delta'];
    if (delta is String && delta.isNotEmpty) buffer.write(delta);
    if (event.data['final'] != true) return;
    final reason = event.data['reason'];
    final text = buffer.toString().trim();
    buffer.clear();
    if (reason != null && reason != 'complete') return;
    if (text.isNotEmpty) {
      // Normal priority, queue behavior: failures are reported through
      // onError, never as fabricated audio.
      speechQueue.openIntent(text: text, priority: SpeechPriority.normal);
    }
  });
}
