// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/chat/state/message_dedupe_index.dart';
import 'package:anima_control/features/chat/state/message_key.dart';

void main() {
  group('MessageKey value semantics', () {
    test('equality and hash come from the exact raw id string, no parsing', () {
      const raw = 'msg_plain-opaque-id.42';
      final first = MessageKey(raw);
      final second = MessageKey(raw);
      final different = MessageKey('msg_other');

      expect(first, second);
      expect(first, isNot(same(second)));
      expect(first.hashCode, second.hashCode);
      expect(first.hashCode, raw.hashCode);
      expect(first == different, isFalse);
      expect(first.hashCode == different.hashCode, isFalse);
    });

    test('toString is diagnostics only and keeps the raw value private', () {
      final key = MessageKey('opaque-1');

      expect(key.toString(), contains('MessageKey'));
    });
  });

  group('MessageKey fails closed on invalid ids', () {
    test('null, empty and whitespace-only ids are rejected', () {
      for (final invalid in <String?>[null, '', '   ', '\t', '\n', ' \t\n ']) {
        expect(
          () => MessageKey(invalid),
          throwsArgumentError,
          reason:
              'expected rejection for ${invalid == null ? 'null' : '[$invalid]'}',
        );
      }
    });

    test(
      'composite and wire-shaped ids are rejected, not split or coerced',
      () {
        for (final invalid in <String>[
          'epoch:1700000000000:seq:3',
          'room:general|msg:42',
          'topic|id',
          'channel/room/msg',
          'a/b:c|d',
          '1700000000000:msg',
        ]) {
          expect(
            () => MessageKey(invalid),
            throwsArgumentError,
            reason: 'expected rejection for [$invalid]',
          );
        }
      },
    );

    test('epoch-prefixed ids are rejected', () {
      for (final invalid in <String>[
        '1700000000000',
        '1700000000000-msg',
        '1700000000000_msg',
        '1700000000000.abc',
        '1234567890tail',
      ]) {
        expect(
          () => MessageKey(invalid),
          throwsArgumentError,
          reason: 'expected rejection for [$invalid]',
        );
      }
    });

    test('digit runs smuggled past the old index-0 guard are rejected', () {
      expect(() => MessageKey(' 1700000000000'), throwsArgumentError);
      expect(() => MessageKey('+1700000000000'), throwsArgumentError);
      expect(() => MessageKey('-1700000000000'), throwsArgumentError);
      expect(() => MessageKey('１７０００００００００００'), throwsArgumentError);
    });
  });

  group('MessageDedupeIndex', () {
    test('repeated opaque ids dedupe to one entry in first-seen order', () {
      final index = MessageDedupeIndex();
      final first = MessageKey('alpha');
      final second = MessageKey('beta');
      final third = MessageKey('gamma');

      expect(index.insert(first), isTrue);
      expect(index.insert(second), isTrue);
      expect(index.insert(first), isFalse);
      expect(index.insert(third), isTrue);
      expect(index.insert(MessageKey('beta')), isFalse);

      expect(index.length, 3);
      expect(index.keys, <MessageKey>[first, second, third]);
      expect(index.contains(first), isTrue);
      expect(index.contains(second), isTrue);
      expect(index.contains(MessageKey('gamma')), isTrue);
      expect(index.contains(MessageKey('missing')), isFalse);
    });

    test('the key-based and raw-based insert paths dedupe identically', () {
      final index = MessageDedupeIndex();
      final key = MessageKey('same-id');

      expect(index.insert(key), isTrue);
      expect(index.insertId('same-id'), isFalse);
      expect(index.contains(key), isTrue);
      expect(index.containsId('same-id'), isTrue);
      expect(index.length, 1);
      expect(index.keys, <MessageKey>[key]);
    });

    test(
      'the index rejects invalid ids through its raw insert and lookup paths',
      () {
        final index = MessageDedupeIndex();

        for (final invalid in <String?>[null, '', '  ', 'a:b', 'a|b', 'a/b']) {
          expect(
            () => index.insertId(invalid),
            throwsArgumentError,
            reason: 'insertId must reject [$invalid]',
          );
          expect(
            () => index.containsId(invalid),
            throwsArgumentError,
            reason: 'containsId must reject [$invalid]',
          );
        }

        for (final invalid in <String>['1700000000000-msg', '1234567890tail']) {
          expect(
            () => index.insertId(invalid),
            throwsArgumentError,
            reason: 'insertId must reject epoch-prefixed [$invalid]',
          );
        }

        // A rejected attempt leaves the index untouched.
        expect(index.length, 0);
        expect(index.keys, isEmpty);
      },
    );

    test(
      'a valid insert after rejected attempts still keeps first-seen order',
      () {
        final index = MessageDedupeIndex();

        expect(() => index.insertId('bad:id'), throwsArgumentError);
        expect(index.insertId('good-one'), isTrue);
        expect(() => index.insertId(''), throwsArgumentError);
        expect(index.insertId('good-two'), isTrue);
        expect(index.insertId('good-one'), isFalse);

        expect(index.keys.map((key) => key.toString()).toList(), <String>[
          MessageKey('good-one').toString(),
          MessageKey('good-two').toString(),
        ]);
      },
    );
  });
}
