// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../chat/chat_screen.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final TextEditingController _importController = TextEditingController();
  final TextEditingController _filterController = TextEditingController();
  Map<String, dynamic>? _core;
  Map<String, dynamic>? _vault;
  List<Map<String, dynamic>> _sessions = const <Map<String, dynamic>>[];
  int? _sessionCursor;
  bool _sessionsTruncated = false;
  bool _loadingMore = false;
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _importController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final coreReply = await widget.client.call('core.status');
      if (!coreReply.ok) {
        setState(() => _error = coreReply.error?.message ?? 'core.status failed');
        return;
      }
      final vaultReply = await widget.client.call('vault.status');
      final page = await widget.client.sessionsListPage();
      setState(() {
        _core = (coreReply.data is Map<String, dynamic>) ? coreReply.data as Map<String, dynamic> : null;
        _vault = (vaultReply.ok && vaultReply.data is Map<String, dynamic>)
            ? vaultReply.data as Map<String, dynamic>
            : null;
        _sessions = page.items.toList();
        _sessionsTruncated = page.truncated;
        _sessionCursor = page.nextCursor;
      });
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadMore() async {
    final cursor = _sessionCursor;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.sessionsListPage(cursor: cursor);
      if (!mounted) return;
      setState(() {
        _sessionsTruncated = page.truncated;
        _sessionCursor = page.nextCursor;
        final existing = _sessions.toList();
        _sessions
          ..clear()
          ..addAll(page.items)
          ..addAll(existing);
      });
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _export(String id) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final jsonl = await widget.client.sessionsExport(id);
      if (mounted) {
        setState(() => _status = 'Exported session $id (${jsonl.length} chars)');
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text('Delete "$id" and all of its messages? This cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final deleted = await widget.client.sessionsDelete(id);
      if (!mounted) return;
      // A missing session reports `false`; that is still success, so the row
      // goes away either way instead of leaving a stale entry on screen.
      setState(() => _status = deleted ? 'Deleted session $id' : 'Session $id was already gone');
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final jsonl = _importController.text;
    if (jsonl.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final reply = await widget.client.call('sessions.import', payload: <String, dynamic>{
        'jsonl': jsonl,
      });
      if (!reply.ok) {
        if (mounted) {
          setState(() => _error = reply.error?.message ?? 'sessions.import failed');
        }
        return;
      }
      final data = reply.data is Map<String, dynamic> ? reply.data as Map<String, dynamic> : null;
      final status = data?['status']?.toString() ?? 'unknown';
      final revision = data?['revision']?.toString() ?? '?';
      if (status == 'applied') {
        if (mounted) setState(() => _status = 'Imported snapshot (revision $revision)');
        if (mounted) await _load();
      } else if (mounted) {
        setState(() => _status = 'Snapshot not applied ($status, revision $revision)');
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _query => _filterController.text.trim().toLowerCase();
  List<Map<String, dynamic>> get _visibleSessions => _query.isEmpty
      ? _sessions
      : _sessions
          .where((s) =>
              ((s['title'] as String?) ?? '').toLowerCase().contains(_query) ||
              ((s['id'] as String?) ?? '').toLowerCase().contains(_query))
          .toList(growable: false);

  Future<void> _newChat() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => ChatScreen(client: widget.client)));
  }

  @override
  Widget build(BuildContext context) {
    final chats = (_vault?['stats'] is Map<String, dynamic>)
        ? (_vault!['stats'] as Map<String, dynamic>)['chats']
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: <Widget>[
          IconButton(
            key: const Key('sessions-new-chat'),
            icon: const Icon(Icons.add_comment),
            tooltip: 'Start new chat',
            onPressed: _newChat,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  if (_status != null) Text(_status!),
                  TextField(
                    key: const Key('sessions-filter'),
                    controller: _filterController,
                    decoration: const InputDecoration(labelText: 'Filter sessions'),
                    onChanged: (_) => setState(() {}),
                  ),
                  ListTile(title: const Text('Session count (core)'), trailing: Text(_core?['sessionCount']?.toString() ?? '—')),
                  ListTile(title: const Text('Message count (core)'), trailing: Text(_core?['messageCount']?.toString() ?? '—')),
                  if (chats is Map<String, dynamic>) ...<Widget>[
                    ListTile(title: const Text('Chat sessions (vault)'), trailing: Text(chats['sessions']?.toString() ?? '—')),
                    ListTile(title: const Text('Chat messages (vault)'), trailing: Text(chats['messages']?.toString() ?? '—')),
                  ],
                  TextField(
                    controller: _importController,
                    decoration: const InputDecoration(labelText: 'JSONL snapshot'),
                    maxLines: 3,
                  ),
                  FilledButton(
                    onPressed: _import,
                    child: const Text('Import'),
                  ),
                  const ListTile(title: Text('Sessions'), dense: true),
                  if (_sessionsTruncated)
                    TextButton(
                      key: const Key('sessions-load-more'),
                      onPressed: _loadingMore ? null : _loadMore,
                      child: Text(
                        _loadingMore ? 'Loading more…' : 'Load more sessions',
                      ),
                    ),
                  if (_visibleSessions.isEmpty)
                    ListTile(title: Text(_sessions.isEmpty ? 'No sessions' : 'No sessions match the filter'), dense: true)
                  else
                    for (final s in _visibleSessions)
                      ListTile(
                        title: Text((s['title'] as String?) ?? (s['id'] as String?) ?? ''),
                        subtitle: Text((s['id'] as String?) ?? ''),
                        // Opening a session replays its persisted turns via
                        // chat.history on the chat screen.
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatScreen(
                              client: widget.client,
                              initialSessionId: (s['id'] as String?) ?? '',
                            ),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              icon: const Icon(Icons.download),
                              tooltip: 'Export session as JSONL',
                              onPressed: () => _export((s['id'] as String?) ?? ''),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              tooltip: 'Delete session',
                              onPressed: () => _delete((s['id'] as String?) ?? ''),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
