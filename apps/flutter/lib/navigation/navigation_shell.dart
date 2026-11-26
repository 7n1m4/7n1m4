// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:path_provider/path_provider.dart';

import 'package:anima_control/speech/lip_sync_rms_data.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';

import '../daemon_client/daemon_client.dart';
import '../l10n/app_localizations.dart';
import '../features/about/about_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/connections/connections_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/stage/stage_background.dart';
import '../features/stage/stage_scene_manager.dart';
import '../features/stage/stage_scenes_screen.dart';
import '../features/stage/stage_screen.dart';
import '../connection/connection_error.dart';
import '../ui/status_bits.dart';

/// The daemon section holding [`CardsSettings.activeCardId`](../../../../crates/anima-core/src/settings.rs).
const String _cardsSettingsSection = 'cards';

/// Read the card id from `settings/cards`, or null when unset/unreadable.
/// An unreachable daemon must not silently override a local choice.
Future<String?> _daemonActiveCardId(DaemonClient client) async {
  try {
    final settings = await client.settingsGet(_cardsSettingsSection);
    final id = settings['activeCardId'] ?? settings['active_card_id'];
    if (id is String) return id;
    return null;
  } on Object {
    return null;
  }
}

/// Read one active card field from a card document. Vue treats
/// `active_state` as canonical and mirrors the same values under
/// `extensions.airi.modules`; this client accepts both shapes and both card
/// envelopes, preferring the root when both are present.
String? readCardActiveField(Map<String, dynamic> card, String field) {
  final extensions = card['extensions'];
  final data = card['data'];
  for (final candidate in <Object?>[
    extensions,
    if (data is Map<String, dynamic>) data['extensions'],
  ]) {
    if (candidate is! Map<String, dynamic>) continue;
    final airi = candidate['airi'];
    if (airi is! Map<String, dynamic>) continue;
    for (final group in <Object?>[airi['active_state'], airi['modules']]) {
      if (group is! Map<String, dynamic>) continue;
      final value = group[field];
      if (value is String && value.isNotEmpty) return value;
    }
  }
  return null;
}

/// Write one active card field into a fresh card document, updating both
/// `modules` and `active_state` in the root and nested `data.extensions`
/// mirrors while preserving every other field verbatim.
Map<String, dynamic> withCardActiveField(
  Map<String, dynamic> card,
  String field,
  String value,
) {
  final updated = <String, dynamic>{...card};
  for (final entry in <Map<String, dynamic>>[
    updated,
    if (updated['data'] is Map<String, dynamic>)
      updated['data'] as Map<String, dynamic>,
  ]) {
    final extensions = entry['extensions'];
    final airi = extensions is Map<String, dynamic> &&
            extensions['airi'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(extensions['airi'] as Map<String, dynamic>)
        : <String, dynamic>{};
    for (final groupName in <String>['modules', 'active_state']) {
      final group = airi[groupName];
      airi[groupName] = <String, dynamic>{
        ...(group is Map<String, dynamic> ? group : const <String, dynamic>{}),
        field: value,
      };
    }
    entry['extensions'] = <String, dynamic>{
      ...(extensions is Map<String, dynamic> ? extensions : const <String, dynamic>{}),
      'airi': airi,
    };
  }
  return updated;
}

/// Supplies the client-local scene library directory. Injected in tests;
/// production resolves the application support directory, never system temp.
typedef SceneStorageDirectoryProvider = Future<Directory> Function();

/// Loads one scene store. Injected for tests because filesystem IO must run
/// outside the fake-async widget zone.
typedef SceneLibraryLoader = Future<void> Function(StageSceneStore store);

/// Production scene library location. A failed lookup is surfaced by the
/// shell instead of falling back to a volatile directory.
Future<Directory> defaultSceneStorageDirectory() =>
    getApplicationSupportDirectory();

Future<void> _loadSceneLibrary(StageSceneStore store) => store.load();

/// Index of the settings hub in the shell's [IndexedStack].
const int settingsDestinationIndex = 2;

/// App-global Ctrl/Cmd+K owner for settings search.
///
/// [NavigationShell] installs this listener on mount and removes it on dispose,
/// so it lives for the app's lifetime without any startup wiring. The settings
/// screen binds its field while mounted, and the shell reports which
/// destination is active — a hidden IndexedStack page is never reachable.
class SettingsSearchShortcut {
  SettingsSearchShortcut._();

  static final SettingsSearchShortcut instance = SettingsSearchShortcut._();

  static bool _installed = false;

  /// Idempotent: the shell installs on mount; repeated calls are no-ops.
  void install() {
    if (_installed) return;
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _installed = true;
  }

  /// Detach the listener and forget transient focus state.
  void uninstall() {
    if (_installed) {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
      _installed = false;
    }
    activeDestinationIndex = 0;
    searchFocus = null;
    clearSearch = null;
    _previousFocus = null;
  }

  int activeDestinationIndex = 0;
  FocusNode? searchFocus;
  void Function()? clearSearch;
  FocusNode? _previousFocus;

  /// Called by the mounted settings screen; it owns the field and its query.
  void bindSearch({
    required FocusNode focus,
    required void Function() close,
  }) {
    searchFocus = focus;
    clearSearch = close;
  }

  void unbindSearch(FocusNode focus) {
    if (identical(searchFocus, focus)) {
      searchFocus = null;
      clearSearch = null;
    }
    if (identical(_previousFocus, focus)) _previousFocus = null;
  }

  static bool _isApplePlatform() =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// A focus node belongs to an editor when an [EditableText] is its ancestor
  /// (EditableText wraps its own [Focus] with the node).
  static bool _isEditor(FocusNode node) =>
      node.context?.findAncestorWidgetOfExactType<EditableText>() != null;

  bool _onKeyEvent(KeyEvent event) {
    // A held key is a repeat, not a fresh chord press.
    if (event is! KeyDownEvent) return false;
    final field = searchFocus;
    if (field == null ||
        activeDestinationIndex != settingsDestinationIndex) {
      return false;
    }
    // A sub-route pushed from settings (providers, cards, ...) obscures the
    // hub. Its field is still mounted, but focusing it would steal focus from
    // the visible page, so the chord only applies on the current route.
    final fieldContext = field.context;
    if (fieldContext == null ||
        ModalRoute.of(fieldContext)?.isCurrent != true) {
      return false;
    }

    final primary = FocusManager.instance.primaryFocus;
    final modifierPressed = _isApplePlatform()
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;

    if (event.logicalKey == LogicalKeyboardKey.keyK && modifierPressed) {
      // A chord belongs to the search field only when no other editor has
      // focus: Ctrl/Cmd+K stays available to the text field being typed in.
      if (primary != null && _isEditor(primary) && !identical(primary, field)) {
        return false;
      }
      // Re-pressing the chord while search is focused must not overwrite the
      // focus we intend to restore on Escape.
      if (primary != null && !identical(primary, field)) {
        _previousFocus = primary;
      }
      field.requestFocus();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape && field.hasFocus) {
      clearSearch?.call();
      final previous = _previousFocus;
      _previousFocus = null;
      if (previous != null) {
        // The close callback setState()s and unfocuses the field; restore once
        // that frame has applied, otherwise its unfocus wins the focus update.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (previous.context?.mounted == true) previous.requestFocus();
        });
      }
      return true;
    }
    return false;
  }
}

/// Thin navigation shell: six destinations, no business logic.
/// An adaptive NavigationRail for wide/desktop windows is deferred.
class NavigationShell extends StatefulWidget {
  const NavigationShell({
    super.key,
    required this.client,
    this.lipSyncFrames,
    this.sceneStorageDirectory,
    SceneStorageDirectoryProvider? sceneStorageDirectoryProvider,
    SceneLibraryLoader? sceneLibraryLoader,
  }) : sceneStorageDirectoryProvider =
           sceneStorageDirectoryProvider ?? defaultSceneStorageDirectory,
       sceneLibraryLoader = sceneLibraryLoader ?? _loadSceneLibrary;

  final DaemonClient client;
  final Stream<LipSyncRmsData>? lipSyncFrames;

  /// Client-local scene library directory. Injected for tests; production
  /// resolves it through [sceneStorageDirectoryProvider].
  final Directory? sceneStorageDirectory;

  final SceneStorageDirectoryProvider sceneStorageDirectoryProvider;

  final SceneLibraryLoader sceneLibraryLoader;

  @override
  State<NavigationShell> createState() => _NavigationShellState();
}

class _NavigationShellState extends State<NavigationShell> {
  int _index = 0;
  StageSceneStore? _scenes;
  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  String? _selectedCardId;
  bool _noCardExplicitlySelected = false;
  String? _cardError;
  String? _sceneError;
  String? _writeError;
  int _cardReadGeneration = 0;
  bool _backdropRestored = false;
  String? _savedBackgroundId;
  StageCaptionStyle _captionStyle = const StageCaptionStyle(docking: StageCaptionDocking.none);
  int _captionReadGeneration = 0;
  final _chatKey = GlobalKey<ChatScreenState>();
  void Function()? _unsubscribeSettingsEvents;
  final _stageRender = StageRenderState();
  bool _stageVisible = false;

  @override
  void initState() {
    super.initState();
    SettingsSearchShortcut.instance.install();
    _unsubscribeSettingsEvents = widget.client.onEvent(_onSettingsChanged);
    unawaited(_prepareScenes());
    unawaited(_loadCards());
    unawaited(_loadCaptionSettings());
  }

  @override
  void dispose() {
    _unsubscribeSettingsEvents?.call();
    SettingsSearchShortcut.instance.uninstall();
    _stageRender.dispose();
    super.dispose();
  }

  /// The event carries only a section name: re-read the caches that section
  /// feeds, never a value from the payload. Sections this shell does not
  /// render are left alone.
  void _onSettingsChanged(GatewayEventFrame event) {
    if (event.topic != EventTopic.settingsChanged) return;
    final section = event.data['section'];
    if (section is! String) return;
    switch (section) {
      case 'cards':
        unawaited(_loadCards());
      case 'captions':
        unawaited(_loadCaptionSettings());
    }
  }

  @override
  void didUpdateWidget(NavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sceneStorageDirectory != oldWidget.sceneStorageDirectory ||
        widget.sceneStorageDirectoryProvider !=
            oldWidget.sceneStorageDirectoryProvider) {
      unawaited(_prepareScenes());
    }
  }

  Future<void> _prepareScenes() async {
    Directory directory;
    try {
      directory =
          widget.sceneStorageDirectory ??
          await widget.sceneStorageDirectoryProvider();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _scenes = null;
        _sceneError = _sceneFailure(error);
      });
      return;
    }
    if (!mounted) return;
    await _loadScenes(StageSceneStore(storageDirectory: directory));
  }

  Future<void> _loadScenes(StageSceneStore store) async {
    if (!mounted) return;
    setState(() {
      _scenes = store;
      _backdropRestored = false;
      _sceneError = null;
    });
    try {
      await widget.sceneLibraryLoader(store);
    } on Object catch (error) {
      if (!mounted || !identical(_scenes, store)) return;
      setState(() => _sceneError = _sceneFailure(error));
      return;
    }
    if (!mounted || !identical(_scenes, store)) return;
    setState(() => _sceneError = null);
    unawaited(_restoreBackdropForSelectedCard());
  }

  String _sceneFailure(Object error) => error is StageSceneException
      ? error.message
      : 'The scene library could not be loaded: $error';
  Future<void> _loadCards() async {
    final generation = ++_cardReadGeneration;
    try {
      final cards = await widget.client.cardsList();
      final persistedId = await _daemonActiveCardId(widget.client);
      if (!mounted || generation != _cardReadGeneration) return;
      if (persistedId == '') _noCardExplicitlySelected = true;
      final id = _resolveSelectedCardId(cards, persistedId);
      if (!mounted || generation != _cardReadGeneration) return;
      setState(() {
        _cards = cards;
        _selectedCardId = id;
        _cardError = null;
      });
      await _restoreBackdropForSelectedCard();
    } on Object catch (error) {
      if (!mounted || generation != _cardReadGeneration) return;
      setState(() {
        _cardError = error is DaemonClientException
            ? error.message
            : 'The stage card list could not be loaded.';
      });
    }
  }

  /// The daemon's persisted choice wins when it names an available card.
  /// Without one, keep a still-valid local choice and otherwise fall back to
  /// the first card, as before. An explicit "No card" is always respected.
  String? _resolveSelectedCardId(
    List<Map<String, dynamic>> cards,
    String? persistedId,
  ) {
    if (cards.isEmpty || _noCardExplicitlySelected) return null;
    if (persistedId != null &&
        cards.any((card) => card['id'] == persistedId)) {
      return persistedId;
    }
    final current = _selectedCardId;
    if (current != null && cards.any((card) => card['id'] == current)) {
      return current;
    }
    return cards.first['id'] as String?;
  }

  /// Read the selected card document and seed the local scene store. Both
  /// startup orders (cards first or scene library first) converge here.
  Future<void> _restoreBackdropForSelectedCard() async {
    final store = _scenes;
    final cardId = _selectedCardId;
    if (store == null || cardId == null || _backdropRestored) return;
    try {
      final card = await widget.client.cardsGet(cardId);
      if (!mounted || !identical(store, _scenes) || _selectedCardId != cardId) {
        return;
      }
      if (card == null) return;
      final backgroundId = readCardActiveField(card, 'activeBackgroundId');
      _savedBackgroundId = backgroundId;
      if (backgroundId != null) {
        // A persisted id may name a scene the library has not loaded yet;
        // leave the flag clear so the load completion retries the seed.
        if (backgroundId != 'none' && store.entryFor(backgroundId) == null) {
          return;
        }
        store.seedActiveForCard(cardId, backgroundId);
      }
      _backdropRestored = true;
      if (mounted) setState(() {});
    } on Object {
      // The card read is best-effort: the card list already decided what to
      // render, and a missing document leaves the local scene selection alone.
    }
  }

  /// Record a successful daemon write, or surface a user-safe failure.
  Future<void> _runWrite(Future<void> Function() write) async {
    try {
      await write();
      if (mounted) setState(() => _writeError = null);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _writeError = userSafeConnectionError(
            error,
            context: 'stage:persist:',
          ));
    }
  }


  /// Persist a backdrop choice on the card and in this client's library.
  Future<void> _activateBackdrop(String cardId, String backgroundId) async {
    final store = _scenes;
    if (store == null) return;
    await _runWrite(() async {
      final card = await widget.client.cardsGet(cardId);
      if (card == null) {
        throw const DaemonClientException(
          kind: DaemonFailureKind.protocol,
          message: 'That card is no longer available.',
        );
      }
      final updated = withCardActiveField(card, 'activeBackgroundId', backgroundId);
      await widget.client.cardsUpdate(cardId, updated);
      await store.activateForCard(cardId, backgroundId);
      if (!mounted) return;
      setState(() {
        _cards = <Map<String, dynamic>>[
          for (final entry in _cards)
            entry['id'] == cardId ? updated : entry,
        ];
      });
    });
  }

  /// Persist a card choice in the daemon's `cards` settings section.
  Future<void> _persistActiveCard(String? cardId) async => _runWrite(() async {
    final settings = await widget.client.settingsGet(_cardsSettingsSection);
    await widget.client.settingsSet(_cardsSettingsSection, <String, dynamic>{
      ...settings,
      'activeCardId': cardId ?? '',
    });
  });

  /// Captions are daemon-owned settings; the stage only renders the snapshot.
  /// A failed or stale read leaves captions hidden (daemon default docking:none).
  Future<void> _loadCaptionSettings() async {
    final generation = ++_captionReadGeneration;
    try {
      final settings = await widget.client.settingsGet('captions');
      if (!mounted || generation != _captionReadGeneration || settings.isEmpty) {
        return;
      }
      setState(() => _captionStyle = StageCaptionStyle.fromSettings(settings));
    } on Object {
      // An unreachable daemon leaves captions hidden: the daemon default is
      // docking:none, never the client's visible bottom-docked fallback.
    }
  }

  void _setIndex(int index) {
    setState(() => _index = index);
    // The app-global chord acts only on the visible destination.
    SettingsSearchShortcut.instance.activeDestinationIndex = index;
  }

  void _selectStageDestination(int index) {
    _setIndex(index);
    setState(() {
      _stageVisible = index == 5;
      _stageRender.setPaused(!_stageVisible);
    });
    if (index == 1 || index == 5) {
      unawaited(_loadCards());
      unawaited(_loadCaptionSettings());
    }
    if (index == 1) unawaited(_chatKey.currentState?.reload());
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(client: widget.client),
      ChatScreen(key: _chatKey, client: widget.client),
      SettingsScreen(
        client: widget.client,
        onOpenConnections: () => _setIndex(3),
        onSearchReady: (focus, close) =>
            SettingsSearchShortcut.instance.bindSearch(focus: focus, close: close),
        onSearchDisposed: SettingsSearchShortcut.instance.unbindSearch,
      ),
      ConnectionsScreen(client: widget.client),
      const AboutScreen(),
      TickerMode(enabled: _stageVisible, child: _buildStage()),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Anima'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ConnectionBadge(client: widget.client),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _selectStageDestination,
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: const Icon(Icons.space_dashboard_outlined),
            selectedIcon: const Icon(Icons.space_dashboard),
            label: AppLocalizations.of(context)!.navControl,
          ),
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: AppLocalizations.of(context)!.navChat,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: AppLocalizations.of(context)!.navSettings,
          ),
          NavigationDestination(
            icon: const Icon(Icons.link_off),
            selectedIcon: const Icon(Icons.link),
            label: AppLocalizations.of(context)!.navConnections,
          ),
          NavigationDestination(
            icon: const Icon(Icons.info_outline),
            selectedIcon: const Icon(Icons.info),
            label: AppLocalizations.of(context)!.navAbout,
          ),
          NavigationDestination(
            icon: const Icon(Icons.landscape_outlined),
            selectedIcon: const Icon(Icons.landscape),
            label: AppLocalizations.of(context)!.navStage,
          ),
        ],
      ),
    );
  }

  Widget _buildStage() {
    final cardError = _cardError;
    final sceneError = _sceneError;
    final writeError = _writeError;
    final store = _scenes;
    return Column(
      children: <Widget>[
        if (cardError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              cardError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (sceneError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              sceneError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (writeError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              writeError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: <Widget>[
              Text('Card', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: _selectedCardId,
                  hint: const Text('No card'),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No card'),
                    ),
                    for (final card in _cards)
                      DropdownMenuItem<String?>(
                        value: card['id'] as String?,
                        child: Text(
                          card['name'] is String
                              ? card['name'] as String
                              : '${card['id']}',
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    _cardReadGeneration++;
                    _savedBackgroundId = null;
                    setState(() {
                      _selectedCardId = value;
                      _noCardExplicitlySelected = value == null;
                      _backdropRestored = false;
                    });
                    unawaited(_persistActiveCard(value));
                    unawaited(_restoreBackdropForSelectedCard());
                  },
                ),
              ),
              IconButton(
                tooltip: 'Manage scenes',
                icon: const Icon(Icons.landscape_outlined),
                onPressed: store == null
                    ? null
                    : () {
                        final cardId = _selectedCardId;
                        var activated = false;
                        final route = Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (context) => StageScenesScreen(
                              store: store,
                              cardId: cardId,
                              onChanged: () {
                                setState(() {});
                                if (cardId == null) return;
                                final current = store.activeForCard(cardId);
                                final saved = _savedBackgroundId;
                                if (current != saved) {
                                  activated = true;
                                  _savedBackgroundId = current;
                                  unawaited(_activateBackdrop(
                                    cardId,
                                    current ?? 'none',
                                  ));
                                }
                              },
                            ),
                          ),
                        );
                        unawaited(route.whenComplete(() {
                          if (!mounted) return;
                          if (activated) {
                            setState(() {});
                            return;
                          }
                          setState(() => _backdropRestored = false);
                          unawaited(_restoreBackdropForSelectedCard());
                        }));
                      },
              ),
            ],
          ),
        ),
        Expanded(
          child: StageScreen(
            client: widget.client,
            frames: widget.lipSyncFrames,
            cardId: _selectedCardId,
            boundSessionId: _chatKey.currentState?.activeSessionId,
            background: store?.activeBackgroundFor(_selectedCardId) ??
                StageBackground.none,
            captionStyle: _captionStyle,
            render: _stageRender,
            paused: !_stageVisible,
          ),
        ),
      ],
    );
  }
}
