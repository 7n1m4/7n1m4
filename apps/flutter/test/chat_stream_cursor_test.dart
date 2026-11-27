// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/chat/state/stream_cursor.dart';

void main() {
  test(
    'the gap tracker records the missing seq between two forward frames',
    () {
      final tracker = StreamGapTracker();

      expect(tracker.highWater, isNull);
      tracker.observe(1);
      expect(tracker.highWater, 1);
      expect(tracker.gaps, <int>{});

      tracker.observe(2);
      expect(tracker.highWater, 2);
      expect(tracker.gaps, <int>{});

      tracker.observe(4);
      expect(tracker.highWater, 4);
      expect(tracker.gaps, <int>{3});
    },
  );

  test(
    'an out-of-order seq leaves high-water and the recorded gap unchanged',
    () {
      final tracker = StreamGapTracker();
      tracker.observe(1);
      tracker.observe(3);
      expect(tracker.highWater, 3);
      expect(tracker.gaps, <int>{2});

      tracker.observe(2);
      expect(tracker.highWater, 3);
      expect(tracker.gaps, <int>{2});

      tracker.observe(3);
      expect(tracker.highWater, 3);
      expect(tracker.gaps, <int>{2});
    },
  );

  group('StreamCursor value semantics', () {
    test('two initial cursors are equal and hash equally', () {
      final first = StreamCursor.initial();
      final second = StreamCursor.initial();

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.hashCode, Object.hash(0, null));
      expect(first, isNot(same(second)));
    });

    test('cursors with different high-water marks are unequal', () {
      final start = StreamCursor.initial();
      final atOne = start.next(1);
      final atTwo = start.next(2);

      expect(start == atOne, isFalse);
      expect(atOne == atTwo, isFalse);
      expect(start.hashCode == atOne.hashCode, isFalse);
      expect(atOne.hashCode == atTwo.hashCode, isFalse);
    });

    test('next returns a new cursor and leaves the receiver unchanged', () {
      final original = StreamCursor.initial();
      final advanced = original.next(9);

      expect(advanced, isNot(same(original)));
      expect(advanced == original, isFalse);
      expect(original, StreamCursor.initial());
      expect(original.toString(), StreamCursor.initial().toString());
      expect(advanced.hashCode, Object.hash(0, 9));
    });

    test('hasPosition flips from false to true after next', () {
      final original = StreamCursor.initial();

      expect(original.hasPosition, isFalse);
      expect(original.next(0).hasPosition, isTrue);
      expect(original.hasPosition, isFalse);
    });

    test('toString carries epoch and high-water values for diagnostics', () {
      final initial = StreamCursor.initial();
      final advanced = initial.next(3);

      expect(initial.toString(), contains('epoch: 0'));
      expect(initial.toString(), contains('highWater: null'));
      expect(advanced.toString(), contains('epoch: 0'));
      expect(advanced.toString(), contains('highWater: 3'));
    });
  });

  test('a multi-step forward jump records every missing sequence number', () {
    final tracker = StreamGapTracker();

    tracker.observe(1);
    tracker.observe(5);

    expect(tracker.highWater, 5);
    expect(tracker.gaps, <int>{2, 3, 4});
  });
}
