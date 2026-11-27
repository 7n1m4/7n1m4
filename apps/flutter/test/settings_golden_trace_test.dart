// SPDX-License-Identifier: GPL-3.0-or-later

// Dart leg of the shared settings bridge trace (v24b). Reads the SAME seven
// frames as crates/anima-channel/tests/interaction_settings_trace.rs and
// checks them through the Dart wire codec (ServerFrame / RpcReply /
// GatewayEventFrame) plus FakeChatClient's settings map.
//
// Every reply/event frame is parsed straight from the raw fixture JSON with
// the production codec: no action is injected and no envelope is rebuilt.
// A frame missing its wire `action` must surface here as an empty action.
//
// Choice of replay surface: a strict codec-level trace assertion plus a
// FakeChatClient settings-map assertion. SettingsScreen's Save writes the
// whole normalized draft, not a partial PATCH, so driving the widget would
// not exercise the partial-write seam this trace pins down. FakeChatClient
// exposes exactly that seam (settingsGet / settingsSet / lastSettingsWritten
// / emitEvent) without inventing a second state writer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

import 'support/fakes.dart';

/// Path to the Rust golden fixtures directory (same resolution as
/// golden_fixtures_test.dart).
final String _fixturesDir = () {
  // Works when tests are run from the repo root.
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  // Works when tests are run from apps/flutter (flutter test default cwd).
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  // Fallback for IDE runners.
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

final File _traceFile = File('$_fixturesDir/trace.settings.captions.json');

Map<String, dynamic> _loadTrace() {
  if (!_traceFile.existsSync())
    fail('trace fixture not found: ${_traceFile.path}');
  return jsonDecode(_traceFile.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _blob(ServerFrame frame) {
  final data = frame.reply!.data;
  expect(
    data,
    isA<Map<String, dynamic>>(),
    reason: 'settings.get carries the SettingsGetReply DTO',
  );
  final settings = (data as Map)['settings'];
  expect(
    settings,
    isA<String>(),
    reason: 'settings field is a JSON string on the wire',
  );
  return jsonDecode(settings as String) as Map<String, dynamic>;
}

void main() {
  group('settings bridge golden trace (dart)', () {
    test('codec replays all seven frames in order', () {
      final trace = _loadTrace();
      expect(trace['schema'], 'airi-channel-trace-v1');
      expect(trace['path'], 'settings.get/set');

      final frames = trace['frames'] as List;
      expect(frames.length, 7, reason: 'the trace must keep all seven frames');
      final f = frames.cast<Map<String, dynamic>>();

      // 0: settings.get request (s1).
      expect(f[0]['type'], 'rpc');
      expect(f[0]['action'], 'settings.get');
      expect(f[0]['id'], 's1');
      expect((f[0]['payload'] as Map)['section'], 'captions');

      // 1: settings.get reply (s1), raw frame through the production codec.
      final r1 = ServerFrame.parse(jsonEncode(f[1]));
      expect(r1.kind, ServerFrameKind.rpc);
      expect(r1.reply, isNotNull);
      expect(r1.reply!.action, 'settings.get');
      expect(r1.reply!.ok, isTrue);
      expect(r1.reply!.id, 's1');
      final initial = _blob(r1);
      expect(initial, <String, dynamic>{
        'enabled': false,
        'fontSize': 150,
        'opacity': 70,
        'docking': 'head',
      });

      // 2: settings.set request (s2) carries a PATCH, not the full blob.
      expect(f[2]['type'], 'rpc');
      expect(f[2]['action'], 'settings.set');
      expect(f[2]['id'], 's2');
      final payload = f[2]['payload'] as Map<String, dynamic>;
      expect(payload['section'], 'captions');
      final patch =
          jsonDecode(payload['settings'] as String) as Map<String, dynamic>;
      expect(patch, <String, dynamic>{'opacity': 55});
      expect(
        patch.length,
        1,
        reason: 'PATCH must carry only the changed field',
      );
      for (final sibling in ['enabled', 'fontSize', 'docking']) {
        expect(
          patch.containsKey(sibling),
          isFalse,
          reason: 'no sibling in PATCH',
        );
      }

      // 3: settings.set reply (s2), raw frame through the production codec.
      final r2 = ServerFrame.parse(jsonEncode(f[3]));
      expect(r2.kind, ServerFrameKind.rpc);
      expect(r2.reply!.action, 'settings.set');
      expect(r2.reply!.ok, isTrue);
      expect(r2.reply!.id, 's2');
      expect(r2.reply!.data, isA<Map<String, dynamic>>());
      expect((r2.reply!.data as Map)['ok'], isTrue);

      // 4: settings.changed event: topic/section/seq, no values.
      final eventFrame = ServerFrame.parse(jsonEncode(f[4]));
      expect(eventFrame.kind, ServerFrameKind.event);
      final event = eventFrame.event!;
      expect(event.topic, EventTopic.settingsChanged);
      expect(event.rawTopic, 'settings.changed');
      expect(event.id, isNull);
      expect(event.data, <String, dynamic>{
        'section': 'captions',
        'seq': 102,
        'ts_ms': 1700000000900,
      });

      // 5: the event is a read hint: re-read with a new id.
      expect(f[5]['type'], 'rpc');
      expect(f[5]['action'], 'settings.get');
      expect(f[5]['id'], 's3');
      expect((f[5]['payload'] as Map)['section'], 'captions');

      // 6: re-read shows the patched opacity with every sibling intact.
      final r3 = ServerFrame.parse(jsonEncode(f[6]));
      expect(r3.kind, ServerFrameKind.rpc);
      expect(r3.reply!.action, 'settings.get');
      expect(r3.reply!.ok, isTrue);
      expect(r3.reply!.id, 's3');
      final merged = _blob(r3);
      expect(merged['opacity'], 55, reason: 'opacity merged to 55');
      expect(merged['enabled'], initial['enabled']);
      expect(merged['fontSize'], initial['fontSize']);
      expect(merged['docking'], initial['docking']);
      final expected = Map<String, dynamic>.from(initial)..['opacity'] = 55;
      expect(merged, expected, reason: 'only opacity changed across the trace');
    });

    test('FakeChatClient writes the PATCH only and reloads after the event', () async {
      final trace = _loadTrace();
      final frames = (trace['frames'] as List).cast<Map<String, dynamic>>();
      final initial = _blob(ServerFrame.parse(jsonEncode(frames[1])));
      final patch = jsonDecode(
        (frames[2]['payload'] as Map)['settings'] as String,
      ) as Map<String, dynamic>;
      final merged = _blob(ServerFrame.parse(jsonEncode(frames[6])));
      final event = ServerFrame.parse(jsonEncode(frames[4])).event!;

      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.settingsToLoad = Map<String, dynamic>.from(initial);

      // settings.get -> the loaded captions values.
      final loaded = await client.settingsGet('captions');
      expect(client.settingsLoads, 1);
      expect(loaded, initial);

      // settings.set -> only the changed field reaches the daemon. No
      // siblings and no local-only keys from normalizeCaptions are written.
      String? writtenSection;
      client.onSet = (section, settings) => writtenSection = section;
      await client.settingsSet('captions', patch);
      expect(writtenSection, 'captions');
      expect(client.lastSettingsWritten, <String, dynamic>{'opacity': 55});
      expect(client.lastSettingsWritten!.keys, <String>{'opacity'});
      for (final sibling in ['enabled', 'fontSize', 'docking']) {
        expect(client.lastSettingsWritten!.containsKey(sibling), isFalse);
      }
      for (final localOnly in [
        'followStageVisibility',
        'followStagePosition',
        'layoutMode',
        'resetTrigger',
        'headTetheredCaptionEnabled',
        'headTetheredCaptionOffset',
        'headTetheredCaptionFollowStrength',
      ]) {
        expect(
          client.lastSettingsWritten!.containsKey(localOnly),
          isFalse,
          reason: 'local-only key $localOnly must not be written',
        );
      }

      // settings.changed -> a fresh read, as the screen's event listener does.
      client.settingsToLoad = Map<String, dynamic>.from(merged);
      final reload = Completer<Map<String, dynamic>>();
      final off = client.onEvent((incoming) {
        if (incoming.topic != EventTopic.settingsChanged) return;
        if (incoming.data['section'] != 'captions') return;
        client.settingsGet('captions').then(reload.complete);
      });
      addTearDown(off);
      client.emitEvent(event);

      final reread = await reload.future;
      expect(
        client.settingsLoads,
        2,
        reason: 'event triggered exactly one re-read',
      );
      expect(reread['opacity'], 55);
      expect(reread['enabled'], initial['enabled']);
      expect(reread['fontSize'], initial['fontSize']);
      expect(reread['docking'], initial['docking']);
      expect(reread, merged, reason: 're-read reflects the merged daemon blob');
    });
  });
}
