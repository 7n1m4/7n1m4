// SPDX-License-Identifier: GPL-3.0-or-later

// In-process algorithmic mirror of packages/stage-ui/src/services/speech/
// audio-cache.ts: key builder (44-66), bounds (92-93), get/has/set (129-191)
// and evict/clear (259-296). BroadcastChannel sync, the global singleton,
// message associations/isMessageCached and engine wiring are deliberately not
// ported. No replay caller exists in the Flutter client yet, so this is not
// cache parity — only the shared key/LRU core.

import 'dart:convert';
import 'dart:typed_data';

/// Deterministic cache key for one synthesis request, encoding every
/// parameter that changes the output audio.
String createSpeechAudioCacheKey({
  required String providerId,
  required String model,
  required String voiceId,
  required String text,
  num? pitch,
  num? speed,
  bool? ssml,
  String? language,
  /// [extra] must contain only non-secret synthesis parameters — never credentials, tokens or provider secrets, since it is encoded into the key.
  Map<String, dynamic>? extra,
}) {
  final buffer = StringBuffer('[')
    ..write(jsonEncode(providerId))
    ..write(',')
    ..write(jsonEncode(model))
    ..write(',')
    ..write(jsonEncode(voiceId))
    ..write(',')
    ..write(_numberText(pitch ?? 0))
    ..write(',')
    ..write(_numberText(speed ?? 1))
    ..write(',')
    ..write(jsonEncode(ssml ?? false))
    ..write(',')
    ..write(jsonEncode(language ?? ''))
    ..write(',')
    ..write(_jsJson(extra)) // null is encoded as `null`, like TS `?? null`
    ..write(',')
    ..write(jsonEncode(text.trim()))
    ..write(']');
  return buffer.toString();
}

// JS JSON.stringify renders integral doubles without `.0`; trimming the
// suffix also avoids int64 clamping for values such as 1e19. Verified: Dart
// and JS both switch to `e` notation at ~1e21, so those already agree.
// shortcut: only the `.0` suffix is normalized; other number-format drift is
// not handled.
String _numberText(num value) {
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

// Recursive JS-style JSON for `extra`: numbers go through [_numberText] and
// map entries keep their iteration order instead of being reordered.
String _jsJson(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is num) {
    return _numberText(value);
  }
  if (value is String) {
    return jsonEncode(value);
  }
  if (value is bool) {
    return value.toString();
  }
  if (value is Map) {
    final buffer = StringBuffer('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) {
        buffer.write(',');
      }
      first = false;
      buffer.write(jsonEncode(entry.key.toString()));
      buffer.write(':');
      buffer.write(_jsJson(entry.value));
    }
    buffer.write('}');
    return buffer.toString();
  }
  if (value is List) {
    final buffer = StringBuffer('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) {
        buffer.write(',');
      }
      buffer.write(_jsJson(value[i]));
    }
    buffer.write(']');
    return buffer.toString();
  }
  return jsonEncode(value);
}

/// In-memory LRU of synthesized audio, bounded by entry count and bytes.
class SpeechAudioCache {
  SpeechAudioCache({
    this.maxEntries = 200,
    this.maxBytes = 50 * 1024 * 1024,
  });

  final int maxEntries;
  final int maxBytes;

  // LinkedHashMap keeps insertion order; re-inserting on [get] refreshes it.
  final Map<String, Uint8List> _entries = <String, Uint8List>{};
  int _currentBytes = 0;

  int get size => _entries.length;
  int get totalBytes => _currentBytes;

  /// Returns the buffer and refreshes its LRU position. A zero-byte presence
  /// placeholder is a miss, matching the TS implementation.
  Uint8List? get(String key) {
    final buffer = _entries[key];
    if (buffer == null || buffer.isEmpty) {
      return null;
    }
    _entries.remove(key);
    _entries[key] = buffer;
    return buffer;
  }

  /// Checks presence without changing LRU order.
  bool has(String key) => _entries.containsKey(key);

  /// Stores [buffer] under [key], evicting the oldest entries as needed.
  void set(String key, Uint8List buffer) {
    if (buffer.lengthInBytes > maxBytes) {
      return;
    }

    final existing = _entries.remove(key);
    if (existing != null) {
      _currentBytes -= existing.lengthInBytes;
    }

    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries ||
            _currentBytes + buffer.lengthInBytes > maxBytes)) {
      _evict(_entries.keys.first);
    }

    _entries[key] = buffer;
    _currentBytes += buffer.lengthInBytes;
  }

  void _evict(String key) {
    final buffer = _entries.remove(key);
    if (buffer != null) {
      _currentBytes -= buffer.lengthInBytes;
    }
  }

  /// Drops all entries and resets the byte counter.
  void clear() {
    _entries.clear();
    _currentBytes = 0;
  }
}
