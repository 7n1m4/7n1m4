// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../../theme/app_theme.dart';

/// Minimal chat surface: sends `chat.send` RPCs and renders streamed
/// `token.delta` events. View state only; the daemon owns sessions.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.client});

  final DaemonClient client;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final List<_ChatMessage> _messages = <_ChatMessage>[];
  String? _sessionId;
  String? _activeMessageId;
  final StringBuffer _deltaBuffer = StringBuffer();
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.client.onEvent = _onEvent;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _onEvent(GatewayEventFrame event) {
    if (event.topic != EventTopic.tokenDelta) return;
    final data = event.data;
    final sid = data['session_id'] as String? ?? '';
    if (_sessionId != null && sid.isNotEmpty && sid != _sessionId) return;
    // The chat.send ack can arrive after the first delta; remember the session
    // from the stream so a Stop press cancels the right turn.
    if (_sessionId == null && sid.isNotEmpty) _sessionId = sid;
    final mid = data['message_id'] as String? ?? '';
    final delta = data['delta'] as String? ?? '';
    final isFinal = data['final'] == true;
    if (!mounted) return;
    setState(() {
      if (_activeMessageId == null ||
          (_activeMessageId != mid && mid.isNotEmpty)) {
        _activeMessageId = mid.isNotEmpty ? mid : _activeMessageId;
        _messages.add(_ChatMessage.assistant(''));
        _deltaBuffer.clear();
      }
      if (delta.isNotEmpty) {
        _deltaBuffer.write(delta);
        final last = _messages.last;
        _messages[_messages.length - 1] =
            last.copyWith(text: _deltaBuffer.toString());
      }
      if (isFinal) {
        _activeMessageId = null;
        _deltaBuffer.clear();
        _sending = false;
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    if (!widget.client.snapshot.isConnected) {
      setState(() => _error = 'Not connected to the daemon.');
      return;
    }
    setState(() {
      _error = null;
      _sending = true;
      _messages.add(_ChatMessage.user(text));
      _input.clear();
    });
    try {
      await widget.client.call('event.subscribe', payload: <String, dynamic>{
        'topics': <String>['token.delta'],
      });
      final reply = await widget.client.call('chat.send', payload: <String, dynamic>{
        'session_id': _sessionId ?? '',
        'content': text,
      });
      if (reply.ok && reply.data is Map<String, dynamic>) {
        final data = reply.data as Map<String, dynamic>;
        final sid = data['session_id'] as String?;
        if (sid != null && sid.isNotEmpty) _sessionId = sid;
        final mid = data['message_id'] as String?;
        if (mid != null && mid.isNotEmpty) _activeMessageId = mid;
      } else if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'chat.send failed');
      }
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Stop the in-flight turn via the daemon's `chat.cancel` verb.
  Future<void> _cancel() async {
    setState(() => _error = null);
    try {
      final cancelled = await widget.client.cancelChat(_sessionId ?? '');
      if (!mounted) return;
      setState(() {
        _sending = false;
        _activeMessageId = null;
        _deltaBuffer.clear();
        if (!cancelled) _error = 'No active turn to cancel.';
      });
    } on DaemonClientException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final m = _messages[index];
              return Align(
                alignment:
                    m.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Card(
                  color: m.isUser
                      ? AppTheme.subtle.withOpacity(0.2)
                      : AppTheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(m.text.isEmpty ? '…' : m.text),
                  ),
                ),
              );
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !_sending,
                    decoration: const InputDecoration(hintText: 'Message'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _sending ? _cancel : _send,
                  icon: _sending
                      ? const Icon(Icons.stop)
                      : const Icon(Icons.send),
                  tooltip: _sending ? 'Stop' : 'Send',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatMessage {
  const _ChatMessage({required this.isUser, required this.text});
  factory _ChatMessage.user(String t) =>
      _ChatMessage(isUser: true, text: t);
  factory _ChatMessage.assistant(String t) =>
      _ChatMessage(isUser: false, text: t);

  final bool isUser;
  final String text;

  _ChatMessage copyWith({String? text}) =>
      _ChatMessage(isUser: isUser, text: text ?? this.text);
}
