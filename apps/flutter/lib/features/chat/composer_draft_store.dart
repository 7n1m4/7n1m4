// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Client-local key/value store for unsent chat composer drafts.
///
/// Follows the `StageSceneStore` precedent: one JSON file in an injected
/// directory, with atomic writes (write a `.tmp` sibling, then rename) so a
/// crash cannot leave a half-written draft. There is no daemon verb and no
/// cross-window channel: drafts stay on this device, in this app profile.
///
/// Keys are session ids. The empty key holds a draft typed before a session
/// exists. Passing [storageDirectory] keeps tests on a temp directory and
/// returns an isolated instance; without it every caller in the process shares
/// one store, so a stale controller cannot overwrite newer drafts. A missing
/// platform channel degrades to an in-memory store — persistence is
/// best-effort and must never block the composer.
class ComposerDraftStore {
  /// Production callers (no injected directory) share one process-wide store.
  /// One map and one persistence path means an old controller cannot flush a
  /// stale snapshot over drafts written by a newer one.
  factory ComposerDraftStore({Directory? storageDirectory}) {
    if (storageDirectory != null) {
      // Tests inject a temp directory and need a fresh, uncached reader.
      return ComposerDraftStore._(storageDirectory);
    }
    return _shared ??= ComposerDraftStore._(null);
  }

  ComposerDraftStore._(this._injectedDirectory);

  static ComposerDraftStore? _shared;

  /// File name inside the chosen directory.
  static const String fileName = 'composer_drafts.json';

  /// Keystrokes are cheap; disk is not. Coalesce writes within this window.
  static const Duration persistDelay = Duration(milliseconds: 200);

  final Directory? _injectedDirectory;
  Directory? _resolvedDirectory;
  bool _ready = false;
  Future<void>? _readyFuture;
  final Map<String, String> _drafts = <String, String>{};

  /// Writes/clears that landed before `ready()` finished loading. They are
  /// replayed after the disk read so a clear cannot be revived from the file.
  final Map<String, String> _pending = <String, String>{};
  Timer? _persistTimer;

  File? get _file {
    final directory = _resolvedDirectory ?? _injectedDirectory;
    if (directory == null) return null;
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// Resolve the location once, then merge disk drafts under any writes that
  /// arrived while resolution was pending. Idempotent and shared by concurrent
  /// callers: the same future is returned until load + replay have finished.
  Future<void> ready() => _readyFuture ??= _loadAndReplay();

  Future<void> _loadAndReplay() async {
    // Always yield here, even with an injected directory: callers rely on
    // `ready()` being asynchronous and this is the gap pre-ready edits land in.
    final directory = await _resolveDirectory();
    _resolvedDirectory = directory;
    if (directory != null) _load();
    for (final entry in _pending.entries) {
      _apply(entry.key, entry.value);
    }
    _pending.clear();
    _ready = true;
    _persistSoon();
  }

  Future<Directory?> _resolveDirectory() async {
    final injected = _injectedDirectory;
    if (injected != null) return injected;
    try {
      return await getApplicationSupportDirectory();
    } on Object {
      return null;
    }
  }

  void _load() {
    final file = _file;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      final drafts = decoded['drafts'];
      if (drafts is! Map) return;
      for (final entry in drafts.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String && !_drafts.containsKey(key)) {
          _drafts[key] = value;
        }
      }
    } on Object {
      // A stale or truncated file is not worth failing the composer over.
    }
  }

  void _apply(String key, String text) {
    if (text.isEmpty) {
      _drafts.remove(key);
    } else {
      _drafts[key] = text;
    }
  }

  /// The persisted draft for [sessionKey], or null when there is none.
  String? read(String sessionKey) => _drafts[sessionKey];

  /// Store [text] for [sessionKey]. Empty text removes the entry: that is how
  /// a committed send clears its draft.
  void write(String sessionKey, String text) {
    if (!_ready) _pending[sessionKey] = text;
    _apply(sessionKey, text);
    if (_ready) _persistSoon();
  }

  /// Write the current drafts now. Called when the composer is disposed so a
  /// trailing keystroke is not lost to the debounce window.
  void flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _persist();
  }

  void _persistSoon() {
    if (_file == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(persistDelay, _persist);
  }

  void _persist() {
    final file = _file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
        jsonEncode(<String, dynamic>{'version': 1, 'drafts': _drafts}),
      );
      temp.renameSync(file.path);
    } on Object catch (_) {
      // Best-effort: a broken draft file must never break sending.
    }
  }
}
