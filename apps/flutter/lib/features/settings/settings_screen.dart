// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../cards/cards_screen.dart';
import '../memory/memory_screen.dart';
import '../providers/providers_screen.dart';
import '../sessions/sessions_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.onOpenConnections,
  });

  final DaemonClient client;
  final VoidCallback onOpenConnections;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _language = TextEditingController();
  // Null until a real settings.get completes: saving an empty section would
  // make the daemon fill every missing key with serde defaults and wipe the
  // user's unrelated settings.
  Map<String, dynamic>? _general;
  bool _loaded = false;
  bool _settingsBusy = false;
  String? _settingsError;
  String? _settingsStatus;
  StreamSubscription<DaemonStatus>? _statusSub;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.client.snapshot.isConnected;
    _statusSub = widget.client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      final regainedConnection = connected && !_wasConnected;
      _wasConnected = connected;
      // A reconnect gets a fresh daemon state; reload before allowing Save.
      if (regainedConnection && mounted) unawaited(_loadGeneral());
    });
    unawaited(_loadGeneral());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _language.dispose();
    super.dispose();
  }

  /// Real read call site for the daemon's typed `general` settings section.
  Future<void> _loadGeneral() async {
    setState(() {
      _settingsBusy = true;
      _settingsError = null;
    });
    try {
      final section = await widget.client.settingsGet('general');
      if (!mounted) return;
      setState(() {
        _general = section;
        _language.text = (section['language'] as String?) ?? '';
        _loaded = true;
      });
    } on DaemonClientException catch (e) {
      if (mounted) {
        setState(() {
          _general = null;
          _loaded = false;
          _settingsError = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  /// Real write call site: send the whole section back with one field changed
  /// (the daemon validates the full typed shape). Refuses to write until a
  /// fresh read has populated the section.
  Future<void> _saveGeneral() async {
    final loaded = _general;
    if (!_loaded || loaded == null) return;
    final updated = Map<String, dynamic>.from(loaded)
      ..['language'] = _language.text.trim();
    setState(() {
      _settingsBusy = true;
      _settingsError = null;
      _settingsStatus = null;
    });
    try {
      final ok = await widget.client.settingsSet('general', updated);
      if (!mounted) return;
      setState(() {
        _general = updated;
        _loaded = true;
        _settingsStatus = ok ? 'General settings saved.' : 'General settings were not saved.';
      });
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _settingsError = e.message);
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('Connection'),
          subtitle: const Text('Host, port, scheme and auth token'),
          onTap: widget.onOpenConnections,
        ),
        const Divider(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('General settings (local daemon)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _language,
                  enabled: !_settingsBusy,
                  decoration: const InputDecoration(labelText: 'Language code'),
                ),
                if (_settingsError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_settingsError!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                if (_settingsStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_settingsStatus!),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: (_settingsBusy || !_loaded) ? null : _saveGeneral,
                    child: const Text('Save general'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.extension_outlined),
          title: const Text('Providers'),
          subtitle: const Text('LLM providers via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ProvidersScreen(client: widget.client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Memory'),
          subtitle: const Text('Memory stats via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => MemoryScreen(client: widget.client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Cards'),
          subtitle: const Text('Cards settings via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => CardsScreen(client: widget.client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.forum_outlined),
          title: const Text('Sessions'),
          subtitle: const Text('Session/message counts via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => SessionsScreen(client: widget.client)),
          ),
        ),
      ],
    );
  }
}
