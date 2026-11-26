// SPDX-License-Identifier: GPL-3.0-or-later

// Pure Dart mirror of the provider-instance helper half of
// packages/stage-ui/src/stores/providers/runtime/instance-store.ts
// (21-22, 127-152, 186-189, 223-310). Cases adapted from
// instance-store.phase5.test.ts:354-409 and its surrounding removeInstance /
// sort coverage. Credential-shaped values are unmistakable placeholders.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/provider_instance.dart';

const Map<String, dynamic> _credentials = <String, dynamic>{
  'apiKey': '<apiKey>',
  'baseUrl': 'https://example.invalid/v1',
};

Map<String, dynamic> _row({
  required String id,
  required String providerId,
  required String label,
  required Map<String, dynamic> options,
  bool isPrimary = false,
}) =>
    <String, dynamic>{
      'instanceId': '$providerId:$id',
      'id': id,
      'providerId': providerId,
      'label': label,
      'options': options,
      'isPrimary': isPrimary,
    };

void main() {
  group('provider instance helpers (pure instance-store.ts mirror)', () {
    test('addInstance builds a clean slug and never repeats the provider id',
        () {
      final rows = <String, Map<String, dynamic>>{};

      final row = addInstance(
        rows,
        'openai-compatible',
        'vLLM Server',
        _credentials,
      );

      expect(row['id'], 'vllm-server');
      expect(row['instanceId'], 'openai-compatible:vllm-server');
      expect(row['isPrimary'], isFalse);

      final instances = listInstances(rows, 'openai-compatible');
      expect(instances, hasLength(1));
      expect(instances.single['id'], 'vllm-server');

      // Options resolve through the clean slug and through a redundant prefix.
      expect(
        providerInstanceOptions(rows, 'openai-compatible', 'vllm-server'),
        _credentials,
      );
      expect(
        providerInstanceOptions(
          rows,
          'openai-compatible',
          'openai-compatible:vllm-server',
        ),
        _credentials,
      );
    });

    test('healing repairs double-prefixed storage keys and row ids', () {
      final rows = <String, Map<String, dynamic>>{
        'openai-compatible:openai-compatible:vllm': <String, dynamic>{
          'instanceId': 'openai-compatible:openai-compatible:vllm',
          'id': 'openai-compatible:vllm',
          'providerId': 'openai-compatible',
          'label': 'vllm',
          'options': <String, dynamic>{
            'apiKey': '<apiKey>',
            'baseUrl': 'https://example.invalid/v1',
          },
          'isPrimary': false,
        },
      };

      final instances = listInstances(rows, 'openai-compatible');

      expect(instances, hasLength(1));
      expect(instances.single['id'], 'vllm');
      expect(instances.single['instanceId'], 'openai-compatible:vllm');
      expect(rows.containsKey('openai-compatible:vllm'), isTrue);
      expect(rows.containsKey('openai-compatible:openai-compatible:vllm'),
          isFalse);

      // Assert the TS fixture options literally, not via a shared helper.
      expect(
        providerInstanceOptions(rows, 'openai-compatible', 'vllm'),
        const <String, dynamic>{
          'apiKey': '<apiKey>',
          'baseUrl': 'https://example.invalid/v1',
        },
      );
      expect(
        providerInstanceOptions(
          rows,
          'openai-compatible',
          'openai-compatible:vllm',
        ),
        const <String, dynamic>{
          'apiKey': '<apiKey>',
          'baseUrl': 'https://example.invalid/v1',
        },
      );
    });

    test('listInstances puts primary first then sorts by label', () {
      final rows = <String, Map<String, dynamic>>{
        'provider:zebra': _row(
          id: 'zebra',
          providerId: 'provider',
          label: 'Beta',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
        'provider:*': _row(
          id: primaryInstanceInfix,
          providerId: 'provider',
          label: 'Zed',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
          isPrimary: true,
        ),
        'provider:alpha': _row(
          id: 'alpha',
          providerId: 'provider',
          label: 'alpha',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
        'other:hidden': _row(
          id: 'hidden',
          providerId: 'other',
          label: 'Hidden',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      // 'Beta' < 'alpha' only under case-sensitive ordering; TS localeCompare
      // puts 'alpha' first.
      final ids = listInstances(rows, 'provider')
          .map((row) => row['id'] as String)
          .toList();

      expect(ids, <String>['*', 'alpha', 'zebra']);
    });

    test('removeInstance falls back to the first row when no primary exists',
        () {
      final rows = <String, Map<String, dynamic>>{
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
        'provider:temp': _row(
          id: 'temp',
          providerId: 'provider',
          label: 'Temp',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      removeInstance(rows, 'provider', 'temp');
      final instances = listInstances(rows, 'provider');

      expect(rows.containsKey('provider:temp'), isFalse);
      expect(rows.containsKey('provider:*'), isTrue);
      expect(instances, hasLength(2));
      expect(instances.first['id'], primaryInstanceInfix);
      expect(instances.first['isPrimary'], isTrue);
      expect(
        instances.first['options'],
        <String, dynamic>{'apiKey': '<apiKey>'},
      );
    });

    test('removeInstance of the primary does not synthesize a fallback', () {
      final rows = <String, Map<String, dynamic>>{
        'provider:*': _row(
          id: primaryInstanceInfix,
          providerId: 'provider',
          label: 'Default',
          options: _credentials,
          isPrimary: true,
        ),
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      removeInstance(rows, 'provider', primaryInstanceInfix);

      expect(rows.containsKey('provider:*'), isFalse);
      expect(listInstances(rows, 'provider').single['id'], 'work');
    });

    test('removeInstance with no instanceId removes the primary, no fallback',
        () {
      final rows = <String, Map<String, dynamic>>{
        'provider:*': _row(
          id: primaryInstanceInfix,
          providerId: 'provider',
          label: 'Default',
          options: _credentials,
          isPrimary: true,
        ),
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      removeInstance(rows, 'provider');

      expect(rows.containsKey('provider:*'), isFalse);
      expect(rows.containsKey('provider:work'), isTrue);
      expect(listInstances(rows, 'provider').single['id'], 'work');
    });

    test('removeInstance synthesizes a primary from a named primary row', () {
      final rows = <String, Map<String, dynamic>>{
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: _credentials,
          isPrimary: true,
        ),
        'provider:temp': _row(
          id: 'temp',
          providerId: 'provider',
          label: 'Temp',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      removeInstance(rows, 'provider', 'temp');

      expect(rows.containsKey('provider:temp'), isFalse);
      final primary = rows['provider:*'];
      expect(primary, isNotNull);
      expect(primary?['id'], primaryInstanceInfix);
      expect(primary?['isPrimary'], isTrue);
      expect(primary?['options'], _credentials);
      expect(rows.containsKey('provider:work'), isTrue);
    });

    test('setPrimaryInstance and setInstanceLabel update the addressed row',
        () {
      final rows = <String, Map<String, dynamic>>{
        'provider:*': _row(
          id: primaryInstanceInfix,
          providerId: 'provider',
          label: 'Default',
          options: _credentials,
          isPrimary: true,
        ),
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: _credentials,
        ),
      };

      setPrimaryInstance(rows, 'provider', 'work');
      setInstanceLabel(rows, 'provider', 'work', 'Server B');

      final instances = listInstances(rows, 'provider');
      expect(instances.first['id'], 'work');
      expect(instances.first['label'], 'Server B');
      expect(instances.first['isPrimary'], isTrue);
      expect(rows['provider:*']?['isPrimary'], isFalse);
    });

    test('setInstanceLabel materializes a missing primary as primary', () {
      final rows = <String, Map<String, dynamic>>{
        'provider:aaa': _row(
          id: 'aaa',
          providerId: 'provider',
          label: 'AAA',
          options: <String, dynamic>{'apiKey': '<apiKey>'},
        ),
      };

      setInstanceLabel(rows, 'provider', primaryInstanceInfix, 'Renamed');

      expect(rows['provider:*']?['id'], primaryInstanceInfix);
      expect(rows['provider:*']?['isPrimary'], isTrue);
      final instances = listInstances(rows, 'provider');
      expect(instances, hasLength(2));
      expect(instances.first['id'], primaryInstanceInfix);
      expect(instances.first['label'], 'Renamed');
    });

    test('ensurePrimaryInstance seeds options only for an empty primary', () {
      final rows = <String, Map<String, dynamic>>{};

      final primary = ensurePrimaryInstance(rows, 'provider', _credentials);
      expect(primary['id'], primaryInstanceInfix);
      expect(primary['options'], _credentials);

      ensurePrimaryInstance(rows, 'provider', <String, dynamic>{
        'apiKey': '<apiKey>',
      });
      expect(rows['provider:*']?['options'], _credentials);
    });

    test('removeAllInstances leaves other providers untouched', () {
      final rows = <String, Map<String, dynamic>>{
        'provider:*': _row(
          id: primaryInstanceInfix,
          providerId: 'provider',
          label: 'Default',
          options: _credentials,
          isPrimary: true,
        ),
        'provider:work': _row(
          id: 'work',
          providerId: 'provider',
          label: 'Work',
          options: _credentials,
        ),
        'other:*': _row(
          id: primaryInstanceInfix,
          providerId: 'other',
          label: 'Default',
          options: _credentials,
          isPrimary: true,
        ),
      };

      removeAllInstances(rows, 'provider');

      expect(listInstances(rows, 'provider'), isEmpty);
      expect(listInstances(rows, 'other'), hasLength(1));
    });
  });
}
