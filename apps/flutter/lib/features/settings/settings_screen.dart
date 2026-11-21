// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../cards/cards_screen.dart';
import '../memory/memory_screen.dart';
import '../providers/providers_screen.dart';
import '../sessions/sessions_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.onOpenConnections,
  });

  final DaemonClient client;
  final VoidCallback onOpenConnections;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('Connection'),
          subtitle: const Text('Host, port, scheme and auth token'),
          onTap: onOpenConnections,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.extension_outlined),
          title: const Text('Providers'),
          subtitle: const Text('LLM providers via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ProvidersScreen(client: client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Memory'),
          subtitle: const Text('Memory stats via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => MemoryScreen(client: client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Cards'),
          subtitle: const Text('Cards settings via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => CardsScreen(client: client)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.forum_outlined),
          title: const Text('Sessions'),
          subtitle: const Text('Session/message counts via daemon RPC'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => SessionsScreen(client: client)),
          ),
        ),
      ],
    );
  }
}
