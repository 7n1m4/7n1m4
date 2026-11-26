// SPDX-License-Identifier: GPL-3.0-or-later

// Pure-Dart port of a BOUNDED SUBSET of the TS math/chemistry speech
// transformers. Sources:
//   packages/speech-transformer-math/src/numbers.ts:12-132  (spellNumber)
//   packages/speech-transformer-chem/src/chem.ts:189-208    (spellFormula)
//   packages/speech-transformer-chem/src/chem.ts:224-287    (speakChemistry)
//   packages/speech-transformer-chem/src/locales/en.ts:6-29 (English words)
//   packages/stage-ui/src/utils/math-speech.ts:31-58,139-199 (helpers)
// Not package parity: no TeX/KaTeX/MathJSON/mhchemparser parser is ported.
// speakChemistry takes an already-shaped MathJSON value: a String head or
// quoted text, a Map with a 'num' key, or a List whose first item is the head.

const _maxGroupedDigits = 12;

const _enOnes = <String>[
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const _enTens = <String>['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
const _enScales = <String>['', 'thousand', 'million', 'billion'];
const _enDivisors = <int>[1, 1000, 1000000, 1000000000];

const _jaDigits = <String>['ゼロ', 'いち', 'に', 'さん', 'よん', 'ご', 'ろく', 'なな', 'はち', 'きゅう'];
// Rendaku and gemination of 百 and 千, for example さんびゃく and はっせん.
const _jaHundreds = <String>['', 'ひゃく', 'にひゃく', 'さんびゃく', 'よんひゃく', 'ごひゃく', 'ろっぴゃく', 'ななひゃく', 'はっぴゃく', 'きゅうひゃく'];
const _jaThousands = <String>['', 'せん', 'にせん', 'さんぜん', 'よんせん', 'ごせん', 'ろくせん', 'ななせん', 'はっせん', 'きゅうせん'];
const _jaScales = <String>['', 'まん', 'おく'];

const _koDigits = <String>['영', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];
const _koScales = <String>['', '만', '억'];
const _tenThousandDivisors = <int>[1, 10000, 100000000];

/// Spells a decimal number as words in `en`, `ja`, or `ko`.
///
/// Grouping commas are ignored: `1,200` is `one thousand two hundred` here.
/// See [speakNumberGroups] for the full pipeline's different reading of it.
String spellNumber(String source, String language) {
  final parts = source.replaceAll(',', '').split('.');
  final integer = parts.first;
  final fraction = parts.length > 1 ? parts[1] : null;

  // Digits after the point are read one by one. English words need spaces;
  // kana and hangul digits are one syllable each and join.
  String byDigit(String digits) => digits
      .split('')
      .map((digit) => _digitFor(language, digit))
      .join(language == 'en' ? ' ' : '');

  // A leading zero, as `007`, is a code or a label, so its digits stay.
  String whole;
  if (integer.length > _maxGroupedDigits || RegExp(r'^0\d').hasMatch(integer)) {
    whole = byDigit(integer);
  } else {
    final literal = integer.trim().isEmpty ? '0' : integer;
    final number = num.tryParse(literal);
    // Dart returns null where JS Number() returns NaN for real garbage such
    // as 'abc' or '12a'; both must reach the TS spellers' NaN artifacts.
    whole = number == null || number.isNaN || number.isInfinite
        ? _nonFiniteInteger(language)
        : _integerFor(language, literal);
  }
  if (fraction == null) return whole;
  switch (language) {
    case 'ja':
      return '$wholeてん${byDigit(fraction)}';
    case 'ko':
      return '$whole 점 ${byDigit(fraction)}';
    default:
      return '$whole point ${byDigit(fraction)}';
  }
}

String _digitFor(String language, String digit) {
  final index = int.tryParse(digit);
  if (index == null) return ''; // JS spells an unparseable digit as nothing.
  final digits = switch (language) {
    'ja' => _jaDigits,
    'ko' => _koDigits,
    _ => _enOnes,
  };
  return index >= 0 && index < digits.length ? digits[index] : '';
}

String _nonFiniteInteger(String language) => switch (language) {
      'ja' => 'undefinedじゅうおくundefinedじゅうまんundefinedじゅう',
      'ko' => 'undefined천undefined백undefined십undefined억undefined천undefined백undefined십undefined만undefined천undefined백undefined십undefined',
      _ => '',
    };

String _integerFor(String language, String digits) {
  switch (language) {
    case 'ja':
      return _jaInteger(digits);
    case 'ko':
      return _koInteger(digits);
    default:
      return _enInteger(digits);
  }
}

String _enBelowThousand(int value) {
  final words = <String>[];
  final hundreds = value ~/ 100;
  final rest = value % 100;
  if (hundreds > 0) words.add('${_enOnes[hundreds]} hundred');
  if (rest >= 20) {
    words.add(rest % 10 == 0 ? _enTens[rest ~/ 10] : '${_enTens[rest ~/ 10]}-${_enOnes[rest % 10]}');
  } else if (rest > 0) {
    words.add(_enOnes[rest]);
  }
  return words.join(' ');
}

String _enInteger(String digits) {
  // JS Number() also accepts scientific notation, for example '1e-7'.
  final value = num.tryParse(digits) ?? 0;
  if (value == 0) return 'zero';
  final words = <String>[];
  for (var scale = _enScales.length - 1; scale >= 0; scale--) {
    final group = (value ~/ _enDivisors[scale]) % 1000;
    if (group > 0) words.add([_enBelowThousand(group), _enScales[scale]].where((word) => word.isNotEmpty).join(' '));
  }
  return words.join(' ');
}

String _jaBelowTenThousand(int value) {
  final thousands = value ~/ 1000;
  final hundreds = value ~/ 100 % 10;
  final tens = value ~/ 10 % 10;
  final ones = value % 10;
  return [
    _jaThousands[thousands],
    _jaHundreds[hundreds],
    tens == 0 ? '' : tens == 1 ? 'じゅう' : '${_jaDigits[tens]}じゅう',
    ones == 0 ? '' : _jaDigits[ones],
  ].join('');
}

String _jaInteger(String digits) {
  final value = num.tryParse(digits) ?? 0;
  if (value == 0) return _jaDigits[0];
  final buffer = StringBuffer();
  for (var scale = _jaScales.length - 1; scale >= 0; scale--) {
    final group = (value ~/ _tenThousandDivisors[scale]) % 10000;
    if (group == 0) continue;
    // 一万 is いちまん, but 千 alone is せん. Before 万 and 億, 一千 is いっせん.
    final thousand = scale > 0 && group ~/ 1000 == 1 ? 'いっ' : '';
    buffer.write("${scale > 0 && group == 1 ? 'いち' : thousand + _jaBelowTenThousand(group)}${_jaScales[scale]}");
  }
  return buffer.toString();
}

String _koBelowTenThousand(int value) {
  final parts = <(int count, String unit)>[
    (value ~/ 1000, '천'),
    (value ~/ 100 % 10, '백'),
    (value ~/ 10 % 10, '십'),
  ];
  // Sino-Korean drops 일 before 십, 백, and 천: 십이, not 일십이.
  final prefix = parts.map((part) => part.$1 == 0 ? '' : "${part.$1 == 1 ? '' : _koDigits[part.$1]}${part.$2}").join();
  final ones = value % 10;
  return prefix + (ones == 0 ? '' : _koDigits[ones]);
}

String _koInteger(String digits) {
  final value = num.tryParse(digits) ?? 0;
  if (value == 0) return _koDigits[0];
  final buffer = StringBuffer();
  for (var scale = _koScales.length - 1; scale >= 0; scale--) {
    final group = (value ~/ _tenThousandDivisors[scale]) % 10000;
    if (group == 0) continue;
    // 만 alone is 10000, without 일.
    buffer.write("${scale == 1 && group == 1 ? '' : _koBelowTenThousand(group)}${_koScales[scale]}");
  }
  return buffer.toString();
}

/// Reads a formula symbol by symbol: each element by its letters, each count
/// as a number, and the parentheses of a group as words. Mirrors `spellFormula`
/// with the English lexicon, for example `Ca(OH)2` as
/// "C A open parenthesis O H close parenthesis two".
String spellFormula(String core) {
  final words = <String>[];
  for (final match in RegExp(r'([A-Z][a-z]?)(\d*)|\((?=[A-Z])|\)(\d*)').allMatches(core)) {
    final element = match.group(1);
    final count = match.group(2);
    final groupCount = match.group(3);
    if (element != null) {
      words.addAll(element.split('').map((letter) => letter.toUpperCase()));
      if (count!.isNotEmpty) words.add(spellNumber(count, 'en'));
    } else if (match.group(0) == '(') {
      words.add('open parenthesis');
    } else {
      words.add('close parenthesis');
      if (groupCount!.isNotEmpty) words.add(spellNumber(groupCount, 'en'));
    }
  }
  return words.join(' ');
}

bool _isFunction(Object? value) => value is List<Object?> && value.isNotEmpty && value.first is String;
bool _isNumber(Object? value) => value is Map<String, Object?> && value['num'] is String;

List<Object?> _argsOf(Object? value) => _isFunction(value) ? (value as List<Object?>).skip(1).toList() : const <Object?>[];
String _headOf(Object? value) => _isFunction(value) ? (value as List<Object?>).first as String : '';
String _textOf(Object? value) => value is String && value.length >= 2 && value.startsWith("'") && value.endsWith("'")
    ? value.substring(1, value.length - 1)
    : '';

class _Species {
  _Species(this.core, this.charge, this.coefficient);

  final String core;
  final String? charge;
  final String? coefficient;
}

_Species _chemSpecies(Object? expression) {
  final args = _argsOf(expression);
  final source = _textOf(args.isEmpty ? 'Nothing' : args[0]);
  final parts = source.split('^');
  final coefficient = args.length > 1 && _isNumber(args[1]) ? (args[1] as Map<String, Object?>)['num'] as String : null;
  return _Species(parts.first, parts.length > 1 ? parts[1] : null, coefficient);
}

// English chemistry words (locales/en.ts): names are empty, so a species is
// always read from its symbols; charges end in "ion" inside an equation.
String _ion(String formula, String charge, bool inEquation) {
  final magnitude = charge.length > 1 ? charge.substring(0, charge.length - 1) : '';
  final number = magnitude.isEmpty ? '' : spellNumber(magnitude, 'en');
  final sign = charge.endsWith('+') ? 'plus' : 'minus';
  return "$formula $number $sign${inEquation ? ' ion' : ''}".replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _symbols(_Species item) => spellFormula(item.core);

String _alone(_Species item) {
  final symbols = _symbols(item);
  final charge = item.charge;
  return charge == null || charge.isEmpty ? symbols : _ion(symbols, charge, false);
}

String _name(_Species item) {
  final symbols = _symbols(item);
  final charge = item.charge;
  return charge == null || charge.isEmpty ? symbols : '$symbols ${_ion('', charge, true).trim()}';
}

String _term(Object? value, bool inEquation) {
  final head = _headOf(value);
  if (head == 'Gas' || head == 'Precipitate') {
    final inner = _term(_argsOf(value).isEmpty ? 'Nothing' : _argsOf(value).first, inEquation);
    return '$inner ${head == 'Gas' ? 'gas' : 'precipitate'}';
  }
  if (head == 'Text') return _textOf(_argsOf(value).isEmpty ? 'Nothing' : _argsOf(value).first);

  // English has no whole-formula names and spells formulas, so a hydrate in
  // an equation is read part by part just like one on its own.
  final parts = head == 'Hydrate' ? _argsOf(value) : <Object?>[value];
  final spoken = parts.map((part) {
    final item = _chemSpecies(part);
    final reading = inEquation ? _name(item) : _alone(item);
    final coefficient = item.coefficient == null ? null : spellNumber(item.coefficient!, 'en');
    return coefficient == null ? reading : '$coefficient $reading';
  });
  // Spaces keep the dot apart: よんドットご would run together in a compact language.
  return spoken.join(' dot ');
}

String _side(Object? value, bool inEquation) {
  final terms = _argsOf(value).map((item) => _term(item, inEquation)).toList();
  if (terms.isEmpty) return '';
  return terms.reduce((left, right) => '$left plus $right');
}

/// Reads an already-shaped `Chemistry` MathJSON expression in English.
///
/// This is the English locale of `speakChemistry` only; the language is not a
/// parameter. Other locales and all parsing are out of scope for this port.
String speakChemistry(Object? expression) {
  final content = _argsOf(expression).isEmpty ? 'Nothing' : _argsOf(expression).first;
  if (!_isFunction(content) || _headOf(content) != 'Reaction') return _side(content, false);

  final args = _argsOf(content);
  final arrow = _textOf(args.isEmpty ? 'Nothing' : args[0]);
  final left = args.length > 1 ? args[1] : 'Nothing';
  final right = args.length > 2 ? args[2] : 'Nothing';
  final condition = args.length > 3 ? args[3] : 'Nothing';

  // English has no `decompose` override, so the plain arrow reading is used
  // even for a one-to-many decomposition.
  String equation;
  switch (arrow) {
    case '->':
      equation = '${_side(left, true)} yields ${_side(right, true)}';
    case '<=>':
      equation = '${_side(left, true)} is in equilibrium with ${_side(right, true)}';
    case '<-':
      equation = '${_side(right, true)} yields ${_side(left, true)}';
    default:
      // No locale defines this reading; an untrusted arrow must not crash the
      // reader, so fall back to the forward "yields" form.
      equation = '${_side(left, true)} yields ${_side(right, true)}';
  }
  if (condition == 'Nothing') return equation;
  final spokenCondition = _headOf(condition) == 'Heat'
      ? 'heat'
      : _textOf(_argsOf(condition).isEmpty ? 'Nothing' : _argsOf(condition).first);
  return 'with $spokenCondition $equation';
}

/// The `1,200` trap: the full MathSpeech pipeline lowers a top-level grouped
/// number to a `Sequence` of its groups and speaks it as `one, two hundred`,
/// unlike [spellNumber]'s `one thousand two hundred`. Bounded to this shape.
String speakNumberGroups(String source) => source.split(',').map((group) => spellNumber(group, 'en')).join(', ');

final _kana = RegExp(r'[\p{Script=Hiragana}\p{Script=Katakana}]', unicode: true);
final _hangul = RegExp(r'\p{Script=Hangul}', unicode: true);
final _han = RegExp(r'\p{Script=Han}', unicode: true);
final _latinWord = RegExp(r'[a-z]{2,}', caseSensitive: false);

/// Selects the language of a formula or price from its surrounding words.
String detectSpeechLanguage(String context, [String? fallback]) {
  if (_kana.hasMatch(context)) return 'ja';
  if (_hangul.hasMatch(context)) return 'ko';
  if (_han.hasMatch(context)) return fallback == 'ja' ? 'ja' : 'zh';
  if (_latinWord.hasMatch(context)) return 'en';
  return fallback ?? 'en';
}

/// Braces a multi-digit or decimal script in bare TeX, for example `2^10`.
String braceBareScripts(String tex) => tex.replaceAllMapped(
      RegExp(r'([\^_])(\d{2,}(?:\.\d+)?|\d+\.\d+)'),
      (match) => '${match.group(1)}{${match.group(2)}}',
    );

/// Replaces balanced `\command{...}` invocations in [text], skipping escaped
/// commands and unbalanced groups.
String replaceBalancedCommand(
  String text,
  String command,
  String Function(String fullMatch, String inner) replacer,
) {
  final prefix = '\\$command{';
  var index = 0;
  final result = StringBuffer();
  while (index < text.length) {
    final start = text.indexOf(prefix, index);
    if (start == -1) {
      result.write(text.substring(index));
      break;
    }
    var backslashes = 0;
    var b = start - 1;
    while (b >= 0 && text[b] == '\\') {
      backslashes++;
      b--;
    }
    if (backslashes.isOdd) {
      result.write(text.substring(index, start + prefix.length));
      index = start + prefix.length;
      continue;
    }

    result.write(text.substring(index, start));
    var depth = 1;
    var pos = start + prefix.length;
    while (pos < text.length && depth > 0) {
      if (text[pos] == '\\') {
        pos += 2;
        continue;
      }
      if (text[pos] == '{') {
        depth++;
      } else if (text[pos] == '}') {
        depth--;
      }
      pos++;
    }
    if (depth == 0) {
      result.write(replacer(text.substring(start, pos), text.substring(start + prefix.length, pos - 1)));
    } else {
      result.write(text.substring(start, pos));
    }
    index = pos;
  }
  return result.toString();
}
