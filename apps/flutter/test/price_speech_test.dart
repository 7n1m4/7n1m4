// SPDX-License-Identifier: GPL-3.0-or-later

// Pure-Dart port of the price-verbalization helpers from
// packages/stage-ui/src/stores/modules/speech.ts:35-103. Cases mirror
// packages/stage-ui/src/stores/modules/speech.test.ts:24-63.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/price_speech.dart';

void main() {
  group('integerToWords', () {
    test('converts single digits and zero', () {
      expect(integerToWords(0), 'zero');
      expect(integerToWords(7), 'seven');
    });

    test('converts teens and tens', () {
      expect(integerToWords(13), 'thirteen');
      expect(integerToWords(19), 'nineteen');
      expect(integerToWords(20), 'twenty');
      expect(integerToWords(42), 'forty-two');
      expect(integerToWords(99), 'ninety-nine');
    });

    test('converts hundreds and thousands', () {
      expect(integerToWords(100), 'one hundred');
      expect(integerToWords(305), 'three hundred five');
      expect(integerToWords(1250), 'one thousand two hundred fifty');
    });

    test('handles negative numbers', () {
      expect(integerToWords(-5), 'minus five');
    });

    test('converts an exact thousand', () {
      expect(integerToWords(1000), 'one thousand');
    });

    test('does not stack-overflow on the most negative int', () {
      const minInt = -9223372036854775807 - 1;
      expect(() => integerToWords(minInt), returnsNormally);
      expect(integerToWords(minInt), startsWith('minus '));
    });
  });

  group('verbalizePrices', () {
    test('converts dollars and cents naturally', () {
      expect(
        verbalizePrices('Your total is \$19.99.'),
        'Your total is nineteen dollars and ninety-nine cents.',
      );
      expect(
        verbalizePrices('Only \$0.50 per ticket'),
        'Only fifty cents per ticket',
      );
      expect(
        verbalizePrices('Costs \$5!'),
        'Costs five dollars!',
      );
      expect(
        verbalizePrices('Total: \$1,200.50'),
        'Total: one thousand two hundred dollars and fifty cents',
      );
    });

    test('covers singular, one-cent, zero-cents and single-digit cents', () {
      expect(verbalizePrices('\$1'), 'one dollar');
      expect(verbalizePrices('\$1.01'), 'one dollar and one cent');
      // TS zero-pads a lone cent digit, so \$0.5 is fifty cents (as is \$0.50).
      expect(verbalizePrices('\$0.5'), 'fifty cents');
      expect(verbalizePrices('\$19.00'), 'nineteen dollars');
    });

    test('passes out-of-range amounts through unchanged without throwing', () {
      for (final amount in <String>['\$1000000', '\$2000000', '\$10000000']) {
        expect(() => verbalizePrices(amount), returnsNormally);
        expect(verbalizePrices(amount), amount);
      }
    });
  });
}
