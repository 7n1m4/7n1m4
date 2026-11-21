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
  Map<String, dynamic>? _stats;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final reply = await widget.client.call('vault.status');
      if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'vault.status failed');
        return;
      }
      final data = reply.data;
      setState(() {
        _stats = (data is Map<String, dynamic>) ? data : null;
      });
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mem = (_stats?['stats'] is Map<String, dynamic>)
        ? (_stats!['stats'] as Map<String, dynamic>)['memory']
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  if (mem is Map<String, dynamic>) ...<Widget>[
                    _row('Summaries', mem['summaries']),
                    _row('Journal entries', mem['journalEntries']),
                    _row('Bytes', mem['bytes']),
                  ] else
                    const ListTile(title: Text('No memory stats available')),
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
