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
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _summaries = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  bool _retrievalAvailable = false;
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
      final data = vaultReply.data;
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
                  const ListTile(title: Text('Journal entries'), dense: true),
                  if (_entries.isEmpty)
                    const ListTile(title: Text('No journal entries'), dense: true)
                  else
                    for (final e in _entries)
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
