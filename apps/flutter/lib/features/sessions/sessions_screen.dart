// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  Map<String, dynamic>? _core;
  Map<String, dynamic>? _vault;
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
      final coreReply = await widget.client.call('core.status');
      if (!coreReply.ok) {
        setState(() => _error = coreReply.error?.message ?? 'core.status failed');
        return;
      }
      final vaultReply = await widget.client.call('vault.status');
      setState(() {
        _core = (coreReply.data is Map<String, dynamic>) ? coreReply.data as Map<String, dynamic> : null;
        _vault = (vaultReply.ok && vaultReply.data is Map<String, dynamic>)
            ? vaultReply.data as Map<String, dynamic>
            : null;
      });
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = (_vault?['stats'] is Map<String, dynamic>)
        ? (_vault!['stats'] as Map<String, dynamic>)['chats']
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Sessions')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ListTile(title: const Text('Session count (core)'), trailing: Text(_core?['sessionCount']?.toString() ?? '—')),
                  ListTile(title: const Text('Message count (core)'), trailing: Text(_core?['messageCount']?.toString() ?? '—')),
                  if (chats is Map<String, dynamic>) ...<Widget>[
                    ListTile(title: const Text('Chat sessions (vault)'), trailing: Text(chats['sessions']?.toString() ?? '—')),
                    ListTile(title: const Text('Chat messages (vault)'), trailing: Text(chats['messages']?.toString() ?? '—')),
                  ],
                ],
              ),
            ),
    );
  }
}
