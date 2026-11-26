// SPDX-License-Identifier: GPL-3.0-or-later

// Pure Dart port of packages/stage-ui/src/stores/modules/speech.ts:
// toSignedPercent and generateSSML. No registry, profiles or cache.
// Verified against the repo-pinned xast-util-to-xml: escaping emits numeric
// character references (`&#x26;`, `&#x3C;`, `&#x22;`), `>` stays literal,
// and the default attribute order is preserved.

/// Language and gender fields of a voice used by [generateSSML].
///
/// Mirrors the subset of the TS `VoiceInfo` that the SSML builder reads:
/// `id`, `gender` and `languages[0].code` (flattened to [languageCode]).
class SsmlVoice {
  const SsmlVoice({
    required this.id,
    this.gender,
    this.languageCode = 'en-US',
  });

  final String id;
  final String? gender;
  final String languageCode;
}

/// Formats a signed percentage: `25` -> `+25%`, `-20` -> `-20%`, `0` -> `0%`.
String toSignedPercent(num value) {
  if (value > 0) {
    return '+${_numberText(value)}%';
  }
  if (value < 0) {
    return '-${_numberText(value.abs())}%';
  }
  return '0%';
}

/// Builds `<speak><voice><prosody>` SSML for [text] and [voice].
///
/// [providerConfig] supplies optional `pitch`, `speed` (rate) and `volume`
/// values. Non-numeric values are coerced as JS relational comparison does
/// (e.g. `toSignedPercent('loud')` yields `0%`); a speed of exactly `1` is
/// emitted as `rate="1"`. Text and attribute values are XML-escaped with
/// numeric character references, and XML noncharacters are dropped.
String generateSSML(
  String text,
  SsmlVoice voice, [
  Map<String, dynamic>? providerConfig,
]) {
  final pitch = providerConfig?['pitch'];
  final speed = providerConfig?['speed'];
  final volume = providerConfig?['volume'];

  final pitchText = pitch == null ? null : toSignedPercent(_asNum(pitch));
  final rateText = speed == null ? null : _rateText(speed);
  final volumeText = volume == null ? null : toSignedPercent(_asNum(volume));

  final hasProsody = pitchText != null || rateText != null || volumeText != null;
  final body = _escapeText(text);
  final content = hasProsody
      ? '<prosody'
          '${_attribute('pitch', pitchText)}'
          '${_attribute('rate', rateText)}'
          '${_attribute('volume', volumeText)}'
          '>$body</prosody>'
      : body;

  final language = voice.languageCode.isEmpty ? 'en-US' : voice.languageCode;
  final gender = (voice.gender ?? '').isEmpty ? 'neutral' : voice.gender!;

  return '<speak version="1.0"'
      ' xmlns="http://www.w3.org/2001/10/synthesis"'
      ' xml:lang="${_escapeAttribute(language)}">'
      '<voice name="${_escapeAttribute(voice.id)}"'
      ' gender="${_escapeAttribute(gender)}">'
      '$content'
      '</voice></speak>';
}

String _attribute(String name, String? value) =>
    value == null ? '' : ' $name="${_escapeAttribute(value)}"';

// JS relational comparison coerces non-numbers: a non-numeric string is not
// > 0 or < 0, so toSignedPercent reports 0% instead of ignoring the field.
num _asNum(Object? value) {
  if (value is num) {
    return value;
  }
  if (value is String) {
    return num.tryParse(value) ?? 0;
  }
  return 0;
}

String _rateText(Object? value) {
  // JS `${speed}` renders a non-numeric string verbatim.
  if (value is String && num.tryParse(value) == null) {
    return value;
  }
  final speed = _asNum(value);
  return speed == 1 ? '1' : _numberText(speed);
}

// JS template literals render integral doubles without a trailing `.0`.
// Trimming the suffix avoids double.toInt() clamping above 2^63-1.
String _numberText(num value) {
  final s = value.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

// xast-util-to-xml (stringifyEntitiesLight) emits numeric character refs.
// Text escapes `&` and `<`; attribute values also escape `"`. C0 controls
// outside tab/newline/CR are removed first. `>` is left as-is.
final RegExp _noncharacter = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

String _escapeText(String value) => value
    .replaceAll(_noncharacter, '')
    .replaceAll('&', '&#x26;')
    .replaceAll('<', '&#x3C;');

String _escapeAttribute(String value) =>
    _escapeText(value).replaceAll('"', '&#x22;');
