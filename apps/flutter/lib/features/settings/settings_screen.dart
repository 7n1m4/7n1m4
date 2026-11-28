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
import 'captions_values.dart';
import 'chat_values.dart';
import 'memory_signals_screen.dart';
import 'settings_catalog.dart';
import 'settings_search.dart';
import 'user_profile_values.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.onOpenConnections,
    this.onSearchReady,
    this.onSearchDisposed,
  });

  final DaemonClient client;
  final VoidCallback onOpenConnections;

  /// App-level chord hooks. The shell owns the global listener; this screen
  /// only lends it its field while mounted, so a hidden tab is unreachable.
  final void Function(FocusNode focus, void Function() close)? onSearchReady;
  final void Function(FocusNode focus)? onSearchDisposed;

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
  userProfile('user-profile', 'User Profile', 'Save user profile'),
  chat('chat', 'Chat', 'Save chat'),
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
  _SectionDraft(this.values) : loaded = true;

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
  final TextEditingController _userName = TextEditingController();
  final TextEditingController _userDescription = TextEditingController();
  final TextEditingController _userPrompt = TextEditingController();
  final TextEditingController _userVoiceProfileId = TextEditingController();
  final TextEditingController _chatTimeout = TextEditingController();
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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchFocused = false;
  // Loads and saves share one in-flight count so an overlapping reload cannot
  // clear the busy flag while a save is still writing. Per-section sets keep a
  // reload from swapping a draft that is dirty or currently being saved.
  int _settingsInFlight = 0;
  final Set<_SettingsSection> _savingSections = <_SettingsSection>{};
  final Set<_SettingsSection> _dirtySections = <_SettingsSection>{};

  bool get _settingsBusy => _settingsInFlight > 0;

  /// Clamp so a duplicated completion can never drive the count negative.
  void _decrementInFlight() {
    setState(() {
      if (_settingsInFlight > 0) {
        _settingsInFlight--;
      }
    });
  }

  String? _settingsError;
  String? _settingsStatus;

  /// Bumped when a clean captions draft is committed by a load. Keying the
  /// captions value fields with it forces a fresh controller — `initialValue`
  /// is ignored after mount — so an async draft is actually displayed.
  int _captionsLoadGeneration = 0;

  String? _languageError;
  StreamSubscription<DaemonStatus>? _statusSub;
  void Function()? _unsubscribeEvents;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    widget.onSearchReady?.call(_searchFocus, _closeSearch);
    _searchFocus.addListener(_onSearchFocusChanged);
    _wasConnected = widget.client.snapshot.isConnected;
    _statusSub = widget.client.statusStream.listen((status) {
      if (status.state == DaemonConnectionState.connected && !_wasConnected) {
        // A reconnect means the daemon's state moved under us: every clean
        // section is reloaded, while a dirty or saving section keeps its draft.
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
    widget.onSearchDisposed?.call(_searchFocus);
    _unsubscribeEvents?.call();
    _statusSub?.cancel();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _searchController.dispose();
    _language.dispose();
    _tint.dispose();
    _userName.dispose();
    _userDescription.dispose();
    _userPrompt.dispose();
    _userVoiceProfileId.dispose();
    _chatTimeout.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted || _searchFocus.hasFocus == _searchFocused) return;
    setState(() => _searchFocused = _searchFocus.hasFocus);
  }

  /// The current result slice, shared by the dropdown and key handling so a
  /// keyboard selection resolves against exactly what the user can see.
  List<SettingsSearchItem> _currentResults() => SettingsSearchIndex.build(
    providers: _providers,
    cards: _cards,
  ).search(_searchQuery);

  /// Local key handling while the search field is focused: Enter selects the
  /// first visible result. Ctrl/Cmd+K and Escape are app-global (owned by the
  /// navigation shell), so they never act on a hidden tab and Escape restores
  /// the focus the chord replaced.
  ///
  /// Only [KeyDownEvent] starts a fresh press; [KeyRepeatEvent] (a held key)
  /// is ignored so a long press cannot submit a result twice.
  KeyEventResult _handleSettingsKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_searchFocus.hasFocus) {
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        final results = _currentResults();
        if (results.isNotEmpty) _openSearchResult(results.first);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  Future<void> _loadSections() async {
    setState(() {
      _settingsInFlight++;
      _settingsError = null;
    });

    // One real `settings.get` per section, each with its own error boundary:
    // a section that will not load stays unsaved without disabling siblings.
    Future<void> loadSection(_SettingsSection section) async {
      // An uncommitted edit or a save in flight owns this draft; swapping it
      // out would discard what the user typed or what is being written.
      if (_dirtySections.contains(section) ||
          _savingSections.contains(section)) {
        return;
      }
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
          } else if (section == _SettingsSection.captions) {
            // Legacy blobs omit the follow/layout/head-tether fields: fill
            // only the absent ones. Present values stay as loaded so a
            // malformed one fails closed at Save instead of being rewritten.
            draft.values = normalizeCaptions(values);
            // Only a clean (non-dirty, non-saving) section reaches this branch,
            // so an in-progress edit keeps its controller and survives reloads.
            _captionsLoadGeneration++;
          } else if (section == _SettingsSection.userProfile) {
            // Same rule as captions: fill only absent fields. A present
            // malformed value stays in the draft so Save fails closed; the
            // controller is display-only and never writes back on Save.
            draft.values = normalizeUserProfile(values);
            _userName.text = _userProfileText(draft.values['name']);
            _userDescription.text = _userProfileText(
              draft.values['description'],
            );
            _userPrompt.text = _userProfileText(draft.values['prompt']);
            _userVoiceProfileId.text = _userProfileText(
              draft.values['voiceProfileId'],
            );
          } else if (section == _SettingsSection.chat) {
            // Fill only absent fields; a present malformed value stays in the
            // draft (and the controller reads as empty) so Save fails closed.
            draft.values = normalizeChat(values);
            _chatTimeout.text = _chatTimeoutText(
              draft.values['streamIdleTimeoutMs'],
            );
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
          } else if (section == _SettingsSection.userProfile) {
            _userName.text = '';
            _userDescription.text = '';
            _userPrompt.text = '';
            _userVoiceProfileId.text = '';
          } else if (section == _SettingsSection.chat) {
            _chatTimeout.text = '';
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
      if (mounted) _decrementInFlight();
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
            ? providerList.whereType<Map<String, dynamic>>().toList(
                growable: false,
              )
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
      _dirtySections.add(section);
      _settingsStatus = null;
    });
  }

  Future<void> _save(_SettingsSection section) async {
    final draft = _drafts[section]!;
    if (!draft.loaded || _savingSections.contains(section)) return;
    _savingSections.add(section);
    setState(() {
      _settingsInFlight++;
      _settingsError = null;
      _settingsStatus = null;
    });
    try {
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
          draft.values['buttons'] = _completeStripButtons(
            draft.values['buttons'],
          );
        }
      }
      if (section == _SettingsSection.captions) {
        final validation = validateCaptions(draft.values);
        if (!validation.isValid) {
          setState(() {
            _settingsError = validation.error;
            _settingsStatus = null;
          });
          return;
        }
      }
      if (section == _SettingsSection.userProfile) {
        // The draft is the source of truth: edits land there via _edit, so a
        // malformed persisted value the user never touched still fails closed
        // before settingsSet is called.
        final validation = validateUserProfile(draft.values);
        if (!validation.isValid) {
          setState(() {
            _settingsError = validation.error;
            _settingsStatus = null;
          });
          return;
        }
      }
      if (section == _SettingsSection.chat) {
        // Same rule as user profile: the draft carries both edits and any
        // malformed persisted value, so nothing unsafe reaches settingsSet.
        final validation = validateChat(draft.values);
        if (!validation.isValid) {
          setState(() {
            _settingsError = validation.error;
            _settingsStatus = null;
          });
          return;
        }
      }
      final updated = Map<String, dynamic>.from(draft.values);
      try {
        final ok = await widget.client.settingsSet(section.key, updated);
        if (!mounted) return;
        setState(() {
          _drafts[section] = _SectionDraft(updated);
          _dirtySections.remove(section);
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
      }
    } finally {
      _savingSections.remove(section);
      if (mounted) _decrementInFlight();
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
      case 'mem-dream-signals':
        _push(MemorySignalsScreen(client: widget.client));
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
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  void _openSearchResult(SettingsSearchItem item) {
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() => _searchQuery = '');
    switch (item.kind) {
      case SettingsSearchKind.catalog:
        final node = item.node;
        if (node != null) _openCatalogNode(node);
      case SettingsSearchKind.provider:
        _push(
          ProvidersScreen(
            client: widget.client,
            initialProviderId: _providerIdFromRoute(item.route),
          ),
        );
      case SettingsSearchKind.card:
        _push(
          CardsScreen(
            client: widget.client,
            initialCardId: _cardIdFromRoute(item.route),
          ),
        );
    }
  }

  /// The card route carries its target as `?cardId=`; the provider route
  /// carries it as the last path segment after `/providers/`.
  static String? _cardIdFromRoute(String route) =>
      Uri.tryParse(route)?.queryParameters['cardId'];

  static String? _providerIdFromRoute(String route) {
    final segments = Uri.tryParse(route)?.pathSegments ?? const <String>[];
    if (segments.length < 3 || segments[segments.length - 2] != 'providers') {
      return null;
    }
    return segments.last;
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
    final results = _currentResults();
    final children = <Widget>[
      TextField(
        key: const Key('settings-search-field'),
        controller: _searchController,
        focusNode: _searchFocus,
        decoration: const InputDecoration(
          hintText: 'Search settings, cards, providers...',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (value) => setState(() => _searchQuery = value),
      ),
      if (_searchFocused) ...<Widget>[
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            'Search Results',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
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
      const Text(
        'Settings',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
      ),
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
              subtitle: node.description == null
                  ? null
                  : Text(node.description!),
              onTap: () => _openCatalogNode(node),
            ),
      _buildCaptionsCard(context),
      _buildUserProfileCard(context),
      _buildChatCard(context),
      if (_settingsError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _settingsError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_settingsStatus != null)
        Padding(
          key: _statusKey,
          padding: const EdgeInsets.only(top: 8),
          child: Text(_settingsStatus!),
        ),
    ];

    return Focus(
      // No autofocus: this page is mounted offstage in the shell's
      // IndexedStack, and stealing focus there would make key handling act on
      // an invisible field. The app-level chord focuses the field on demand.
      onKeyEvent: _handleSettingsKey,
      // All children stay in the tree: the status/error row sits below the
      // cards, and a lazy ListView would leave it unbuilt when Save is tapped
      // from a scrolled position.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
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
            _dirtySections.add(_SettingsSection.general);
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
                  _SettingsSection.general,
                  'usePageSpecificTransitions',
                  value,
                )
              : null,
          title: const Text('Use page-specific transitions'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['websocketSecureEnabled'] == true,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.general,
                  'websocketSecureEnabled',
                  value,
                )
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
        const Text(
          'Preset hues',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
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
                  key: ValueKey<String>(
                    'theme-swatch-${group.key}-${swatch.key}',
                  ),
                  onPressed: enabled ? () => _applyThemeHue(swatch.hue) : null,
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
      _dirtySections.add(_SettingsSection.theme);
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
      _dirtySections.add(_SettingsSection.theme);
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
          value: values['fontSize'],
          min: 50,
          max: 200,
          enabled: enabled,
          onChanged: (value) =>
              _edit(_SettingsSection.captions, 'fontSize', value),
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
            DropdownMenuItem<String>(
              value: 'head',
              child: Text('Head (bottom alias)'),
            ),
            DropdownMenuItem<String>(value: 'none', child: Text('Hidden')),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.captions, 'docking', value)
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['followStageVisibility'] != false,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.captions,
                  'followStageVisibility',
                  value,
                )
              : null,
          title: const Text('Follow stage visibility'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['followStagePosition'] != false,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.captions,
                  'followStagePosition',
                  value,
                )
              : null,
          title: const Text('Follow stage position'),
        ),
        DropdownButtonFormField<String>(
          initialValue: _layoutModeValue(values['layoutMode']),
          decoration: const InputDecoration(labelText: 'Layout mode'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(
              value: 'single',
              child: Text('Active sentence only'),
            ),
            DropdownMenuItem<String>(
              value: 'multi',
              child: Text('Full dialog block'),
            ),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.captions, 'layoutMode', value)
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['headTetheredCaptionEnabled'] == true,
          onChanged: enabled
              ? (value) => _edit(
                  _SettingsSection.captions,
                  'headTetheredCaptionEnabled',
                  value,
                )
              : null,
          title: const Text('In-scene head-tethered caption (Live2D)'),
        ),
        _percentField(
          label: 'Head tether strength (%)',
          value: values['headTetheredCaptionFollowStrength'],
          min: 0,
          max: 100,
          enabled: enabled,
          onChanged: (value) => _edit(
            _SettingsSection.captions,
            'headTetheredCaptionFollowStrength',
            value,
          ),
        ),
        for (final axis in const <String>['x', 'y'])
          KeyedSubtree(
            key: ValueKey<String>(
              'Head offset $axis (px)-$_captionsLoadGeneration',
            ),
            child: TextFormField(
              key: ValueKey<String>('Head offset $axis (px)'),
              enabled: enabled,
              initialValue: _formatNumber(
                _captionOffsetValue(values['headTetheredCaptionOffset'], axis),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: InputDecoration(labelText: 'Head offset $axis (px)'),
              onChanged: (text) {
                final parsed = double.tryParse(text);
                if (parsed != null && parsed.isFinite) {
                  _editCaptionOffset(axis, parsed);
                }
              },
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: enabled
                ? () => _edit(
                    _SettingsSection.captions,
                    'resetTrigger',
                    ((values['resetTrigger'] is int
                            ? values['resetTrigger'] as int
                            : 0) +
                        1),
                  )
                : null,
            child: const Text('Reset caption panel'),
          ),
        ),
      ],
    );
  }

  /// Increment the monotonic reset trigger without dropping the nested
  /// offset's other axis or any unknown key in the section.
  void _editCaptionOffset(String axis, double value) {
    final draft = _drafts[_SettingsSection.captions]!;
    if (!draft.loaded) return;
    final raw = draft.values['headTetheredCaptionOffset'];
    final offset = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    offset[axis] = value;
    setState(() {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..['headTetheredCaptionOffset'] = offset;
      _dirtySections.add(_SettingsSection.captions);
      _settingsStatus = null;
    });
  }

  Widget _buildUserProfileCard(BuildContext context) {
    final draft = _drafts[_SettingsSection.userProfile]!;
    final enabled = draft.loaded && !_settingsBusy;
    return _buildCard(
      _SettingsSection.userProfile,
      children: <Widget>[
        TextField(
          key: const Key('user-profile-name'),
          enabled: enabled,
          controller: _userName,
          decoration: const InputDecoration(labelText: 'Display name'),
          onChanged: (text) =>
              _edit(_SettingsSection.userProfile, 'name', text),
        ),
        TextField(
          key: const Key('user-profile-description'),
          enabled: enabled,
          controller: _userDescription,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Description'),
          onChanged: (text) =>
              _edit(_SettingsSection.userProfile, 'description', text),
        ),
        TextField(
          key: const Key('user-profile-prompt'),
          enabled: enabled,
          controller: _userPrompt,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Extra prompt'),
          onChanged: (text) =>
              _edit(_SettingsSection.userProfile, 'prompt', text),
        ),
        TextField(
          key: const Key('user-profile-voice-profile-id'),
          enabled: enabled,
          controller: _userVoiceProfileId,
          decoration: const InputDecoration(labelText: 'Voice profile id'),
          onChanged: (text) =>
              _edit(_SettingsSection.userProfile, 'voiceProfileId', text),
        ),
      ],
    );
  }

  Widget _buildChatCard(BuildContext context) {
    final draft = _drafts[_SettingsSection.chat]!;
    final values = draft.values;
    final enabled = draft.loaded && !_settingsBusy;
    return _buildCard(
      _SettingsSection.chat,
      children: <Widget>[
        DropdownButtonFormField<String>(
          key: const Key('chat-send-mode'),
          initialValue: _chatModeValue(
            values['sendMode'],
            chatSendModes,
            'enter',
          ),
          decoration: const InputDecoration(labelText: 'Send shortcut'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'enter', child: Text('Enter')),
            DropdownMenuItem<String>(
              value: 'ctrl-enter',
              child: Text('Ctrl+Enter'),
            ),
            DropdownMenuItem<String>(
              value: 'double-enter',
              child: Text('Double Enter'),
            ),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.chat, 'sendMode', value)
              : null,
        ),
        DropdownButtonFormField<String>(
          key: const Key('chat-suggest-mode'),
          initialValue: _chatModeValue(
            values['suggestMode'],
            chatSuggestModes,
            'double-enter',
          ),
          decoration: const InputDecoration(labelText: 'Suggestion shortcut'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'enter', child: Text('Enter')),
            DropdownMenuItem<String>(
              value: 'ctrl-enter',
              child: Text('Ctrl+Enter'),
            ),
            DropdownMenuItem<String>(
              value: 'double-enter',
              child: Text('Double Enter'),
            ),
            DropdownMenuItem<String>(
              value: 'disabled',
              child: Text('Disabled'),
            ),
          ],
          onChanged: enabled
              ? (value) => _edit(_SettingsSection.chat, 'suggestMode', value)
              : null,
        ),
        TextField(
          key: const Key('chat-stream-idle-timeout-ms'),
          controller: _chatTimeout,
          enabled: enabled,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Stream idle timeout (ms)',
          ),
          // Keep a non-numeric draft string so Save fails closed on it; a
          // valid decimal lands in the draft as the u64 the daemon expects.
          onChanged: (text) => _edit(
            _SettingsSection.chat,
            'streamIdleTimeoutMs',
            int.tryParse(text) ?? text,
          ),
        ),
        SwitchListTile(
          key: const Key('chat-show-director-notes'),
          contentPadding: EdgeInsets.zero,
          value: values['showDirectorNotes'] == true,
          onChanged: enabled
              ? (value) =>
                    _edit(_SettingsSection.chat, 'showDirectorNotes', value)
              : null,
          title: const Text('Show director notes'),
        ),
        SwitchListTile(
          key: const Key('chat-combine-system-messages'),
          contentPadding: EdgeInsets.zero,
          value: values['combineSystemMessages'] == true,
          onChanged: enabled
              ? (value) =>
                    _edit(_SettingsSection.chat, 'combineSystemMessages', value)
              : null,
          title: const Text('Combine system messages'),
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
              ? (value) =>
                    _edit(_SettingsSection.controlStrip, 'dockedEdge', value)
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['collapsed'] == true,
          onChanged: enabled
              ? (value) =>
                    _edit(_SettingsSection.controlStrip, 'collapsed', value)
              : null,
          title: const Text('Collapsed to the docked edge'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: values['captionOpen'] == true,
          onChanged: enabled
              ? (value) =>
                    _edit(_SettingsSection.controlStrip, 'captionOpen', value)
              : null,
          title: const Text('Caption overlay open'),
        ),
        TextField(
          enabled: enabled,
          controller: _tint,
          decoration: const InputDecoration(labelText: 'Background tint'),
          onChanged: (_) => _dirtySections.add(_SettingsSection.controlStrip),
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
                      values['buttons'],
                      enabledButtons,
                      id,
                      value ?? false,
                    ),
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
    return KeyedSubtree(
      key: ValueKey<String>('$label-$_captionsLoadGeneration'),
      child: TextFormField(
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
          if (parsed != null && parsed != value) {
            onChanged(parsed.clamp(min, max));
          }
        },
      ),
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
            Text(
              section.label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
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
      case 'mem-dream-signals':
        return Icons.nightlight_outlined;
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
typedef _HueGroup = ({String key, String title, List<_HueSwatch> swatches});

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

/// Display text for a persisted user-profile field. A non-string blob value is
/// shown as empty but kept in the draft, so Save still fails closed on it.
String _userProfileText(Object? value) => value is String ? value : '';

/// Display value of a stored chat shortcut. An unrecognized value reads as
/// the daemon default; the raw value stays in the draft so Save fails closed.
String _chatModeValue(Object? value, Set<String> allowed, String fallback) =>
    value is String && allowed.contains(value) ? value : fallback;

/// Display text for the persisted idle timeout. A malformed value reads as
/// empty but stays in the draft, so Save still fails closed on it.
String _chatTimeoutText(Object? value) => value is int ? '$value' : '';

/// Wire value of a stored caption docking (`top`/`bottom`/`head`/`none`);
/// anything unrecognized reads as the daemon's own default, `none`.
String _dockingValue(Object? value) => switch (value) {
  'top' => 'top',
  'bottom' => 'bottom',
  'head' => 'head',
  'none' => 'none',
  _ => 'none',
};

/// Display value of a stored caption layout mode; anything unrecognized reads
/// as the daemon default, `single`. The raw value is kept in the draft so Save
/// still fails closed on a malformed blob.
String _layoutModeValue(Object? value) => switch (value) {
  'single' => 'single',
  'multi' => 'multi',
  _ => 'single',
};

/// Display value of one axis of the head-tethered plank offset; the daemon
/// defaults are x=0, y=-15.
double _captionOffsetValue(Object? raw, String axis) {
  if (raw is Map) {
    final value = raw[axis];
    if (value is num && value.isFinite) return value.toDouble();
  }
  return axis == 'x' ? 0.0 : -15.0;
}

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
