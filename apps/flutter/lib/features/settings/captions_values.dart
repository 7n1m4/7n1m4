// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure value helpers for the persisted `settings/captions` section.
///
/// Mirrors `CaptionsSettings` in `crates/anima-core/src/settings.rs:807-861`.
/// No widget, no transport, no state adapter: this library only reads and
/// copies maps, so it cannot write to the daemon on its own.
library;

/// Value-free error text. Raw field values are never echoed back, so a
/// hand-edited blob cannot leak secrets or confuse the user.
const String captionsInvalidValuesError =
    'Captions settings contain invalid values. Check each field and try again.';

/// Every field the daemon persists, in camelCase wire spelling.
const List<String> captionsPersistedKeys = <String>[
  'enabled',
  'fontSize',
  'opacity',
  'docking',
  'followStageVisibility',
  'followStagePosition',
  'layoutMode',
  'resetTrigger',
  'headTetheredCaptionEnabled',
  'headTetheredCaptionOffset',
  'headTetheredCaptionFollowStrength',
];

/// Serde defaults for legacy blobs that omit a field.
const Map<String, dynamic> captionsDefaults = <String, dynamic>{
  'enabled': true,
  'fontSize': 100.0,
  'opacity': 20.0,
  'docking': 'none',
  'followStageVisibility': true,
  'followStagePosition': true,
  'layoutMode': 'single',
  'resetTrigger': 0,
  'headTetheredCaptionEnabled': false,
  'headTetheredCaptionOffset': <String, dynamic>{'x': 0.0, 'y': -15.0},
  'headTetheredCaptionFollowStrength': 100.0,
};

const Set<String> captionsDockingValues = <String>{
  'top',
  'bottom',
  'head',
  'none',
};

const Set<String> captionsLayoutModes = <String>{'single', 'multi'};

/// Outcome of checking a captions draft before it is PATCHed.
class CaptionsValidation {
  const CaptionsValidation._(this.error);

  /// A sanitized message when invalid, or `null` when the draft is safe.
  final String? error;

  bool get isValid => error == null;

  static const CaptionsValidation valid = CaptionsValidation._(null);
  static const CaptionsValidation invalid = CaptionsValidation._(
    captionsInvalidValuesError,
  );
}

/// Fail closed on any *present* field that cannot deserialize into
/// `CaptionsSettings`. Absent fields are left to the daemon's serde defaults.
CaptionsValidation validateCaptions(Map<String, dynamic> values) {
  for (final key in captionsPersistedKeys) {
    if (!values.containsKey(key)) continue;
    final value = values[key];
    switch (key) {
      case 'enabled':
      case 'followStageVisibility':
      case 'followStagePosition':
      case 'headTetheredCaptionEnabled':
        if (value is! bool) return CaptionsValidation.invalid;
      case 'fontSize':
        if (!_isInRange(value, 50, 200)) return CaptionsValidation.invalid;
      case 'opacity':
      case 'headTetheredCaptionFollowStrength':
        if (!_isInRange(value, 0, 100)) return CaptionsValidation.invalid;
      case 'docking':
        if (value is! String || !captionsDockingValues.contains(value)) {
          return CaptionsValidation.invalid;
        }
      case 'layoutMode':
        if (value is! String || !captionsLayoutModes.contains(value)) {
          return CaptionsValidation.invalid;
        }
      case 'resetTrigger':
        // u64 on the wire: a double or a negative would fail to deserialize.
        if (value is! int || value.isNegative) {
          return CaptionsValidation.invalid;
        }
      case 'headTetheredCaptionOffset':
        if (!_isOffset(value)) return CaptionsValidation.invalid;
    }
  }
  return CaptionsValidation.valid;
}

bool _isInRange(Object? value, num min, num max) =>
    value is num && value.isFinite && value >= min && value <= max;

bool _isOffset(Object? value) {
  if (value is! Map) return false;
  final x = value['x'];
  final y = value['y'];
  return x is num && x.isFinite && y is num && y.isFinite;
}

/// Fill only absent persisted fields with daemon defaults. Present values —
/// valid or not — are copied unchanged so [validateCaptions] still fails
/// closed, and unknown keys survive the round-trip untouched.
Map<String, dynamic> normalizeCaptions(Map<String, dynamic> values) {
  final result = Map<String, dynamic>.from(values);
  // Legacy blobs spelled this one field `font_size`. Migrate it at read time:
  // otherwise the defaults loop fills `fontSize` with 100 and the next
  // unrelated save silently replaces the user's size. A migrated value that
  // is out of range stays in the draft so validateCaptions still fails closed.
  if (result['fontSize'] == null && result['font_size'] != null) {
    result['fontSize'] = result['font_size'];
    result.remove('font_size');
  }
  for (final entry in captionsDefaults.entries) {
    if (result.containsKey(entry.key)) continue;
    final value = entry.value;
    result[entry.key] = value is Map ? Map<String, dynamic>.from(value) : value;
  }
  return result;
}
