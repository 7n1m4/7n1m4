// SPDX-License-Identifier: GPL-3.0-or-later

// Composer parity: chat context settings load through the typed settings.get
// wrapper, and attachments are restored on a failed send / cleared on a
// committed send. Attachments stay local to the composer until the daemon's
// chat.send wire contract gains an attachments field.

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

  test('attachments are restored on failed send and cleared on success',
      () async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    var sendFails = true;
    client.onCall = (action, payload) => RpcReply(
          action: action,
          ok: action != 'chat.send' || !sendFails,
          error: action == 'chat.send' && sendFails
              ? const RpcError(code: 'internal', message: 'boom')
              : null,
          data: action == 'chat.send' && !sendFails
              ? <String, dynamic>{'sessionId': 's1', 'messageId': 'm-1'}
              : <String, dynamic>{},
        );
    client.emitStatus(DaemonConnectionState.connected);
    final controller = ChatComposerController(client: client);
    controller.addAttachment('image', 'asset://x');
    controller.input.text = 'hi';
    expect(await controller.handleSend(), isNull);
    expect(controller.attachments, hasLength(1));
    expect(controller.input.text, 'hi');
    sendFails = false;
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
