// SPDX-License-Identifier: GPL-3.0-or-later

// Companion Connectors settings surface. Every card here maps 1:1 to a
// section registered in `settings_section()` in the daemon core; reads and
// writes go through `settings.get` / `settings.set`. Unrelated keys in a
// section round-trip untouched. Integration modules with no daemon section
// keep an honest, narrow notice instead of client-only state that looks saved.

import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';
import 'discord_settings_patch.dart';

enum _FieldKind {
  text,
  number,
  integer,
  boolean,
  choice,
  jsonList,
  jsonMap,
  hearingDeviceMap,
}

class _ModuleField {
  const _ModuleField(
    this.key,
    this.label, {
    required this.kind,
    this.options = const <String>[],
    this.maxLines = 1,
  });

  final String key;
  final String label;
  final _FieldKind kind;
  final List<String> options;
  final int maxLines;
}

class _ModuleSection {
  const _ModuleSection(this.key, this.label, this.icon, this.fields);

  final String key;
  final String label;
  final IconData icon;
  final List<_ModuleField> fields;
}

/// Sections editable on this screen, in display order.
///
/// Every key must match a registration in `settings_section()` in
/// `crates/anima-daemon/src/core.rs`.
const List<_ModuleSection> _sections = <_ModuleSection>[
  _ModuleSection(
    'audio-device',
    'Audio device',
    Icons.hearing_outlined,
    <_ModuleField>[
      _ModuleField(
        'selectedInputDevice',
        'Input device ID (empty = default)',
        kind: _FieldKind.text,
      ),
      _ModuleField(
        'selectedOutputDevice',
        'Output device ID (empty = default)',
        kind: _FieldKind.text,
      ),
      _ModuleField(
        'inputEnabled',
        'Microphone input enabled',
        kind: _FieldKind.boolean,
      ),
    ],
  ),
  _ModuleSection(
    'local-llm',
    'Local LLM',
    Icons.memory_outlined,
    <_ModuleField>[
      _ModuleField(
        'modelPath',
        'GGUF model path (empty = not configured)',
        kind: _FieldKind.text,
      ),
      _ModuleField(
        'contextSize',
        'Context size (tokens)',
        kind: _FieldKind.integer,
      ),
      _ModuleField('temperature', 'Temperature', kind: _FieldKind.number),
      _ModuleField('maxTokens', 'Max tokens', kind: _FieldKind.integer),
      _ModuleField(
        'gpuLayers',
        'GPU layers (0 = CPU, negative = offload all)',
        kind: _FieldKind.integer,
      ),
    ],
  ),
  _ModuleSection(
    'consciousness',
    'Consciousness',
    Icons.psychology_outlined,
    <_ModuleField>[
      _ModuleField(
        'activeProvider',
        'Active provider ID',
        kind: _FieldKind.text,
      ),
      _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
      _ModuleField(
        'activeCustomModel',
        'Custom model name',
        kind: _FieldKind.text,
      ),
    ],
  ),
  _ModuleSection(
    'speech',
    'Speech',
    Icons.record_voice_over_outlined,
    <_ModuleField>[
      _ModuleField(
        'activeProvider',
        'Active provider ID',
        kind: _FieldKind.text,
      ),
      _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
      _ModuleField('voice', 'Voice ID', kind: _FieldKind.text),
      _ModuleField('outputVolume', 'Output volume', kind: _FieldKind.number),
      _ModuleField('enabled', 'Speech enabled', kind: _FieldKind.boolean),
      _ModuleField('pitch', 'Pitch', kind: _FieldKind.number),
      _ModuleField('rate', 'Rate', kind: _FieldKind.number),
      _ModuleField('ssmlEnabled', 'SSML enabled', kind: _FieldKind.boolean),
      _ModuleField('language', 'Language', kind: _FieldKind.text),
      _ModuleField(
        'voiceProfiles',
        'Voice profiles (JSON array)',
        kind: _FieldKind.jsonList,
        maxLines: 3,
      ),
    ],
  ),
  _ModuleSection('hearing', 'Hearing', Icons.hearing_outlined, <_ModuleField>[
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField(
      'activeCustomModel',
      'Custom model name',
      kind: _FieldKind.text,
    ),
    _ModuleField(
      'autoSendEnabled',
      'Auto-send recognized speech',
      kind: _FieldKind.boolean,
    ),
    _ModuleField(
      'autoSendDelay',
      'Auto-send delay (ms)',
      kind: _FieldKind.integer,
    ),
    _ModuleField(
      'detectionMode',
      'Detection mode',
      kind: _FieldKind.choice,
      options: <String>['vad', 'manual'],
    ),
    _ModuleField('tapToTalk', 'Tap-to-talk', kind: _FieldKind.boolean),
    _ModuleField(
      'voiceInputMode',
      'Voice input mode',
      kind: _FieldKind.choice,
      options: <String>['dictation', 'voice-message'],
    ),
    _ModuleField('vadThreshold', 'VAD threshold', kind: _FieldKind.number),
    _ModuleField(
      'speechProviderSettings',
      'Speech provider settings',
      kind: _FieldKind.hearingDeviceMap,
    ),
    _ModuleField(
      'transcriptionProviderSettings',
      'Transcription provider settings',
      kind: _FieldKind.hearingDeviceMap,
    ),
  ]),
  _ModuleSection('vision', 'Vision', Icons.visibility_outlined, <_ModuleField>[
    _ModuleField(
      'strategy',
      'Strategy',
      kind: _FieldKind.choice,
      options: <String>['direct', 'forward'],
    ),
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField(
      'contextWindow',
      'Images in context',
      kind: _FieldKind.integer,
    ),
    _ModuleField(
      'activeAdvanced',
      'Advanced options (JSON object)',
      kind: _FieldKind.jsonMap,
      maxLines: 3,
    ),
    _ModuleField(
      'promptShim',
      'Direct prompt',
      kind: _FieldKind.text,
      maxLines: 3,
    ),
    _ModuleField(
      'promptShimForward',
      'Forward prompt',
      kind: _FieldKind.text,
      maxLines: 3,
    ),
    _ModuleField(
      'witnessEnabled',
      'Ambient vision (witness)',
      kind: _FieldKind.boolean,
    ),
    _ModuleField(
      'witnessPrompt',
      'Witness prompt',
      kind: _FieldKind.text,
      maxLines: 3,
    ),
    _ModuleField(
      'respectSchedule',
      'Respect heartbeat schedule',
      kind: _FieldKind.boolean,
    ),
  ]),
];

/// One loaded section: the daemon's own map plus the user's edits.
/// `values` starts as the loaded map, so a save round-trips every key this
/// screen does not edit (including future/unknown keys).
class _SectionDraft {
  _SectionDraft(this.values) : loaded = true;

  _SectionDraft.unavailable()
    : values = const <String, dynamic>{},
      loaded = false;

  Map<String, dynamic> values;
  bool loaded;
}

class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key, required this.client});

  final DaemonClient client;

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final Map<String, GlobalKey> _cardKeys = <String, GlobalKey>{
    for (final section in _sections) section.key: GlobalKey(),
  };
  final Map<String, _SectionDraft> _drafts = <String, _SectionDraft>{
    for (final section in _sections) section.key: _SectionDraft.unavailable(),
  };

  /// Raw row IDs, kept so duplicate keys can be rejected before the emitted
  /// map silently collapses them and drops a user-entered row.
  final Map<String, List<String>> _hearingProviderIds =
      <String, List<String>>{};
  bool _busy = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    for (final section in _sections) {
      for (final field in section.fields) {
        if (_isTextLike(field.kind)) {
          _controllers[fieldId(section.key, field)] = TextEditingController();
        }
      }
    }
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static bool _isTextLike(_FieldKind kind) => switch (kind) {
    _FieldKind.text ||
    _FieldKind.number ||
    _FieldKind.integer ||
    _FieldKind.jsonList ||
    _FieldKind.jsonMap => true,
    _ => false,
  };

  static String fieldId(String section, _ModuleField field) =>
      'modules-$section-${field.key}';

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // One read per registered section, isolated so one failed load cannot
    // erase the sections that did load. Errors are sanitized before display:
    // RPC handler messages can carry config paths or credential-shaped text.
    final results = await Future.wait(<Future<_LoadResult>>[
      for (final section in _sections)
        widget.client
            .settingsGet(section.key)
            .then(
              (value) => _LoadResult(section.key, values: value),
              onError: (Object error) => _LoadResult(
                section.key,
                error: userSafeConnectionError(
                  error,
                  context: 'settings.get:${section.key}',
                ),
              ),
            ),
    ]);
    if (!mounted) return;
    setState(() {
      final errors = <String>[];
      for (final result in results) {
        if (result.error != null) {
          errors.add(result.error!);
          _drafts[result.section] = _SectionDraft.unavailable();
          continue;
        }
        final draft = _SectionDraft(result.values!);
        _drafts[result.section] = draft;
        for (final section in _sections) {
          if (section.key != result.section) continue;
          for (final field in section.fields) {
            if (_isTextLike(field.kind)) {
              final value = draft.values[field.key];
              _controllers[fieldId(section.key, field)]!.text = switch (field
                  .kind) {
                // Dart's toString() is not JSON (unquoted keys, single quotes),
                // so a loaded non-empty container could never be re-saved.
                _FieldKind.jsonList ||
                _FieldKind.jsonMap => value == null ? '' : jsonEncode(value),
                _ => value?.toString() ?? '',
              };
            }
          }
        }
      }
      if (errors.isNotEmpty) _error = errors.toSet().join(' ');
      _busy = false;
    });
  }

  Future<void> _save(_ModuleSection section) async {
    final draft = _drafts[section.key]!;
    if (!draft.loaded) return;
    final updated = Map<String, dynamic>.from(draft.values);
    String? validationError;
    for (final field in section.fields) {
      final id = fieldId(section.key, field);
      switch (field.kind) {
        case _FieldKind.text:
          updated[field.key] = _controllers[id]!.text.trim();
        case _FieldKind.number:
          final value = double.tryParse(_controllers[id]!.text.trim());
          if (value == null) {
            validationError = _numberError(section.key, field);
          } else {
            updated[field.key] = value;
          }
        case _FieldKind.integer:
          final value = int.tryParse(_controllers[id]!.text.trim());
          if (value == null) {
            validationError = _numberError(section.key, field);
          } else {
            updated[field.key] = value;
          }
        case _FieldKind.boolean:
        case _FieldKind.choice:
          updated[field.key] = draft.values[field.key];
        case _FieldKind.jsonList:
        case _FieldKind.jsonMap:
          final text = _controllers[id]!.text.trim();
          if (text.isEmpty) {
            // Missing JSON fields default to an empty container, matching
            // the typed daemon defaults; an empty editor is not an error.
            updated[field.key] = field.kind == _FieldKind.jsonList
                ? <dynamic>[]
                : <String, dynamic>{};
          } else {
            try {
              final decoded = jsonDecode(text);
              final valid = field.kind == _FieldKind.jsonList
                  ? decoded is List
                  : decoded is Map<String, dynamic>;
              if (!valid) {
                validationError ??= '${field.label} must be valid JSON.';
              } else {
                updated[field.key] = decoded;
              }
            } on FormatException {
              validationError ??= '${field.label} must be valid JSON.';
            }
          }
        case _FieldKind.hearingDeviceMap:
          // The structured editor keeps a typed map in the draft; validate it
          // here so a half-typed row can never reach the daemon.
          final error = _hearingDeviceMapError(
            field,
            draft.values[field.key],
            _hearingProviderIds[id],
          );
          if (error != null) validationError ??= error;
      }
    }
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final saved = await widget.client.settingsSet(section.key, updated);
      if (!mounted) return;
      setState(() {
        if (saved) {
          _drafts[section.key] = _SectionDraft(updated);
          _status = '${section.label} settings saved.';
        } else {
          _status = '${section.label} settings were not saved.';
        }
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = userSafeConnectionError(
            error,
            context: 'settings.set:${section.key}',
          );
          _busy = false;
        });
      }
    }
  }

  String _numberError(String section, _ModuleField field) => switch (section) {
    'local-llm' =>
      'Context size, max tokens, GPU layers and temperature must be numbers.',
    'hearing' => 'Auto-send delay and VAD threshold must be numbers.',
    'vision' => 'Context window must be a whole number.',
    'speech' => switch (field.key) {
      'rate' ||
      'pitch' ||
      'outputVolume' => 'Speech ${field.label.toLowerCase()} must be a number.',
      _ => '${field.label} must be a number.',
    },
    _ => '${field.label} must be a number.',
  };

  String? _hearingDeviceMapError(
    _ModuleField field,
    Object? value,
    List<String>? providerIds,
  ) {
    if (value is! Map<String, dynamic>) {
      return '${field.label} must be a map of providers.';
    }
    for (final entry in value.entries) {
      if (entry.key.trim().isEmpty) {
        return '${field.label} provider IDs cannot be empty.';
      }
      final config = entry.value;
      if (config is! Map<String, dynamic>) {
        return '${field.label} entries must be device settings.';
      }
      if (config['sampleRate'] is! num) {
        return '${field.label} sample rate must be a number.';
      }
    }
    // Duplicate IDs collapse in the emitted map, silently dropping a row.
    // Check the raw row IDs so that row is rejected instead of lost.
    final seen = <String>{};
    for (final provider in providerIds ?? const <String>[]) {
      if (!seen.add(provider)) {
        return '${field.label} provider IDs must be unique.';
      }
    }
    return null;
  }

  void _edit(String section, _ModuleField field, Object? value) {
    final draft = _drafts[section]!;
    if (!draft.loaded) return;
    setState(() {
      draft.values = Map<String, dynamic>.from(draft.values)
        ..[field.key] = value;
      _status = null;
    });
  }

  void _jump(GlobalKey key) {
    final context = key.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Companion Connectors')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'Connectors configured by the daemon',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final section in _sections)
            ListTile(
              leading: Icon(section.icon),
              title: Text(section.label),
              subtitle: const Text('Daemon-backed settings'),
              onTap: () => _jump(_cardKeys[section.key]!),
            ),
          DiscordSectionEditor(client: widget.client),
          const _UnavailableNotice(
            'Integration modules (MCP and ACP) have no daemon settings '
            'section in this build. They cannot be configured here without '
            'client-only state that would not persist.',
          ),
          const Divider(),
          for (final section in _sections)
            if (_drafts[section.key]!.loaded) _buildCard(section),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(_ModuleSection section) {
    final draft = _drafts[section.key]!;
    return Card(
      key: _cardKeys[section.key],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              section.label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final field in section.fields)
              _buildField(section, field, draft),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: draft.loaded && !_busy ? () => _save(section) : null,
                child: Text('Save ${section.label}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    _ModuleSection section,
    _ModuleField field,
    _SectionDraft draft,
  ) {
    final enabled = !_busy;
    final id = fieldId(section.key, field);
    switch (field.kind) {
      case _FieldKind.text:
      case _FieldKind.number:
      case _FieldKind.integer:
      case _FieldKind.jsonList:
      case _FieldKind.jsonMap:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: Key(id),
            enabled: enabled,
            controller: _controllers[id],
            keyboardType: switch (field.kind) {
              _FieldKind.number || _FieldKind.integer => TextInputType.number,
              _ => TextInputType.text,
            },
            maxLines: field.maxLines,
            decoration: InputDecoration(labelText: field.label),
          ),
        );
      case _FieldKind.hearingDeviceMap:
        final raw = draft.values[field.key];
        final values = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _HearingDeviceMapEditor(
            fieldId: id,
            label: field.label,
            values: values,
            enabled: enabled,
            onChanged: (value, providerIds) {
              _edit(section.key, field, value);
              _hearingProviderIds[id] = providerIds;
            },
          ),
        );
      case _FieldKind.boolean:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: draft.values[field.key] == true,
          onChanged: enabled
              ? (value) => _edit(section.key, field, value)
              : null,
          title: Text(field.label),
        );
      case _FieldKind.choice:
        final options = field.options;
        final current = draft.values[field.key]?.toString();
        final value = options.contains(current) ? current : options.first;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DropdownButtonFormField<String>(
            key: Key(id),
            // ignore: deprecated_member_use — initialValue cannot track edits.
            value: value,
            decoration: InputDecoration(labelText: field.label),
            items: <DropdownMenuItem<String>>[
              for (final option in options)
                DropdownMenuItem<String>(value: option, child: Text(option)),
            ],
            onChanged: enabled
                ? (selected) => _edit(section.key, field, selected)
                : null,
          ),
        );
    }
  }
}

/// One provider override row. Controllers live in the row so typing never
/// rebuilds the editor or steals focus from the field being edited.
class _HearingDeviceRow {
  _HearingDeviceRow({
    String provider = '',
    String deviceId = 'default',
    String sampleRate = '16000',
    this.original = const <String, dynamic>{},
  }) : providerController = TextEditingController(text: provider),
       deviceIdController = TextEditingController(text: deviceId),
       sampleRateController = TextEditingController(text: sampleRate);

  final TextEditingController providerController;
  final TextEditingController deviceIdController;
  final TextEditingController sampleRateController;

  /// Unknown nested keys survive a round-trip even though this editor only
  /// surfaces the two fields in the documented shape.
  final Map<String, dynamic> original;

  void dispose() {
    providerController.dispose();
    deviceIdController.dispose();
    sampleRateController.dispose();
  }
}

/// The typed map plus the raw (pre-collapse) row IDs, so the screen can reject
/// duplicate providers instead of letting the map literal drop one.
typedef _HearingMapChanged = void Function(
  Map<String, dynamic> values,
  List<String> providerIds,
);

/// Structured editor for the hearing maps shaped
/// `Record<string, {deviceId: string, sampleRate: number}>`.
///
/// Emits a fresh typed map on every edit. An unparseable sample rate stays as
/// text so the screen can reject it at save time instead of silently dropping
/// the row.
class _HearingDeviceMapEditor extends StatefulWidget {
  const _HearingDeviceMapEditor({
    required this.fieldId,
    required this.label,
    required this.values,
    required this.enabled,
    required this.onChanged,
  });

  final String fieldId;
  final String label;
  final Map<String, dynamic> values;
  final bool enabled;
  final _HearingMapChanged onChanged;

  @override
  State<_HearingDeviceMapEditor> createState() =>
      _HearingDeviceMapEditorState();
}

class _HearingDeviceMapEditorState extends State<_HearingDeviceMapEditor> {
  late final List<_HearingDeviceRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = <_HearingDeviceRow>[
      for (final entry in widget.values.entries)
        _HearingDeviceRow(
          provider: entry.key,
          deviceId: entry.value is Map
              ? entry.value['deviceId']?.toString() ?? 'default'
              : 'default',
          sampleRate: entry.value is Map
              ? entry.value['sampleRate']?.toString() ?? '16000'
              : '16000',
          original: entry.value is Map<String, dynamic>
              ? entry.value
              : <String, dynamic>{},
        ),
    ];
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() => <String, dynamic>{
    for (final row in _rows)
      row.providerController.text.trim(): <String, dynamic>{
        ...row.original,
        'deviceId': row.deviceIdController.text.trim(),
        'sampleRate':
            num.tryParse(row.sampleRateController.text.trim()) ??
            row.sampleRateController.text.trim(),
      },
  };

  List<String> _providerIds() => <String>[
    for (final row in _rows) row.providerController.text.trim(),
  ];

  void _changed() => widget.onChanged(_collect(), _providerIds());

  void _addRow() {
    setState(() => _rows.add(_HearingDeviceRow()));
    _changed();
  }

  void _removeRow(int index) {
    setState(() => _rows.removeAt(index).dispose());
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        for (var index = 0; index < _rows.length; index++) _buildRow(index),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: Key('${widget.fieldId}-add'),
            onPressed: widget.enabled ? _addRow : null,
            icon: const Icon(Icons.add),
            label: const Text('Add provider'),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    final prefix = '${widget.fieldId}-row-$index';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 2,
            child: TextField(
              key: Key('$prefix-provider'),
              enabled: widget.enabled,
              controller: row.providerController,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(
                labelText: 'Provider ID',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              key: Key('$prefix-deviceId'),
              enabled: widget.enabled,
              controller: row.deviceIdController,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(
                labelText: 'Device ID',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: Key('$prefix-sampleRate'),
              enabled: widget.enabled,
              controller: row.sampleRateController,
              keyboardType: TextInputType.number,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(
                labelText: 'Sample rate',
                isDense: true,
              ),
            ),
          ),
          IconButton(
            key: Key('$prefix-remove'),
            onPressed: widget.enabled ? () => _removeRow(index) : null,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove provider',
          ),
        ],
      ),
    );
  }
}

class _LoadResult {
  _LoadResult(this.section, {this.values, this.error});

  final String section;
  final Map<String, dynamic>? values;
  final String? error;
}

class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

/// Token-safe editor for the daemon's registered `settings/discord` section.
///
/// The read is lazy on purpose: opening Companion Connectors must not add a
/// seventh `settings.get` call. The token field always starts blank because the
/// daemon never returns the credential; saving goes exclusively through
/// [buildDiscordPatch], so a blank field cannot wipe the stored token and a
/// `hasToken` hint is never echoed back as a writable field.
class DiscordSectionEditor extends StatefulWidget {
  const DiscordSectionEditor({super.key, required this.client});

  final DaemonClient client;

  @override
  State<DiscordSectionEditor> createState() => _DiscordSectionEditorState();
}

class _DiscordSectionEditorState extends State<DiscordSectionEditor> {
  final TextEditingController _tokenController = TextEditingController();
  Map<String, dynamic>? _view;
  Map<String, String> _choices = <String, String>{};
  bool _loading = false;
  bool _saving = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = null;
    });
    try {
      final view = await widget.client.settingsGet('discord');
      if (!mounted) return;
      setState(() {
        _view = view;
        _choices = <String, String>{
          for (final entry in discordChoiceValues.entries)
            entry.key:
                view[entry.key] is String &&
                    entry.value.contains(view[entry.key])
                ? view[entry.key] as String
                : entry.value.first,
        };
        _loading = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = userSafeConnectionError(
            error,
            context: 'settings.get:discord',
          );
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final view = _view;
    if (view == null) return;
    final patch = buildDiscordPatch(
      view,
      edits: _choices,
      typedToken: _tokenController.text,
    );
    setState(() {
      _saving = true;
      _error = null;
      _status = null;
    });
    try {
      final saved = await widget.client.settingsSet('discord', patch);
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (saved) {
          _status = 'Discord settings saved.';
          _tokenController.clear();
          // Keep the edited values, but never retain a token locally: the next
          // save must not re-send it just because the field was cleared.
          _view = <String, dynamic>{...view, ...patch}..remove('token');
        } else {
          _status = 'Discord settings were not saved.';
        }
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userSafeConnectionError(
            error,
            context: 'settings.set:discord',
          );
        });
      }
    }
  }

  static String _label(String key) => switch (key) {
    'executionMode' => 'Execution mode',
    'chatMode' => 'Chat mode',
    'voiceMode' => 'Voice mode',
    'voiceCall' => 'Voice call',
    _ => key,
  };

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Discord',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (view == null)
              FilledButton(
                key: const Key('modules-discord-load'),
                onPressed: _loading ? null : _load,
                child: const Text('Load Discord settings'),
              )
            else ...<Widget>[
              Text(
                view['hasToken'] == true
                    ? 'Bot token configured (leave blank to keep it).'
                    : 'No bot token configured.',
              ),
              const SizedBox(height: 8),
              for (final entry in discordChoiceValues.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<String>(
                    key: Key('modules-discord-${entry.key}'),
                    // ignore: deprecated_member_use — initialValue cannot track edits.
                    value: _choices[entry.key],
                    decoration: InputDecoration(labelText: _label(entry.key)),
                    items: <DropdownMenuItem<String>>[
                      for (final option in entry.value)
                        DropdownMenuItem<String>(
                          value: option,
                          child: Text(option),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (String? selected) {
                            if (selected == null) return;
                            setState(() => _choices[entry.key] = selected);
                          },
                  ),
                ),
              TextField(
                key: const Key('modules-discord-token'),
                controller: _tokenController,
                obscureText: true,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'New bot token (blank = keep existing)',
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('modules-discord-save'),
                  onPressed: _saving ? null : _save,
                  child: const Text('Save Discord'),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status!),
              ),
          ],
        ),
      ),
    );
  }
}
