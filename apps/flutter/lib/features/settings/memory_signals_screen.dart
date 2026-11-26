// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';

/// Console for the six `extensions.airi.dreamState` fields of the active card.
/// Mirrors `packages/stage-pages/src/pages/settings/modules/memory-signals.vue`:
/// every control writes straight through to `cards.update` with a whole-
/// document spread, so sibling keys survive the patch.
class MemorySignalsScreen extends StatefulWidget {
  const MemorySignalsScreen({super.key, required this.client});

  final DaemonClient client;

  @override
  State<MemorySignalsScreen> createState() => _MemorySignalsScreenState();
}

class _MemorySignalsScreenState extends State<MemorySignalsScreen> {
  /// The daemon section holding `CardsSettings.activeCardId`.
  static const String _cardsSettingsSection = 'cards';

  final TextEditingController _maxSessions = TextEditingController();
  final TextEditingController _timeout = TextEditingController();
  final TextEditingController _minTurns = TextEditingController();

  Map<String, dynamic>? _card;
  String? _cardId;
  int _generation = 0;
  bool _busy = false;
  String? _error;
  String? _status;
  String? _syncWarning;
  Timer? _numericDebounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _numericDebounce?.cancel();
    _maxSessions.dispose();
    _timeout.dispose();
    _minTurns.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _syncWarning = null;
    });
    try {
      final settings = await widget.client.settingsGet(_cardsSettingsSection);
      final rawId = settings['activeCardId'] ?? settings['active_card_id'];
      final cardId = rawId is String && rawId.isNotEmpty ? rawId : null;
      final card = cardId == null ? null : await widget.client.cardsGet(cardId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _cardId = cardId;
        _card = card;
        _syncControllers(card);
      });
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = userSafeConnectionError(
            e,
            context: 'dream-state.load',
          ));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  void _syncControllers(Map<String, dynamic>? card) {
    final dreamState = _dreamStateFrom(card);
    _maxSessions.text = _numberText(dreamState['maxSessionsPerDay'], 4);
    _timeout.text = _numberText(dreamState['sessionTimeoutMinutes'], 60);
    _minTurns.text = _numberText(dreamState['minConversationTurns'], 4);
  }

  /// One field edit: re-read the card, spread the whole fresh document, then
  /// replace only the touched `dreamState` key. Re-reading before the save is
  /// the `cards_screen.dart` pattern: an external edit must not be clobbered.
  Future<void> _patchDreamState(Map<String, dynamic> patch) async {
    final card = _card;
    final cardId = _cardId;
    if (card == null || cardId == null || cardId.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _syncWarning = null;
    });
    try {
      final fresh = await widget.client.cardsGet(cardId);
      final base = fresh ?? card;
      final extensions = base['extensions'];
      final airi = extensions is Map<String, dynamic> ? extensions['airi'] : null;
      final dreamState =
          airi is Map<String, dynamic> ? airi['dreamState'] : null;
      final updated = <String, dynamic>{
        ...base,
        'extensions': <String, dynamic>{
          ...(extensions is Map<String, dynamic>
              ? extensions
              : const <String, dynamic>{}),
          'airi': <String, dynamic>{
            ...(airi is Map<String, dynamic> ? airi : const <String, dynamic>{}),
            'dreamState': <String, dynamic>{
              ...(dreamState is Map<String, dynamic>
                  ? dreamState
                  : const <String, dynamic>{}),
              ...patch,
            },
          },
        },
      };
      await widget.client.cardsUpdate(cardId, updated);
      // The save succeeded: commit locally before the best-effort refresh. A
      // failed refresh is only a sync warning, never a save error.
      if (!mounted) return;
      setState(() {
        _card = updated;
        _syncControllers(updated);
        _status = 'Dream state updated.';
      });
      await _refreshSaved(cardId, updated);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = userSafeConnectionError(
              e,
              context: 'dream-state.save',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Best-effort read-back of a successful save. Only the warning changes on
  /// failure: the committed values stay visible and editable.
  Future<void> _refreshSaved(
    String cardId,
    Map<String, dynamic> savedDocument,
  ) async {
    setState(() => _syncWarning = null);
    try {
      final saved = await widget.client.cardsGet(cardId);
      if (!mounted) return;
      setState(() {
        _card = saved ?? savedDocument;
        _syncControllers(_card);
      });
    } on Object {
      if (!mounted) return;
      setState(() => _syncWarning = 'Saved, but could not refresh latest settings');
    }
  }

  /// Vue's `v-model` writes on every change; debounce so a multi-digit entry
  /// becomes one `cards.update` instead of one per keystroke.
  void _scheduleNumericPatch(
    String field,
    TextEditingController controller,
    int fallback, {
    required int min,
    required int max,
  }) {
    _numericDebounce?.cancel();
    _numericDebounce = Timer(const Duration(milliseconds: 150), () {
      _numericDebounce = null;
      if (!mounted) return;
      _patchDreamState(<String, dynamic>{
        field: _numberValue(controller, fallback, min: min, max: max),
      });
    });
  }

  void _flushNumericPatch(
    String field,
    TextEditingController controller,
    int fallback, {
    required int min,
    required int max,
  }) {
    _numericDebounce?.cancel();
    _numericDebounce = null;
    _patchDreamState(<String, dynamic>{
      field: _numberValue(controller, fallback, min: min, max: max),
    });
  }

  static Map<String, dynamic> _dreamStateFrom(Map<String, dynamic>? card) {
    final extensions = card?['extensions'];
    final airi = extensions is Map<String, dynamic> ? extensions['airi'] : null;
    final dreamState =
        airi is Map<String, dynamic> ? airi['dreamState'] : null;
    return dreamState is Map<String, dynamic>
        ? dreamState
        : const <String, dynamic>{};
  }

  static String _numberText(Object? value, int fallback) {
    if (value is num && value.isFinite && value.toInt() != 0) {
      return value.toInt().toString();
    }
    return fallback.toString();
  }

  /// `Number(value) || default` from Vue: empty, unparsable and zero all mean
  /// "use the default". No daemon-side bounds exist, so clamp here.
  static int _numberValue(
    TextEditingController controller,
    int fallback, {
    required int min,
    required int max,
  }) {
    final parsed = int.tryParse(controller.text.trim());
    if (parsed == null || parsed == 0) return fallback;
    return parsed.clamp(min, max).toInt();
  }

  static String _threshold(Object? value) => switch (value) {
        'minimal' => 'minimal',
        'lush' => 'lush',
        _ => 'balanced',
      };

  @override
  Widget build(BuildContext context) {
    final dreamState = _dreamStateFrom(_card);
    final threshold = _threshold(dreamState['journalingThreshold']);

    return Scaffold(
      appBar: AppBar(title: const Text('The Dream State')),
      body: _busy && _card == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      key: const Key('dream-save-error'),
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_status!, key: const Key('dream-save-status')),
                  ),
                if (_syncWarning != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _syncWarning!,
                            key: const Key('dream-sync-warning'),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            final id = _cardId;
                            final card = _card;
                            if (id != null && card != null) {
                              _refreshSaved(id, card);
                            }
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                if (_card == null)
                  ListTile(
                    title: Text(_cardId == null
                        ? 'No active card selected.'
                        : 'Card not found.'),
                  )
                else ...<Widget>[
                  SwitchListTile(
                    key: const Key('dream-state-enabled'),
                    title: const Text('Enable Dream State'),
                    subtitle: const Text(
                      'Allow idle-time chips generation for the active character',
                    ),
                    value: dreamState['enabled'] == true,
                    onChanged: _busy
                        ? null
                        : (value) => _patchDreamState(<String, dynamic>{
                              'enabled': value,
                            }),
                  ),
                  const SizedBox(height: 8),
                  const Text('Journaling Threshold',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButtonFormField<String>(
                    key: ValueKey<String>(
                        'dream-journaling-threshold-$threshold'),
                    initialValue: threshold,
                    decoration: const InputDecoration(
                      labelText: 'Density of recorded memories',
                    ),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: 'minimal',
                        child: Text('Minimal — tags only'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'balanced',
                        child: Text('Balanced — significant moments'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'lush',
                        child: Text('Lush — most sessions'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              _patchDreamState(<String, dynamic>{
                                'journalingThreshold': value,
                              });
                            }
                          },
                  ),
                  const SizedBox(height: 16),
                  _numberField(
                    key: const Key('dream-max-sessions'),
                    label: 'Max Sessions / Day',
                    controller: _maxSessions,
                    fallback: 4,
                    min: 1,
                    max: 24,
                    field: 'maxSessionsPerDay',
                  ),
                  _numberField(
                    key: const Key('dream-timeout'),
                    label: 'Timeout (Minutes)',
                    controller: _timeout,
                    fallback: 60,
                    min: 1,
                    max: 1440,
                    field: 'sessionTimeoutMinutes',
                  ),
                  _numberField(
                    key: const Key('dream-min-turns'),
                    label: 'Min Turns to Dream',
                    controller: _minTurns,
                    fallback: 4,
                    min: 1,
                    max: 100,
                    field: 'minConversationTurns',
                  ),
                  SwitchListTile(
                    key: const Key('dream-strict-afk'),
                    title: const Text('Strict AFK Gating'),
                    subtitle: const Text("Only dreams while you're away"),
                    value: dreamState['strictAfkGating'] != false,
                    onChanged: _busy
                        ? null
                        : (value) => _patchDreamState(<String, dynamic>{
                              'strictAfkGating': value,
                            }),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _numberField({
    required Key key,
    required String label,
    required TextEditingController controller,
    required int fallback,
    required int min,
    required int max,
    required String field,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: key,
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(labelText: label),
        onChanged: _busy
            ? null
            : (_) => _scheduleNumericPatch(
                  field,
                  controller,
                  fallback,
                  min: min,
                  max: max,
                ),
        onFieldSubmitted: _busy
            ? null
            : (_) => _flushNumericPatch(
                  field,
                  controller,
                  fallback,
                  min: min,
                  max: max,
                ),
      ),
    );
  }
}
