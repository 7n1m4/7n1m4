// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'daemon_client/daemon_client.dart';
import 'l10n/app_localizations.dart';
import 'navigation/navigation_shell.dart';
import 'speech/lip_sync_rms_data.dart';
import 'theme/app_theme.dart';

class AnimaApp extends StatefulWidget {
  const AnimaApp({
    super.key,
    required this.client,
    this.lipSync = const SizedBox.shrink(),
    this.lipSyncFrames,
    this.sceneStorageDirectory,
    SceneStorageDirectoryProvider? sceneStorageDirectoryProvider,
  }) : sceneStorageDirectoryProvider =
           sceneStorageDirectoryProvider ?? defaultSceneStorageDirectory;

  final DaemonClient client;

  /// Optional renderer surface wired at app entry (client-local lip_sync).
  final Widget lipSync;

  /// Optional stream of lip-sync RMS frames for the navigation shell.
  final Stream<LipSyncRmsData>? lipSyncFrames;

  /// Optional client-local scene library directory (tests only).
  final Directory? sceneStorageDirectory;

  /// Resolves the production scene library directory.
  final SceneStorageDirectoryProvider sceneStorageDirectoryProvider;

  @override
  State<AnimaApp> createState() => _AnimaAppState();
}

class _AnimaAppState extends State<AnimaApp> {
  // Until the daemon replies we use its own serde defaults, not a fabricated
  // palette. The daemon is the only owner of this section.
  ThemeData _theme = AppTheme.fromParsed(AppThemeSettings.daemonDefaults);
  StreamSubscription<DaemonStatus>? _statusSub;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.client.snapshot.isConnected;
    _statusSub = widget.client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      if (connected && !_wasConnected) unawaited(_loadTheme());
      _wasConnected = connected;
    });
    unawaited(_loadTheme());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _loadTheme() async {
    try {
      final settings = await widget.client.settingsGet('theme');
      if (!mounted) return;
      setState(() => _theme = AppTheme.fromSettings(settings));
    } catch (_) {
      // An unreachable daemon leaves its defaults in place. Never write a
      // local fallback back: the daemon owns this section.
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anima',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('en')],
      home: Column(
        children: <Widget>[
          Expanded(
            child: NavigationShell(
              client: widget.client,
              lipSyncFrames: widget.lipSyncFrames,
              sceneStorageDirectory: widget.sceneStorageDirectory,
              sceneStorageDirectoryProvider:
                  widget.sceneStorageDirectoryProvider,
            ),
          ),
          widget.lipSync,
        ],
      ),
    );
  }
}
