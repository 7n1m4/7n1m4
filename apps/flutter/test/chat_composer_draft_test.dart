// SPDX-License-Identifier: GPL-3.0-or-later

// Composer drafts are client-local: one file-backed KV store keyed by session.
// These tests drive the real store against a temp directory — no platform
// channel, no daemon write, no fabricated reply files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_composer_controller.dart';
import 'package:anima_control/features/chat/composer_draft_store.dart';

import 'support/fakes.dart';

FakeChatClient _client({bool sendOk = true}) {
  final client = FakeChatClient();
  client.emitStatus(DaemonConnectionState.connected);
  client.onCall = (action, payload) {
    if (action == 'chat.send') {
      return sendOk
          ? RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'},
            )
          : RpcReply(
              action: action,
              ok: false,
              error: const RpcError(code: 'internal', message: 'boom'),
            );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  };
  return client;
}

/// Writes are debounced; wait past the window before reading the file back.
Future<void> _settle() =>
    Future<void>.delayed(ComposerDraftStore.persistDelay + const Duration(milliseconds: 60));

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('composer-draft-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File draftFile() => File(
    '${temp.path}${Platform.pathSeparator}${ComposerDraftStore.fileName}',
  );

  test(
    'text changes persist a draft that a new session restores',
    () async {
      final client = _client();
      addTearDown(client.dispose);
      final first = ChatComposerController(
        client: client,
        sessionId: 's1',
        draftStore: ComposerDraftStore(storageDirectory: temp),
      );
      addTearDown(first.dispose);
      first.input.text = 'half written';
      await _settle();

      final file = draftFile();
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((decoded['drafts'] as Map)['s1'], 'half written');

      final second = ChatComposerController(
        client: client,
        sessionId: 's1',
        draftStore: ComposerDraftStore(storageDirectory: temp),
      );
      addTearDown(second.dispose);
      await second.restoreDraft();
      expect(second.input.text, 'half written');
    },
  );

  test('drafts are per session and survive switching back and forth', () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller = ChatComposerController(
      client: client,
      sessionId: 'a',
      draftStore: ComposerDraftStore(storageDirectory: temp),
    );
    addTearDown(controller.dispose);
    await controller.restoreDraft();

    controller.input.text = 'draft-a';
    controller.sessionId = 'b';
    expect(controller.input.text, isEmpty);
    await controller.restoreDraft();
    controller.input.text = 'draft-b';

    controller.sessionId = 'a';
    await controller.restoreDraft();
    expect(controller.input.text, 'draft-a');

    controller.sessionId = 'b';
    await controller.restoreDraft();
    expect(controller.input.text, 'draft-b');
  });

  test('a committed send clears the stored draft', () async {
    final client = _client();
    addTearDown(client.dispose);
    final controller = ChatComposerController(
      client: client,
      sessionId: 's1',
      draftStore: ComposerDraftStore(storageDirectory: temp),
    );
    addTearDown(controller.dispose);

    controller.input.text = 'will send';
    expect(await controller.handleSend(), 'm-1');
    controller.finishTurn();
    expect(controller.input.text, isEmpty);

    await _settle();
    final reloaded = ComposerDraftStore(storageDirectory: temp);
    await reloaded.ready();
    expect(reloaded.read('s1'), isNull);
  });

  test('a failed send restores the draft and keeps it on disk', () async {
    final client = _client(sendOk: false);
    addTearDown(client.dispose);
    final controller = ChatComposerController(
      client: client,
      sessionId: 's1',
      draftStore: ComposerDraftStore(storageDirectory: temp),
    );
    addTearDown(controller.dispose);
    controller.input.text = 'retry me';
    expect(await controller.handleSend(), isNull);
    expect(controller.input.text, 'retry me');
    expect(controller.error, 'boom');

    await _settle();
    final reloaded = ComposerDraftStore(storageDirectory: temp);
    await reloaded.ready();
    expect(reloaded.read('s1'), 'retry me');
  });

  test(
    'a draft typed before a session exists is kept under the empty key',
    () async {
      final client = _client();
      addTearDown(client.dispose);
      final controller = ChatComposerController(
        client: client,
        draftStore: ComposerDraftStore(storageDirectory: temp),
      );
      addTearDown(controller.dispose);
      controller.input.text = 'no session yet';

      await _settle();
      final reloaded = ComposerDraftStore(storageDirectory: temp);
      await reloaded.ready();
      expect(reloaded.read(''), 'no session yet');
    },
  );

  test(
    'a truncated draft file is ignored and replaced on the next write',
    () async {
      final file = draftFile();
      await file.writeAsString('{ not json');

      final client = _client();
      addTearDown(client.dispose);
      final controller = ChatComposerController(
        client: client,
        sessionId: 's1',
        draftStore: ComposerDraftStore(storageDirectory: temp),
      );
      addTearDown(controller.dispose);
      await controller.restoreDraft();
      expect(controller.input.text, isEmpty);
      controller.input.text = 'fresh';

      await _settle();
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((decoded['drafts'] as Map)['s1'], 'fresh');
    },
  );

  test('a clear before ready wins over a draft loaded from disk', () async {
    await draftFile().writeAsString(jsonEncode(<String, dynamic>{
      'version': 1,
      'drafts': <String, String>{'s1': 'stale', 's2': 'keep'},
    }));

    final store = ComposerDraftStore(storageDirectory: temp);
    // A just-sent draft clears before ready reads the file. Replaying that
    // clear after the load must not revive the stale text.
    store.write('s1', '');
    await store.ready();

    expect(store.read('s1'), isNull);
    expect(store.read('s2'), 'keep');
  });

  test('a failed send files the draft under the session it was sent from',
      () async {
    final client = _client(sendOk: false);
    addTearDown(client.dispose);
    final handler = client.onCall!;
    late final ChatComposerController controller;
    client.onCall = (action, payload) {
      final reply = handler(action, payload);
      if (action == 'chat.send') controller.sessionId = 's2';
      return reply;
    };
    controller = ChatComposerController(
      client: client,
      sessionId: 's1',
      draftStore: ComposerDraftStore(storageDirectory: temp),
    );
    addTearDown(controller.dispose);

    controller.input.text = 'retry me';
    expect(await controller.handleSend(), isNull);
    expect(controller.sessionId, 's2');
    // The new session's field must not inherit the failed session's text.
    expect(controller.input.text, isEmpty);
    expect(controller.error, 'boom');

    await _settle();
    final reloaded = ComposerDraftStore(storageDirectory: temp);
    await reloaded.ready();
    expect(reloaded.read('s1'), 'retry me');
    expect(reloaded.read('s2'), isNull);
  });
}
