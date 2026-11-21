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
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final reply = await widget.client.call('settings.get', payload: {'section': 'cards'});
      if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'settings.get failed');
        return;
      }
      final data = reply.data;
      if (data is Map<String, dynamic>) {
        _controller.text = data['settings']?.toString() ?? '';
      }
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      Object? parsed;
      try {
        parsed = jsonDecode(_controller.text);
      } catch (_) {
        parsed = _controller.text;
      }
      final reply = await widget.client.call(
        'settings.set',
        payload: {'section': 'cards', 'settings': parsed},
      );
      if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'settings.set failed');
        return;
      }
      setState(() => _status = 'Saved');
    } on DaemonClientException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cards'),
        actions: <Widget>[
          IconButton(onPressed: _busy ? null : _save, icon: const Icon(Icons.save)),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  if (_status != null) Text(_status!),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Cards settings (JSON)',
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
