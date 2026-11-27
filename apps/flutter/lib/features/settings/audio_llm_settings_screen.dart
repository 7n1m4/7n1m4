// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';

/// Settings surface for daemon-owned audio device + local LLM + consciousness
/// (LLM provider) selection. All reads/writes go through `settings.get` /
/// `settings.set`; nothing is persisted locally.
class AudioLlmSettingsScreen extends StatefulWidget {
  const AudioLlmSettingsScreen({super.key, required this.client});

  final DaemonClient client;

  @override
  State<AudioLlmSettingsScreen> createState() => _AudioLlmSettingsScreenState();
}

class _AudioLlmSettingsScreenState extends State<AudioLlmSettingsScreen> {
  bool _busy = false;
  String? _error;
  String? _status;

  final Map<String, Map<String, dynamic>> _drafts = <String, Map<String, dynamic>>{};
  final Map<String, bool> _loaded = <String, bool>{};

  final TextEditingController _audioInput = TextEditingController();
  final TextEditingController _audioOutput = TextEditingController();
  bool _audioInputEnabled = true;

  final TextEditingController _llmPath = TextEditingController();
  final TextEditingController _llmContext = TextEditingController();
  final TextEditingController _llmTemp = TextEditingController();
  final TextEditingController _llmMaxTokens = TextEditingController();
  final TextEditingController _llmGpu = TextEditingController();

  final TextEditingController _consciousProvider = TextEditingController();
  final TextEditingController _consciousModel = TextEditingController();
  final TextEditingController _consciousCustom = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _audioInput.dispose();
    _audioOutput.dispose();
    _llmPath.dispose();
    _llmContext.dispose();
    _llmTemp.dispose();
    _llmMaxTokens.dispose();
    _llmGpu.dispose();
    _consciousProvider.dispose();
    _consciousModel.dispose();
    _consciousCustom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      for (final section in const <String>['audio-device', 'local-llm', 'consciousness']) {
        final values = await widget.client.settingsGet(section);
        _drafts[section] = Map<String, dynamic>.from(values);
        _loaded[section] = true;
      }
      final audio = _drafts['audio-device']!;
      _audioInput.text = (audio['selectedInputDevice'] ?? '').toString();
      _audioOutput.text = (audio['selectedOutputDevice'] ?? '').toString();
      _audioInputEnabled = audio['inputEnabled'] == true;

      final llm = _drafts['local-llm']!;
      _llmPath.text = (llm['modelPath'] ?? '').toString();
      _llmContext.text = (llm['contextSize'] ?? '').toString();
      _llmTemp.text = (llm['temperature'] ?? '').toString();
      _llmMaxTokens.text = (llm['maxTokens'] ?? '').toString();
      _llmGpu.text = (llm['gpuLayers'] ?? '').toString();

      final c = _drafts['consciousness']!;
      _consciousProvider.text = (c['activeProvider'] ?? '').toString();
      _consciousModel.text = (c['activeModel'] ?? '').toString();
      _consciousCustom.text = (c['activeCustomModel'] ?? '').toString();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = e is DaemonClientException
            ? userSafeConnectionError(e, context: 'settings.load:audio-llm')
            : 'Settings could not be loaded.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String section) async {
    final draft = _drafts[section];
    if (draft == null || _loaded[section] != true) return;
    final updated = Map<String, dynamic>.from(draft);
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      if (section == 'audio-device') {
        updated['selectedInputDevice'] = _audioInput.text.trim();
        updated['selectedOutputDevice'] = _audioOutput.text.trim();
        updated['inputEnabled'] = _audioInputEnabled;
      } else if (section == 'local-llm') {
        updated['modelPath'] = _llmPath.text.trim();
        final ctx = int.tryParse(_llmContext.text.trim());
        if (ctx != null) updated['contextSize'] = ctx;
        final temp = double.tryParse(_llmTemp.text.trim());
        if (temp != null) updated['temperature'] = temp;
        final mt = int.tryParse(_llmMaxTokens.text.trim());
        if (mt != null) updated['maxTokens'] = mt;
        final gpu = int.tryParse(_llmGpu.text.trim());
        if (gpu != null) updated['gpuLayers'] = gpu;
      } else if (section == 'consciousness') {
        updated['activeProvider'] = _consciousProvider.text.trim();
        updated['activeModel'] = _consciousModel.text.trim();
        updated['activeCustomModel'] = _consciousCustom.text.trim();
      }
      final ok = await widget.client.settingsSet(section, updated);
      if (!mounted) return;
      setState(() {
        if (ok) {
          _drafts[section] = updated;
          _status = '$section settings saved.';
        } else {
          _error = 'Could not save $section settings.';
        }
      });
    } on DaemonClientException catch (e) {
      if (mounted) {
        setState(() => _error = userSafeConnectionError(e, context: 'settings.set:$section'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Audio & LLM')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Audio device', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(enabled: enabled, controller: _audioInput, decoration: const InputDecoration(labelText: 'Input device ID')),
                  TextField(enabled: enabled, controller: _audioOutput, decoration: const InputDecoration(labelText: 'Output device ID')),
                  SwitchListTile(contentPadding: EdgeInsets.zero, value: _audioInputEnabled, onChanged: enabled ? (v) => setState(() => _audioInputEnabled = v) : null, title: const Text('Microphone input enabled')),
                  Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: enabled ? () => _save('audio-device') : null, child: const Text('Save audio device'))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Local LLM', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(enabled: enabled, controller: _llmPath, decoration: const InputDecoration(labelText: 'GGUF model path')),
                  TextField(enabled: enabled, controller: _llmContext, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Context size')),
                  TextField(enabled: enabled, controller: _llmTemp, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Temperature')),
                  TextField(enabled: enabled, controller: _llmMaxTokens, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max tokens')),
                  TextField(enabled: enabled, controller: _llmGpu, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'GPU layers')),
                  Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: enabled ? () => _save('local-llm') : null, child: const Text('Save local LLM'))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Consciousness (LLM provider)', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(enabled: enabled, controller: _consciousProvider, decoration: const InputDecoration(labelText: 'Active provider ID')),
                  TextField(enabled: enabled, controller: _consciousModel, decoration: const InputDecoration(labelText: 'Active model ID')),
                  TextField(enabled: enabled, controller: _consciousCustom, decoration: const InputDecoration(labelText: 'Custom model name')),
                  Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: enabled ? () => _save('consciousness') : null, child: const Text('Save consciousness'))),
                ],
              ),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!)),
        ],
      ),
    );
  }
}
