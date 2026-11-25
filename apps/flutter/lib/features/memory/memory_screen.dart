// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final TextEditingController _appendController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _kindFilter = 'all';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _summaries = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  bool _retrievalAvailable = false;
  bool? _remoteSyncEnabled;
  String? _manifestStatus;
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
    _appendController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vaultReply = await widget.client.call('vault.status');
      if (!vaultReply.ok) {
        setState(() => _error = vaultReply.error?.message ?? 'vault.status failed');
        return;
      }
      // Each read is a real daemon verb; no data is fabricated client-side.
      final summaries = await widget.client.stmmList();
      final entries = await widget.client.journalSearch();
      final retrieval = await widget.client.retrievalStatus();
      final settingsReply = await widget.client.settingsGet('general');
      final data = vaultReply.data;
      final section = settingsReply;
      if (mounted) {
        setState(() {
          _remoteSyncEnabled = section['remoteSyncEnabled'] is bool ? section['remoteSyncEnabled'] as bool : false;
          _manifestStatus = 'Display model manifest is not available from the daemon.';
        });
      }
      setState(() {
        _stats = (data is Map<String, dynamic>) ? data : null;
        _summaries = summaries;
        _entries = entries;
        _retrievalAvailable = retrieval;
      });
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _rebuild() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await widget.client.stmmRebuild();
      await _load();
      if (mounted) setState(() => _status = 'Short-term memory rebuilt');
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _append() async {
    final content = _appendController.text.trim();
    if (content.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final id = await widget.client.journalAppend(content);
      if (mounted) setState(() => _status = 'Journal entry $id added');
      _appendController.clear();
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> get _visibleEntries {
    final q = _searchController.text.trim().toLowerCase();
    return _entries.where((e) {
      final kind = (e['kind'] as String?) ?? 'note';
      if (_kindFilter != 'all' && kind != _kindFilter) return false;
      if (q.isNotEmpty) {
        final content = ((e['content'] as String?) ?? '').toLowerCase();
        if (!content.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final entries = await widget.client.journalSearch(query: _searchController.text.trim());
      if (mounted) {
        setState(() {
          _entries = entries;
          _status = 'Search complete';
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mem = (_stats?['stats'] is Map<String, dynamic>)
        ? (_stats!['stats'] as Map<String, dynamic>)['memory']
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _rebuild,
            icon: const Icon(Icons.build),
            tooltip: 'Rebuild short-term memory',
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
                  _row('Retrieval available', _retrievalAvailable),
                  ListTile(key: const Key('memory-auth-status'), title: const Text('Remote sync (accounts)'), subtitle: Text(_remoteSyncEnabled == true ? 'Enabled by user' : 'Disabled (local-only)')),
                  ListTile(key: const Key('memory-manifest-status'), title: const Text('Display-model manifest'), subtitle: Text(_manifestStatus ?? 'Not available from the daemon')),
                  if (mem is Map<String, dynamic>) ...<Widget>[
                    _row('Summaries', mem['summaries']),
                    _row('Journal entries', mem['journalEntries']),
                    _row('Bytes', mem['bytes']),
                  ],
                  const ListTile(title: Text('Short-term summaries'), dense: true),
                  if (_summaries.isEmpty)
                    const ListTile(title: Text('No summaries'), dense: true)
                  else
                    for (final s in _summaries)
                      ListTile(
                        title: Text((s['content'] as String?) ?? ''),
                        subtitle: Text('day ${s['day'] ?? ''}'),
                        dense: true,
                      ),
                  TextField(
                    key: const Key('memory-search'),
                    controller: _searchController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Search journal',
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _search,
                    icon: const Icon(Icons.search),
                    label: const Text('Search'),
                  ),
                  DropdownButton<String>(
                    value: _kindFilter,
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'all', child: Text('all')),
                      DropdownMenuItem(value: 'note', child: Text('note')),
                      DropdownMenuItem(value: 'milestone', child: Text('milestone')),
                      DropdownMenuItem(value: 'dream', child: Text('dream')),
                    ],
                    onChanged: (v) => setState(() => _kindFilter = v ?? 'all'),
                  ),
                  const ListTile(title: Text('Journal entries'), dense: true),
                  if (_entries.isEmpty)
                    const ListTile(title: Text('No journal entries'), dense: true)
                  else if (_visibleEntries.isEmpty)
                    const ListTile(title: Text('No journal entries match.'), dense: true)
                  else
                    for (final e in _visibleEntries)
                      ListTile(
                        title: Text((e['content'] as String?) ?? ''),
                        subtitle: Text((e['kind'] as String?) ?? 'note'),
                        dense: true,
                      ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _appendController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'New journal entry',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _append,
                    icon: const Icon(Icons.add),
                    label: const Text('Append journal entry'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _row(String label, Object? value) => ListTile(
        title: Text(label),
        trailing: Text(value?.toString() ?? '—'),
      );
}
