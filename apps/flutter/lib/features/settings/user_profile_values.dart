// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure value helpers for the persisted `settings/user-profile` section.
///
/// Mirrors `UserProfileSettings` in `crates/anima-core/src/settings.rs:1154-1189`.
/// No widget, no transport, no state adapter: this library only reads and
/// copies maps, so it cannot write to the daemon on its own.
library;

/// Value-free error text. Raw field values are never echoed back, so a
/// hand-edited blob cannot leak secrets or confuse the user.
const String userProfileInvalidValuesError =
    'User profile settings contain invalid values. Check each field and try again.';

/// Every field the daemon persists, in camelCase wire spelling.
const List<String> userProfilePersistedKeys = <String>[
  'name',
  'description',
  'prompt',
  'voiceProfileId',
];

/// Serde defaults for legacy blobs that omit a field. `prompt` and
/// `voiceProfileId` default to empty; `name` and `description` have the
/// daemon's own non-empty defaults.
const Map<String, dynamic> userProfileDefaults = <String, dynamic>{
  'name': 'Richy',
  'description': 'A hands-on, down-to-earth creator who loves building things from scratch. Prefers honest, direct conversation and cozy downtime after a long day of work.',
  'prompt': '',
  'voiceProfileId': '',
};

/// An opaque voice-profile id: ASCII letters, digits, `_`, `-` and `.` only.
/// Empty is the daemon's "no profile selected" value. Separators, whitespace
/// and punctuation used to smuggle composite or injection-shaped ids are
/// rejected before any write.
final RegExp _voiceProfileIdPattern = RegExp(r'^[A-Za-z0-9._-]*$');

/// Outcome of checking a user-profile draft before it is PATCHed.
class UserProfileValidation {
  const UserProfileValidation._(this.error);

  /// A sanitized message when invalid, or `null` when the draft is safe.
  final String? error;

  bool get isValid => error == null;

  static const UserProfileValidation valid = UserProfileValidation._(null);
  static const UserProfileValidation invalid = UserProfileValidation._(
    userProfileInvalidValuesError,
  );
}

/// Fail closed on any *present* field that cannot deserialize into
/// `UserProfileSettings`, or on a structurally unsafe `voiceProfileId`.
/// Absent fields are left to the daemon's serde defaults.
UserProfileValidation validateUserProfile(Map<String, dynamic> values) {
  for (final key in userProfilePersistedKeys) {
    if (!values.containsKey(key)) continue;
    final value = values[key];
    // Every field is a String on the wire; serde rejects any other shape.
    if (value is! String) return UserProfileValidation.invalid;
    if (key == 'voiceProfileId' && !_voiceProfileIdPattern.hasMatch(value)) {
      return UserProfileValidation.invalid;
    }
  }
  return UserProfileValidation.valid;
}

/// Fill only absent persisted fields with daemon defaults. Present values —
/// valid or not — are copied unchanged so [validateUserProfile] still fails
/// closed, and unknown keys survive the round-trip untouched.
Map<String, dynamic> normalizeUserProfile(Map<String, dynamic> values) {
  final result = Map<String, dynamic>.from(values);
  for (final entry in userProfileDefaults.entries) {
    if (result.containsKey(entry.key)) continue;
    result[entry.key] = entry.value;
  }
  return result;
}
