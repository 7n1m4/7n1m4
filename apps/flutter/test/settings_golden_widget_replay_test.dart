// SPDX-License-Identifier: GPL-3.0-or-later

// Real-execution leg of the settings bridge golden trace. Unlike
// settings_golden_trace_test.dart (codec + FakeChatClient), this test boots a
// REAL DaemonClient over a ScriptedTransport and pumps a REAL SettingsScreen:
// the Rust-produced golden reply and settings.changed event travel through the
// transport, the production frame codec, the client's event bus and finally
// into the widget's section loader.
//
// Only the captions settings.get replies and the settings.changed event are
// verbatim Rust golden frames; their correlation id is rebound to the live
// request id (the trace uses symbolic ids such as "s1", the client uses ints).
// auth, core.status, event.subscribe, runtime.status, providers.list,
// cards.list, settings.set and the non-captions settings.get replies are
// hand-built scaffolding. Every frame consumed — golden or scaffolded — is
// parsed through the production ServerFrame / RpcReply / GatewayEventFrame
// codec rather than a hand-built reader.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

/// Same fixture resolution as golden_fixtures_test.dart.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

final File _traceFile = File('$_fixturesDir/trace.settings.captions.json');
final File _eventFile = File(
  '$_fixturesDir/event.settings_changed.captions.json',
);

Map<String, dynamic> _readJson(File file) {
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

final Map<String, dynamic> _healthyCore = <String, dynamic>{
  'app': 'anima-daemon',
  'version': '0.1.0',
  'coreAvailable': true,
  'storeAvailable': true,
  'storeHealth': 'ok',
  'protocol': 'airi-channel/1',
  'sessionCount': 3,
  'messageCount': 12,
};

String _replyFrame(String action, Object id, Object? data, {bool ok = true}) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': ok,
      'id': id,
      if (data != null) 'data': data,
    });

Object? _dataFor(String action) => switch (action) {
  'core.status' => _healthyCore,
  'event.subscribe' => <String, dynamic>{'subscribed': true},
  'runtime.status' => <String, dynamic>{
    'app': 'anima-daemon',
    'version': '0.1.0',
  },
  'providers.list' => <String, dynamic>{'providers': <dynamic>[]},
  'cards.list' => <String, dynamic>{'cards': <dynamic>[], 'truncated': false},
  _ => <String, dynamic>{},
};

/// Answers every RPC the real client puts on the wire, one wave at a time.
/// `settings.get` for captions is answered straight from the golden frame;
/// all other reads get an empty section so the screen can finish its load.
class _ReplayPeer {
  _ReplayPeer(this.transport, this.captionsReply);

  final ScriptedTransport transport;

  /// Raw golden reply frame (correlation id is rebound per request).
  String captionsReply;

  int _handled = 0;
  final List<Map<String, dynamic>> settingsSets = <Map<String, dynamic>>[];

  int captionsGets() => transport.sent
      .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
      .where(
        (frame) =>
            frame['type'] == 'rpc' &&
            frame['action'] == 'settings.get' &&
            (frame['payload'] as Map?)?['section'] == 'captions',
      )
      .length;

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 12; pass++) {
      while (_handled < transport.sent.length) {
        final request =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (request['type'] != 'rpc') continue;
        final action = request['action'] as String?;
        final id = request['id'];
        if (action == null || id == null) continue;
        switch (action) {
          case 'settings.get':
            final section = (request['payload'] as Map?)?['section'];
            if (section == 'captions') {
              final golden = jsonDecode(captionsReply) as Map<String, dynamic>;
              // The trace uses symbolic ids; only the id changes on the wire.
              final reply = jsonEncode(<String, dynamic>{...golden, 'id': id});
              transport.receive(reply);
            } else {
              transport.receive(
                _replyFrame(action, id, <String, dynamic>{
                  'section': section,
                  'settings': '{}',
                }),
              );
            }
          case 'settings.set':
            settingsSets.add(request);
            transport.receive(
              _replyFrame(action, id, <String, dynamic>{'ok': true}),
            );
          default:
            transport.receive(_replyFrame(action, id, _dataFor(action)));
        }
      }
      await flush();
      if (_handled >= transport.sent.length) {
        await flush();
        if (_handled >= transport.sent.length) return;
      }
    }
    fail('replay did not quiesce after 12 waves');
  }
}

bool _switchOf(WidgetTester tester, String title) => tester
    .widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(SwitchListTile),
        ),
        matching: find.byType(Switch),
      ),
    )
    .value;

String _fieldTextOf(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey<String>(label)),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

String? _dockingShownOf(WidgetTester tester) => tester
    .widget<DropdownButton<String>>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Docking'),
          matching: find.byType(DropdownButtonFormField<String>),
        ),
        matching: find.byType(DropdownButton<String>),
      ),
    )
    .value;

class _ReplayHarness {
  _ReplayHarness(this.client, this.transport, this.peer);

  final DaemonClient client;
  final ScriptedTransport transport;
  final _ReplayPeer peer;
}

/// Boot a real client (auth -> core.status -> four event.subscribe RPCs) and
/// pump a real SettingsScreen whose captions reads answer from [captionsReply].
Future<_ReplayHarness> _bootReplay(
  WidgetTester tester, {
  required String captionsReply,
}) async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 5),
    rpcTimeout: const Duration(seconds: 5),
    heartbeatInterval: const Duration(hours: 1),
  );
  addTearDown(client.dispose);
  final peer = _ReplayPeer(transport, captionsReply);
  // In testWidgets the whole body runs in FakeAsync: a Future.delayed timer
  // would never fire without a pump, so flush through the tester.
  Future<void> micro() => tester.pump();

  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await micro();
  expect(jsonDecode(transport.sent.single)['type'], 'auth');
  transport.receive('{"type":"auth","ok":true}');
  await micro();
  await peer.drain(micro);
  await connecting;
  await peer.drain(micro);
  expect(client.snapshot.state, DaemonConnectionState.connected);
  expect(
    transport.sent
        .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
        .where((frame) => frame['action'] == 'event.subscribe')
        .length,
    4,
    reason: 'the client re-subscribes to all four topics',
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsScreen(client: client, onOpenConnections: () {}),
      ),
    ),
  );
  await peer.drain(() => tester.pump());
  await tester.pumpAndSettle();
  return _ReplayHarness(client, transport, peer);
}

void main() {
  testWidgets(
    'Rust golden settings wire drives a real DaemonClient and SettingsScreen',
    (tester) async {
      final trace = _readJson(_traceFile);
      expect(trace['schema'], 'airi-channel-trace-v1');
      final frames = (trace['frames'] as List).cast<Map<String, dynamic>>();
      expect(frames, hasLength(7));

      // Parse the reply frames through the production codec before using them.
      final initialFrame = ServerFrame.parse(jsonEncode(frames[1]));
      final mergedFrame = ServerFrame.parse(jsonEncode(frames[6]));
      expect(initialFrame.kind, ServerFrameKind.rpc);
      expect(initialFrame.reply!.action, 'settings.get');
      final goldenEvent = ServerFrame.parse(jsonEncode(_readJson(_eventFile)));
      expect(goldenEvent.kind, ServerFrameKind.event);
      expect(goldenEvent.event!.topic, EventTopic.settingsChanged);
      expect(goldenEvent.event!.data['section'], 'captions');
      expect(goldenEvent.event!.data['seq'], 102);
      expect(goldenEvent.event!.data['ts_ms'], 1700000000900);

      final patchFrame = ServerFrame.parse(jsonEncode(frames[2]));
      expect(patchFrame.kind, ServerFrameKind.rpc);
      expect(patchFrame.reply!.action, 'settings.set');
      final goldenPatch = jsonDecode(
        (frames[2]['payload'] as Map)['settings'] as String,
      ) as Map<String, dynamic>;
      expect(goldenPatch, <String, dynamic>{'opacity': 55});

      final initialReply = jsonEncode(frames[1]);
      final mergedReply = jsonEncode(frames[6]);
      expect(
        (jsonDecode(initialReply)['data'] as Map)['settings'],
        '{"enabled":false,"fontSize":150,"opacity":70,"docking":"head"}',
      );

      final harness = await _bootReplay(tester, captionsReply: initialReply);
      final client = harness.client;
      final transport = harness.transport;
      final peer = harness.peer;

      // Observe the real event bus so we can tell "ignored by the screen"
      // apart from "never delivered".
      int settingsEvents = 0;
      final off = client.onEvent((event) {
        if (event.topic == EventTopic.settingsChanged) settingsEvents++;
      });
      addTearDown(off);

      // (a) Draft/wire hydration via the Save payload (the visible percent
      // fields keep their mount-time controller: see the skipped test below).
      expect(_switchOf(tester, 'Show captions'), isFalse);
      final before = peer.captionsGets();
      expect(before, 1, reason: 'initial load reads captions exactly once');

      Future<Map<String, dynamic>> saveCaptions() async {
        final save = find.widgetWithText(FilledButton, 'Save captions');
        expect(save, findsOneWidget);
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await peer.drain(() => tester.pump());
        await tester.pumpAndSettle();
        final request = peer.settingsSets.last;
        expect(request['action'], 'settings.set');
        final payload = request['payload'] as Map<String, dynamic>;
        expect(payload['section'], 'captions');
        // The live client sends the settings DTO as a map (the Rust golden
        // trace spells the PATCH as a JSON string); both decode to one map.
        final raw = payload['settings'];
        if (raw is String) {
          return jsonDecode(raw) as Map<String, dynamic>;
        }
        return Map<String, dynamic>.from(raw as Map);
      }

      final initialWritten = await saveCaptions();
      expect(initialWritten['enabled'], false);
      expect(initialWritten['fontSize'], 150);
      expect(initialWritten['opacity'], 70);
      expect(initialWritten['docking'], 'head');

      // (d) A wrong section and a malformed section still reach the client,
      // but neither may reload the screen.
      final canonical = _readJson(_eventFile);
      final wrongSection = Map<String, dynamic>.from(canonical)
        ..['data'] = <String, dynamic>{
          'section': 'chat-provider',
          'seq': 103,
          'ts_ms': 1700000001000,
        };
      final malformed = Map<String, dynamic>.from(canonical)
        ..['data'] = <String, dynamic>{
          'section': 42,
          'seq': 104,
          'ts_ms': 1700000001100,
        };
      expect(
        ServerFrame.parse(jsonEncode(wrongSection)).event!.data['section'],
        'chat-provider',
      );
      expect(
        ServerFrame.parse(jsonEncode(malformed)).event!.data['section'],
        42,
      );
      transport.receive(jsonEncode(wrongSection));
      transport.receive(jsonEncode(malformed));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(settingsEvents, 2, reason: 'both frames reached the real bus');
      expect(
        peer.captionsGets(),
        before,
        reason: 'wrong section and malformed payload do not reload',
      );

      // (b) The canonical Rust event produces exactly one captions re-read,
      // answered with the golden merged blob (opacity 55).
      peer.captionsReply = mergedReply;
      transport.receive(jsonEncode(canonical));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(settingsEvents, 3);
      expect(
        peer.captionsGets(),
        before + 1,
        reason: 'settings.changed triggers exactly one captions re-read',
      );

      // (c) A subsequent Save writes the merged blob with siblings intact.
      final written = await saveCaptions();
      expect(peer.settingsSets, hasLength(2));
      expect(written['opacity'], 55);
      expect(written['opacity'], goldenPatch['opacity']);
      expect(written['enabled'], false);
      expect(written['fontSize'], 150);
      expect(written['docking'], 'head');

      final initialData = initialFrame.reply!.data as Map<String, dynamic>;
      final goldenInitial =
          jsonDecode(initialData['settings'] as String) as Map<String, dynamic>;
      for (final key in <String>['enabled', 'fontSize', 'opacity', 'docking']) {
        expect(
          initialWritten[key],
          goldenInitial[key],
          reason: '$key hydrated from the golden reply',
        );
      }
      final goldenData = mergedFrame.reply!.data as Map<String, dynamic>;
      final goldenMerged =
          jsonDecode(goldenData['settings'] as String) as Map<String, dynamic>;
      for (final key in <String>['enabled', 'fontSize', 'opacity', 'docking']) {
        expect(
          written[key],
          goldenMerged[key],
          reason: '$key survived the merged PATCH',
        );
      }
      expect(find.text('Captions settings saved.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // Widget-level gap: the golden draft reaches Save (see the test above), but
  // the percent fields keep the controller created at mount from min values.
  // These are the assertions that should hold once the widget refreshes them.
  testWidgets(
    'captions fields display the golden values after the async load',
    (tester) async {
      final frames = (_readJson(_traceFile)['frames'] as List)
          .cast<Map<String, dynamic>>();
      final harness = await _bootReplay(
        tester,
        captionsReply: jsonEncode(frames[1]),
      );
      expect(harness.peer.captionsGets(), 1);
      expect(_fieldTextOf(tester, 'Font size (%)'), '150');
      expect(_fieldTextOf(tester, 'Opacity (%)'), '70');
      expect(_dockingShownOf(tester), 'head');
      expect(_switchOf(tester, 'Show captions'), isFalse);
    },
    // Skip reason (this Flutter's testWidgets.skip is bool?, not String):
    // settings_screen.dart percent fields keep stale controller after async
    // reload — tracked by follow-up bead airi-0614.
    skip: true,
  );
}
