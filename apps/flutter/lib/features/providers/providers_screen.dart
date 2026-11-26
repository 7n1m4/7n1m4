// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../../connection/connection_error.dart';
import '../../ui/loading_placeholder.dart';

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

class _ProviderModel {
  const _ProviderModel({required this.id, this.ownedBy});

  factory _ProviderModel.fromJson(Map<String, dynamic> json) => _ProviderModel(
        id: (json['id'] ?? '').toString(),
        ownedBy: json['ownedBy']?.toString() ?? json['owned_by']?.toString(),
      );

  final String id;
  final String? ownedBy;
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
  const ProvidersScreen({super.key, required this.client, this.initialProviderId});
  final DaemonClient client;

  /// Provider to select on arrival (the tail of a provider deep link). The
  /// matching row is loaded into the existing edit form, like an Edit tap.
  final String? initialProviderId;

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
  String? _modelsProviderId;
  Map<String, List<_ProviderModel>> _modelsByProvider = const {};
  bool _modelsLoading = false;
  String? _modelsError;
  bool _initialTargetApplied = false;

  // Daemon-owned selection, mirrored in this widget only as read-only UI
  // state. Writes go through `settings.set` on the daemon, never local storage.
  static const String _activeSection = 'chat-provider';
  String _activeProvider = '';
  String _activeModel = '';
  String? _activeProviderId;
  String? _activeModelId;
  bool _activeSaving = false;

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

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final providers = await widget.client.providersList();
      final rows = <_ProviderRow>[];
      for (final item in providers) {
        rows.add(_ProviderRow.fromJson(item));
      }
      final activeReply = await widget.client.call('settings.get', payload: <String, dynamic>{
        'section': _activeSection,
      });
      if (!activeReply.ok) {
        throw DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: activeReply.error?.message ?? 'settings.get failed.',
          code: activeReply.error?.code,
        );
      }
      final replyData = activeReply.data;
      final rawActive = replyData is Map ? replyData['settings'] : null;
      Map<String, dynamic> active = const <String, dynamic>{};
      if (rawActive is String) {
        try {
          final decoded = jsonDecode(rawActive);
          if (decoded is Map<String, dynamic>) active = decoded;
        } on FormatException {
          active = const <String, dynamic>{};
        }
      } else if (rawActive is Map<String, dynamic>) {
        active = rawActive;
      }
      if (mounted) {
        setState(() {
          _providers = rows;
          _activeProvider = (active['activeProvider'] ?? '').toString();
          _activeModel = (active['activeModel'] ?? '').toString();
          _activeProviderId = _activeProvider.isEmpty ? null : _activeProvider;
          _activeModelId = _activeModel.isEmpty ? null : _activeModel;
        });
        if (_activeProvider.isNotEmpty) _loadActiveModels(_activeProvider);
        final target = widget.initialProviderId;
        if (!_initialTargetApplied && target != null && target.isNotEmpty) {
          for (final row in rows) {
            if (row.id == target) {
              _edit(row);
              _initialTargetApplied = true;
              break;
            }
          }
        }
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() {
        _error = userSafeConnectionError(e, context: 'providers.list:');
        _status = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = userSafeConnectionError(e, context: 'providers.list:');
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Run a mutation through its typed wrapper, surface a sanitized error on
  /// failure, then refresh the list. [onSuccess] receives the wrapper's typed
  /// result (a saved id or a deleted flag).
  Future<void> _mutate(
    String context,
    Future<Object?> Function() action,
    void Function(Object? data) onSuccess,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final data = await action();
      if (mounted) setState(() => onSuccess(data));
      await _load();
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = userSafeConnectionError(e, context: context));
    } catch (e) {
      if (mounted) setState(() => _error = userSafeConnectionError(e, context: context));
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
    await _mutate('providers.save:', () async {
      final savedId = await widget.client.providersSave(payload);
      // A save that the daemon cannot resolve into a usable model is not a
      // success: surface the validation error rather than an optimistic
      // 'Saved' message on top of a broken row.
      await widget.client.providersModels(savedId);
      return savedId;
    }, (data) {
      final savedId = data?.toString() ?? id;
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
    await _mutate('providers.delete:', () => widget.client.providersDelete(id), (_) {
      _status = 'Deleted provider $id';
      _clearForm();
    });
  }

  /// Partial update: the daemon keeps stored credentials when a save omits
  /// them, so toggling enabled must never send a (possibly empty) key.
  /// It omits `rotateSecrets` too, so a toggle never rotates the stored credential.
  Future<void> _setEnabled(_ProviderRow row, bool enabled) async {
    await _mutate('providers.save:', () => widget.client.providersSave(<String, dynamic>{
      'id': row.id,
      'kind': row.kind,
      'enabled': enabled,
    }), (_) {
      _status = '${enabled ? 'Enabled' : 'Disabled'} provider ${row.id}';
    });
  }

  void _onActiveProviderChanged(String? id) {
    setState(() {
      _activeProviderId = id;
      _activeModelId = null;
    });
    if (id != null) _loadActiveModels(id);
  }

  Future<void> _loadActiveModels(String id) async {
    setState(() {
      _modelsLoading = true;
      _modelsError = null;
      _modelsProviderId = id;
    });
    try {
      final (_, modelsReply) = await widget.client.providersModels(id);
      if (mounted) {
        setState(() {
          _modelsByProvider = <String, List<_ProviderModel>>{
            ..._modelsByProvider,
            id: modelsReply.map(_ProviderModel.fromJson).toList(),
          };
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _modelsError = userSafeConnectionError(e, context: 'providers.models:'));
    } catch (e) {
      if (mounted) setState(() => _modelsError = userSafeConnectionError(e, context: 'providers.models:'));
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  Future<void> _saveActiveSelection() async {
    final providerId = _activeProviderId ?? '';
    final model = _activeModelId ?? '';
    setState(() {
      _busy = true;
      _activeSaving = true;
      _error = null;
      _status = null;
    });
    try {
      final ok = await widget.client.settingsSet(_activeSection, <String, dynamic>{
        'activeProvider': providerId,
        'activeModel': model,
      });
      if (mounted) {
        setState(() {
          if (ok) {
            _activeProvider = providerId;
            _activeModel = model;
            _status = providerId.isEmpty
                ? 'Cleared chat provider selection'
                : 'Chat provider: $providerId${model.isEmpty ? '' : ' · $model'}';
          } else {
            _error = 'Could not save the active chat provider.';
          }
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = userSafeConnectionError(e, context: 'settings.set:'));
    } catch (e) {
      if (mounted) setState(() => _error = userSafeConnectionError(e, context: 'settings.set:'));
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _activeSaving = false;
      });
    }
  }

  Future<void> _loadModels(_ProviderRow row) async {
    setState(() {
      _modelsLoading = true;
      _modelsError = null;
      _modelsProviderId = row.id;
    });
    try {
      final models = <_ProviderModel>[];
      final (_, modelsReply) = await widget.client.providersModels(row.id);
      for (final item in modelsReply) {
        models.add(_ProviderModel.fromJson(item));
      }
      if (mounted) {
        setState(() {
          _modelsByProvider = <String, List<_ProviderModel>>{
            ..._modelsByProvider,
            row.id: models,
          };
        });
      }
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _modelsError = userSafeConnectionError(e, context: 'providers.models:'));
    } catch (e) {
      if (mounted) setState(() => _modelsError = userSafeConnectionError(e, context: 'providers.models:'));
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
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
          ? LoadingPlaceholder(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  for (final height in <double>[320, 180, 96, 96])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorScheme.onSurface.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SizedBox(height: height, width: double.infinity),
                      ),
                    ),
                ],
              ),
            )
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
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const Text('Active chat provider', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            value: _activeProviderId,
                            decoration: const InputDecoration(labelText: 'Provider for chat'),
                            hint: const Text('Automatic (first enabled)'),
                            items: <DropdownMenuItem<String>>[
                              const DropdownMenuItem<String>(value: null, child: Text('Automatic (first enabled)')),
                              if (_activeProviderId != null &&
                                  !_providers.any((p) => p.enabled && p.id == _activeProviderId))
                                DropdownMenuItem<String>(
                                  value: _activeProviderId,
                                  child: Text('$_activeProviderId (unavailable)'),
                                ),
                              for (final row in _providers.where((p) => p.enabled))
                                DropdownMenuItem<String>(value: row.id, child: Text(row.id)),
                            ],
                            onChanged: _busy ? null : _onActiveProviderChanged,
                          ),
                          DropdownButtonFormField<String>(
                            value: _activeModelId,
                            decoration: const InputDecoration(labelText: 'Model for chat'),
                            hint: const Text('Provider default'),
                            items: <DropdownMenuItem<String>>[
                              const DropdownMenuItem<String>(value: null, child: Text('Provider default')),
                              if (_activeModelId != null &&
                                  !(_modelsByProvider[_activeProviderId] ?? const <_ProviderModel>[])
                                      .any((m) => m.id == _activeModelId))
                                DropdownMenuItem<String>(value: _activeModelId, child: Text(_activeModelId!)),
                              for (final model in _modelsByProvider[_activeProviderId] ?? const <_ProviderModel>[])
                                DropdownMenuItem<String>(value: model.id, child: Text(model.id)),
                            ],
                            onChanged: _busy || _activeProviderId == null
                                ? null
                                : (value) => setState(() => _activeModelId = value),
                          ),
                          if (_modelsLoading && _modelsProviderId == _activeProviderId)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(),
                            ),
                          if (_modelsError != null && _modelsProviderId == _activeProviderId)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_modelsError!, style: TextStyle(color: colorScheme.error)),
                            ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: _busy || _activeSaving ? null : _saveActiveSelection,
                            child: const Text('Use for chat'),
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
                          OutlinedButton(
                            onPressed: _busy || _modelsLoading ? null : () => _loadModels(row),
                            child: const Text('Models'),
                          ),
                          if (_modelsError != null)
                            Text(_modelsError!, style: TextStyle(color: colorScheme.error)),
                          if (_modelsLoading && _modelsProviderId == row.id)
                            const Padding(
                              padding: EdgeInsets.all(8),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          else
                            for (final model in _modelsByProvider[row.id] ?? const <_ProviderModel>[])
                              ListTile(
                                title: Text(model.id),
                                subtitle: model.ownedBy == null || model.ownedBy!.isEmpty
                                    ? null
                                    : Text(model.ownedBy!),
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
