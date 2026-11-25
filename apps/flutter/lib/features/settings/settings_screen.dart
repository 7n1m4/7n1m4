// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../cards/cards_screen.dart';
import '../memory/memory_screen.dart';
import '../providers/providers_screen.dart';
import '../sessions/sessions_screen.dart';
import 'settings_catalog.dart';

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
  static final SettingsTopology _catalog = settingsCatalogTopology;

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

  void _openCatalogNode(SettingsTopologyNode node) {
    switch (node.id) {
      case 'sys-connection':
        widget.onOpenConnections();
      case 'area-providers':
        _push(ProvidersScreen(client: widget.client));
      case 'area-memory':
        _push(MemoryScreen(client: widget.client));
      case 'area-card':
        _push(CardsScreen(client: widget.client));
      case 'area-modules':
        _push(SessionsScreen(client: widget.client));
      case 'sys-general':
        return;
      default:
        return;
    }
  }

  void _push(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
      const SizedBox(height: 8),
      for (final node in _catalog.orderedChildren(_catalog.rootId))
        if (node.visible)
          if (node.id == 'sys-general')
            _buildGeneralCard(context)
          else
            ListTile(
              leading: Icon(_iconForNode(node)),
              title: Text(node.label),
              subtitle: node.description == null ? null : Text(node.description!),
              onTap: () => _openCatalogNode(node),
            ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _buildGeneralCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('General Preferences',
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
    );
  }

  IconData _iconForNode(SettingsTopologyNode node) {
    switch (node.id) {
      case 'area-card':
        return Icons.person_outline;
      case 'area-models':
        return Icons.people_outline;
      case 'area-scene':
        return Icons.image_outlined;
      case 'area-memory':
        return Icons.psychology_outlined;
      case 'area-modules':
        return Icons.forum_outlined;
      case 'area-providers':
        return Icons.extension_outlined;
      case 'area-data':
        return Icons.storage_outlined;
      case 'sys-connection':
        return Icons.link;
      case 'area-stage':
        return Icons.tune;
      case 'area-docs':
        return Icons.menu_book_outlined;
      case 'area-about':
        return Icons.info_outline;
      default:
        return Icons.settings_outlined;
    }
  }
}