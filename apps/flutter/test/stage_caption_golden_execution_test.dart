// SPDX-License-Identifier: GPL-3.0-or-later

// Round v35 real-execution leg of the chat `token.delta` golden. The Rust
// handler test and chat_golden_trace_test.dart (codec + ChatScreen) already bind
// `trace.chat.send.token_delta.json`, but the Flutter STAGE caption consumer
// never did: stage_caption_overlay_test.dart / stage_parity_test.dart only feed
// hand-built Dart maps, and emotion_tag_golden_widget_replay_test.dart uses a
// DIFFERENT golden. This test closes that gap with the UNCHANGED Rust golden
// bytes: production ServerFrame codec -> real DaemonClient over
// ScriptedTransport -> real StageRenderStateBinding -> StageCaptionController.
// No production edits, no new golden, no widget-state shortcuts.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';

import 'support/fakes.dart';

/// Same fixture resolution as golden_fixtures_test.dart and the emotion golden
/// widget replay test.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

final File _goldenFile = File('$_fixturesDir/trace.chat.send.token_delta.json');

Map<String, dynamic> _readGolden() {
  if (!_goldenFile.existsSync()) fail('fixture not found: ${_goldenFile.path}');
  return jsonDecode(_goldenFile.readAsStringSync()) as Map<String, dynamic>;
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

String _replyFrame(String action, Object id, Object? data) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': true,
      'id': id,
      if (data != null) 'data': data,
    });

Object? _dataFor(String action) => switch (action) {
  'core.status' => _healthyCore,
  'event.subscribe' => <String, dynamic>{'subscribed': true},
  'event.unsubscribe' => <String, dynamic>{'subscribed': false},
  'runtime.status' => <String, dynamic>{
    'app': 'anima-daemon',
    'version': '0.1.0',
  },
  'providers.list' => <String, dynamic>{'providers': <dynamic>[]},
  'cards.list' => <String, dynamic>{'cards': <dynamic>[], 'truncated': false},
  _ => <String, dynamic>{},
};

/// Answers every RPC the real client and the stage binding put on the wire.
class _ReplayPeer {
  _ReplayPeer(this.transport);

  final ScriptedTransport transport;
  int _handled = 0;
  final List<Map<String, dynamic>> subscriptions = <Map<String, dynamic>>[];

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 12; pass++) {
      while (_handled < transport.sent.length) {
        final request =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (request['type'] != 'rpc') continue;
        final action = request['action'] as String?;
        final id = request['id'];
        if (action == null || id == null) continue;
        if (action == 'event.subscribe' || action == 'event.unsubscribe') {
          subscriptions.add(request);
        }
        transport.receive(_replyFrame(action, id, _dataFor(action)));
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

class _Harness {
  _Harness(this.client, this.transport, this.peer);

  final DaemonClient client;
  final ScriptedTransport transport;
  final _ReplayPeer peer;
}

/// Boot a real client (auth -> core.status -> four event.subscribe RPCs).
Future<_Harness> _bootClient(WidgetTester tester) async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 5),
    rpcTimeout: const Duration(seconds: 5),
    heartbeatInterval: const Duration(hours: 1),
  );
  addTearDown(client.dispose);
  final peer = _ReplayPeer(transport);
  // In testWidgets the body runs in FakeAsync: flush with tester.pump().
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
    reason: 'the client subscribes to its four built-in topics',
  );
  return _Harness(client, transport, peer);
}

void main() {
  testWidgets(
    'Rust chat.send token.delta golden drives the real stage caption consumer',
    (tester) async {
      // Read and parse the UNCHANGED Rust golden bytes.
      final golden = _readGolden();
      expect(golden['schema'], 'airi-channel-trace-v1');
      expect(golden['path'], 'chat.send');
      final rawFrames = (golden['frames'] as List).cast<Map<String, dynamic>>();
      expect(rawFrames.length, 5, reason: 'trace must hold exactly 5 frames');

      // Every frame goes through the production ServerFrame codec.
      final parsed = <ServerFrame>[];
      for (var i = 0; i < rawFrames.length; i++) {
        final frame = ServerFrame.parse(jsonEncode(rawFrames[i]));
        expect(frame.parseError, isNull, reason: 'frame $i failed to parse');
        parsed.add(frame);
      }
      expect(parsed.map((frame) => frame.kind).toList(), <ServerFrameKind>[
        ServerFrameKind.rpc,
        ServerFrameKind.rpc,
        ServerFrameKind.event,
        ServerFrameKind.event,
        ServerFrameKind.event,
      ], reason: 'request -> ack -> two text deltas + empty terminal');

      // Frame 0 is the client request: the production request codec must emit
      // the exact fixture bytes.
      final request = rawFrames[0];
      expect(
        RpcRequest(
          action: request['action'] as String,
          payload: request['payload'] as Map<String, dynamic>,
          id: request['id'],
        ).toJson(),
        request,
      );

      // Frame 1 is the daemon ack, decoded by the production RpcReply codec.
      final ack = RpcReply.fromJson(rawFrames[1]);
      expect(ack.action, 'chat.send');
      expect(ack.ok, isTrue);
      expect(ack.id, 't1', reason: 'rpc id must pass through verbatim');
      expect(ack.data, <String, dynamic>{
        'sessionId': 'sess-abc',
        'messageId': 'msg-1',
        'accepted': true,
      });
      expect(parsed[1].reply!.data, ack.data);

      // Frames 2/3/4 are token.delta events; decode them both via ServerFrame
      // (which calls GatewayEventFrame.fromJson) and directly, then compare.
      final events = <GatewayEventFrame>[];
      for (var i = 2; i < 5; i++) {
        final viaCodec = parsed[i].event;
        final direct = GatewayEventFrame.fromJson(rawFrames[i]);
        expect(viaCodec, isNotNull, reason: 'frame $i');
        expect(viaCodec!.topic, EventTopic.tokenDelta, reason: 'frame $i');
        expect(viaCodec.rawTopic, 'token.delta', reason: 'frame $i');
        expect(direct.topic, EventTopic.tokenDelta);
        expect(direct.data, viaCodec.data);
        events.add(direct);
      }
      expect(events.map((event) => event.data['delta']).toList(), <String>[
        'Hello',
        ' world',
        '',
      ]);
      expect(events.map((event) => event.data['seq']).toList(), <int>[5, 6, 7]);
      expect(events.map((event) => event.data['final']).toList(), <bool>[
        false,
        false,
        true,
      ]);
      expect(events[2].data['reason'], 'complete');
      for (final event in events) {
        expect(event.data['session_id'], 'sess-abc');
        expect(event.data['message_id'], 'msg-1');
      }

      final harness = await _bootClient(tester);
      final client = harness.client;
      final transport = harness.transport;
      final peer = harness.peer;

      final state = StageRenderState(actorId: 'character-7');
      final binding = StageRenderStateBinding(
        client: client,
        state: state,
        boundSessionId: 'sess-abc',
      );
      addTearDown(state.dispose);
      await peer.drain(() => tester.pump());
      expect(
        binding.isBound,
        isTrue,
        reason: 'the stage binding subscribes to the client event bus',
      );
      expect(
        peer.subscriptions
            .where((request) => request['action'] == 'event.subscribe')
            .any((request) {
              final topics = (request['payload'] as Map?)?['topics'];
              return topics is List &&
                  topics.length == 2 &&
                  topics[0] == 'emotion.tag' &&
                  topics[1] == 'token.delta';
            }),
        isTrue,
        reason: 'the binding explicitly opts into the golden topic',
      );

      // Anti-vacuous baseline: no caption before any golden frame is fed.
      expect(state.caption.segments, isEmpty);

      // Observe the real bus so "ignored by the stage" is distinguishable from
      // "never delivered by the transport".
      var deltaEvents = 0;
      final off = client.onEvent((event) {
        if (event.topic == EventTopic.tokenDelta) deltaEvents++;
      });
      addTearDown(off);

      /// Deliver one golden frame's exact bytes through the real transport; the
      /// real client re-parses them before the binding sees them.
      Future<void> deliver(int index) async {
        final decoded = ServerFrame.parse(jsonEncode(rawFrames[index]));
        expect(decoded.event, isNotNull, reason: 'frame $index');
        transport.receive(jsonEncode(decoded.raw));
        await peer.drain(() => tester.pump());
        await tester.pumpAndSettle();
      }

      // (a) Frame 2: one active-looking accumulation 'Hello', not final.
      await deliver(2);
      expect(deltaEvents, 1);
      expect(state.caption.segments.length, 1);
      expect(state.caption.segments.single.text, 'Hello');
      expect(state.caption.segments.single.isActive, isFalse);

      // (b) Frame 3: appended in the SAME segment, still non-final.
      await deliver(3);
      expect(deltaEvents, 2);
      expect(state.caption.segments.length, 1);
      expect(state.caption.segments.single.text, 'Hello world');
      expect(state.caption.segments.single.isActive, isFalse);

      // (c) Frame 4: empty delta + final:true + reason:complete finalizes the
      // text. Exactly one sentence, active, with no fabricated/duplicate text.
      await deliver(4);
      expect(deltaEvents, 3);
      expect(
        state.caption.segments.map((segment) => segment.text).toList(),
        <String>['Hello world'],
      );
      expect(state.caption.segments.length, 1);
      expect(state.caption.segments.single.text, 'Hello world');
      expect(
        state.caption.segments.where((segment) => segment.isActive).length,
        1,
      );
      expect(state.caption.segments.single.isActive, isTrue);

      // (d) A foreign-session frame carrying a different message_id and a
      // higher seq reaches the real bus but is dropped by the binding's session
      // filter, so the finalized caption is untouched. (token.delta has no
      // actor_id; session binding is the stage's equivalent trust boundary.)
      final spoofData = <String, dynamic>{
        ...(rawFrames[2]['data'] as Map<String, dynamic>),
        'session_id': 'foreign-sess',
        'message_id': 'msg-foreign',
        'delta': 'SPOOF',
        'index': 3,
        'seq': 8,
        'ts_ms': 1700000001100,
      };
      final spoof = <String, dynamic>{
        'type': 'event',
        'topic': 'token.delta',
        'data': spoofData,
      };
      final decodedSpoof = ServerFrame.parse(jsonEncode(spoof));
      expect(decodedSpoof.event!.topic, EventTopic.tokenDelta);
      transport.receive(jsonEncode(decodedSpoof.raw));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(deltaEvents, 4, reason: 'the spoof reached the real bus');
      expect(
        state.caption.segments.map((segment) => segment.text).toList(),
        <String>['Hello world'],
      );
      expect(state.caption.segments.single.isActive, isTrue);
      expect(tester.takeException(), isNull);

      // binding.dispose omitted: the event.unsubscribe future does not settle
      // under FakeAsync; all proof assertions complete before teardown.
    },
  );
}
