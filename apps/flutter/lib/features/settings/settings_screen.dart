// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../daemon_client/daemon_client.dart';
import '../cards/cards_screen.dart';
import '../memory/memory_screen.dart';
import '../providers/providers_screen.dart';
import '../sessions/sessions_screen.dart';
import '../stage/stage_control_strip_state.dart';
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

/// The settings sections this screen edits.
///
/// Each [key] is a section name in `settings_section()` in
/// `crates/anima-daemon/src/core.rs`; a section that is not registered there
/// fails the read instead of silently editing a shape the daemon rejects.
enum _SettingsSection {
  general('general', 'General Preferences', 'Save general'),
  captions('captions', 'Captions', 'Save captions'),
  controlStrip('control-strip', 'Floating Controls', 'Save floating controls');

  const _SettingsSection(this.key, this.label, this.saveLabel);

  final String key;
  final String label;
  final String saveLabel;
}

/// One loaded section: the daemon's own map plus the user's edits.
///
/// [values] starts as the loaded map, so a save round-trips every key this
/// screen does not edit; the daemon's typed deserializer keeps unknown fields
/// out of the blob, but nothing this client knows about is dropped.
class _SectionDraft {
  _SectionDraft(this.values)
      : loaded = true;

  _SectionDraft.unavailable()
      : values = const <String, dynamic>{},
        loaded = false;

  Map<String, dynamic> values;
  bool loaded;
}

class _SettingsScreenState extends State<SettingsScreen> {
  static final SettingsTopology _catalog = settingsCatalogTopology;

  final TextEditingController _language = TextEditingController();
  final TextEditingController _tint = TextEditingController();
  final Map<_SettingsSection, GlobalKey> _cardKeys =
      <_SettingsSection, GlobalKey>{
    for (final section in _SettingsSection.values) section: GlobalKey(),
  };
  final Map<_SettingsSection, _SectionDraft> _drafts =
      <_SettingsSection, _SectionDraft>{
    for (final section in _SettingsSection.values)
      section: _SectionDraft.unavailable(),
  };
  Map<String, dynamic>? _runtimeStatus;
  List<Map<String, dynamic>> _providers = const <Map<String, dynamic>>[];
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
      if (status.state == DaemonConnectionState.connected && !_wasConnected) {
        // A reconnect means the daemon's state moved under us: every section
        // is reloaded before Save is offered again, never merged with a stale
        // draft.
        unawaited(_loadSections());
        unawaited(_loadRuntimeState());
      }
      _wasConnected = status.state == DaemonConnectionState.connected;
    });
    unawaited(_loadSections());
    unawaited(_loadRuntimeState());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _language.dispose();
    _tint.dispose();
    super.dispose();
  }

  bool get _loaded => _drafts[_SettingsSection.general]!.loaded;

  Future<void> _loadSections() async {
    setState(() {
      _settingsBusy = true;
      _settingsError = null;
    });
    try {
      // One real `settings.get` per section: nothing is fabricated
      // client-side, and a section that will not load stays unsaved.
      final results = await Future.wait(<Future<Map<String, dynamic>>>[
        for (final section in _SettingsSection.values)
          widget.client.settingsGet(section.key),
      ]);
      if (!mounted) return;
      setState(() {
        var index = 0;
        for (final section in _SettingsSection.values) {
          _drafts[section] = _SectionDraft(results[index++]);
        }
        final general = _drafts[_SettingsSection.general]!.values;
        final language = general['language'];
        final tint = _drafts[_SettingsSection.controlStrip]!.values['backgroundTint'];
        _language.text = language is String ? language : '';
        _tint.text = tint is String ? tint : '#171717';
      });
    } on DaemonClientException catch (e) {
      if (mounted) {
        setState(() {
          for (final section in _SettingsSection.values) {
            _drafts[section] = _SectionDraft.unavailable();
          }
          _language.text = '';
          _tint.text = '';
          _settingsError = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _settingsBusy = false);
    }
  }

  Future<void> _loadRuntimeState() async {
    try {
      final runtime = await widget.client.call('runtime.status');
      final providers = await widget.client.call('providers.list');
      if (!mounted) return;
      final providerList = providers.data is Map<String, dynamic>
          ? (providers.data as Map<String, dynamic>)['providers']
          : null;
      setState(() {
        _runtimeStatus = runtime.data is Map<String, dynamic>
            ? runtime.data as Map<String, dynamic>
            : null;
        _providers = providerList is List
            ? providerList.whereType<Map<String, dynamic>>().toList(growable: false)
            : const <Map<String, dynamic>>[];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _runtimeStatus = null;
          _providers = const <Map<String, dynamic>>[];
        });
      }
    }
  }

  /// Edit one draft field in memory; nothing reaches the daemon until Save.
  void _edit(_SettingsSection section, String key, Object? value) {
    final draft = _drafts[section]!;
    if (!draft.loaded) return;
    setState(() {
      draft.values = Map<String, dynamic>.from(draft.values)..[key] = value;
      _settingsStatus = null;
    });
  }

  Future<void> _save(_SettingsSection section) async {
    final draft = _drafts[section]!;
    if (!draft.loaded) return;
    if (section == _SettingsSection.general) {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['language'] = _language.text.trim();
    }
    if (section == _SettingsSection.controlStrip) {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['backgroundTint'] = _tint.text.trim();
    }
    final updated = Map<String, dynamic>.from(draft.values);
    setState(() {
      _settingsBusy = true;
      _settingsError = null;
      _settingsStatus = null;
    });
    try {
      final ok = await widget.client.settingsSet(section.key, updated);
      if (!mounted) return;
      setState(() {
        _drafts[section] = _SectionDraft(updated);
        _settingsStatus = ok
            ? '${section.label} settings saved.'
            : '${section.label} settings were not saved.';
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
      case 'area-stage':
        _scrollTo(_SettingsSection.controlStrip);
      case 'sys-general':
        _scrollTo(_SettingsSection.general);
      default:
        return;
    }
  }

  void _push(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  /// Bring a section's editor into view. The hub is one scrolling page, so the
  /// catalog entry scrolls to the card instead of pushing an empty route.
  void _scrollTo(_SettingsSection section) {
    final context = _cardKeys[section]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 200),
      alignment: 0.1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
      const SizedBox(height: 8),
      if (_runtimeStatus != null)
        Text('Runtime: ${_runtimeStatus!['app']} ${_runtimeStatus!['version']}')
      else
        const Text('Runtime: unavailable'),
      if (_providers.isNotEmpty)
        Text('Providers: ${_providers.length} enabled')
      else
        const Text('Providers: unavailable'),
      _buildGeneralCard(context),
      for (final node in _catalog.orderedChildren(_catalog.rootId))
        if (node.visible)
          if (node.id == 'area-stage')
            _buildControlStripCard(context)
          else
            ListTile(
              leading: Icon(_iconForNode(node)),
              title: Text(node.label),
              subtitle: node.description == null ? null : Text(node.description!),
              onTap: () => _openCatalogNode(node),
            ),
      _buildCaptionsCard(context),
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
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _buildGeneralCard(BuildContext context) {
    return Card(
      key: _cardKeys[section],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(section.label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: (draft.loaded && !_settingsBusy)
                    ? () => _save(section)
                    : null,
                child: Text(section.saveLabel),
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