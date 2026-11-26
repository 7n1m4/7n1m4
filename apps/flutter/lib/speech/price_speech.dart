// SPDX-License-Identifier: GPL-3.0-or-later

// Pure-Dart port of the price-verbalization helpers from
// packages/stage-ui/src/stores/modules/speech.ts:35-103. English-only, like
// the TS source; the `_language` argument is kept for signature parity.

/// Converts a non-negative (or negative) integer into English words.
///
/// Mirrors `integerToWords` in speech.ts: handles zero, a minus prefix,
/// units/teens/tens up to 999, and groups up to quintillions. Uses a BigInt
/// magnitude so the most negative int cannot overflow during negation.
String integerToWords(int num) {
  if (num == 0) return 'zero';

  const ones = <String>[
    '', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
    'sixteen', 'seventeen', 'eighteen', 'nineteen',
  ];
  const tens = <String>[
    '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty',
    'ninety',
  ];
  const scales = <String>[
    '', 'thousand', 'million', 'billion', 'trillion', 'quadrillion',
    'quintillion',
  ];

  String convertThreeDigits(int n) {
    var str = '';
    if (n >= 100) {
      str += '${ones[n ~/ 100]} hundred';
      n = n % 100;
      if (n > 0) str += ' ';
    }
    if (n >= 20) {
      str += tens[n ~/ 10];
      n = n % 10;
      if (n > 0) str += '-${ones[n]}';
    } else if (n > 0) {
      str += ones[n];
    }
    return str;
  }

  // Negating minInt as an int wraps back to itself and would recurse forever.
  var magnitude = BigInt.from(num).abs();
  final groupBase = BigInt.from(1000);
  final groups = <int>[];
  while (magnitude > BigInt.zero) {
    groups.add((magnitude % groupBase).toInt());
    magnitude ~/= groupBase;
  }

  final parts = <String>[];
  for (var i = groups.length - 1; i >= 0; i--) {
    if (groups[i] == 0) continue;
    final words = convertThreeDigits(groups[i]);
    parts.add(scales[i].isEmpty ? words : '$words ${scales[i]}');
  }

  final result = parts.join(' ');
  return num < 0 ? 'minus $result' : result;
}

/// Rewrites dollar amounts in [text] into spoken English.
///
/// Matches `$19.99`, `$1,200.50`, `$5`, `$0.50`, etc. The [language] argument
/// is accepted for parity with the TS source but is currently English-only.
String verbalizePrices(String text, [String language = 'en']) {
  // Matches dollar amounts like $19.99, $1,200.50, $5, $0.50.
  const priceRegex = r'\$(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{1,2}))?(?=$|[\s,.;:!?)\]])';

  return text.replaceAllMapped(RegExp(priceRegex), (match) {
    final whole = match.group(0)!;
    final dollars = int.tryParse(match.group(1)!.replaceAll(',', ''));
    // Beyond the word table's range, leave the amount untouched instead of
    // emitting a wrong value (or throwing on an out-of-range group index).
    if (dollars == null || dollars >= 1000000) return whole;

    final dollarsWord = integerToWords(dollars);
    final dollarUnit = dollars == 1 ? 'dollar' : 'dollars';

    final centsStr = match.group(2);
    if (centsStr != null) {
      final paddedCents = centsStr.length == 1 ? '${centsStr}0' : centsStr;
      final cents = int.tryParse(paddedCents);
      if (cents != null && cents > 0) {
        final centsWord = integerToWords(cents);
        final centUnit = cents == 1 ? 'cent' : 'cents';
        if (dollars == 0) return '$centsWord $centUnit';
        return '$dollarsWord $dollarUnit and $centsWord $centUnit';
      }
    }

    return '$dollarsWord $dollarUnit';
  });
}
