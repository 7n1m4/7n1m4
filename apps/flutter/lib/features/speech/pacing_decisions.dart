// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure conversational-pacing decision rules, mirrored from
/// `crates/anima-core/src/pacing.rs`.
///
/// This library is a read-only rules asset. It owns no store, no wire type, no
/// timer, no daemon verb and no cue/speech transport: all timing is supplied by
/// the caller in milliseconds, and the returned selections are indices into a
/// caller-owned filler list. Cue wiring stays a separate concern.
///
/// Covered: the bounded TTFT ring and EMA/p90 deadline calibration, the chunk
/// invariant reasoning-category classifier, and the deterministic arm/deadline
/// turn state machine with commit/attempt caps.
library;

/// Rust's `u64::MAX` as Dart's signed-64-bit pattern (`-1`). Dart `int` cannot
/// hold values above `2^63-1`, so all u64 values here are kept as bit patterns
/// and compared with [_compareU64].
const int maxU64 = -1;

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;
final BigInt _signedMax = (BigInt.one << 63) - BigInt.one;

/// Most recent TTFT samples retained for deadline calibration.
const int defaultTtftWindow = 32;

/// Default category-evidence buffer size, in characters.
const int defaultMaxReasoningChars = 1024;

/// Default arm-delay bounds, in milliseconds.
const double defaultArmMinMs = 900.0;
const double defaultArmMaxMs = 3500.0;

/// Deadline used when no TTFT samples are available.
const double defaultDeadlineMs = 1800.0;

/// Initial cached opportunity is skipped when p90 is at or below this value.
const double ultraFastP90Ms = 700.0;

/// Default synthesis budgets, in milliseconds.
const double defaultFillerSynthesisBudgetMs = 3200.0;
const double defaultSynthesisBudgetMs = 3200.0;

/// Repeat-opportunity interval when the turn is dispatched ultra-fast.
const double defaultPacingIntervalMs = 15000.0;

/// Mirrors Rust's `f64::min` / `f64::max`: NaN is ignored.
double _min(double a, double b) => a.isNaN
    ? b
    : b.isNaN
    ? a
    : (a < b ? a : b);
double _max(double a, double b) => a.isNaN
    ? b
    : b.isNaN
    ? a
    : (a > b ? a : b);

/// Rust's `Option::filter(is_finite).unwrap_or(default)`.
double finiteOr(double? value, double fallback) =>
    value != null && value.isFinite ? value : fallback;

/// Rust's `finite_or(value, default).max(0.0).round() as u64` (saturating cast).
int msOr(double? value, double fallback) =>
    _toU64(_max(finiteOr(value, fallback), 0.0));

int _toU64(double value) {
  if (value.isNaN) return 0;
  final rounded = value.round();
  if (rounded <= 0) return 0;
  final big = BigInt.from(rounded);
  if (big > _u64Mask) return maxU64;
  if (big > _signedMax) return (big - (BigInt.one << 64)).toInt();
  return rounded;
}

BigInt _unsigned(int value) => BigInt.from(value) & _u64Mask;

/// Compare two u64 bit patterns by their unsigned values.
int _compareU64(int a, int b) => _unsigned(a).compareTo(_unsigned(b));

/// Rust's `u64::saturating_add`, for callers supplying `u64`-shaped timestamps.
int saturatingAddU64(int a, int b) {
  final sum = _unsigned(a) + _unsigned(b);
  final saturated = sum > _u64Mask ? _u64Mask : sum;
  return saturated > _signedMax
      ? (saturated - (BigInt.one << 64)).toInt()
      : saturated.toInt();
}

/// A chronological, bounded ring of successful time-to-first-token samples.
///
/// Samples are retained in insertion order; pushing past capacity drops the
/// oldest. Non-finite or negative samples are rejected, so card-supplied data
/// cannot poison the deadline math.
final class TtftWindow {
  TtftWindow() : this.withCapacity(defaultTtftWindow);

  TtftWindow.withCapacity(int capacity)
    : _capacity = capacity < 1 ? 1 : capacity;

  final List<double> _samples = <double>[];
  final int _capacity;

  /// Append a successful TTFT sample. Returns `false` for invalid input.
  bool push(double sampleMs) {
    if (!sampleMs.isFinite || sampleMs < 0.0) return false;
    if (_samples.length == _capacity) _samples.removeAt(0);
    _samples.add(sampleMs);
    return true;
  }

  /// Number of retained samples.
  int get len => _samples.length;

  /// Whether the window has no samples.
  bool get isEmpty => _samples.isEmpty;

  /// Drop all retained samples.
  void clear() => _samples.clear();

  /// Samples in chronological order.
  List<double> get samples => List<double>.unmodifiable(_samples);

  /// Nearest-rank quantile of the samples, or `null` when empty.
  double? percentile(double q) {
    if (_samples.isEmpty) return null;
    final clampedQ = q.isNaN
        ? 0.0
        : (q < 0.0
              ? 0.0
              : q > 1.0
              ? 1.0
              : q);
    final sorted = <double>[..._samples]..sort();
    final index = (sorted.length * clampedQ).floor();
    return sorted[index < sorted.length ? index : sorted.length - 1];
  }

  /// EMA and mean absolute deviation, updated together in one pass.
  ///
  /// `mu` starts at the smallest sample with `alpha = 2 / (clamp(n, 8, 32) + 1)`,
  /// and `d` uses `beta = 0.2` with the running `mu`.
  ({double mu, double deviation})? emaAndDeviation() {
    if (_samples.isEmpty) return null;
    final alpha =
        2.0 / (_max(8.0, _min(32.0, _samples.length.toDouble())) + 1.0);
    const beta = 0.2;
    var mu = percentile(0.0)!;
    var deviation = 0.0;
    for (final sample in _samples) {
      mu = alpha * sample + (1.0 - alpha) * mu;
      deviation = beta * (sample - mu).abs() + (1.0 - beta) * deviation;
    }
    return (mu: mu, deviation: deviation);
  }
}

/// Outcome of adaptive initial-arm calibration.
final class InitialDeadline {
  const InitialDeadline.disabled() : _afterMs = null;

  const InitialDeadline.afterMs(int value) : _afterMs = value;

  final int? _afterMs;

  /// Null when pacing is disabled or the provider is too fast to need a filler.
  int? get afterMs => _afterMs;

  /// True when no initial opportunity should be armed.
  bool get isDisabled => _afterMs == null;

  @override
  bool operator ==(Object other) =>
      other is InitialDeadline && other._afterMs == _afterMs;

  @override
  int get hashCode => _afterMs.hashCode;

  @override
  String toString() => isDisabled
      ? 'InitialDeadline.disabled'
      : 'InitialDeadline.afterMs($_afterMs)';
}

/// Compute the frozen initial arm deadline from a policy and TTFT history.
InitialDeadline calculateInitialDeadline(
  PacingPolicy policy,
  TtftWindow samples,
) {
  if (!policy.enabled) return const InitialDeadline.disabled();

  final minMs = finiteOr(policy.armMinMs, defaultArmMinMs);
  final maxMs = finiteOr(policy.armMaxMs, defaultArmMaxMs);
  int clampMs(double value) =>
      _toU64(_max(_max(_min(value, maxMs), minMs), 0.0));

  final p90 = samples.percentile(0.9);
  if (p90 == null) {
    return InitialDeadline.afterMs(clampMs(defaultDeadlineMs));
  }
  if (p90 <= ultraFastP90Ms) return const InitialDeadline.disabled();

  final ema = samples.emaAndDeviation();
  if (ema == null) return InitialDeadline.afterMs(clampMs(defaultDeadlineMs));

  final kFast = finiteOr(policy.kFast, 0.5);
  var deadline = ema.mu - kFast * ema.deviation;
  if (samples.len >= 20) {
    final p10 = samples.percentile(0.1);
    if (p10 != null && p10 > deadline) deadline = p10;
  }
  return InitialDeadline.afterMs(clampMs(deadline));
}

/// Thinking-filler category (mirrors `AiriThinkingFillerCategory`).
enum ThinkingFillerCategory {
  generic,
  analytical,
  memory,
  emotional,
  uncertain,
}

/// One thinking filler (`extensions.airi.acting.pacing.fillers[]`).
final class ThinkingFiller {
  const ThinkingFiller({
    required this.text,
    this.category = ThinkingFillerCategory.generic,
    this.enabled = false,
  });

  final String text;
  final ThinkingFillerCategory category;
  final bool enabled;
}

/// Conversational pacing configuration (the fields consulted by this core).
final class PacingPolicy {
  const PacingPolicy({
    this.enabled = false,
    this.armMinMs,
    this.armMaxMs,
    this.categoryThreshold,
    this.kFast,
    this.maxFillersPerTurn,
    this.pacingIntervalMs,
    this.fillers,
    this.maxFillerSynthesisBudgetMs,
    this.maxSynthesisBudgetMs,
  });

  final bool enabled;
  final double? armMinMs;
  final double? armMaxMs;
  final double? categoryThreshold;
  final double? kFast;
  final double? maxFillersPerTurn;
  final double? pacingIntervalMs;
  final List<ThinkingFiller>? fillers;
  final double? maxFillerSynthesisBudgetMs;
  final double? maxSynthesisBudgetMs;
}

/// Net evidence for each specific thinking-filler category.
final class CategoryScores {
  const CategoryScores({
    this.analytical = 0,
    this.memory = 0,
    this.emotional = 0,
    this.uncertain = 0,
  });

  final int analytical;
  final int memory;
  final int emotional;
  final int uncertain;

  int get(ThinkingFillerCategory category) => switch (category) {
    ThinkingFillerCategory.analytical => analytical,
    ThinkingFillerCategory.memory => memory,
    ThinkingFillerCategory.emotional => emotional,
    ThinkingFillerCategory.uncertain => uncertain,
    ThinkingFillerCategory.generic => 0,
  };

  CategoryScores add(ThinkingFillerCategory category, int delta) =>
      switch (category) {
        ThinkingFillerCategory.analytical => CategoryScores(
          analytical: analytical + delta,
          memory: memory,
          emotional: emotional,
          uncertain: uncertain,
        ),
        ThinkingFillerCategory.memory => CategoryScores(
          analytical: analytical,
          memory: memory + delta,
          emotional: emotional,
          uncertain: uncertain,
        ),
        ThinkingFillerCategory.emotional => CategoryScores(
          analytical: analytical,
          memory: memory,
          emotional: emotional + delta,
          uncertain: uncertain,
        ),
        ThinkingFillerCategory.uncertain => CategoryScores(
          analytical: analytical,
          memory: memory,
          emotional: emotional,
          uncertain: uncertain + delta,
        ),
        ThinkingFillerCategory.generic => this,
      };

  @override
  bool operator ==(Object other) =>
      other is CategoryScores &&
      other.analytical == analytical &&
      other.memory == memory &&
      other.emotional == emotional &&
      other.uncertain == uncertain;

  @override
  int get hashCode => Object.hash(analytical, memory, emotional, uncertain);
}

/// Result of one bounded category-evaluation pass.
final class ClassificationResult {
  const ClassificationResult({
    this.category = ThinkingFillerCategory.generic,
    this.confidence = 0.0,
    this.scores = const CategoryScores(),
    this.matchedTokens = const <String>[],
  });

  final ThinkingFillerCategory category;
  final double confidence;
  final CategoryScores scores;
  final List<String> matchedTokens;

  @override
  bool operator ==(Object other) =>
      other is ClassificationResult &&
      other.category == category &&
      other.confidence == confidence &&
      other.scores == scores &&
      _sameStrings(other.matchedTokens, matchedTokens);

  @override
  int get hashCode =>
      Object.hash(category, confidence, scores, Object.hashAll(matchedTokens));
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const ClassificationResult _emptyResult = ClassificationResult();

const List<ThinkingFillerCategory> _specificCategories =
    <ThinkingFillerCategory>[
      ThinkingFillerCategory.analytical,
      ThinkingFillerCategory.memory,
      ThinkingFillerCategory.emotional,
      ThinkingFillerCategory.uncertain,
    ];

const List<String> _negations = <String>[
  'not',
  'no',
  'never',
  'neither',
  'nor',
  'dont',
  "don't",
  'doesnt',
  "doesn't",
  'didnt',
  "didn't",
  'wont',
  "won't",
  'wouldnt',
  "wouldn't",
  'cant',
  "can't",
  'couldnt',
  "couldn't",
  'shouldnt',
  "shouldn't",
  'hardly',
  'scarcely',
];

const List<String> _analyticalLexicon = <String>[
  'calculate',
  'calculation',
  'compute',
  'computing',
  'analyze',
  'analysis',
  'logic',
  'logical',
  'math',
  'mathematical',
  'reason',
  'reasoning',
  'deduce',
  'deduction',
  'step',
  'evaluate',
  'evaluation',
  'formula',
  'code',
  'algorithm',
  'system',
  'solve',
  'solution',
  'estimate',
  'optimize',
];

const List<String> _memoryLexicon = <String>[
  'recall',
  'recalling',
  'remember',
  'remembering',
  'history',
  'past',
  'earlier',
  'previous',
  'yesterday',
  'before',
  'memory',
  'memories',
  'context',
  'remind',
  'forget',
  'recollect',
];

const List<String> _emotionalLexicon = <String>[
  'feel',
  'feeling',
  'happy',
  'sad',
  'angry',
  'excited',
  'tender',
  'heart',
  'warmth',
  'empathy',
  'sympathetic',
  'affection',
  'worried',
  'grief',
  'joy',
  'fond',
  'anxious',
  'care',
];

const List<String> _uncertainLexicon = <String>[
  'maybe',
  'perhaps',
  'unsure',
  'wonder',
  'wondering',
  'hesitate',
  'doubt',
  'confused',
  'confusion',
  'guess',
  'guessing',
  'unclear',
  'possibly',
  'dilemma',
  'ponder',
];

List<String> _lexicon(ThinkingFillerCategory category) => switch (category) {
  ThinkingFillerCategory.analytical => _analyticalLexicon,
  ThinkingFillerCategory.memory => _memoryLexicon,
  ThinkingFillerCategory.emotional => _emotionalLexicon,
  ThinkingFillerCategory.uncertain => _uncertainLexicon,
  ThinkingFillerCategory.generic => const <String>[],
};

final RegExp _letterPattern = RegExp(r'\p{L}', unicode: true);
final RegExp _numberPattern = RegExp(r'\p{N}', unicode: true);

/// Rust's `char::is_alphabetic() || char::is_numeric()`.
bool _isWordRune(int rune) {
  final character = String.fromCharCode(rune);
  return _letterPattern.hasMatch(character) ||
      _numberPattern.hasMatch(character);
}

bool _isWordCharRune(int rune) =>
    _isWordRune(rune) || rune == 0x27 || rune == 0x2019;

/// Lowercases text and splits it into words, preserving internal apostrophes.
List<String> _tokenize(String text) {
  final tokens = <String>[];
  final current = StringBuffer();
  var previousWasWord = false;
  for (final rune in text.runes) {
    final isWord = _isWordRune(rune);
    if (isWord) {
      current.write(String.fromCharCode(rune).toLowerCase());
    } else if ((rune == 0x27 || rune == 0x2019) &&
        previousWasWord &&
        current.isNotEmpty) {
      current.write("'");
    } else if (current.isNotEmpty) {
      tokens.add(current.toString());
      current.clear();
    }
    previousWasWord = isWord;
  }
  if (current.isNotEmpty) tokens.add(current.toString());
  return tokens;
}

/// Completed terms only, unless [includeTrailing] keeps the partial last word.
String? _evaluablePrefix(String buffer, bool includeTrailing) {
  if (buffer.trim().isEmpty) return '';
  if (includeTrailing) return buffer;
  var end = 0;
  var offset = 0;
  for (final rune in buffer.runes) {
    final width = rune > 0xFFFF ? 2 : 1;
    if (!_isWordCharRune(rune)) end = offset + width;
    offset += width;
  }
  return end == 0 ? null : buffer.substring(0, end);
}

/// Bounded, chunk-invariant lexicon classifier for hidden reasoning text.
final class CategoryClassifier {
  CategoryClassifier(PacingPolicy policy)
    : this.withLimits(
        _max(finiteOr(policy.categoryThreshold, 1.0), 1.0),
        defaultMaxReasoningChars,
      );

  CategoryClassifier.withLimits(double threshold, int maxChars)
    : _threshold = _max(threshold, 1.0),
      _maxChars = maxChars < 1 ? 1 : maxChars;

  final double _threshold;
  final int _maxChars;
  String _buffer = '';

  /// Number of buffered reasoning characters (for diagnostics and tests).
  int bufferedChars() => _buffer.runes.length;

  /// Append a reasoning chunk and classify completed terms only.
  ClassificationResult consume(String chunk) {
    if (chunk.isNotEmpty) {
      _buffer += chunk;
      final extra = bufferedChars() - _maxChars;
      if (extra > 0) {
        _buffer = _buffer.runes.skip(extra).map(String.fromCharCode).join();
      }
    }
    return _evaluate(false);
  }

  /// Classify the buffer including a trailing partial word.
  ClassificationResult flush() => _evaluate(true);

  /// Clear the evidence window (used between filler opportunities).
  void reset() => _buffer = '';

  ClassificationResult _evaluate(bool includeTrailing) {
    final prefix = _evaluablePrefix(_buffer, includeTrailing);
    if (prefix == null || prefix.isEmpty) return _emptyResult;

    final tokens = _tokenize(prefix);
    var scores = const CategoryScores();
    final matchedTokens = <String>[];
    var lastNegation = -100;
    for (var index = 0; index < tokens.length; index++) {
      final token = tokens[index];
      if (_negations.contains(token)) {
        lastNegation = index;
        continue;
      }
      final negated = index - lastNegation <= 3;
      for (final category in _specificCategories) {
        if (_lexicon(category).contains(token)) {
          matchedTokens.add(token);
          scores = scores.add(category, negated ? -1 : 1);
        }
      }
    }

    var best = ThinkingFillerCategory.generic;
    var highestNet = 0;
    for (final category in _specificCategories) {
      final net = scores.get(category);
      if (net >= _threshold && net > highestNet) {
        highestNet = net;
        best = category;
      }
    }

    final evidence = matchedTokens.length.toDouble();
    final confidence = best != ThinkingFillerCategory.generic && evidence > 0.0
        ? _clamp01(highestNet / evidence)
        : 0.0;

    return ClassificationResult(
      category: best,
      confidence: confidence,
      scores: scores,
      matchedTokens: List<String>.unmodifiable(matchedTokens),
    );
  }

  /// Strongest eligible category not already used this turn, with the relative
  /// guard so a weak runner-up cannot win solely because a dominant category
  /// already spoke.
  ThinkingFillerCategory? topCategoryExcluding(
    Iterable<ThinkingFillerCategory> excluded,
  ) {
    final result = flush();
    var strongest = 0;
    for (final category in _specificCategories) {
      final net = result.scores.get(category);
      if (net > strongest) strongest = net;
    }

    ThinkingFillerCategory? best;
    var highestNet = 0;
    for (final category in _specificCategories) {
      if (excluded.contains(category)) continue;
      final net = result.scores.get(category);
      if (net >= _threshold && net >= 0.5 * strongest && net > highestNet) {
        highestNet = net;
        best = category;
      }
    }
    return best;
  }
}

double _clamp01(double value) {
  if (value.isNaN) return 0.0;
  if (value < 0.0) return 0.0;
  if (value > 1.0) return 1.0;
  return value;
}

/// Lifecycle phase of one pacing turn.
enum PacingPhase {
  idle,
  staging,
  fillerArmed,
  fillerActive,
  answerReady,
  settled,
}

/// Which opportunity the caller is evaluating.
enum Opportunity { initial, interval }

/// Why an armed filler was disarmed before it started.
enum CancelReason { answerArrived, inferenceError, invalidated, assistantEnd }

/// A cancellation to hand to the (future) cue owner.
final class CancelOutcome {
  const CancelOutcome(this.reason, this.attempt);

  final CancelReason reason;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is CancelOutcome &&
      other.reason == reason &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(reason, attempt);

  @override
  String toString() => 'CancelOutcome($reason, $attempt)';
}

/// Result of a filler ending on the (future) audio clock.
enum DisarmOutcome { rearmed, closed, ignored }

/// A filler opportunity selected by the decision layer.
final class FillerSelection {
  const FillerSelection({
    required this.attempt,
    required this.category,
    required this.fillerIndex,
    required this.maxPrepareMs,
    required this.maxAsideMs,
  });

  final int attempt;
  final ThinkingFillerCategory category;
  final int? fillerIndex;
  final int maxPrepareMs;
  final int maxAsideMs;

  @override
  bool operator ==(Object other) =>
      other is FillerSelection &&
      other.attempt == attempt &&
      other.category == category &&
      other.fillerIndex == fillerIndex &&
      other.maxPrepareMs == maxPrepareMs &&
      other.maxAsideMs == maxAsideMs;

  @override
  int get hashCode =>
      Object.hash(attempt, category, fillerIndex, maxPrepareMs, maxAsideMs);
}

/// Pure arm/deadline turn state machine.
final class TurnPacing {
  TurnPacing(this._policy, TtftWindow samples, this.t0Ms) {
    _deadline = calculateInitialDeadline(_policy, samples);
    if (!_policy.enabled) {
      _phase = PacingPhase.idle;
    } else if (_deadline.isDisabled) {
      _phase = PacingPhase.staging;
      _nextEligibleAtMs = saturatingAddU64(
        t0Ms,
        msOr(_policy.pacingIntervalMs, defaultPacingIntervalMs),
      );
    } else {
      _phase = PacingPhase.staging;
    }
    _classifier = CategoryClassifier(_policy);
    _lastTransitionMs = t0Ms;
  }

  final PacingPolicy _policy;
  late final InitialDeadline _deadline;
  PacingPhase _phase = PacingPhase.idle;
  late final CategoryClassifier _classifier;

  /// Turn start time supplied at dispatch.
  final int t0Ms;

  int? _nextEligibleAtMs;
  int _attempts = 0;
  int _committed = 0;
  int _spoken = 0;
  final List<ThinkingFillerCategory> _usedCategories =
      <ThinkingFillerCategory>[];
  int? _armedAttempt;
  bool _initialArmDone = false;
  bool _pacingClosed = false;
  int _lastTransitionMs = 0;

  /// Attempt id currently armed, if any.
  int? get armedAttempt => _armedAttempt;

  /// Frozen initial deadline for this turn.
  InitialDeadline get deadline => _deadline;

  /// Current phase.
  PacingPhase get phase => _phase;

  /// Time of the most recent accepted transition.
  int get lastTransitionMs => _lastTransitionMs;

  /// Earliest time for an interval opportunity, if one is scheduled.
  int? get nextEligibleAtMs => _nextEligibleAtMs;

  /// Filler attempts started this turn.
  int get attempts => _attempts;

  /// Fillers committed to a (future) cue this turn.
  int get committed => _committed;

  /// Fillers reported as started on the (future) audio clock.
  int get spoken => _spoken;

  /// Whether pacing is latched closed for this turn.
  bool get isClosed => _pacingClosed;

  /// Categories already used this turn.
  List<ThinkingFillerCategory> get usedCategories =>
      List<ThinkingFillerCategory>.unmodifiable(_usedCategories);

  /// Commit cap, clamped to 1..8 fillers.
  int get maxFillers => _toU64(
    _max(
      1.0,
      _min(8.0, finiteOr(_policy.maxFillersPerTurn, 3.0).round().toDouble()),
    ),
  );

  /// Attempt cap: twice the commit cap.
  int get maxAttempts => 2 * maxFillers;

  /// Whether the initial deadline has elapsed.
  bool initialOpportunityDue(int nowMs) {
    final delay = _deadline.afterMs;
    if (delay == null) return false;
    return _compareU64(nowMs, saturatingAddU64(t0Ms, delay)) >= 0;
  }

  /// Feed hidden reasoning into the bounded classifier.
  ClassificationResult observeReasoning(String chunk) =>
      _classifier.consume(chunk);

  /// Reset the category-evidence window between opportunities.
  void resetEvidence() => _classifier.reset();

  void _close() {
    _pacingClosed = true;
    _nextEligibleAtMs = null;
  }

  /// Fire an opportunity: select a filler and transition to [PacingPhase.fillerArmed].
  ///
  /// Returns `null` when the phase, deadline, commit cap, attempt cap, or a
  /// zero uncached-preparation budget forbids another filler.
  FillerSelection? armOpportunity(int nowMs, Opportunity kind) {
    if (!_policy.enabled || _pacingClosed || _phase != PacingPhase.staging) {
      return null;
    }

    if (_committed >= maxFillers) {
      _close();
      _phase = PacingPhase.settled;
      _lastTransitionMs = nowMs;
      return null;
    }
    if (_attempts >= maxAttempts) return null;

    if (kind == Opportunity.initial) {
      if (_initialArmDone || !initialOpportunityDue(nowMs)) return null;
    } else {
      if (!_initialArmDone && !_deadline.isDisabled) return null;
      final eligible = _nextEligibleAtMs;
      if (eligible == null || _compareU64(nowMs, eligible) < 0) return null;
    }

    var category =
        _classifier.topCategoryExcluding(_usedCategories) ??
        ThinkingFillerCategory.generic;
    final fillers = _policy.fillers ?? const <ThinkingFiller>[];
    var fillerIndex = _enabledIndex(fillers, category);
    if (fillerIndex == null && category != ThinkingFillerCategory.generic) {
      category = ThinkingFillerCategory.generic;
      fillerIndex = _enabledIndex(fillers, category);
    }

    final maxPrepareMs = msOr(
      _policy.maxFillerSynthesisBudgetMs,
      defaultFillerSynthesisBudgetMs,
    );
    if (fillerIndex == null && maxPrepareMs == 0) {
      // No cached phrase and no budget to prepare one: stay silent.
      return null;
    }

    _attempts++;
    _committed++;
    _usedCategories.add(category);
    _armedAttempt = _attempts;
    _phase = PacingPhase.fillerArmed;
    _lastTransitionMs = nowMs;
    _nextEligibleAtMs = null;
    if (kind == Opportunity.initial) _initialArmDone = true;
    if (_committed >= maxFillers) _close();

    return FillerSelection(
      attempt: _attempts,
      category: category,
      fillerIndex: fillerIndex,
      maxPrepareMs: maxPrepareMs,
      maxAsideMs: msOr(_policy.maxSynthesisBudgetMs, defaultSynthesisBudgetMs),
    );
  }

  static int? _enabledIndex(
    List<ThinkingFiller> fillers,
    ThinkingFillerCategory category,
  ) {
    for (var i = 0; i < fillers.length; i++) {
      if (fillers[i].enabled && fillers[i].category == category) return i;
    }
    return null;
  }

  /// Record a skipped initial opportunity and schedule the next interval.
  void skipInitial(int nowMs) {
    if (_policy.enabled &&
        !_pacingClosed &&
        _phase == PacingPhase.staging &&
        !_deadline.isDisabled &&
        !_initialArmDone) {
      _initialArmDone = true;
      _lastTransitionMs = nowMs;
      _classifier.reset();
      _nextEligibleAtMs = saturatingAddU64(
        nowMs,
        msOr(_policy.pacingIntervalMs, defaultPacingIntervalMs),
      );
    }
  }

  /// Report that an armed filler actually started (Armed -> Active).
  bool fire(int nowMs) {
    if (_phase != PacingPhase.fillerArmed) return false;
    _phase = PacingPhase.fillerActive;
    _spoken++;
    _lastTransitionMs = nowMs;
    return true;
  }

  /// Report that a playing filler ended (Active -> Staging or Settled).
  DisarmOutcome disarm(int nowMs) {
    if (_phase != PacingPhase.fillerActive) return DisarmOutcome.ignored;
    _armedAttempt = null;
    _lastTransitionMs = nowMs;
    _classifier.reset();

    if (_pacingClosed || _committed >= maxFillers || _attempts >= maxAttempts) {
      _close();
      _phase = PacingPhase.settled;
      return DisarmOutcome.closed;
    }

    _phase = PacingPhase.staging;
    _nextEligibleAtMs = saturatingAddU64(
      nowMs,
      msOr(_policy.pacingIntervalMs, defaultPacingIntervalMs),
    );
    return DisarmOutcome.rearmed;
  }

  /// Record first usable answer onset; disarm an armed but unstarted filler.
  CancelOutcome? onAnswer(int nowMs) {
    _close();
    _lastTransitionMs = nowMs;
    final wasArmed = _phase == PacingPhase.fillerArmed;
    if (wasArmed) {
      _armedAttempt = null;
      _phase = PacingPhase.answerReady;
      return CancelOutcome(CancelReason.answerArrived, _attempts);
    }
    if (_phase == PacingPhase.staging) _phase = PacingPhase.answerReady;
    // A committed or playing filler finishes; answer playback queues behind it.
    return null;
  }

  /// Cancel the turn; disarm an armed but unstarted filler.
  CancelOutcome? cancel(CancelReason reason, int nowMs) {
    final wasArmed = _phase == PacingPhase.fillerArmed;
    _close();
    _phase = PacingPhase.settled;
    _lastTransitionMs = nowMs;
    if (wasArmed) {
      _armedAttempt = null;
      return CancelOutcome(reason, _attempts);
    }
    return null;
  }

  /// Settle the turn without a separate cancellation outcome.
  void settle(int nowMs) {
    _close();
    _phase = PacingPhase.settled;
    _lastTransitionMs = nowMs;
  }
}
