// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:anima_control/speech/lip_sync_rms_data.dart';

import '../daemon_client/daemon_client.dart';
import '../l10n/app_localizations.dart';
import '../features/about/about_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/connections/connections_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/stage/stage_scene_manager.dart';
import '../features/stage/stage_scenes_screen.dart';
import '../features/stage/stage_screen.dart';
import '../ui/status_bits.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_prepareScenes());
    unawaited(_loadCards());
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
  }

  String _sceneFailure(Object error) => error is StageSceneException
      ? error.message
      : 'The scene library could not be loaded: $error';

  Future<void> _loadCards() async {
    try {
      final cards = await widget.client.cardsList();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        final current = _selectedCardId;
        if (cards.isEmpty) {
          _selectedCardId = null;
        } else if (_noCardExplicitlySelected) {
          // An explicit "No card" is a choice, not a missing selection.
          _selectedCardId = null;
        } else if (current == null ||
            !cards.any((card) => card['id'] == current)) {
          _selectedCardId = cards.first['id'] as String?;
        }
        _cardError = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _cardError = error is DaemonClientException
            ? error.message
            : 'The stage card list could not be loaded.';
      });
    }
  }

  void _selectStageDestination(int index) {
    setState(() => _index = index);
    if (index == 5) unawaited(_loadCards());
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(client: widget.client),
      ChatScreen(client: widget.client),
      SettingsScreen(
        client: widget.client,
        onOpenConnections: () => setState(() => _index = 3),
      ),
      ConnectionsScreen(client: widget.client),
      const AboutScreen(),
      _buildStage(),
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
                  onChanged: (value) => setState(() {
                    _selectedCardId = value;
                    _noCardExplicitlySelected = value == null;
                  }),
                ),
              ),
              IconButton(
                tooltip: 'Manage scenes',
                icon: const Icon(Icons.landscape_outlined),
                onPressed: store == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => StageScenesScreen(
                            store: store,
                            onChanged: () => setState(() {}),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StageScreen(
            client: widget.client,
            frames: widget.lipSyncFrames,
            cardId: _selectedCardId,
            background: store?.activeBackground,
          ),
        ),
      ],
    );
  }
}
