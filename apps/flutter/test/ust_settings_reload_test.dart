// SPDX-License-Identifier: GPL-3.0-or-later

// UST options are daemon-owned: a `settings.changed` event for the `speech`
// section must re-read the active profile and change subsequent spoken text,
// never write a local snapshot back with `settings.set`.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart'
    show DaemonConnectionState, DaemonStatus, EventTopic, GatewayEventFrame;
import 'package:anima_control/main.dart'
    show
        UstOptionsReloadState,
        loadUstOptionsOnce,
        reloadUstOptionsOnSettingsChanged,
        speakCompletedTurns;
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';

import 'support/fakes.dart';

/// A speech section with one active profile. [tilde] of null leaves `~`
/// untouched; a string replaces it, so a profile swap is audible.
Map<String, dynamic> _speechSettings(String? tilde) => <String, dynamic>{
      'activeProvider': 'virtual-audio-studio',
      'voice': 'pet-voice',
      'voiceProfiles': <dynamic>[
        <String, dynamic>{
          'id': 'pet-voice',
          'name': 'Pet',
          'baseVoice': 'pet-voice',
          'baseProvider': 'piper',
          'ust': <String, dynamic>{
            'enabled': true,
            if (tilde != null) 'tildeReplacement': tilde,
          },
        },
      ],
    };

GatewayEventFrame _settingsChanged(String section) => GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': section},
    );

/// Counts live `statusStream` subscriptions so the bounded connection wait can
/// be checked for listener leaks after its timeout fires.
class _TrackedStatusClient extends FakeChatClient {
  _TrackedStatusClient() {
    _controller = StreamController<DaemonStatus>.broadcast(
      onListen: () => subscriptions++,
      onCancel: () => subscriptions--,
    );
  }

  late final StreamController<DaemonStatus> _controller;
  int subscriptions = 0;

  @override
  Stream<DaemonStatus> get statusStream => _controller.stream;

  @override
  void emitStatus(DaemonConnectionState state) {
    _controller.add(DaemonStatus(state: state));
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

void main() {
  test('settings.changed(speech) reloads the profile into spoken text', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final controller =
        LipSyncController(actorId: 'pet', engine: IdleEngine());
    addTearDown(controller.dispose);
    final spoken = <String>[];
    final queue = SpeechIntentQueue(
      sink: (text, {abort}) async => spoken.add(text),
    );

    var options = const UstOptions();
    speakCompletedTurns(
      client,
      controller,
      queue: queue,
      optionsForTurn: () => options,
    );
    final reloadState = UstOptionsReloadState();
    reloadUstOptionsOnSettingsChanged(
      client,
      (loaded) => options = loaded,
      reloadState,
    );

    // Startup load still reads once and keeps `~` as spoken text.
    client.emitStatus(DaemonConnectionState.connected);
    client.settingsToLoad = _speechSettings(null);
    await loadUstOptionsOnce(client, (loaded) => options = loaded, reloadState);
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 1);

    client.emitEvent(tokenDelta(delta: 'a~b', isFinal: true, reason: 'complete'));
    await Future<void>.delayed(Duration.zero);
    expect(spoken, <String>['a~b']);

    // Unrelated sections and malformed payloads must not re-read speech.
    client.settingsToLoad = _speechSettings('nyan');
    client.emitEvent(_settingsChanged('theme'));
    client.emitEvent(const GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': 42},
    ));
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 1);

    // A speech change re-reads once and replaces the holder for later turns.
    client.emitEvent(_settingsChanged('speech'));
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 2);

    client.emitEvent(tokenDelta(delta: 'a~b', isFinal: true, reason: 'complete'));
    await Future<void>.delayed(Duration.zero);
    expect(spoken, <String>['a~b', 'a nyan b']);
    expect(client.lastSettingsWritten, isNull);
  });

  test('speech-only event reloads even without the startup loader', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final controller =
        LipSyncController(actorId: 'pet', engine: IdleEngine());
    addTearDown(controller.dispose);
    final spoken = <String>[];
    final queue = SpeechIntentQueue(
      sink: (text, {abort}) async => spoken.add(text),
    );

    var options = const UstOptions();
    speakCompletedTurns(
      client,
      controller,
      queue: queue,
      optionsForTurn: () => options,
    );
    reloadUstOptionsOnSettingsChanged(client, (loaded) => options = loaded);
    expect(client.settingsLoads, 0);

    client.settingsToLoad = _speechSettings('nyan');
    client.emitEvent(_settingsChanged('chat'));
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 0);

    client.emitEvent(_settingsChanged('speech'));
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 1);

    client.emitEvent(tokenDelta(delta: 'a~b', isFinal: true, reason: 'complete'));
    await Future<void>.delayed(Duration.zero);
    expect(spoken, <String>['a nyan b']);
    expect(client.lastSettingsWritten, isNull);
  });

  test('late startup reply cannot overwrite a newer settings.changed reload',
      () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    // Connected up front so the loader goes straight to settings.get.
    client.emitStatus(DaemonConnectionState.connected);

    // Two completers let the two settings.get calls land out of order.
    final startupReply = Completer<Map<String, dynamic>>();
    final reloadReply = Completer<Map<String, dynamic>>();
    client.deferredSettings = startupReply;

    final controller =
        LipSyncController(actorId: 'pet', engine: IdleEngine());
    addTearDown(controller.dispose);
    final spoken = <String>[];
    final queue = SpeechIntentQueue(
      sink: (text, {abort}) async => spoken.add(text),
    );
    var options = const UstOptions();
    speakCompletedTurns(
      client,
      controller,
      queue: queue,
      optionsForTurn: () => options,
    );

    final reloadState = UstOptionsReloadState();
    reloadUstOptionsOnSettingsChanged(
      client,
      (loaded) => options = loaded,
      reloadState,
    );
    final loading =
        loadUstOptionsOnce(client, (loaded) => options = loaded, reloadState);

    // The startup read is parked; a speech change starts a second read on the
    // other completer so the reload can finish first.
    expect(client.settingsLoads, 1);
    client.deferredSettings = reloadReply;
    client.emitEvent(_settingsChanged('speech'));
    expect(client.settingsLoads, 2);

    // Fresh reload lands first and installs the `nyan` profile.
    reloadReply.complete(_speechSettings('nyan'));
    await Future<void>.delayed(Duration.zero);

    // The stale startup reply lands afterwards and must be discarded.
    startupReply.complete(_speechSettings(null));
    await loading;

    client.emitEvent(tokenDelta(delta: 'a~b', isFinal: true, reason: 'complete'));
    await Future<void>.delayed(Duration.zero);
    expect(spoken, <String>['a nyan b']);
    expect(client.lastSettingsWritten, isNull);
  });

  test('a burst of speech changes starts only one settings.get', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.emitStatus(DaemonConnectionState.connected);
    final reply = Completer<Map<String, dynamic>>();
    client.deferredSettings = reply;

    var options = const UstOptions();
    final unsubscribe = reloadUstOptionsOnSettingsChanged(
      client,
      (loaded) => options = loaded,
    );
    addTearDown(unsubscribe);

    client.emitEvent(_settingsChanged('speech'));
    client.emitEvent(_settingsChanged('speech'));
    client.emitEvent(_settingsChanged('speech'));
    expect(client.settingsLoads, 1);

    reply.complete(_speechSettings('nyan'));
    await Future<void>.delayed(Duration.zero);
    expect(client.settingsLoads, 1);
    expect(options.tildeReplacement, 'nyan');
  });

  testWidgets(
      'bounded connection wait cancels its status subscription on timeout',
      (tester) async {
    final client = _TrackedStatusClient();
    addTearDown(client.dispose);
    unawaited(loadUstOptionsOnce(client, (_) {}));
    expect(client.subscriptions, 1);

    await tester.pump(const Duration(seconds: 11));

    expect(client.subscriptions, 0);
    expect(client.settingsLoads, 0);
  });
}
