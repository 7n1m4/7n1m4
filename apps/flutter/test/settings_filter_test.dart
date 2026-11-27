// SPDX-License-Identifier: GPL-3.0-or-later

// Contract tests for the pure settings result filter. No widgets, no I/O:
// filtering is a deterministic function of its arguments alone.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/settings/settings_filter.dart';
import 'package:anima_control/features/settings/settings_search_results.dart';

SettingsResultItem item(
  String id, {
  required String title,
  String category = 'Settings',
  String? description,
}) {
  return SettingsResultItem(
    id: id,
    title: title,
    category: category,
    description: description,
  );
}

void main() {
  group('filterSettingsResults', () {
    test('case-insensitive substring match over human-readable fields', () {
      final results = filterSettingsResults(<SettingsResultItem>[
        item('one', title: 'Hello World', category: 'Primary Page'),
        item('two', title: 'Unrelated', category: 'Developer Tools'),
        item(
          'three',
          title: 'Something',
          category: 'System Preferences',
          description: 'An echo chamber',
        ),
      ], 'HELLO');
      expect(results.map((result) => result.id), <String>['one']);

      final byCategory = filterSettingsResults(<SettingsResultItem>[
        item('one', title: 'Hello', category: 'Primary Page'),
        item('two', title: 'Nope', category: 'Developer Tools'),
      ], 'developer');
      expect(byCategory.map((result) => result.id), <String>['two']);

      final byDescription = filterSettingsResults(<SettingsResultItem>[
        item('one', title: 'Hello', description: 'Echo chamber'),
        item('two', title: 'Nope', description: 'Nothing here'),
      ], 'echo');
      expect(byDescription.map((result) => result.id), <String>['one']);
    });

    test('matching never considers the id', () {
      final results = filterSettingsResults(<SettingsResultItem>[
        item('supersecretid', title: 'Nothing searchable here'),
        item('visible', title: 'Regular title'),
      ], 'secret');
      expect(results, isEmpty);
    });

    test('ties break deterministically by ascending id, not input order', () {
      const shuffled = <String>['c-id', 'a-id', 'b-id'];
      final items = shuffled.map(
        (id) => item(id, title: 'Shared theme', category: 'Shared category'),
      );

      final first = filterSettingsResults(items, 'shared');
      final again = filterSettingsResults(items.toList().reversed, 'shared');

      expect(first.map((result) => result.id), <String>[
        'a-id',
        'b-id',
        'c-id',
      ]);
      expect(again.map((result) => result.id), <String>[
        'a-id',
        'b-id',
        'c-id',
      ]);
    });

    test('empty or whitespace-only query preserves input order', () {
      final items = <SettingsResultItem>[
        item('pear', title: 'Pear'),
        item('apple', title: 'Apple'),
        item('banana', title: 'Banana'),
      ];

      expect(
        filterSettingsResults(items, '').map((result) => result.id),
        <String>['pear', 'apple', 'banana'],
      );
      expect(
        filterSettingsResults(items, '   \t\n ').map((result) => result.id),
        <String>['pear', 'apple', 'banana'],
      );
    });

    test('invalid and duplicate ids fail closed', () {
      final items = <SettingsResultItem>[
        item('', title: 'Empty id'),
        item('   ', title: 'Whitespace id'),
        item('/settings/providers/x', title: 'Composite route id'),
        item('card:123', title: 'Composite key id'),
        item('valid-a', title: 'Alpha'),
        item('valid-b', title: 'Beta'),
        item('valid-a', title: 'Alpha duplicate'),
      ];

      // Blank query: invalid rows are dropped, first duplicate wins, order kept.
      expect(
        filterSettingsResults(items, '').map((result) => result.id),
        <String>['valid-a', 'valid-b'],
      );
      // Substring query: same fail-closed rules apply before ranking.
      expect(
        filterSettingsResults(items, 'a').map((result) => result.id),
        <String>['valid-a', 'valid-b'],
      );
    });
  });

  group('SettingsResultItem', () {
    test('isValidId rejects empty, whitespace and composite ids', () {
      expect(SettingsResultItem.isValidId('simple-id_2'), isTrue);
      expect(SettingsResultItem.isValidId(''), isFalse);
      expect(SettingsResultItem.isValidId('  '), isFalse);
      expect(SettingsResultItem.isValidId('/settings/x'), isFalse);
      expect(SettingsResultItem.isValidId('card:123'), isFalse);
    });
  });
}
