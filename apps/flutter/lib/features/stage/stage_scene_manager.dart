// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local background library, ported in behavior from the Vue
// `useBackgroundStore` (packages/stage-ui/src/stores/background.ts). The
// daemon has no background verb, so entries are persisted only in this
// client's application-support directory. Per-card backdrop ids are seeded
// from daemon card documents (`extensions.airi.modules.activeBackgroundId`,
// mirrored under `data.extensions.airi.modules`); this store never writes a
// card, leaving that to the owning UI via `cards.update`.

import 'dart:convert';
import 'dart:io';

import 'stage_background.dart';

/// A stable code + user-safe message for a scene-library failure.
class StageSceneException implements Exception {
  const StageSceneException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'StageSceneException($code): $message';
}

/// One backdrop in the client-local library.
class StageSceneEntry {
  const StageSceneEntry({
    required this.id,
    required this.background,
    required this.label,
  });

  /// Opaque, locally generated id (`bg-…`, matching the Vue store prefix).
  final String id;
  final StageBackground background;
  final String label;

  StageBackgroundKind get kind => background.kind;
  String? get imagePath => background.imagePath;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'kind': background.kind.name,
        'tint': background.tint,
        'imagePath': background.imagePath,
        'fingerprint': background.fingerprint,
      };

  static StageSceneEntry fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final kindName = json['kind'];
    final kind = StageBackgroundKind.values
        .where((value) => value.name == kindName)
        .cast<StageBackgroundKind?>()
        .firstOrNull;
    if (id is! String || id.isEmpty || kind == null) {
      throw const StageSceneException(
        'invalid-entry',
        'A stored scene is malformed.',
      );
    }
    return StageSceneEntry(
      id: id,
      label: json['label'] is String ? json['label'] as String : id,
      background: StageBackground(
        kind: kind,
        tint: json['tint'] is int ? json['tint'] as int : null,
        imagePath: json['imagePath'] is String
            ? json['imagePath'] as String
            : null,
        fingerprint: json['fingerprint'] is String
            ? json['fingerprint'] as String
            : null,
      ),
    );
  }
}

/// Add/remove/activate backdrops and resolve the active one for the stage.
///
/// Construction does not touch the filesystem: call [load] once from the
/// owning screen. Writes are atomic (write temp, then rename), so a crash
/// never leaves a half-written library.
class StageSceneStore {
  StageSceneStore({required this.storageDirectory});

  final Directory storageDirectory;
  final List<StageSceneEntry> _entries = <StageSceneEntry>[];
  String? _activeId;

  /// Per-card scene selection (Vue `activeBackgroundId` lives on the card).
  /// An empty key means the card has no scene of its own and falls back to the
  /// library-wide selection.
  final Map<String, String> _activeByCard = <String, String>{};
  int _sequence = 0;

  File get _libraryFile =>
      File('${storageDirectory.path}${Platform.pathSeparator}scenes.json');

  List<StageSceneEntry> get entries => List<StageSceneEntry>.unmodifiable(_entries);
  String? get activeId => _activeId;
  StageBackground get activeBackground => activeBackgroundFor(null);

  /// The library entry matching [id], or null when the id is unknown.
  StageSceneEntry? entryFor(String? id) {
    if (id == null) return null;
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// The scene id currently selected for [cardId], or null when none.
  String? activeFor(String? cardId) =>
      (cardId == null ? _activeId : _activeByCard[cardId]) ?? _activeId;

  /// Per-card selection only; never falls back to the library-wide scene.
  String? activeForCard(String cardId) => _activeByCard[cardId];

  /// The backdrop for [cardId]: its own scene when set, otherwise the library
  /// default. One card's choice never overwrites another's.
  StageBackground activeBackgroundFor(String? cardId) {
    final id = (cardId == null ? null : _activeByCard[cardId]) ?? _activeId;
    if (id == null) return StageBackground.none;
    for (final entry in _entries) {
      if (entry.id == id) return entry.background;
    }
    return StageBackground.none;
  }

  /// Seed the per-card selection from a card document without persisting.
  /// An absent or unrecognized id leaves any local selection intact: Vue ids
  /// may reference builtin or journal backgrounds this library cannot paint.
  /// An explicit `none` clears the per-card choice.
  void seedActiveForCard(String cardId, String? backgroundId) {
    if (backgroundId == null) return;
    if (backgroundId == 'none') {
      _activeByCard.remove(cardId);
      return;
    }
    final entry = entryFor(backgroundId);
    if (entry != null) _activeByCard[cardId] = entry.id;
  }

  /// Change the card's backdrop and persist the selection locally. `none`
  /// clears the per-card choice; an unknown id fails loudly.
  Future<void> activateForCard(String cardId, String? backgroundId) async {
    final entry = backgroundId == null || backgroundId == 'none'
        ? null
        : entryFor(backgroundId);
    if (backgroundId != null &&
        backgroundId != 'none' &&
        entry == null) {
      throw const StageSceneException(
        'unknown-scene',
        'That scene is no longer in the library.',
      );
    }
    if (entry == null) {
      _activeByCard.remove(cardId);
    } else {
      _activeByCard[cardId] = entry.id;
    }
    await _persist();
  }

  Future<void> load() async {
    _entries.clear();
    if (!await _libraryFile.exists()) {
      _activeId = null;
      return;
    }
    try {
      final decoded = jsonDecode(await _libraryFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a scene library');
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is List) {
        for (final raw in rawEntries) {
          if (raw is Map<String, dynamic>) {
            _entries.add(StageSceneEntry.fromJson(raw));
          }
        }
      }
      final active = decoded['activeId'];
      _activeId = active is String &&
              _entries.any((entry) => entry.id == active)
          ? active
          : null;
      _activeByCard.clear();
      final byCard = decoded['activeByCard'];
      if (byCard is Map) {
        for (final entry in byCard.entries) {
          final cardId = entry.key;
          final sceneId = entry.value;
          if (cardId is String &&
              sceneId is String &&
              _entries.any((scene) => scene.id == sceneId)) {
            _activeByCard[cardId] = sceneId;
          }
        }
      }
    } on Object catch (error) {
      throw StageSceneException(
        'load-failed',
        'The scene library could not be read (${error.runtimeType}).',
      );
    }
  }

  /// Resolve and add one backdrop. A missing image or a bad tint fails loudly
  /// through [StageBackgroundResolver] and leaves the library unchanged.
  Future<StageSceneEntry> add({String? tint, String? imagePath}) async {
    final background = await const StageBackgroundResolver().resolve(
      tint: tint,
      imagePath: imagePath,
    );
    if (background.kind == StageBackgroundKind.none) {
      throw const StageSceneException(
        'empty-scene',
        'A scene needs a tint or an image.',
      );
    }
    final id = 'bg-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final label = switch (background.kind) {
      StageBackgroundKind.tint => 'Tint #${(background.tint! & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
      StageBackgroundKind.image => background.imagePath?.split(Platform.pathSeparator).last ?? 'Image',
      StageBackgroundKind.none => 'None',
    };
    final entry = StageSceneEntry(id: id, background: background, label: label);
    _entries.add(entry);
    await _persist();
    return entry;
  }

  Future<bool> activate(String id, {String? cardId}) async {
    if (!_entries.any((entry) => entry.id == id)) {
      throw const StageSceneException(
        'unknown-scene',
        'That scene is no longer in the library.',
      );
    }
    if (cardId == null) {
      _activeId = id;
    } else {
      _activeByCard[cardId] = id;
    }
    await _persist();
    return true;
  }

  Future<void> deactivate({String? cardId}) async {
    if (cardId == null) {
      _activeId = null;
    } else {
      _activeByCard.remove(cardId);
    }
    await _persist();
  }

  Future<bool> remove(String id) async {
    final before = _entries.length;
    _entries.removeWhere((entry) => entry.id == id);
    if (_entries.length == before) return false;
    if (_activeId == id) _activeId = null;
    _activeByCard.removeWhere((_, sceneId) => sceneId == id);
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    await storageDirectory.create(recursive: true);
    final payload = jsonEncode(<String, dynamic>{
      'entries': <Map<String, dynamic>>[
        for (final entry in _entries) entry.toJson(),
      ],
      'activeId': _activeId,
      'activeByCard': _activeByCard,
    });
    final target = _libraryFile;
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(payload, flush: true);
      await temp.rename(target.path);
    } on Object catch (error) {
      throw StageSceneException(
        'save-failed',
        'The scene library could not be saved (${error.runtimeType}).',
      );
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } on Object {
        // Best-effort cleanup; the original failure is the one that matters.
      }
    }
  }
}
