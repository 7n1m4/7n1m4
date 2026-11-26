// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';
import '../../theme/app_theme.dart';
import '../cards/cards_screen.dart';
import '../data/data_screen.dart';
import '../memory/memory_screen.dart';
import '../modules/modules_screen.dart';
import '../providers/providers_screen.dart';
import '../sessions/sessions_screen.dart';
import '../stage/stage_control_strip_state.dart';
import 'settings_catalog.dart';
import 'settings_search.dart';

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
  theme('theme', 'Theme', 'Save theme'),
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
  final GlobalKey _statusKey = GlobalKey();
  final Map<_SettingsSection, _SectionDraft> _drafts =
      <_SettingsSection, _SectionDraft>{
    for (final section in _SettingsSection.values)
      section: _SectionDraft.unavailable(),
  };
  Map<String, dynamic>? _runtimeStatus;
  List<Map<String, dynamic>> _providers = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  String _searchQuery = '';
  bool _settingsBusy = false;
  String? _settingsError;
  String? _settingsStatus;
  String? _languageError;
  StreamSubscription<DaemonStatus>? _statusSub;
  void Function()? _unsubscribeEvents;
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
        unawaited(_loadCards());
      }
      _wasConnected = status.state == DaemonConnectionState.connected;
    });
    // Another client can change a section while this screen is open. The
    // event carries only the section name, so reload it from the daemon.
    _unsubscribeEvents = widget.client.onEvent((event) {
      if (event.topic != EventTopic.settingsChanged) return;
      final section = event.data['section'];
      if (section is! String) return;
      if (!_SettingsSection.values.any((s) => s.key == section)) return;
      unawaited(_loadSections());
    });
    unawaited(_loadSections());
    unawaited(_loadRuntimeState());
    unawaited(_loadCards());
  }

  @override
  void dispose() {
    _unsubscribeEvents?.call();
    _statusSub?.cancel();
    _language.dispose();
    _tint.dispose();
    super.dispose();
  }

  Future<void> _loadSections() async {
    setState(() {
      _settingsBusy = true;
      _settingsError = null;
    });

    // One real `settings.get` per section, each with its own error boundary:
    // a section that will not load stays unsaved without disabling siblings.
    Future<void> loadSection(_SettingsSection section) async {
      try {
        final values = await widget.client.settingsGet(section.key);
        if (!mounted) return;
        setState(() {
          final draft = _SectionDraft(values);
          _drafts[section] = draft;
          if (section == _SettingsSection.general) {
            final language = values['language'];
            _language.text = language is String ? language : '';
            _languageError = null;
          } else if (section == _SettingsSection.controlStrip) {
            final tint = values['backgroundTint'];
            _tint.text = tint is String ? tint : '#171717';
          } else if (section == _SettingsSection.theme) {
            // Normalize the four theme fields through the same decoder the app
            // uses, so the editor only writes back well-typed values. Other
            // keys in the section are carried through untouched.
            final theme = AppThemeSettings.fromSettings(values);
            draft.values = <String, dynamic>{
              ...values,
              'dark': theme.dark,
              'hue': theme.hue,
              'hueDynamic': theme.hueDynamic,
              'chromaMultiplier': theme.chromaMultiplier,
            };
          }
        });
      } on Object catch (e) {
        if (!mounted) return;
        setState(() {
          _drafts[section] = _SectionDraft.unavailable();
          // Only the controllers owned by the failing section are touched;
          // they are shared across reloads, so a sibling's value survives.
          if (section == _SettingsSection.general) {
            _language.text = '';
            _languageError = null;
          } else if (section == _SettingsSection.controlStrip) {
            _tint.text = '';
          }
          _settingsError = e is DaemonClientException
              ? userSafeConnectionError(
                  e,
                  context: 'settings.load:${section.key}',
                )
              : 'Settings could not be loaded.';
        });
      }
    }

    try {
      await Future.wait(<Future<void>>[
        for (final section in _SettingsSection.values) loadSection(section),
      ]);
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

  /// Card names extend the search index. A failed read only empties that
  /// source: it must not clear the provider/runtime state loaded above.
  Future<void> _loadCards() async {
    try {
      // NOTICE: the daemon may cap `cards.list` below this limit; only the
      // first 200 cards can appear in the search index, not the whole library.
      final page = await widget.client.cardsListPage(limit: 200);
      if (!mounted) return;
      setState(() => _cards = page.items.toList(growable: false));
    } on Object catch (_) {
      if (mounted) setState(() => _cards = const <Map<String, dynamic>>[]);
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
      final language = _language.text.trim();
      if (!_isValidLocale(language)) {
        setState(() {
          _languageError = 'Use a locale code such as "en" or "zh-Hant".';
          _settingsStatus = null;
        });
        return;
      }
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['language'] = language;
    }
    if (section == _SettingsSection.controlStrip) {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['backgroundTint'] = _tint.text.trim();
      if (draft.values.containsKey('buttons')) {
        draft.values['buttons'] = _completeStripButtons(draft.values['buttons']);
      }
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
      if (mounted) {
        setState(() {
          _settingsError = userSafeConnectionError(
            e,
            context: 'settings.set:${section.key}',
          );
        });
      }
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
        _push(ModulesScreen(client: widget.client));
      case 'area-sessions':
        _push(SessionsScreen(client: widget.client));
      case 'area-data':
        _push(DataScreen(client: widget.client));
      case 'area-stage':
        _scrollTo(_SettingsSection.controlStrip);
      case 'area-system':
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

  void _openSearchResult(SettingsSearchItem item) {
    setState(() => _searchQuery = '');
    switch (item.kind) {
      case SettingsSearchKind.catalog:
        final node = item.node;
        if (node != null) _openCatalogNode(node);
      case SettingsSearchKind.provider:
        _push(ProvidersScreen(client: widget.client));
      case SettingsSearchKind.card:
        _push(CardsScreen(client: widget.client));
    }
  }

  IconData _iconForSearchItem(SettingsSearchItem item) => switch (item.kind) {
        SettingsSearchKind.provider => Icons.extension_outlined,
        SettingsSearchKind.card => Icons.person_outline,
        SettingsSearchKind.catalog =>
          item.node == null ? Icons.settings_outlined : _iconForNode(item.node!),
      };

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
    final results = SettingsSearchIndex.build(
      providers: _providers,
      cards: _cards,
    ).search(_searchQuery);
    final children = <Widget>[
      TextField(
        key: const Key('settings-search-field'),
        decoration: const InputDecoration(
          hintText: 'Search settings, cards, providers...',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (value) => setState(() => _searchQuery = value),
      ),
      if (_searchQuery.trim().isNotEmpty) ...<Widget>[
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('Search Results',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (results.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No results'),
          ),
        for (final item in results)
          ListTile(
            key: ValueKey<String>('settings-search-result-${item.id}'),
            leading: Icon(_iconForSearchItem(item)),
            title: Text(item.title),
            subtitle: Text(item.category),
            onTap: () => _openSearchResult(item),
          ),
        const Divider(),
      ],
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
      _buildThemeCard(context),
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
          key: _statusKey,
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
    final draft = _drafts[_SettingsSection.general]!;
    final values = draft.values;
    final enabled = draft.loaded && !_settingsBusy;
    // `remoteSyncEnabled` is deliberately absent: it was retired under
    // airi-3cp. The key is still round-tripped in [values] on save.
    return _buildCard(
      _SettingsSection.general,
      children: <Widget>[
        TextField(
          controller: _language,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'Language code',
            errorText: _languageError,
          ),
          onChanged: (_) {
            if (_languageError != null) setState(() => _languageError = null);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['disableTransitions'] != false,
          onChanged: enabled
              ? (value) =>
                  _edit(_SettingsSection.general, 'disableTransitions', value)
              : null,
          title: const Text('Disable page transitions'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['usePageSpecificTransitions'] != false,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.general, 'usePageSpecificTransitions', value)
              : null,
          title: const Text('Use page-specific transitions'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['websocketSecureEnabled'] == true,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.general, 'websocketSecureEnabled', value)
              : null,
          title: const Text('Secure websocket (wss://)'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['autostart'] == true,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.general, 'autostart', value)
              : null,
          title: const Text('Launch at login'),
        ),
      ],
    );
  }

  Widget _buildThemeCard(BuildContext context) {
    final draft = _drafts[_SettingsSection.theme]!;
    final values = draft.values;
    final enabled = draft.loaded && !_settingsBusy;
    final theme = AppThemeSettings.fromSettings(values);
    return _buildCard(
      _SettingsSection.theme,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: theme.dark,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.theme, 'dark', value)
              : null,
          title: const Text('Dark mode'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: theme.hueDynamic,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.theme, 'hueDynamic', value)
              : null,
          title: const Text('Dynamic hue'),
        ),
        const SizedBox(height: 4),
        const Text('Preset hues', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final group in _themeHueGroups) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              group.title,
              key: ValueKey<String>('theme-group-${group.key}'),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final swatch in group.swatches)
                TextButton(
                  key: ValueKey<String>('theme-swatch-${group.key}-${swatch.key}'),
                  onPressed: enabled
                      ? () => _applyThemeHue(swatch.hue)
                      : null,
                  child: Text(swatch.label),
                ),
            ],
          ),
        ],
        _labeledSlider(
          label: 'Hue',
          value: theme.hue,
          min: 0,
          max: 360,
          enabled: enabled && !theme.hueDynamic,
          onChanged: (value) => _edit(_SettingsSection.theme, 'hue', value),
        ),
        _labeledSlider(
          label: 'Vibrancy',
          value: theme.chromaMultiplier,
          min: 0,
          max: 2,
          enabled: enabled,
          onChanged: (value) =>
              _edit(_SettingsSection.theme, 'chromaMultiplier', value),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: enabled ? _resetTheme : null,
            child: const Text('Reset to defaults'),
          ),
        ),
      ],
    );
  }

  /// A preset writes both fields the way Vue's `applyPrimaryColorFrom` does:
  /// a chosen hue is manual, so dynamic hue is switched off.
  void _applyThemeHue(double hue) {
    final draft = _drafts[_SettingsSection.theme]!;
    if (!draft.loaded) return;
    setState(() {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['hue'] = hue
        ..['hueDynamic'] = false;
      _settingsStatus = null;
    });
  }

  /// Restore the daemon's own theme defaults; nothing else in the section is
  /// touched, so unknown keys still round-trip on save.
  void _resetTheme() {
    const defaults = AppThemeSettings.daemonDefaults;
    final draft = _drafts[_SettingsSection.theme]!;
    if (!draft.loaded) return;
    setState(() {
      // Vue's resetToDefault() restores hue/chroma only: dark mode is a
      // separate user choice and must not be flipped by a palette reset.
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['hue'] = defaults.hue
        ..['hueDynamic'] = defaults.hueDynamic
        ..['chromaMultiplier'] = defaults.chromaMultiplier;
      _settingsStatus = null;
    });
  }

  Widget _buildCaptionsCard(BuildContext context) {
    final draft = _drafts[_SettingsSection.captions]!;
    final values = draft.values;
    final enabled = draft.loaded && !_settingsBusy;
    return _buildCard(
      _SettingsSection.captions,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['enabled'] != false,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.captions, 'enabled', value)
              : null,
          title: const Text('Show captions'),
        ),
        _percentField(
          label: 'Font size (%)',
          value: values['fontSize'] ?? values['font_size'],
          min: 50,
          max: 200,
          enabled: enabled,
          onChanged: (value) {
            // Migrate a stale snake_case spelling to camelCase in the same edit,
            // removing font_size when fontSize is not yet present, then set fontSize.
            final draft = _drafts[_SettingsSection.captions]!;
            final current = draft.values;
            if (current['fontSize'] == null && current['font_size'] != null) {
              draft.values = Map<String, dynamic>.from(current)..remove('font_size');
            }
            _edit(_SettingsSection.captions, 'fontSize', value);
          },
        ),
        _percentField(
          label: 'Opacity (%)',
          value: values['opacity'],
          min: 0,
          max: 100,
          enabled: enabled,
          onChanged: (value) =>
              _edit(_SettingsSection.captions, 'opacity', value),
        ),
        DropdownButtonFormField<String>(
          initialValue: _dockingValue(values['docking']),
          decoration: const InputDecoration(labelText: 'Docking'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'top', child: Text('Top')),
            DropdownMenuItem<String>(value: 'bottom', child: Text('Bottom')),
            DropdownMenuItem<String>(value: 'head', child: Text('Head (bottom alias)')),
            DropdownMenuItem<String>(value: 'none', child: Text('Hidden')),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.captions, 'docking', value)
              : null,
        ),
      ],
    );
  }

  Widget _buildControlStripCard(BuildContext context) {
    final draft = _drafts[_SettingsSection.controlStrip]!;
    final values = draft.values;
    final enabled = draft.loaded && !_settingsBusy;
    final storedButtons = _stripStoredButtons(values['buttons']);
    final enabledButtons = <String>{
      for (final entry in storedButtons)
        if (entry['enabled'] == true && entry['id'] is String)
          entry['id'] as String,
    };
    return _buildCard(
      _SettingsSection.controlStrip,
      children: <Widget>[
        DropdownButtonFormField<String>(
          initialValue: _edgeWire(values['dockedEdge']),
          decoration: const InputDecoration(labelText: 'Docked edge'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'left', child: Text('Left')),
            DropdownMenuItem<String>(value: 'right', child: Text('Right')),
            DropdownMenuItem<String>(value: 'top', child: Text('Top')),
            DropdownMenuItem<String>(value: 'bottom', child: Text('Bottom')),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.controlStrip, 'dockedEdge', value)
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['collapsed'] == true,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.controlStrip, 'collapsed', value)
              : null,
          title: const Text('Collapsed to the docked edge'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['captionOpen'] == true,
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.controlStrip, 'captionOpen', value)
              : null,
          title: const Text('Caption overlay open'),
        ),
        TextField(
          enabled: enabled,
          controller: _tint,
          decoration: const InputDecoration(labelText: 'Background tint'),
        ),
        const SizedBox(height: 8),
        const Text('Buttons', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final id in kStageStripCatalog)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: enabledButtons.contains(id),
            title: Text(_stripButtonLabel(id)),
            onChanged: enabled
                ? (value) => _edit(
                      _SettingsSection.controlStrip,
                      'buttons',
                      _toggleStripButton(
                          values['buttons'], enabledButtons, id, value ?? false),
                    )
                : null,
          ),
      ],
    );
  }

  /// A bounded double slider. The value is read from the draft on every build
  /// so external settings changes are never merged with a stale slider state.
  Widget _labeledSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required bool enabled,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('$label: ${_formatNumber(value)}'),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }

  /// A bounded percentage field. The clamp applies as the user types; an
  /// empty field edits nothing.
  Widget _percentField({
    required String label,
    required Object? value,
    required double min,
    required double max,
    required bool enabled,
    required ValueChanged<double> onChanged,
  }) {
    return TextFormField(
      key: ValueKey<String>(label),
      enabled: enabled,
      initialValue: value is num && value.isFinite
          ? _formatNumber(value.toDouble())
          : _formatNumber(min),
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(labelText: label),
      onChanged: (text) {
        final parsed = double.tryParse(text);
        if (parsed != null && parsed != value) onChanged(parsed.clamp(min, max));
      },
    );
  }

  Widget _buildCard(
    _SettingsSection section, {
    required List<Widget> children,
  }) {
    final draft = _drafts[section]!;
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
      case 'area-memory':
        return Icons.psychology_outlined;
      case 'area-modules':
        return Icons.layers_outlined;
      case 'area-sessions':
        return Icons.forum_outlined;
      case 'area-providers':
        return Icons.extension_outlined;
      case 'area-data':
        return Icons.storage_outlined;
      case 'sys-connection':
        return Icons.link;
      case 'area-stage':
        return Icons.tune;
      default:
        return Icons.settings_outlined;
    }
  }
}

/// One swatch in a theme preset group. [hue] is the OKLCH hue angle from
/// culori's `converter('oklch')` — the same conversion Vue's `getHueFrom()`
/// uses — rounded to two decimals, so a swatch applies exactly the hue the
/// web settings page would for the same hex.
typedef _HueSwatch = ({String key, String label, double hue});

/// One row of the 24-colour spectrum, in the order of
/// `packages/stage-pages/src/pages/settings/system/color-presets.json`.
typedef _HueGroup = ({
  String key,
  String title,
  List<_HueSwatch> swatches,
});

/// All 24 grouped swatches from `color-presets.json`: four groups of six.
/// The swatch labelled with the group's short name is that group's
/// representative — the four hues this screen offered before expansion — so
/// the existing labels and their hues keep working. A `null` hex (ocean's
/// signature cyan) falls back to the daemon default hue, as Vue does.
const List<_HueGroup> _themeHueGroups = <_HueGroup>[
  (
    key: 'warm',
    title: 'Warm & Fire',
    swatches: <_HueSwatch>[
      (key: 'crimson', label: 'Warm', hue: 17.58), // #E11D48 Crimson
      (key: 'coral', label: 'Coral', hue: 16.44), // #F43F5E
      (key: 'tangerine', label: 'Tangerine', hue: 41.12), // #EA580C
      (key: 'marigold', label: 'Marigold', hue: 70.08), // #F59E0B
      (key: 'amber', label: 'Amber', hue: 86.05), // #EAB308
      (key: 'lemon', label: 'Lemon', hue: 130.85), // #84CC16
    ],
  ),
  (
    key: 'flora',
    title: 'Earth & Flora',
    swatches: <_HueSwatch>[
      (key: 'lime', label: 'Lime', hue: 131.68), // #65A30D
      (key: 'emerald', label: 'Flora', hue: 149.21), // #16A34A Emerald
      (key: 'mint', label: 'Mint', hue: 162.48), // #10B981
      (key: 'jade', label: 'Jade', hue: 163.23), // #059669
      (key: 'viridian', label: 'Viridian', hue: 184.70), // #0D9488
      (key: 'teal', label: 'Teal', hue: 221.72), // #0891B2
    ],
  ),
  (
    key: 'ocean',
    title: 'Ocean & Sky',
    swatches: <_HueSwatch>[
      (key: 'turquoise', label: 'Turquoise', hue: 215.22), // #06B6D4
      (key: 'cyan', label: 'Signature Cyan', hue: 220.44), // null → default
      (key: 'cerulean', label: 'Ocean', hue: 262.88), // #2563EB Cerulean
      (key: 'cobalt', label: 'Cobalt', hue: 259.81), // #3B82F6
      (key: 'sapphire', label: 'Sapphire', hue: 276.97), // #4F46E5
      (key: 'denim', label: 'Denim', hue: 277.12), // #6366F1
    ],
  ),
  (
    key: 'bloom',
    title: 'Royal & Bloom',
    swatches: <_HueSwatch>[
      (key: 'indigo', label: 'Bloom', hue: 293.01), // #7C3AED Indigo
      (key: 'amethyst', label: 'Amethyst', hue: 302.32), // #9333EA
      (key: 'violet', label: 'Violet', hue: 303.90), // #A855F7
      (key: 'fuchsia', label: 'Fuchsia', hue: 322.90), // #C026D3
      (key: 'magenta', label: 'Magenta', hue: 0.58), // #DB2777
      (key: 'rose', label: 'Rose', hue: 2.17), // #E11D74
    ],
  ),
];

/// Empty means "use system default" (the daemon's `GeneralSettings::default`).
/// Otherwise accept a BCP-47-style tag: 2-3 letters plus optional subtags.
final RegExp _localePattern = RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$');

bool _isValidLocale(String value) =>
    value.isEmpty || _localePattern.hasMatch(value);

/// Wire value of a stored caption docking (`top`/`bottom`/`head`/`none`);
/// anything unrecognized reads as the daemon's own default, `none`.
String _dockingValue(Object? value) => switch (value) {
      'top' => 'top',
      'bottom' => 'bottom',
      'head' => 'head',
      'none' => 'none',
      _ => 'none',
    };

/// Wire value of a stored docked edge (`ControlStripDockedEdge`); anything
/// unrecognized reads as the daemon default, `right`.
String _edgeWire(Object? value) => switch (value) {
      'left' => 'left',
      'top' => 'top',
      'bottom' => 'bottom',
      _ => 'right',
    };

/// The daemon's `buttons` array as a list of entries in stored order. A
/// missing or malformed list falls back to the daemon's own default set
/// (`StageControlStripSettings`), never to an invented arrangement.
List<Map<String, dynamic>> _stripStoredButtons(Object? raw) {
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  if (raw is List) {
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || !seen.add(id)) continue;
      result.add(Map<String, dynamic>.from(entry));
    }
  }
  if (raw is! List && result.isEmpty) {
    for (final id in kStageStripCatalog) {
      result.add(<String, dynamic>{'id': id, 'enabled': true});
    }
  }
  return result;
}

/// Return the stored buttons plus any catalog entries the daemon omitted, so
/// saving an unrelated field does not silently shrink the stored catalog.
List<Map<String, dynamic>> _completeStripButtons(Object? raw) {
  final result = _stripStoredButtons(raw);
  final seen = result
      .where((entry) => entry['id'] is String)
      .map((entry) => entry['id'] as String)
      .toSet();
  for (final id in kStageStripCatalog) {
    if (seen.add(id)) {
      result.add(<String, dynamic>{'id': id, 'enabled': false});
    }
  }
  return result;
}

/// Write the daemon's `buttons` array back with `id` toggled to `value`: the
/// stored entry keeps its position and fields with only `enabled` flipped,
/// a missing entry is appended, and the daemon's default catalog entries
/// follow in daemon order.
List<Map<String, dynamic>> _toggleStripButton(
  Object? raw,
  Set<String> enabled,
  String id,
  bool value,
) {
  final next = <String>{...enabled};
  if (value) {
    next.add(id);
  } else {
    next.remove(id);
  }
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final entry in _stripStoredButtons(raw)) {
    final entryId = entry['id'];
    if (entryId is! String || !kStageStripCatalog.contains(entryId)) {
      // An id this build does not surface is carried through untouched.
      result.add(entry);
      continue;
    }
    result.add(<String, dynamic>{...entry, 'enabled': next.contains(entryId)});
    seen.add(entryId);
  }
  for (final entry in kStageStripCatalog) {
    if (seen.contains(entry)) continue;
    result.add(<String, dynamic>{'id': entry, 'enabled': next.contains(entry)});
    seen.add(entry);
  }
  return result;
}

String _stripButtonLabel(String id) => switch (id) {
      'chat' => 'Chat toggle',
      'actor-characters' => 'Characters',
      'mic' => 'Microphone',
      'stage' => 'Actor stage',
      'stage-atmosphere' => 'Stage & chat theme',
      'caption' => 'Captions',
      _ => id,
    };

String _formatNumber(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();