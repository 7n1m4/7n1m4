// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
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
  if (controller != null) {
    var ustOptions = const UstOptions();
    // One coordinator for both writers: a late startup reply must not clobber
    // options installed by a newer settings.changed reload. Until the daemon
    // answers, starter defaults apply to every terminal turn; the holder is
    // re-read on every turn.
    final reloadState = UstOptionsReloadState();
    _speakCompletedTurns(client, controller, () => ustOptions);
    reloadUstOptionsOnSettingsChanged(
      client,
      (options) => ustOptions = options,
      reloadState,
    );
    unawaited(
      loadUstOptionsOnce(client, (options) => ustOptions = options, reloadState),
    );
  }
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
void _speakCompletedTurns(DaemonClient client, LipSyncController controller,
        UstOptions Function() optionsForTurn) =>
    speakCompletedTurns(client, controller, optionsForTurn: optionsForTurn);

/// Shared coordination between the startup load and `settings.changed`
/// reloads. Both paths must be given the *same* instance (as `main` does) so a
/// reply from an older read cannot replace options installed by a newer one.
class UstOptionsReloadState {
  /// Bumped only when a reload is actually installed. The startup loader
  /// captures this value before its first await and skips its apply if it
  /// changed in the meantime.
  int generation = 0;

  /// At most one reload RPC is in flight; a burst of events collapses into the
  /// single read already underway instead of starting N concurrent RPCs.
  bool reloadInFlight = false;
}

/// Wait until the daemon reports connected, but never longer than [timeout].
/// Uses an explicit subscription because `firstWhere(...).timeout(...)` leaves
/// `firstWhere`'s listener attached when the timeout fires. Both exit paths
/// cancel the subscription and the timer synchronously.
Future<void> _waitForConnection(DaemonClient client, Duration timeout) {
  final connected = Completer<void>();
  Timer? timer;
  StreamSubscription<DaemonStatus>? subscription;
  void cleanup() {
    subscription?.cancel();
    timer?.cancel();
  }

  subscription = client.statusStream.listen((status) {
    if (status.state == DaemonConnectionState.connected &&
        !connected.isCompleted) {
      connected.complete();
      cleanup();
    }
  });
  timer = Timer(timeout, () {
    if (!connected.isCompleted) {
      connected.completeError(
        TimeoutException('daemon did not connect', timeout),
      );
      cleanup();
    }
  });
  // The snapshot may have flipped between the caller's check and listen().
  if (client.snapshot.isConnected && !connected.isCompleted) {
    connected.complete();
    cleanup();
  }
  return connected.future;
}

/// Read `settings/speech` once, as soon as the client can answer. A client that
/// has not connected yet (the user connects from the Connections screen) is
/// waited on rather than probed once and forgotten, but only for a bounded
/// time. The caller's subscription must already be registered: [apply] writes
/// the loaded options into the holder that is re-read on every turn. Settings
/// are daemon-owned, so this never writes a local fallback back.
///
/// Pass the same [state] used by [reloadUstOptionsOnSettingsChanged] so a late
/// reply from this startup read cannot overwrite a newer reload.
Future<void> loadUstOptionsOnce(
  DaemonClient client,
  void Function(UstOptions) apply, [
  UstOptionsReloadState? state,
]) async {
  final reloadState = state ?? UstOptionsReloadState();
  final generation = reloadState.generation;
  try {
    if (!client.snapshot.isConnected) {
      await _waitForConnection(client, const Duration(seconds: 10));
    }
    final settings = await client.settingsGet('speech');
    // A settings.changed reload landed while this reply was in flight; it owns
    // the holder now, so discard the older startup value.
    if (generation != reloadState.generation) return;
    apply(UstOptions.fromSpeechSettings(settings));
  } catch (_) {
    // An unreachable daemon or section keeps the pre-connect starter defaults.
  }
}

/// Re-read `settings/speech` when the daemon publishes a `settings.changed`
/// event for the `speech` section, replacing the holder [apply] writes in
/// place. Settings are daemon-owned: this never writes a local snapshot back
/// with `settings.set`. Returns the unsubscribe handle from [DaemonClient.onEvent].
/// Share [state] with [loadUstOptionsOnce] to keep their replies ordered.
void Function() reloadUstOptionsOnSettingsChanged(
  DaemonClient client,
  void Function(UstOptions) apply, [
  UstOptionsReloadState? state,
]) {
  final reloadState = state ?? UstOptionsReloadState();
  return client.onEvent((event) {
    if (event.topic != EventTopic.settingsChanged) return;
    if (event.data['section'] != 'speech') return;
    // The event arrives on a live connection, so read immediately: the bounded
    // first-connect wait belongs to [loadUstOptionsOnce] alone.
    unawaited(_reloadUstOptions(client, apply, reloadState));
  });
}

Future<void> _reloadUstOptions(
  DaemonClient client,
  void Function(UstOptions) apply,
  UstOptionsReloadState state,
) async {
  if (state.reloadInFlight) return;
  state.reloadInFlight = true;
  try {
    final settings = await client.settingsGet('speech');
    state.generation++;
    apply(UstOptions.fromSpeechSettings(settings));
  } catch (_) {
    // An unreadable section leaves the last good options in place.
  } finally {
    state.reloadInFlight = false;
  }
}

/// Testable seam for the token.delta -> local TTS bridge. A terminal frame
/// carries `reason: complete|cancelled|error`; cancelled and error are
/// terminal even without `final: true`. Only a successful turn is spoken:
/// cancelled and failed replies stop this client's queue instead. An absent
/// reason is treated as complete so an older daemon without the field keeps
/// working; intermediate deltas are buffered until the terminal frame.
/// Foreign `session_id` deltas are ignored so one turn cannot cancel another
/// session's speech.
void speakCompletedTurns(
  DaemonClient client,
  LipSyncController controller, {
  SpeechIntentQueue? queue,
  UstOptions Function()? optionsForTurn,
}) {
  // One client-local queue per bridge: it serializes synthesis and aborts the
  // in-flight source on replace/interrupt. No daemon state is duplicated here.
  final speechQueue = queue ?? SpeechIntentQueue(
    sink: controller.speak,
    onError: (error, intent) =>
        debugPrint('speech failed for ${intent.intentId}: $error'),
  );
  final ustOptions = optionsForTurn ?? () => const UstOptions();
  final buffer = StringBuffer();
  String? boundSessionId;
  client.onEvent((event) {
    if (event.topic != EventTopic.tokenDelta) return;
    final data = event.data;
    final reason = data['reason'];
    final isFinal = data['final'] == true;
    // The publisher marks cancelled/error terminal without final: true
    // (crates/anima-daemon/src/events.rs), so reason alone must end a turn.
    final terminal = isFinal || reason == 'cancelled' || reason == 'error';
    // The event lane carries every session. Keep the session bound across a
    // terminal so a foreign cancel cannot stop speech from a prior turn; a
    // new turn's first delta may rebind to a different session.
    final sid = data['session_id'];
    if (sid is String && sid.isNotEmpty) {
      if (boundSessionId == null || (buffer.isEmpty && !terminal)) {
        boundSessionId = sid;
      } else if (sid != boundSessionId) {
        return;
      }
    }
    final delta = data['delta'];
    if (delta is String && delta.isNotEmpty) buffer.write(delta);
    if (!terminal) return;
    final text = buffer.toString().trim();
    buffer.clear();
    if (reason != null && reason != 'complete') {
      // A cancelled/failed turn leaves a previous intent synthesizing. Stop
      // only this client's queue; the daemon keeps its own speech state.
      speechQueue.stopAll();
      return;
    }
    if (text.isNotEmpty) {
      // Normal priority, queue behavior: failures are reported through
      // onError, never as fabricated audio.
      speechQueue.openIntent(
        text: applyUstTransform(text, ustOptions()),
        priority: SpeechPriority.normal,
      );
    }
  });
}
