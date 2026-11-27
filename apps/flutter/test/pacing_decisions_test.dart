// SPDX-License-Identifier: GPL-3.0-or-later

// Parity tests for the pure TTFT/filler decision core. Reference:
//   crates/anima-core/src/pacing.rs (including its #[cfg(test)] module)
//
// These exercise pure rules only: no wire types, timers, cue wiring or speech
// transport. Every expected value below is literal and taken from the Rust
// oracle, so drift in the Dart mirror cannot hide behind a shared helper.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/onboarding/onboarding_rules.dart';
import 'package:anima_control/features/speech/pacing_decisions.dart';

TtftWindow window(List<double> samples) {
  final ring = TtftWindow();
  for (final sample in samples) {
    expect(ring.push(sample), isTrue, reason: '$sample');
  }
  return ring;
}

PacingPolicy cardPolicy(double maxFillers) => PacingPolicy(
  enabled: true,
  maxFillersPerTurn: maxFillers,
  fillers: <ThinkingFiller>[
    const ThinkingFiller(
      text: 'Hmm, let me see.',
      category: ThinkingFillerCategory.generic,
      enabled: true,
    ),
    const ThinkingFiller(
      text: 'Let me work through the steps.',
      category: ThinkingFillerCategory.analytical,
      enabled: true,
    ),
    const ThinkingFiller(
      text: 'I remember something like that.',
      category: ThinkingFillerCategory.memory,
      enabled: true,
    ),
  ],
);

int dueMs(TurnPacing turn) {
  final delay = turn.deadline.afterMs;
  expect(delay, isNotNull, reason: 'expected an armed deadline');
  return turn.t0Ms + delay!;
}

TurnPacing capsFor(double maxFillers) =>
    TurnPacing(cardPolicy(maxFillers), window(<double>[1200]), 1000);

void main() {
  group('ttft ring', () {
    test('rejects NaN, both infinities and negatives without mutation', () {
      final ring = TtftWindow.withCapacity(3);
      expect(ring.isEmpty, isTrue);
      expect(ring.push(double.nan), isFalse);
      expect(ring.push(double.infinity), isFalse);
      expect(ring.push(double.negativeInfinity), isFalse);
      expect(ring.push(-1.0), isFalse);
      expect(ring.isEmpty, isTrue);
      expect(ring.len, 0);
      expect(ring.samples, isEmpty);
      expect(ring.percentile(0.9), isNull);
      expect(ring.emaAndDeviation(), isNull);
    });

    test('evicts chronologically at capacity and clamps capacity to one', () {
      final ring = TtftWindow.withCapacity(3);
      for (final value in <double>[100, 200, 300, 400]) {
        expect(ring.push(value), isTrue);
      }
      expect(ring.len, 3);
      expect(ring.samples, <double>[200, 300, 400]);
      expect(ring.percentile(0.0), 200);
      expect(ring.percentile(1.0), 400);

      final single = TtftWindow.withCapacity(0);
      expect(single.push(1.0), isTrue);
      expect(single.push(2.0), isTrue);
      expect(single.samples, <double>[2]);

      ring.clear();
      expect(ring.isEmpty, isTrue);
    });
  });

  group('ema and initial deadline', () {
    test('pins the Rust EMA value and stays inside sample bounds', () {
      final ring = window(<double>[900, 1200, 1500, 1800, 2100]);
      expect(ring.percentile(0.0), 900.0);
      expect(ring.percentile(1.0), 2100.0);
      final p90 = ring.percentile(0.9)!;
      expect(p90 >= 900.0 && p90 <= 2100.0, isTrue);

      final ema = ring.emaAndDeviation()!;
      expect(ema.mu >= 900.0 && ema.mu <= 2100.0, isTrue);
      expect((ema.mu - 1434.2478280749883).abs() < 1e-6, isTrue);
      expect(ema.deviation >= 0.0, isTrue);
    });

    test('defaults, ultra-fast disable, bounds and inverted bounds', () {
      final policy = cardPolicy(3);
      expect(calculateInitialDeadline(policy, TtftWindow()).afterMs, 1800);
      expect(
        calculateInitialDeadline(
          policy,
          window(<double>[300, 320, 280]),
        ).isDisabled,
        isTrue,
      );
      expect(
        calculateInitialDeadline(
          policy,
          window(<double>[200, 700, 700]),
        ).isDisabled,
        isTrue,
      );
      expect(
        calculateInitialDeadline(
          policy,
          window(<double>[200, 700.5, 700.5]),
        ).afterMs,
        900,
      );

      final slow = window(<double>[900, 1300, 1700, 2100]);
      final armed = calculateInitialDeadline(policy, slow).afterMs!;
      expect(armed >= 900 && armed <= 3500, isTrue);

      const inverted = PacingPolicy(
        enabled: true,
        armMinMs: 2500,
        armMaxMs: 1000,
        maxFillersPerTurn: 3,
      );
      expect(calculateInitialDeadline(inverted, slow).afterMs, 2500);

      const disabled = PacingPolicy(enabled: false, maxFillersPerTurn: 3);
      expect(calculateInitialDeadline(disabled, slow).isDisabled, isTrue);
    });
  });

  group('classifier', () {
    test('detects categories and negation', () {
      final classifier = CategoryClassifier(const PacingPolicy());

      expect(
        classifier
            .consume('Let me recall the previous conversation from yesterday ')
            .category,
        ThinkingFillerCategory.memory,
      );
      classifier.reset();
      expect(
        classifier.consume('I feel happy and tender ').category,
        ThinkingFillerCategory.emotional,
      );
      classifier.reset();
      expect(
        classifier.consume('Maybe, perhaps I am unsure ').category,
        ThinkingFillerCategory.uncertain,
      );
      classifier.reset();
      final negated = classifier.consume(
        'I do not recall the previous conversation ',
      );
      expect(negated.category, ThinkingFillerCategory.generic);
      expect(negated.scores.memory < 0, isTrue);
      classifier.reset();
      expect(
        classifier.consume('Let me analyze and compute the formula ').category,
        ThinkingFillerCategory.analytical,
      );
    });

    test('treats both apostrophe forms as negation tokens', () {
      final straight = CategoryClassifier(const PacingPolicy());
      final straightResult = straight.consume(
        "I don't recall the previous conversation ",
      );
      expect(straightResult.category, ThinkingFillerCategory.generic);
      expect(straightResult.scores.memory, lessThan(0));
      expect(straightResult.matchedTokens, contains('recall'));

      final curly = CategoryClassifier(const PacingPolicy());
      final curlyResult = curly.consume(
        'I don’t recall the previous conversation ',
      );
      expect(curlyResult.category, ThinkingFillerCategory.generic);
      expect(curlyResult.scores.memory, lessThan(0));
      expect(curlyResult.matchedTokens, contains('recall'));
    });

    test('is chunk invariant and evaluates a trailing word only on flush', () {
      final whole = CategoryClassifier(const PacingPolicy());
      final expected = whole.consume('I remember the earlier memory ');

      final chunked = CategoryClassifier(const PacingPolicy());
      chunked.consume('I rem');
      final actual = chunked.consume('ember the earlier memory ');
      expect(actual, expected);
      expect(actual.category, ThinkingFillerCategory.memory);
      expect(actual.matchedTokens, <String>['remember', 'earlier', 'memory']);

      final trailing = CategoryClassifier(const PacingPolicy());
      expect(
        trailing.consume('let me recall').category,
        ThinkingFillerCategory.generic,
      );
      final flushed = trailing.flush();
      expect(flushed.category, ThinkingFillerCategory.memory);
      expect(flushed.matchedTokens, <String>['recall']);
      expect(flushed.confidence, 1.0);

      final bounded = CategoryClassifier.withLimits(1.0, 128);
      bounded.consume('${'x' * 500} recall ');
      expect(bounded.bufferedChars(), 128);
      expect(bounded.flush().category, ThinkingFillerCategory.memory);
    });
  });

  group('turn state machine', () {
    test('arms, fires and disarms through both opportunity kinds', () {
      final policy = cardPolicy(2);
      final turn = TurnPacing(policy, window(<double>[1200, 1400]), 1000);
      expect(turn.phase, PacingPhase.staging);
      expect(turn.initialOpportunityDue(1000), isFalse);

      final due = dueMs(turn);
      expect(turn.initialOpportunityDue(due), isTrue);
      final first = turn.armOpportunity(due, Opportunity.initial);
      expect(first, isNotNull);
      expect(first!.attempt, 1);
      expect(first.fillerIndex, isNotNull);
      expect(turn.phase, PacingPhase.fillerArmed);
      expect(turn.committed, 1);
      expect(turn.armOpportunity(due + 1, Opportunity.initial), isNull);

      expect(turn.fire(due + 10), isTrue);
      expect(turn.phase, PacingPhase.fillerActive);
      expect(turn.spoken, 1);
      expect(turn.fire(due + 11), isFalse);

      expect(turn.disarm(due + 900), DisarmOutcome.rearmed);
      expect(turn.phase, PacingPhase.staging);
      final next = turn.nextEligibleAtMs!;
      expect(turn.armOpportunity(next - 1, Opportunity.interval), isNull);
      final second = turn.armOpportunity(next, Opportunity.interval);
      expect(second, isNotNull);
      expect(second!.attempt, 2);
      expect(turn.fire(next + 1), isTrue);
      expect(turn.disarm(next + 900), DisarmOutcome.closed);
      expect(turn.phase, PacingPhase.settled);
      expect(turn.isClosed, isTrue);
    });

    test('skipped initial rearms an interval opportunity', () {
      final policy = cardPolicy(2);
      final turn = TurnPacing(policy, window(<double>[1200]), 1000);
      expect(turn.armOpportunity(1000, Opportunity.initial), isNull);
      expect(turn.committed, 0);

      turn.skipInitial(1000);
      expect(turn.phase, PacingPhase.staging);
      final next = turn.nextEligibleAtMs!;
      expect(turn.armOpportunity(next - 1, Opportunity.interval), isNull);
      final selection = turn.armOpportunity(next, Opportunity.interval);
      expect(selection, isNotNull);
      expect(selection!.attempt, 1);
    });

    test('answer and cancel disarm an armed filler', () {
      final policy = cardPolicy(3);
      final samples = window(<double>[1200]);
      final due = dueMs(TurnPacing(policy, samples, 1000));

      final answered = TurnPacing(policy, samples, 1000);
      answered.armOpportunity(due, Opportunity.initial);
      expect(
        answered.onAnswer(due + 5),
        const CancelOutcome(CancelReason.answerArrived, 1),
      );
      expect(answered.phase, PacingPhase.answerReady);
      expect(answered.isClosed, isTrue);
      expect(
        answered.armOpportunity(due + 99999, Opportunity.interval),
        isNull,
      );

      final canceled = TurnPacing(policy, samples, 1000);
      canceled.armOpportunity(due, Opportunity.initial);
      expect(
        canceled.cancel(CancelReason.invalidated, due + 6),
        const CancelOutcome(CancelReason.invalidated, 1),
      );
      expect(canceled.phase, PacingPhase.settled);

      final playing = TurnPacing(policy, samples, 1000);
      playing.armOpportunity(due, Opportunity.initial);
      expect(playing.fire(due + 1), isTrue);
      expect(playing.onAnswer(due + 2), isNull);
      expect(playing.phase, PacingPhase.fillerActive);
      expect(playing.disarm(due + 500), DisarmOutcome.closed);
    });

    test('commit and attempt caps clamp to 1..8 fillers and 2x attempts', () {
      expect(capsFor(1).maxFillers, 1);
      expect(capsFor(1).maxAttempts, 2);
      expect(capsFor(0).maxFillers, 1);
      expect(capsFor(-5).maxFillers, 1);
      expect(capsFor(99).maxFillers, 8);
      expect(capsFor(99).maxAttempts, 16);
      expect(capsFor(double.nan).maxFillers, 3);
      expect(capsFor(3.6).maxFillers, 4);

      final policy = cardPolicy(1);
      final samples = window(<double>[1200]);
      final due = dueMs(TurnPacing(policy, samples, 1000));
      final turn = TurnPacing(policy, samples, 1000);
      expect(turn.armOpportunity(due, Opportunity.initial), isNotNull);
      expect(turn.fire(due + 1), isTrue);
      expect(turn.disarm(due + 100), DisarmOutcome.closed);
      expect(turn.committed, 1);
      expect(turn.attempts <= 2 * turn.maxFillers, isTrue);
      expect(turn.armOpportunity(due + 99999, Opportunity.interval), isNull);
    });

    test('saturates now plus delay at u64::MAX', () {
      const maxU64 = 0xFFFFFFFFFFFFFFFF;
      final turn = TurnPacing(
        cardPolicy(2),
        window(<double>[1200]),
        maxU64 - 5,
      );
      expect(turn.initialOpportunityDue(maxU64), isTrue);
      turn.skipInitial(maxU64);
      expect(turn.nextEligibleAtMs, maxU64);

      final fastPolicy = PacingPolicy(
        enabled: true,
        pacingIntervalMs: 1000,
        fillers: cardPolicy(2).fillers,
      );
      final fast = TurnPacing(fastPolicy, window(<double>[200]), maxU64 - 100);
      expect(fast.deadline.isDisabled, isTrue);
      expect(fast.nextEligibleAtMs, maxU64);
    });

    test('zero preparation budget skips an uncached filler', () {
      const noCache = PacingPolicy(
        enabled: true,
        maxFillersPerTurn: 2,
        fillers: null,
        maxFillerSynthesisBudgetMs: 0,
      );
      final turn = TurnPacing(noCache, window(<double>[1200]), 1000);
      final due = dueMs(turn);
      expect(turn.armOpportunity(due, Opportunity.initial), isNull);
      expect(turn.committed, 0);
      expect(turn.phase, PacingPhase.staging);

      const budgeted = PacingPolicy(
        enabled: true,
        maxFillersPerTurn: 2,
        maxFillerSynthesisBudgetMs: 3200,
      );
      final prepared = TurnPacing(budgeted, window(<double>[1200]), 1000);
      final selection = prepared.armOpportunity(
        dueMs(prepared),
        Opportunity.initial,
      );
      expect(selection, isNotNull);
      expect(selection!.fillerIndex, isNull);
      expect(selection.maxPrepareMs, 3200);
      expect(selection.maxAsideMs, 3200);
    });

    test('selection prefers the strongest unused category', () {
      final policy = cardPolicy(3);
      final samples = window(<double>[1200]);
      final due = dueMs(TurnPacing(policy, samples, 1000));
      final turn = TurnPacing(policy, samples, 1000);

      turn.observeReasoning('Let me analyze and compute the formula ');
      final first = turn.armOpportunity(due, Opportunity.initial)!;
      expect(first.category, ThinkingFillerCategory.analytical);

      expect(turn.fire(due + 1), isTrue);
      expect(turn.disarm(due + 100), DisarmOutcome.rearmed);
      final next = turn.nextEligibleAtMs!;
      turn.observeReasoning('I recall the previous history ');
      final second = turn.armOpportunity(next, Opportunity.interval)!;
      expect(second.category, ThinkingFillerCategory.memory);
      expect(turn.usedCategories, <ThinkingFillerCategory>[
        ThinkingFillerCategory.analytical,
        ThinkingFillerCategory.memory,
      ]);
    });
  });

  group('u64 ms conversion matches Rust saturating cast', () {
    test('large finite doubles keep their exact u64 bit pattern or saturate', () {
      // Rust: finite_or(v, default).max(0.0).round() as u64.
      // 1e19 = 10000000000000000000 -> signed bit pattern -8446744073709551616.
      expect(msOr(1e19, 0), -8446744073709551616);
      // 1.5e19 = 15000000000000000000 -> signed bit pattern -3446744073709551616.
      expect(msOr(1.5e19, 0), -3446744073709551616);
      // 1e30 exceeds u64::MAX -> saturates to the -1 bit pattern.
      expect(msOr(1e30, 0), -1);
    });

    test('NaN, negative and sub-one inputs return zero', () {
      expect(msOr(double.nan, 0), 0);
      expect(msOr(-1.0, 0), 0);
      expect(msOr(0.4, 0), 0);
    });
  });

  group('ttft preset boundaries', () {
    test('799 / 800 / 2500 / 2501 match the frozen onboarding rule', () {
      const cases = <(int, String)>[
        (799, 'snappy'),
        (800, 'balanced'),
        (2500, 'balanced'),
        (2501, 'deep'),
      ];
      for (final (ttftMs, expected) in cases) {
        expect(pacingForTtftMs(ttftMs).id, expected, reason: '$ttftMs ms');
      }
    });
  });
}
