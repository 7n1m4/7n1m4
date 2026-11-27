// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure value helpers for the persisted `settings/chat` section.
///
/// Mirrors `ChatSettings` in `crates/anima-core/src/settings.rs:241-272`.
/// No widget, no transport, no state adapter: this library only reads and
/// copies maps, so it cannot write to the daemon on its own.
library;

/// Value-free error text. Raw field values are never echoed back, so a
/// hand-edited blob cannot leak secrets or confuse the user.
const String chatInvalidValuesError =
    'Chat settings contain invalid values. Check each field and try again.';

/// Every field the daemon persists, in camelCase wire spelling.
const List<String> chatPersistedKeys = <String>[
  'sendMode',
  'suggestMode',
  'streamIdleTimeoutMs',
  'showDirectorNotes',
  'combineSystemMessages',
];

/// Serde defaults for legacy blobs that omit a field.
const Map<String, dynamic> chatDefaults = <String, dynamic>{
  'sendMode': 'enter',
  'suggestMode': 'double-enter',
  'streamIdleTimeoutMs': 600000,
  'showDirectorNotes': true,
  'combineSystemMessages': false,
};

/// The TS store migrated users from 30s to the daemon's 10min default.
/// Migrate on read so the next unrelated save cannot rewrite the old value.
const int chatLegacyStreamIdleTimeoutMs = 30000;

const Set<String> chatSendModes = <String>{
  'enter',
  'ctrl-enter',
  'double-enter',
};

const Set<String> chatSuggestModes = <String>{
  'enter',
  'ctrl-enter',
  'double-enter',
  'disabled',
};

/// Outcome of checking a chat draft before it is PATCHed.
class ChatValidation {
  const ChatValidation._(this.error);

  /// A sanitized message when invalid, or `null` when the draft is safe.
  final String? error;

  bool get isValid => error == null;

  static const ChatValidation valid = ChatValidation._(null);
  static const ChatValidation invalid = ChatValidation._(
    chatInvalidValuesError,
  );
}

/// Fail closed on any *present* field that cannot deserialize into
/// `ChatSettings`. Absent fields are left to the daemon's serde defaults.
ChatValidation validateChat(Map<String, dynamic> values) {
  for (final key in chatPersistedKeys) {
    if (!values.containsKey(key)) continue;
    final value = values[key];
    switch (key) {
      case 'sendMode':
        if (value is! String || !chatSendModes.contains(value)) {
          return ChatValidation.invalid;
        }
      case 'suggestMode':
        if (value is! String || !chatSuggestModes.contains(value)) {
          return ChatValidation.invalid;
        }
      case 'streamIdleTimeoutMs':
        // u64 on the wire: a double, a string or a BigInt beyond Dart's int
        // range would fail to deserialize.
        if (value is! int || value.isNegative) return ChatValidation.invalid;
      case 'showDirectorNotes':
      case 'combineSystemMessages':
        if (value is! bool) return ChatValidation.invalid;
    }
  }
  return ChatValidation.valid;
}

/// Fill only absent persisted fields with daemon defaults. Present values —
/// valid or not — are copied unchanged so [validateChat] still fails closed,
/// and unknown keys survive the round-trip untouched.
Map<String, dynamic> normalizeChat(Map<String, dynamic> values) {
  final result = Map<String, dynamic>.from(values);
  // Dart considers 30000.0 == 30000, but Rust's u64 serde rejects floats:
  // migrate only the exact int, so a malformed double survives and fails
  // closed at validation.
  if (result['streamIdleTimeoutMs'] is int &&
      result['streamIdleTimeoutMs'] == chatLegacyStreamIdleTimeoutMs) {
    result['streamIdleTimeoutMs'] = chatDefaults['streamIdleTimeoutMs'];
  }
  for (final entry in chatDefaults.entries) {
    if (result.containsKey(entry.key)) continue;
    result[entry.key] = entry.value;
  }
  return result;
}
