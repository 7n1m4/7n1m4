// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  Map<String, dynamic>? _detail;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cards = await widget.client.cardsList();
      if (mounted) setState(() => _cards = cards);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String id) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final card = await widget.client.cardsGet(id);
      if (mounted) setState(() => _detail = card);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cards'),
        actions: <Widget>[
          IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                // Cards are explicitly out of scope for the local daemon
                // port: card verbs return a not-implemented error. Never show
                // a false "import succeeded" state here.
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Card management is not available on the local daemon.'),
                  ),
                ),
                const SizedBox(height: 8),
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const ListTile(title: Text('Cards'), dense: true),
                if (_cards.isEmpty)
                  const ListTile(title: Text('No cards available'), dense: true)
                else
                  for (final c in _cards)
                    ListTile(
                      title: Text((c['name'] as String?) ?? (c['id'] as String?) ?? ''),
                      subtitle: Text((c['id'] as String?) ?? ''),
                      onTap: () => _open((c['id'] as String?) ?? ''),
                    ),
                if (_detail != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(jsonEncode(_detail)),
                    ),
                  ),
              ],
            ),
    );
  }
}
