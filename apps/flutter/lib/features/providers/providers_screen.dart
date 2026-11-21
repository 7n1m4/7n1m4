// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  List<Map<String, dynamic>> _providers = const [];
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
      final reply = await widget.client.call('providers.list');
      if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'providers.list failed');
        return;
      }
      final data = reply.data;
      final list = (data is Map<String, dynamic>) ? data['providers'] : null;
      setState(() {
        _providers = (list is List)
            ? list.whereType<Map<String, dynamic>>().toList()
            : const [];
      });
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Providers')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  if (_providers.isEmpty && _error == null)
                    const ListTile(title: Text('No providers configured')),
                  for (final p in _providers)
                    Card(
                      child: ListTile(
                        title: Text(p['id']?.toString() ?? ''),
                        subtitle: Text(
                          '${p['kind']} · ${p['model']} · ${p['enabled'] == true ? 'enabled' : 'disabled'}',
                        ),
                        trailing: p['baseUrl'] != null && (p['baseUrl'] as String).isNotEmpty
                            ? Text(p['baseUrl'].toString(), style: Theme.of(context).textTheme.bodySmall)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
