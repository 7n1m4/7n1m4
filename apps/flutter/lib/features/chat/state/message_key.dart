// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
//
// In-memory opaque message identity. Nothing here parses a wire envelope,
// extracts an epoch, or joins/splits composite strings.

/// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
///
/// Immutable, opaque identity for a locally observed message. The raw id stays
/// private; equality and hashing use the exact string, character for character.
class MessageKey {
  MessageKey._(this._raw);

  /// Fails closed: null, blank, composite/wire-shaped and long-digit ids are
  /// rejected outright. The stored id is never coerced or normalized.
  factory MessageKey(String? raw) {
    final rejection = _rejectionReason(raw);
    if (rejection != null) throw ArgumentError.value(raw, 'raw', rejection);
    return MessageKey._(raw!);
  }

  final String _raw;

  static const _compositeSeparators = <String>{':', '|', '/'};
  static const _epochPrefixLength = 10;
  static const _asciiDigitZero = 48;
  static const _decimalDigitZeros = <int>{
    0x0030, // ASCII
    0x0660, // Arabic-Indic
    0x06F0, // Extended Arabic-Indic
    0x0966, // Devanagari
    0x09E6, // Bengali
    0x0E50, // Thai
    0xFF10, // Fullwidth
  };

  /// Validation-only ASCII folding: maps Unicode decimal digits onto ASCII
  /// digits so a smuggled digit run cannot hide in another digit script. The
  /// returned string is discarded; equality and hash keep the exact raw id.
  static String _foldDigitsToAscii(String raw) {
    final codes = <int>[];
    for (final unit in raw.codeUnits) {
      final digit = _asciiDigitValue(unit);
      codes.add(digit < 0 ? unit : _asciiDigitZero + digit);
    }
    return String.fromCharCodes(codes);
  }

  static int _asciiDigitValue(int unit) {
    for (final zero in _decimalDigitZeros) {
      if (unit >= zero && unit <= zero + 9) return unit - zero;
    }
    return -1;
  }

  /// Structural rejection only: scan for forbidden shapes. No splitting, no
  /// epoch extraction and no joining happen here.
  static String? _rejectionReason(String? raw) {
    if (raw == null) return 'id must not be null';
    if (raw.trim().isEmpty) return 'id must not be empty or whitespace-only';

    for (final separator in _compositeSeparators) {
      if (raw.contains(separator)) {
        return 'id must not contain composite separator [$separator]';
      }
    }

    // A long consecutive digit run anywhere is an embedded epoch-like token;
    // do not stop at the first non-digit or at the start of the string.
    var run = 0;
    for (final unit in _foldDigitsToAscii(raw.trim()).codeUnits) {
      if (unit >= _asciiDigitZero && unit <= _asciiDigitZero + 9) {
        run++;
        if (run >= _epochPrefixLength) {
          return 'id must not carry an epoch prefix';
        }
      } else {
        run = 0;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MessageKey && other._raw == _raw;

  @override
  int get hashCode => _raw.hashCode;

  @override
  String toString() => 'MessageKey($_raw)';
}
