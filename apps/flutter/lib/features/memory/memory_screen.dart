// SPDX-License-Identifier: GPL-3.0-or-later
// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
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
  final TextEditingController _summaryContentController = TextEditingController();
  final TextEditingController _summaryDayController = TextEditingController();
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
    _summaryContentController.dispose();
    _summaryDayController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await widget.client.vaultStatus();
      if (vault == null) {
        setState(() => _error = 'vault.status failed');
        return;
      }
      // Each read is a real daemon verb; no data is fabricated client-side.
      final summaries = await widget.client.stmmList();
      final entries = await widget.client.journalSearch();
      final retrieval = await widget.client.retrievalStatus();
      final settingsReply = await widget.client.settingsGet('general');
      final data = vault;
      final section = settingsReply;
      if (mounted) {
        setState(() {
          _remoteSyncEnabled = section['remoteSyncEnabled'] is bool ? section['remoteSyncEnabled'] as bool : false;
          _manifestStatus = 'Display model manifest is not available from the daemon.';
        });
      }
      setState(() {
        _stats = data;
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

  Future<void> _deleteSummary(Map<String, dynamic> summary) async {
    final id = summary['id']?.toString() ?? '';
    final day = summary['day']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete summary?'),
        content: Text('Delete the summary for $day? This cannot be undone.'),
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
    if (confirmed != true || !mounted) return;
    try {
      final deleted = await widget.client.stmmDelete(id);
      if (!mounted) return;
      setState(() {
        _status = deleted
            ? 'Deleted summary for ${day.isEmpty ? id : day}'
            : 'Summary for ${day.isEmpty ? id : day} was already gone';
      });
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _deleteEntry(Map<String, dynamic> entry) async {
    final id = entry['id']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete journal entry?'),
        content: Text('Delete journal entry $id? This cannot be undone.'),
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
    if (confirmed != true || !mounted) return;
    try {
      final deleted = await widget.client.journalDelete(id);
      if (!mounted) return;
      setState(() {
        _status = deleted ? 'Deleted journal entry $id' : 'Journal entry $id was already gone';
      });
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
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


  /// Persist a summary block from the explicit form values. Text and day come
  /// from the user's input; the id, token estimate and timestamp are derived
  /// locally for this minimal manual path, and no source session is claimed.
  Future<void> _saveSummary() async {
    final content = _summaryContentController.text.trim();
    final day = _summaryDayController.text.trim();
    if (content.isEmpty || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      setState(() => _error = 'Enter a summary and a day in YYYY-MM-DD format.');
      return;
    }
    final id = 'flutter-summary-$day-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final upserted = await widget.client.stmmUpsert(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': id,
          'day': day,
          'content': content,
          'tokenEstimate': (content.length / 4).round(),
          'sourceSessionIds': const <String>[],
          'createdAt': DateTime.now().microsecondsSinceEpoch,
        },
      ]);
      if (mounted) {
        setState(() => _status = 'Saved $upserted summary block');
      }
      _summaryContentController.clear();
      await _load();
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
                        trailing: IconButton(
                          key: const Key('memory-summary-delete'),
                          icon: const Icon(Icons.delete),
                          tooltip: 'Delete summary',
                          onPressed: () => _deleteSummary(s),
                        ),
                      ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('memory-summary-content'),
                    controller: _summaryContentController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'New summary',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('memory-summary-day'),
                    controller: _summaryDayController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Summary day (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('memory-summary-save'),
                    onPressed: _busy ? null : _saveSummary,
                    icon: const Icon(Icons.save),
                    label: const Text('Save summary'),
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
                        trailing: IconButton(
                          key: const Key('memory-entry-delete'),
                          icon: const Icon(Icons.delete),
                          tooltip: 'Delete journal entry',
                          onPressed: () => _deleteEntry(e),
                        ),
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
