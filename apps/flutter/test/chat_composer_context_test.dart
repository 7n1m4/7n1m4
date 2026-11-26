// SPDX-License-Identifier: GPL-3.0-or-later

// Composer parity: chat context settings load through the typed settings.get
// wrapper, and sends with attachments are refused with a visible warning
// until the daemon's chat.send wire contract gains an attachments field.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_composer_controller.dart';

import 'support/fakes.dart';

void main() {
  test('context settings load through the typed settings.get wrapper', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.settingsToLoad = <String, dynamic>{'sendMode': 'ctrl-enter'};
    final controller = ChatComposerController(client: client);
    await controller.loadContextSettings();
    expect(controller.contextSettings['sendMode'], 'ctrl-enter');
  });

  test('sending with an attachment warns and keeps the draft intact',
      () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final sends = <Map<String, dynamic>?>[];
    client.onCall = (action, payload) {
      if (action == 'chat.send') sends.add(payload);
      return RpcReply(
        action: action,
        ok: true,
        data: action == 'chat.send'
            ? <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'}
            : <String, dynamic>{},
      );
    };
    client.emitStatus(DaemonConnectionState.connected);
    final controller = ChatComposerController(client: client);
    var committed = false;
    controller.onMessageCommitted = (_) => committed = true;
    controller.addAttachment('image', 'asset://x');
    controller.input.text = 'hi';

    expect(await controller.handleSend(), isNull);
    expect(controller.error, isNotNull);
    expect(controller.error, contains('attachment'));
    expect(controller.attachments.map((a) => a.url), ['asset://x']);
    expect(controller.input.text, 'hi');
    expect(controller.isComposing, isFalse);
    expect(sends, isEmpty);
    expect(committed, isFalse);
  });

  test('sending with no attachments still commits the draft', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: true,
          data: action == 'chat.send'
              ? <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'}
              : <String, dynamic>{},
        );
    client.emitStatus(DaemonConnectionState.connected);
    final controller = ChatComposerController(client: client);
    controller.input.text = 'hi';

    expect(await controller.handleSend(), 'm-1');
    expect(controller.attachments, isEmpty);
    expect(controller.input.text, isEmpty);
  });

  test('chat.send leaves daemon-owned provider/model selection out of the payload', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    Map<String, dynamic>? sentPayload;
    client.onCall = (action, payload) {
      if (action == 'settings.get' && payload?['section'] == 'chat-provider') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'settings': <String, dynamic>{
              'activeProvider': 'chosen',
              'activeModel': 'picked-model',
            },
          },
        );
      }
      if (action == 'chat.send') {
        sentPayload = payload;
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'},
        );
      }
      return RpcReply(action: action, ok: true, data: <String, dynamic>{});
    };
    client.emitStatus(DaemonConnectionState.connected);
    final controller = ChatComposerController(client: client);
    await controller.loadContextSettings();
    expect(controller.activeProvider, 'chosen');
    expect(controller.activeModel, 'picked-model');
    controller.input.text = 'hi';
    expect(await controller.handleSend(), 'm-1');
    expect(sentPayload, isNotNull);
    final payload = sentPayload!;
    expect(payload, isNot(contains('activeProvider')));
    expect(payload, isNot(contains('activeModel')));
    expect(payload['sessionId'], '');
    expect(payload['content'], 'hi');
  });

  test('invalid attachment adds are ignored', () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final controller = ChatComposerController(client: client);
    controller.addAttachment('video', 'asset://x');
    controller.addAttachment('image', ' ');
    controller.removeAttachmentAt(3);
    expect(controller.attachments, isEmpty);
  });
}
