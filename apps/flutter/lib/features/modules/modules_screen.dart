// SPDX-License-Identifier: GPL-3.0-or-later

// Companion Connectors settings surface. Every card here maps 1:1 to a
// section registered in `settings_section()` in the daemon core; reads and
// writes go through `settings.get` / `settings.set`. Unrelated keys in a
// section round-trip untouched. Integration modules with no daemon section
// keep an honest, narrow notice instead of client-only state that looks saved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';

enum _FieldKind { text, number, integer, boolean, choice, jsonList, jsonMap }

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
  _ModuleSection('audio-device', 'Audio device', Icons.hearing_outlined, <_ModuleField>[
    _ModuleField('selectedInputDevice', 'Input device ID (empty = default)',
        kind: _FieldKind.text),
    _ModuleField('selectedOutputDevice', 'Output device ID (empty = default)',
        kind: _FieldKind.text),
    _ModuleField('inputEnabled', 'Microphone input enabled', kind: _FieldKind.boolean),
  ]),
  _ModuleSection('local-llm', 'Local LLM', Icons.memory_outlined, <_ModuleField>[
    _ModuleField('modelPath', 'GGUF model path (empty = not configured)',
        kind: _FieldKind.text),
    _ModuleField('contextSize', 'Context size (tokens)', kind: _FieldKind.integer),
    _ModuleField('temperature', 'Temperature', kind: _FieldKind.number),
    _ModuleField('maxTokens', 'Max tokens', kind: _FieldKind.integer),
    _ModuleField('gpuLayers', 'GPU layers (0 = CPU, negative = offload all)',
        kind: _FieldKind.integer),
  ]),
  _ModuleSection('consciousness', 'Consciousness', Icons.psychology_outlined, <_ModuleField>[
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField('activeCustomModel', 'Custom model name', kind: _FieldKind.text),
  ]),
  _ModuleSection('speech', 'Speech', Icons.record_voice_over_outlined, <_ModuleField>[
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField('voice', 'Voice ID', kind: _FieldKind.text),
    _ModuleField('outputVolume', 'Output volume', kind: _FieldKind.number),
    _ModuleField('enabled', 'Speech enabled', kind: _FieldKind.boolean),
    _ModuleField('pitch', 'Pitch', kind: _FieldKind.number),
    _ModuleField('rate', 'Rate', kind: _FieldKind.number),
    _ModuleField('ssmlEnabled', 'SSML enabled', kind: _FieldKind.boolean),
    _ModuleField('language', 'Language', kind: _FieldKind.text),
    _ModuleField('voiceProfiles', 'Voice profiles (JSON array)',
        kind: _FieldKind.jsonList, maxLines: 3),
  ]),
  _ModuleSection('hearing', 'Hearing', Icons.hearing_outlined, <_ModuleField>[
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField('activeCustomModel', 'Custom model name', kind: _FieldKind.text),
    _ModuleField('autoSendEnabled', 'Auto-send recognized speech',
        kind: _FieldKind.boolean),
    _ModuleField('autoSendDelay', 'Auto-send delay (ms)', kind: _FieldKind.integer),
    _ModuleField('detectionMode', 'Detection mode',
        kind: _FieldKind.choice, options: <String>['vad', 'manual']),
    _ModuleField('tapToTalk', 'Tap-to-talk', kind: _FieldKind.boolean),
    _ModuleField('voiceInputMode', 'Voice input mode',
        kind: _FieldKind.choice,
        options: <String>['dictation', 'voice-message']),
    _ModuleField('vadThreshold', 'VAD threshold', kind: _FieldKind.number),
    _ModuleField('speechProviderSettings', 'Speech provider settings (JSON object)',
        kind: _FieldKind.jsonMap, maxLines: 3),
    _ModuleField('transcriptionProviderSettings',
        'Transcription provider settings (JSON object)',
        kind: _FieldKind.jsonMap, maxLines: 3),
  ]),
  _ModuleSection('vision', 'Vision', Icons.visibility_outlined, <_ModuleField>[
    _ModuleField('strategy', 'Strategy',
        kind: _FieldKind.choice, options: <String>['direct', 'forward']),
    _ModuleField('activeProvider', 'Active provider ID', kind: _FieldKind.text),
    _ModuleField('activeModel', 'Active model ID', kind: _FieldKind.text),
    _ModuleField('contextWindow', 'Images in context', kind: _FieldKind.integer),
    _ModuleField('activeAdvanced', 'Advanced options (JSON object)',
        kind: _FieldKind.jsonMap, maxLines: 3),
    _ModuleField('promptShim', 'Direct prompt', kind: _FieldKind.text, maxLines: 3),
    _ModuleField('promptShimForward', 'Forward prompt',
        kind: _FieldKind.text, maxLines: 3),
    _ModuleField('witnessEnabled', 'Ambient vision (witness)',
        kind: _FieldKind.boolean),
    _ModuleField('witnessPrompt', 'Witness prompt', kind: _FieldKind.text, maxLines: 3),
    _ModuleField('respectSchedule', 'Respect heartbeat schedule',
        kind: _FieldKind.boolean),
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
        _FieldKind.text || _FieldKind.number || _FieldKind.integer ||
        _FieldKind.jsonList || _FieldKind.jsonMap => true,
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
        widget.client.settingsGet(section.key).then(
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
              _controllers[fieldId(section.key, field)]!.text =
                  draft.values[field.key]?.toString() ?? '';
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
          _error = userSafeConnectionError(error, context: 'settings.set:${section.key}');
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
          'rate' || 'pitch' || 'outputVolume' => 'Speech ${field.label.toLowerCase()} must be a number.',
          _ => '${field.label} must be a number.',
        },
        _ => '${field.label} must be a number.',
      };

  void _edit(String section, _ModuleField field, Object? value) {
    final draft = _drafts[section]!;
    if (!draft.loaded) return;
    setState(() {
      draft.values = Map<String, dynamic>.from(draft.values)..[field.key] = value;
      _status = null;
    });
  }

  void _jump(GlobalKey key) {
    final context = key.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 200));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Companion Connectors')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('Connectors configured by the daemon',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final section in _sections)
            ListTile(
              leading: Icon(section.icon),
              title: Text(section.label),
              subtitle: const Text('Daemon-backed settings'),
              onTap: () => _jump(_cardKeys[section.key]!),
            ),
          const _UnavailableNotice(
            'Integration modules (Discord, MCP and ACP) have no daemon settings '
            'section in this build. They cannot be configured here without '
            'client-only state that would not persist.',
          ),
          const Divider(),
          for (final section in _sections)
            if (_drafts[section.key]!.loaded)
              _buildCard(section),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
            Text(section.label, style: const TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildField(_ModuleSection section, _ModuleField field, _SectionDraft draft) {
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
      child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
    );
  }
}
