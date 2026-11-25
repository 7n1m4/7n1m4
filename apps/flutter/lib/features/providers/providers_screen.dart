// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';

/// Read-only projection of a provider row. Only allowlisted metadata from
/// `providers.list` reaches the widget tree: credentials never do.
class _ProviderRow {
  const _ProviderRow({
    required this.id,
    required this.kind,
    required this.model,
    required this.baseUrl,
    required this.enabled,
  });

  factory _ProviderRow.fromJson(Map<String, dynamic> json) => _ProviderRow(
        id: (json['id'] ?? '').toString(),
        kind: (json['kind'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        baseUrl: (json['baseUrl'] ?? json['base_url'] ?? '').toString(),
        enabled: json['enabled'] == true,
      );

  final String id;
  final String kind;
  final String model;
  final String baseUrl;
  final bool enabled;
}

// Mirrors `anima_store::ProviderKind`, which rejects any other tag.
const List<String> _providerKinds = <String>[
  'open-ai-compatible',
  'anthropic',
  'google-gemini',
  'aws-bedrock',
  'local-server',
];

class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  String _kind = _providerKinds.first;
  final TextEditingController _id = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();

  List<_ProviderRow> _providers = const <_ProviderRow>[];
  bool _loading = true;
  bool _busy = false;
  bool _enabled = true;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _id.dispose();
    _model.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  /// A non-ok reply is promoted to an exception so no mutation path can
  /// silently report success or lose the daemon's error text.
  Future<RpcReply> _call(String action, {Map<String, dynamic>? payload}) async {
    final reply = await widget.client.call(action, payload: payload);
    if (!reply.ok) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: reply.error?.message ?? '$action failed.',
        code: reply.error?.code,
      );
    }
    return reply;
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final reply = await _call('providers.list');
      final data = reply.data;
      final list = data is Map ? data['providers'] : null;
      final rows = <_ProviderRow>[];
      if (list is List) {
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            rows.add(_ProviderRow.fromJson(item));
          }
        }
      }
      if (mounted) setState(() => _providers = rows);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() {
        _error = e.message;
        _status = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = e.toString();
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _mutate(
    String action,
    Map<String, dynamic> payload,
    void Function(Object? data) onSuccess,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final reply = await _call(action, payload: payload);
      if (mounted) setState(() => onSuccess(reply.data));
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final id = _id.text.trim();
    final kind = _kind;
    if (id.isEmpty || kind.isEmpty) {
      setState(() {
        _error = 'Provider id and kind are required.';
        _status = null;
      });
      return;
    }
    final payload = <String, dynamic>{
      'id': id,
      'kind': kind,
      'model': _model.text.trim(),
      'baseUrl': _baseUrl.text.trim(),
      'enabled': _enabled,
    };
    // Write-only: never prefill this field from a list reply, never echo it.
    // The daemon keeps a stored credential unless rotation is opted into,
    // so only a typed key rotates.
    if (_apiKey.text.isNotEmpty) {
      payload['apiKey'] = _apiKey.text;
      payload['rotateSecrets'] = true;
    }
    await _mutate('providers.save', payload, (data) {
      final savedId = (data is Map ? data['id'] : null)?.toString() ?? id;
      _status = 'Saved provider $savedId';
      _apiKey.clear();
    });
  }

  Future<void> _delete() async {
    final id = _id.text.trim();
    if (id.isEmpty) {
      setState(() {
        _error = 'Provider id is required.';
        _status = null;
      });
      return;
    }
    await _mutate('providers.delete', <String, dynamic>{'id': id}, (_) {
      _status = 'Deleted provider $id';
      _clearForm();
    });
  }

  /// Partial update: the daemon keeps stored credentials when a save omits
  /// them, so toggling enabled must never send a (possibly empty) key.
  /// It omits `rotateSecrets` too, so a toggle never rotates the stored credential.
  Future<void> _setEnabled(_ProviderRow row, bool enabled) async {
    await _mutate('providers.save', <String, dynamic>{
      'id': row.id,
      'kind': row.kind,
      'enabled': enabled,
    }, (_) {
      _status = '${enabled ? 'Enabled' : 'Disabled'} provider ${row.id}';
    });
  }

  void _clearForm() {
    _id.clear();
    _kind = _providerKinds.first;
    _model.clear();
    _baseUrl.clear();
    _apiKey.clear();
    _enabled = true;
  }

  void _edit(_ProviderRow row) {
    setState(() {
      _id.text = row.id;
      _kind = _providerKinds.contains(row.kind) ? row.kind : _providerKinds.first;
      _model.text = row.model;
      _baseUrl.text = row.baseUrl;
      _apiKey.clear();
      _enabled = row.enabled;
      _error = null;
      _status = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Providers'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(_error!, style: TextStyle(color: colorScheme.error)),
                  if (_status != null) Text(_status!),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TextField(
                            controller: _id,
                            decoration: const InputDecoration(labelText: 'Provider ID'),
                          ),
                          DropdownButtonFormField<String>(
                            value: _kind,
                            decoration: const InputDecoration(labelText: 'Kind'),
                            items: <DropdownMenuItem<String>>[
                              for (final kind in _providerKinds)
                                DropdownMenuItem<String>(value: kind, child: Text(kind)),
                            ],
                            onChanged: (value) => setState(() => _kind = value ?? _providerKinds.first),
                          ),
                          TextField(
                            controller: _model,
                            decoration: const InputDecoration(labelText: 'Model'),
                          ),
                          TextField(
                            controller: _baseUrl,
                            decoration: const InputDecoration(labelText: 'Base URL'),
                          ),
                          TextField(
                            controller: _apiKey,
                            obscureText: true,
                            decoration: const InputDecoration(labelText: 'API key (write-only)'),
                          ),
                          CheckboxListTile(
                            title: const Text('Enabled'),
                            value: _enabled,
                            onChanged: (value) => setState(() => _enabled = value ?? false),
                          ),
                          Row(
                            children: <Widget>[
                              FilledButton(
                                onPressed: _busy ? null : _save,
                                child: const Text('Save'),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _busy ? null : _delete,
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_providers.isEmpty && _error == null)
                    const ListTile(title: Text('No providers configured')),
                  for (final row in _providers)
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ListTile(
                            title: Text(row.id),
                            subtitle: Text(
                              '${row.kind} · ${row.model}'
                              '${row.baseUrl.isEmpty ? '' : ' · ${row.baseUrl}'}'
                              ' · ${row.enabled ? 'enabled' : 'disabled'}',
                            ),
                          ),
                          ButtonBar(
                            children: <Widget>[
                              TextButton(
                                onPressed: () => _edit(row),
                                child: const Text('Edit'),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _setEnabled(row, !row.enabled),
                                child: Text(row.enabled ? 'Disable' : 'Enable'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
