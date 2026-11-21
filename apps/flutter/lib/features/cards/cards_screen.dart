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
  final TextEditingController _controller = TextEditingController();
  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  Map<String, dynamic>? _detail;
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      _status = null;
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

  Future<void> _import() async {
    Object? parsed;
    try {
      parsed = jsonDecode(_controller.text);
    } catch (e) {
      setState(() => _error = 'Invalid card JSON: $e');
      return;
    }
    if (parsed is! Map<String, dynamic>) {
      setState(() => _error = 'Card JSON must be an object');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await widget.client.cardsImport(parsed);
      if (mounted) setState(() => _status = 'Card import accepted');
      await _load();
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
                if (_error != null)
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (_status != null) Text(_status!),
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
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Card JSON to import',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_upload),
                  label: const Text('Import card'),
                ),
              ],
            ),
    );
  }
}
