// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../../theme/app_theme.dart';

/// Minimal chat surface: sends `chat.send` RPCs and renders streamed
/// `token.delta` events. View state only; the daemon owns sessions.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.client, this.initialSessionId});

  final DaemonClient client;

  /// When opening a persisted session, its id is replayed via `chat.history`.
  final String? initialSessionId;

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
  bool _assistantStreaming = false;
  bool _historyUnavailable = false;
  String? _error;
  StreamSubscription<DaemonStatus>? _statusSub;
  void Function()? _unsubscribeEvent;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _unsubscribeEvent = widget.client.onEvent(_onEvent);
    _wasConnected = widget.client.snapshot.isConnected;
    // A reconnect lands on a fresh socket with no in-flight turn from this
    // screen's point of view: drop the stuck "sending" state instead of
    // leaving the input disabled until a full app relaunch. The status stream
    // also emits on core/error updates, so only a real transition counts.
    _statusSub = widget.client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      final regainedConnection = connected && !_wasConnected;
      _wasConnected = connected;
      if (regainedConnection && mounted) {
        setState(() {
          _sending = false;
          _assistantStreaming = false;
          _activeMessageId = null;
          _deltaBuffer.clear();
        });
      }
    });
    final initial = widget.initialSessionId;
    if (initial != null && initial.isNotEmpty) {
      _sessionId = initial;
      unawaited(_loadHistory());
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _unsubscribeEvent?.call();
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
      // The daemon can stream a terminal delta with an empty message_id. Key
      // the bubble on an explicit stream-active flag, not on message_id being
      // non-empty, or every such token creates its own assistant bubble.
      final newTurn =
          !_assistantStreaming ||
          (mid.isNotEmpty &&
              _activeMessageId != null &&
              _activeMessageId != mid);
      if (newTurn) {
        _messages.add(_ChatMessage.assistant(''));
        _deltaBuffer.clear();
        _assistantStreaming = true;
      }
      if (mid.isNotEmpty) _activeMessageId = mid;
      if (delta.isNotEmpty) {
        _deltaBuffer.write(delta);
        final last = _messages.last;
        _messages[_messages.length - 1] =
            last.copyWith(text: _deltaBuffer.toString());
      }
      if (isFinal) {
        _assistantStreaming = false;
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
      final reply = await widget.client.call('chat.send', payload: <String, dynamic>{
        'session_id': _sessionId ?? '',
        'content': text,
      });
      if (!mounted) return;
      if (reply.ok && reply.data is Map<String, dynamic>) {
        // ChatSendReply is serde camelCase on the wire (sessionId/messageId);
        // snake_case here left the session unset so Stop cancelled nothing.
        final data = reply.data as Map<String, dynamic>;
        final sid = data['sessionId'] as String?;
        if (sid != null && sid.isNotEmpty) _sessionId = sid;
        final mid = data['messageId'] as String?;
        if (mid != null && mid.isNotEmpty) _activeMessageId = mid;
        // The ack is early: the turn is still streaming. Leave _sending set so
        // Stop stays live until a final delta, a cancel ack, or an error.
      } else if (!reply.ok) {
        setState(() {
          _error = reply.error?.message ?? 'chat.send failed';
          _sending = false;
        });
      }
    } on DaemonClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = false;
      });
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
        _assistantStreaming = false;
        _activeMessageId = null;
        _deltaBuffer.clear();
        if (!cancelled) _error = 'No active turn to cancel.';
      });
    } on DaemonClientException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// Replay prior turns when a session is opened. Missing history (empty
  /// session) and an unregistered/failing `chat.history` are both non-fatal:
  /// the user can still chat, the screen just starts empty.
  Future<void> _loadHistory() async {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) return;
    try {
      final turns = await widget.client.chatHistory(sid);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(turns.map(_messageFromHistory));
        _historyUnavailable = false;
      });
    } on DaemonClientException {
      if (!mounted) return;
      setState(() => _historyUnavailable = true);
    }
  }

  _ChatMessage _messageFromHistory(Map<String, dynamic> turn) {
    final text = (turn['content'] as String?) ?? '';
    return turn['role'] == 'user'
        ? _ChatMessage.user(text)
        : _ChatMessage.assistant(text);
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
        if (_historyUnavailable)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Chat history unavailable for this session.'),
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
