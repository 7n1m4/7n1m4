// SPDX-License-Identifier: GPL-3.0-or-later

// Round v30 real-execution Dart leg for the additive chat.send attachments
// golden. Boots a REAL DaemonClient over a ScriptedTransport and replays the
// UNCHANGED golden payload through the production RpcRequest codec, then feeds
// the real RPC reply frames through ServerFrame.parse -> RpcReply.fromJson.
// ChatScreen and the composer are frozen; this uses only the raw client seam.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

import 'support/fakes.dart';

/// Same fixture resolution as the other golden replay tests.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

Map<String, dynamic> _read(String name) {
  final file = File('$_fixturesDir/$name');
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  test('real DaemonClient replays the attachments golden and rejects a forbidden MIME', () async {
    // The golden is read verbatim; no request field is re-shaped here.
    final golden = _read('chat.send.attachments.request.json');

    final transport = ScriptedTransport();
    final client = DaemonClient(
      transportFactory: () => transport,
      authTimeout: const Duration(seconds: 5),
      rpcTimeout: const Duration(seconds: 5),
    );
    addTearDown(client.dispose);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'tok'),
    );
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
          'sessionCount': 0,
          'messageCount': 0,
        },
        'id': probe['id'],
      }),
    );
    await connecting;

    // --- ACCEPT: raw call; the production codec must emit the golden bytes.
    final pending = client.call('chat.send', payload: golden);
    await Future<void>.delayed(Duration.zero);
    final request = jsonDecode(transport.sent.last) as Map<String, dynamic>;
    expect(request.keys.toSet(), {'type', 'action', 'id', 'payload'});
    expect(request['type'], 'rpc');
    expect(request['action'], 'chat.send');
    expect(request['id'], isA<int>());
    expect((request['id'] as int) > 0, isTrue, reason: 'client minted the id');
    expect(request['payload'], golden, reason: 'exact golden payload bytes');

    final sentPayload = request['payload'] as Map<String, dynamic>;
    expect(sentPayload.keys.toList(), ['sessionId', 'content', 'attachments']);
    expect(
      sentPayload.containsKey('genUi'),
      isFalse,
      reason: 'no genUi on the wire',
    );
    final descriptors = (sentPayload['attachments'] as List)
        .cast<Map<String, dynamic>>();
    expect(descriptors.length, 1);
    expect(descriptors.single.keys.toList(), [
      'mimeType',
      'data',
      'fileName',
      'url',
    ], reason: 'camelCase descriptor key set and order survive the codec');
    expect(descriptors.single['mimeType'], 'image/png');
    expect(descriptors.single['fileName'], 'a.png');
    expect(
      base64.decode(descriptors.single['data'] as String),
      utf8.encode('hello'),
      reason: 'exact base64 bytes survive production encoding',
    );

    final ackFrame = <String, dynamic>{
      'type': 'rpc',
      'action': 'chat.send',
      'ok': true,
      'id': request['id'],
      'data': <String, dynamic>{
        'sessionId': 'sess-abc',
        'messageId': 'msg-golden-1',
        'accepted': true,
      },
    };
    final parsedAck = ServerFrame.parse(jsonEncode(ackFrame));
    expect(parsedAck.parseError, isNull);
    expect(parsedAck.kind, ServerFrameKind.rpc);
    expect(parsedAck.reply, isNotNull);
    final decodedAck = RpcReply.fromJson(parsedAck.raw);
    expect(decodedAck.ok, isTrue);
    expect(decodedAck.action, 'chat.send');
    expect(decodedAck.data, {
      'sessionId': 'sess-abc',
      'messageId': 'msg-golden-1',
      'accepted': true,
    });
    transport.receive(jsonEncode(ackFrame));
    final reply = await pending;
    expect(reply.ok, isTrue);
    expect(reply.data, decodedAck.data);

    // --- REJECT: a real daemon error string must decode as an RPC failure.
    final forbidden = Map<String, dynamic>.from(golden);
    forbidden['attachments'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'mimeType': 'image/svg+xml',
        'data': 'aGVsbG8=',
        'fileName': 'a.svg',
      },
    ];
    final pendingReject = client.call('chat.send', payload: forbidden);
    await Future<void>.delayed(Duration.zero);
    final rejectRequest =
        jsonDecode(transport.sent.last) as Map<String, dynamic>;
    final rejectFrame = <String, dynamic>{
      'type': 'rpc',
      'action': 'chat.send',
      'ok': false,
      'id': rejectRequest['id'],
      'error': <String, dynamic>{
        'code': 'rpc_handler_error',
        'message': 'unsupported attachment MIME type',
      },
    };
    final parsedReject = ServerFrame.parse(jsonEncode(rejectFrame));
    expect(parsedReject.parseError, isNull);
    final decodedReject = RpcReply.fromJson(parsedReject.raw);
    expect(decodedReject.isFailure, isTrue);
    expect(decodedReject.error, isNotNull);
    expect(decodedReject.error!.code, 'rpc_handler_error');
    expect(decodedReject.error!.message, 'unsupported attachment MIME type');

    transport.receive(jsonEncode(rejectFrame));
    final failed = await pendingReject;
    expect(failed.isFailure, isTrue);
    expect(failed.error!.code, 'rpc_handler_error');
    expect(failed.error!.message, 'unsupported attachment MIME type');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
