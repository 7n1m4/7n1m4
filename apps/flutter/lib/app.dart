// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'daemon_client/daemon_client.dart';
import 'l10n/app_localizations.dart';
import 'navigation/navigation_shell.dart';
import 'theme/app_theme.dart';

class AnimaApp extends StatelessWidget {
  const AnimaApp({super.key, required this.client, this.lipSync = const SizedBox.shrink()});

  final DaemonClient client;

  /// Optional renderer surface wired at app entry (client-local lip_sync).
  final Widget lipSync;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Anima',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('en')],
      home: Column(
        children: <Widget>[
          Expanded(child: NavigationShell(client: client)),
          lipSync,
        ],
      ),
    );
  }
}
