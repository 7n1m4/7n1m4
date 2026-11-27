// SPDX-License-Identifier: GPL-3.0-or-later

// Dart leg of the shared STMM authority trace (v24b). The same eight-frame
// JSON envelope is locked by crates/anima-channel/tests/interaction_stmm_trace.rs.
// This test does two things: a strict codec-level trace assertion through
// ServerFrame/RpcReply, then a client-level replay through DaemonClient +
// ScriptedTransport (list -> upsert -> delete -> re-list) that proves the
// daemon row is authoritative, the upsert count is 1, and nothing resurrects.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

import 'support/fakes.dart';

/// Path to the shared Rust golden fixtures directory.
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

Map<String, dynamic> _loadFixture() {
  final file = File('$_fixturesDir/trace.stmm.authority.json');
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Future<(DaemonClient, ScriptedTransport)> _connectedClient() async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 2),
    rpcTimeout: const Duration(seconds: 2),
  );
  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await Future<void>.delayed(Duration.zero);
  transport.receive('{"type":"auth","ok":true}');
  await Future<void>.delayed(Duration.zero);
  final probe = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  transport.receive(
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': 'core.status',
      'ok': true,
      'data': <String, dynamic>{
        'app': 'anima-daemon',
        'version': '0.1.0',
        'coreAvailable': true,
        'storeAvailable': true,
        'storeHealth': 'ok',
        'protocol': 'airi-channel/1',
        'sessionCount': 3,
        'messageCount': 12,
      },
      'id': probe['id'],
    }),
  );
  await connecting;
  return (client, transport);
}

Map<String, dynamic> _lastRequest(ScriptedTransport transport) =>
    jsonDecode(transport.sent.last) as Map<String, dynamic>;

/// Deliver a fixture reply frame, re-iding it to the client's numeric request
/// id: the trace uses language-neutral markers m1..m4, while DaemonClient
/// correlates pending calls with integers.
void _deliverFixtureReply(
  ScriptedTransport transport,
  Map<String, dynamic> frame,
  Map<String, dynamic> request,
) {
  transport.receive(
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': frame['action'],
      'ok': frame['ok'],
      'data': frame['data'],
      'id': request['id'],
    }),
  );
}

void main() {
  test('dart STMM authority trace parses every frame through ServerFrame', () {
    final fixture = _loadFixture();
    expect(fixture['schema'], 'airi-channel-trace-v1');
    expect(fixture['path'], 'stmm.list/upsert/delete');
    final frames = fixture['frames'] as List;
    expect(frames.length, 8, reason: 'trace must hold exactly 8 frames');

    final parsed = <ServerFrame>[];
    for (var i = 0; i < frames.length; i++) {
      final frame = ServerFrame.parse(jsonEncode(frames[i]));
      expect(frame.parseError, isNull, reason: 'frame $i failed to parse');
      expect(frame.kind, ServerFrameKind.rpc, reason: 'frame $i');
      expect(frame.reply, isNotNull, reason: 'frame $i');
      parsed.add(frame);
    }

    const actions = <String>[
      'stmm.list',
      'stmm.list',
      'stmm.upsert',
      'stmm.upsert',
      'stmm.delete',
      'stmm.delete',
      'stmm.list',
      'stmm.list',
    ];
    const ids = <String>['m1', 'm1', 'm2', 'm2', 'm3', 'm3', 'm4', 'm4'];
    for (var i = 0; i < frames.length; i++) {
      expect(parsed[i].reply!.action, actions[i], reason: 'frame $i action');
      expect(parsed[i].reply!.id, ids[i], reason: 'frame $i id passthrough');
      expect((frames[i] as Map<String, dynamic>)['id'], ids[i]);
    }

    // Request frames must be byte-for-byte what RpcRequest emits.
    for (final i in [0, 2, 4, 6]) {
      final raw = frames[i] as Map<String, dynamic>;
      expect(
        RpcRequest(
          action: raw['action'] as String,
          payload: raw['payload'] as Map<String, dynamic>,
          id: raw['id'],
        ).toJson(),
        raw,
        reason: 'frame $i request must match the Dart request codec',
      );
    }

    // Frame 1: the daemon-authoritative row. The list reply uses the daemon's
    // snake_case StoredSummary fields; the upsert request below uses camelCase.
    final daemonRow =
        ((parsed[1].reply!.data as Map<String, dynamic>)['summaries'] as List)
            .cast<Map<String, dynamic>>();
    expect(daemonRow, hasLength(1));
    expect(daemonRow.single, <String, dynamic>{
      'id': 'summary-1',
      'day': '2026-11-25',
      'content': 'A summary',
      'source_session_ids': <String>['s1'],
      'token_estimate': 3,
      'created_at': 1764000000000000,
    });

    expect(
      ((parsed[3].reply!.data as Map<String, dynamic>)['upserted']),
      1,
      reason: 'upsert reply reports the written count',
    );
    expect(
      ((parsed[5].reply!.data as Map<String, dynamic>)['deleted']),
      isTrue,
      reason: 'delete reply reports a removed row',
    );
    expect(
      ((parsed[7].reply!.data as Map<String, dynamic>)['summaries']),
      isEmpty,
      reason: 'the final list is empty: no resurrect',
    );
  });

  test(
    'dart STMM client replay keeps the daemon authoritative with no resurrect',
    () async {
      final fixture = _loadFixture();
      final frames = (fixture['frames'] as List).cast<Map<String, dynamic>>();
      final (client, transport) = await _connectedClient();
      addTearDown(client.dispose);

      final daemonRow =
          ((frames[1]['data'] as Map<String, dynamic>)['summaries'] as List)
              .cast<Map<String, dynamic>>();

      final listed = client.stmmList();
      var request = _lastRequest(transport);
      expect(request['action'], 'stmm.list');
      expect(request['payload'], <String, dynamic>{'limit': 50});
      _deliverFixtureReply(transport, frames[1], request);
      expect(
        await listed,
        daemonRow,
        reason: 'the daemon row, not a client fabrication, is authoritative',
      );

      final blocks =
          ((frames[2]['payload'] as Map<String, dynamic>)['blocks'] as List)
              .cast<Map<String, dynamic>>();
      final upserted = client.stmmUpsert(blocks);
      request = _lastRequest(transport);
      expect(request['action'], 'stmm.upsert');
      expect(request['payload'], frames[2]['payload']);
      _deliverFixtureReply(transport, frames[3], request);
      expect(await upserted, 1, reason: 'upsert returns the daemon count');

      final deleted = client.stmmDelete('summary-1');
      request = _lastRequest(transport);
      expect(request['action'], 'stmm.delete');
      expect(request['payload'], frames[4]['payload']);
      _deliverFixtureReply(transport, frames[5], request);
      expect(await deleted, isTrue);

      final afterDelete = client.stmmList();
      request = _lastRequest(transport);
      expect(request['action'], 'stmm.list');
      _deliverFixtureReply(transport, frames[7], request);
      expect(
        await afterDelete,
        isEmpty,
        reason: 'no resurrect after delete: the daemon list is empty',
      );
    },
  );
}
