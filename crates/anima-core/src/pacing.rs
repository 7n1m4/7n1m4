// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure conversational-pacing decision layer for thinking fillers.
//!
//! This module ports the *decision* half of `turn-pacing-coordinator.ts` and
//! `category-classifier.ts`: a bounded TTFT sample ring with EMA/p90 deadline
//! calculation, a deterministic arm/deadline turn state machine, a bounded
//! reasoning-category classifier, and filler selection under the commit and
//! synthesis-budget caps carried by [`AiriPacing`]. It uses the card schema
//! types from [`crate::cards`] instead of redefining them.
//!
//! NOTE: this slice intentionally has no consumer yet. There are no wire types,
//! chat changes, speech cues, timers, or daemon wiring here. A follow-up must
//! feed real successful TTFT samples into [`TtftWindow`] and bind the returned
//! [`FillerSelection`] / [`CancelOutcome`] decisions to bounded cues.

use crate::cards::{AiriPacing, AiriThinkingFillerCategory};
use std::collections::VecDeque;

/// Most recent TTFT samples retained for deadline calibration.
pub const DEFAULT_TTFT_WINDOW: usize = 32;

/// Default category-evidence buffer size, in characters.
const DEFAULT_MAX_REASONING_CHARS: usize = 1024;

/// Default arm-delay bounds, in milliseconds.
const DEFAULT_ARM_MIN_MS: f64 = 900.0;
const DEFAULT_ARM_MAX_MS: f64 = 3500.0;
/// Deadline used when no TTFT samples are available.
const DEFAULT_DEADLINE_MS: f64 = 1800.0;
/// Initial cached opportunity is skipped when p90 is at or below this value.
const ULTRA_FAST_P90_MS: f64 = 700.0;
/// Default synthesis budgets, in milliseconds.
const DEFAULT_FILLER_SYNTHESIS_BUDGET_MS: f64 = 3200.0;
const DEFAULT_SYNTHESIS_BUDGET_MS: f64 = 3200.0;
/// Repeat-opportunity interval when the turn is dispatched ultra-fast.
const DEFAULT_PACING_INTERVAL_MS: f64 = 15000.0;

const SPECIFIC_CATEGORIES: [AiriThinkingFillerCategory; 4] = [
    AiriThinkingFillerCategory::Analytical,
    AiriThinkingFillerCategory::Memory,
    AiriThinkingFillerCategory::Emotional,
    AiriThinkingFillerCategory::Uncertain,
];

fn finite_or(value: Option<f64>, default: f64) -> f64 {
    value.filter(|v| v.is_finite()).unwrap_or(default)
}

fn ms_or(value: Option<f64>, default: f64) -> u64 {
    finite_or(value, default).max(0.0).round() as u64
}

/// A chronological, bounded ring of successful time-to-first-token samples.
///
/// Samples are retained in insertion order; pushing past capacity drops the
/// oldest. Non-finite or negative samples are rejected so card-supplied data
/// cannot poison the deadline math.
#[derive(Debug, Clone)]
pub struct TtftWindow {
    samples: VecDeque<f64>,
    capacity: usize,
}

impl Default for TtftWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl TtftWindow {
    /// Create a window holding up to [`DEFAULT_TTFT_WINDOW`] samples.
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_TTFT_WINDOW)
    }

    /// Create a window holding up to `capacity` samples (at least one).
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            samples: VecDeque::with_capacity(capacity.max(1)),
            capacity: capacity.max(1),
        }
    }

    /// Append a successful TTFT sample. Returns `false` for invalid input.
    pub fn push(&mut self, sample_ms: f64) -> bool {
        if !sample_ms.is_finite() || sample_ms < 0.0 {
            return false;
        }
        if self.samples.len() == self.capacity {
            self.samples.pop_front();
        }
        self.samples.push_back(sample_ms);
        true
    }

    /// Number of retained samples.
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// Whether the window has no samples.
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Drop all retained samples.
    pub fn clear(&mut self) {
        self.samples.clear();
    }

    /// Iterate samples in chronological order.
    pub fn iter(&self) -> impl Iterator<Item = f64> + '_ {
        self.samples.iter().copied()
    }

    /// A quantile of the samples using the coordinator's nearest-rank variant.
    ///
    /// The sorting copy keeps the percentile monotonic while the ring itself
    /// stays chronological. Returns `None` for an empty window.
    pub fn percentile(&self, q: f64) -> Option<f64> {
        if self.samples.is_empty() {
            return None;
        }
        let q = q.clamp(0.0, 1.0);
        let mut sorted: Vec<f64> = self.samples.iter().copied().collect();
        sorted.sort_by(f64::total_cmp);
        let index = ((sorted.len() as f64) * q).floor() as usize;
        sorted.get(index.min(sorted.len() - 1)).copied()
    }

    /// EMA and mean absolute deviation, updated together in one pass.
    ///
    /// Mirrors the coordinator: `mu` starts at the smallest sample with
    /// `alpha = 2 / (clamp(n, 8, 32) + 1)`, and `d` uses `beta = 0.2` with the
    /// *running* `mu` (each sample updates `mu` before its error is measured).
    /// `mu` stays in `[min, max]` because every update is a convex combination.
    pub fn ema_and_deviation(&self) -> Option<(f64, f64)> {
        if self.samples.is_empty() {
            return None;
        }
        let alpha = 2.0 / (self.samples.len().clamp(8, 32) as f64 + 1.0);
        let beta = 0.2;
        let mut mu = self.percentile(0.0)?;
        let mut deviation = 0.0;
        for sample in self.samples.iter().copied() {
            mu = alpha * sample + (1.0 - alpha) * mu;
            deviation = beta * (sample - mu).abs() + (1.0 - beta) * deviation;
        }
        Some((mu, deviation))
    }
}

/// Outcome of adaptive initial-arm calibration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitialDeadline {
    /// Pacing is disabled, or the provider is too fast to need an initial filler.
    Disabled,
    /// Arm the first opportunity this many milliseconds after turn start.
    AfterMs(u64),
}

/// Compute the frozen initial arm deadline from a policy and TTFT history.
///
/// Mirrors the coordinator: no samples yields a clamped 1800 ms deadline,
/// p90 <= 700 ms disables the initial opportunity, and otherwise
/// `mu - kFast * deviation` (floored by p10 with at least 20 samples) is
/// clamped to the configured arm bounds.
pub fn calculate_initial_deadline(policy: &AiriPacing, samples: &TtftWindow) -> InitialDeadline {
    if !policy.enabled {
        return InitialDeadline::Disabled;
    }

    let min_ms = finite_or(policy.arm_min_ms, DEFAULT_ARM_MIN_MS);
    let max_ms = finite_or(policy.arm_max_ms, DEFAULT_ARM_MAX_MS);
    let clamp_ms = |value: f64| -> u64 { value.min(max_ms).max(min_ms).max(0.0).round() as u64 };

    let Some(p90) = samples.percentile(0.9) else {
        return InitialDeadline::AfterMs(clamp_ms(DEFAULT_DEADLINE_MS));
    };
    if p90 <= ULTRA_FAST_P90_MS {
        return InitialDeadline::Disabled;
    }

    let Some((mu, deviation)) = samples.ema_and_deviation() else {
        return InitialDeadline::AfterMs(clamp_ms(DEFAULT_DEADLINE_MS));
    };
    let k_fast = finite_or(policy.k_fast, 0.5);
    let mut deadline = mu - k_fast * deviation;

    if samples.len() >= 20 {
        if let Some(p10) = samples.percentile(0.1) {
            deadline = deadline.max(p10);
        }
    }

    InitialDeadline::AfterMs(clamp_ms(deadline))
}

/// Net evidence for each specific thinking-filler category.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CategoryScores {
    /// Analytical score.
    pub analytical: i32,
    /// Memory score.
    pub memory: i32,
    /// Emotional score.
    pub emotional: i32,
    /// Uncertain score.
    pub uncertain: i32,
}

impl CategoryScores {
    /// Net score for one category.
    pub fn get(self, category: AiriThinkingFillerCategory) -> i32 {
        match category {
            AiriThinkingFillerCategory::Analytical => self.analytical,
            AiriThinkingFillerCategory::Memory => self.memory,
            AiriThinkingFillerCategory::Emotional => self.emotional,
            AiriThinkingFillerCategory::Uncertain => self.uncertain,
            AiriThinkingFillerCategory::Generic => 0,
        }
    }

    fn add(&mut self, category: AiriThinkingFillerCategory, delta: i32) {
        match category {
            AiriThinkingFillerCategory::Analytical => self.analytical += delta,
            AiriThinkingFillerCategory::Memory => self.memory += delta,
            AiriThinkingFillerCategory::Emotional => self.emotional += delta,
            AiriThinkingFillerCategory::Uncertain => self.uncertain += delta,
            AiriThinkingFillerCategory::Generic => {}
        }
    }
}

/// Result of one bounded category-evaluation pass.
#[derive(Debug, Clone, PartialEq)]
pub struct ClassificationResult {
    /// Winning category, or `Generic` when nothing clears the threshold.
    pub category: AiriThinkingFillerCategory,
    /// Winning net score as a fraction of all matched evidence.
    pub confidence: f64,
    /// Per-category net scores.
    pub scores: CategoryScores,
    /// Lexicon terms that matched, including negated matches.
    pub matched_tokens: Vec<String>,
}

const NEGATIONS: &[&str] = &[
    "not",
    "no",
    "never",
    "neither",
    "nor",
    "dont",
    "don't",
    "doesnt",
    "doesn't",
    "didnt",
    "didn't",
    "wont",
    "won't",
    "wouldnt",
    "wouldn't",
    "cant",
    "can't",
    "couldnt",
    "couldn't",
    "shouldnt",
    "shouldn't",
    "hardly",
    "scarcely",
];

fn lexicon(category: AiriThinkingFillerCategory) -> &'static [&'static str] {
    match category {
        AiriThinkingFillerCategory::Analytical => &[
            "calculate",
            "calculation",
            "compute",
            "computing",
            "analyze",
            "analysis",
            "logic",
            "logical",
            "math",
            "mathematical",
            "reason",
            "reasoning",
            "deduce",
            "deduction",
            "step",
            "evaluate",
            "evaluation",
            "formula",
            "code",
            "algorithm",
            "system",
            "solve",
            "solution",
            "estimate",
            "optimize",
        ],
        AiriThinkingFillerCategory::Memory => &[
            "recall",
            "recalling",
            "remember",
            "remembering",
            "history",
            "past",
            "earlier",
            "previous",
            "yesterday",
            "before",
            "memory",
            "memories",
            "context",
            "remind",
            "forget",
            "recollect",
        ],
        AiriThinkingFillerCategory::Emotional => &[
            "feel",
            "feeling",
            "happy",
            "sad",
            "angry",
            "excited",
            "tender",
            "heart",
            "warmth",
            "empathy",
            "sympathetic",
            "affection",
            "worried",
            "grief",
            "joy",
            "fond",
            "anxious",
            "care",
        ],
        AiriThinkingFillerCategory::Uncertain => &[
            "maybe",
            "perhaps",
            "unsure",
            "wonder",
            "wondering",
            "hesitate",
            "doubt",
            "confused",
            "confusion",
            "guess",
            "guessing",
            "unclear",
            "possibly",
            "dilemma",
            "ponder",
        ],
        AiriThinkingFillerCategory::Generic => &[],
    }
}

/// Lowercases text and splits it into words, preserving internal apostrophes.
fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut previous_was_word = false;

    for ch in text.chars() {
        let is_word = ch.is_alphabetic() || ch.is_numeric();
        if is_word {
            for lower in ch.to_lowercase() {
                current.push(lower);
            }
        } else if (ch == '\'' || ch == '\u{2019}') && previous_was_word && !current.is_empty() {
            current.push('\'');
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
        previous_was_word = is_word;
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn is_word_char(ch: char) -> bool {
    ch.is_alphabetic() || ch.is_numeric() || ch == '\'' || ch == '\u{2019}'
}

fn evaluable_prefix(buffer: &str, include_trailing: bool) -> Option<&str> {
    if buffer.trim().is_empty() {
        return Some("");
    }
    if include_trailing {
        return Some(buffer);
    }
    let mut end = None;
    for (index, ch) in buffer.char_indices() {
        if !is_word_char(ch) {
            end = Some(index + ch.len_utf8());
        }
    }
    end.map(|at| &buffer[..at])
}

fn empty_result() -> ClassificationResult {
    ClassificationResult {
        category: AiriThinkingFillerCategory::Generic,
        confidence: 0.0,
        scores: CategoryScores::default(),
        matched_tokens: Vec::new(),
    }
}

/// Bounded, chunk-invariant lexicon classifier for hidden reasoning text.
///
/// A trailing partial word is held until a delimiter arrives, so splitting a
/// reasoning stream into arbitrary chunks does not change the score.
#[derive(Debug, Clone)]
pub struct CategoryClassifier {
    threshold: f64,
    max_chars: usize,
    buffer: String,
}

impl CategoryClassifier {
    /// Build from a card's pacing policy (`categoryThreshold` when present).
    pub fn new(policy: &AiriPacing) -> Self {
        Self::with_limits(
            finite_or(policy.category_threshold, 1.0).max(1.0),
            DEFAULT_MAX_REASONING_CHARS,
        )
    }

    /// Build with an explicit score threshold and character-window bound.
    pub fn with_limits(threshold: f64, max_chars: usize) -> Self {
        Self {
            threshold: threshold.max(1.0),
            max_chars: max_chars.max(1),
            buffer: String::new(),
        }
    }

    /// Number of buffered reasoning characters (for diagnostics and tests).
    pub fn buffered_chars(&self) -> usize {
        self.buffer.chars().count()
    }

    /// Append a reasoning chunk and classify completed terms only.
    pub fn consume(&mut self, chunk: &str) -> ClassificationResult {
        if !chunk.is_empty() {
            self.buffer.push_str(chunk);
            let extra = self.buffered_chars().saturating_sub(self.max_chars);
            if extra > 0 {
                self.buffer = self.buffer.chars().skip(extra).collect();
            }
        }
        self.evaluate(false)
    }

    /// Classify the buffer including a trailing partial word.
    pub fn flush(&self) -> ClassificationResult {
        self.evaluate(true)
    }

    /// Clear the evidence window (used between filler opportunities).
    pub fn reset(&mut self) {
        self.buffer.clear();
    }

    fn evaluate(&self, include_trailing: bool) -> ClassificationResult {
        let Some(prefix) = evaluable_prefix(&self.buffer, include_trailing) else {
            return empty_result();
        };
        if prefix.is_empty() {
            return empty_result();
        }

        let tokens = tokenize(prefix);
        let mut scores = CategoryScores::default();
        let mut matched_tokens = Vec::new();
        let mut last_negation = -100_i32;

        for (index, token) in tokens.iter().enumerate() {
            if NEGATIONS.contains(&token.as_str()) {
                last_negation = index as i32;
                continue;
            }
            let negated = index as i32 - last_negation <= 3;
            for &category in &SPECIFIC_CATEGORIES {
                if lexicon(category).contains(&token.as_str()) {
                    matched_tokens.push(token.clone());
                    scores.add(category, if negated { -1 } else { 1 });
                }
            }
        }

        let mut best = AiriThinkingFillerCategory::Generic;
        let mut highest_net = 0;
        for &category in &SPECIFIC_CATEGORIES {
            let net = scores.get(category);
            if net as f64 >= self.threshold && net > highest_net {
                highest_net = net;
                best = category;
            }
        }

        let evidence = matched_tokens.len() as f64;
        let confidence = if best != AiriThinkingFillerCategory::Generic && evidence > 0.0 {
            (highest_net as f64 / evidence).clamp(0.0, 1.0)
        } else {
            0.0
        };

        ClassificationResult {
            category: best,
            confidence,
            scores,
            matched_tokens,
        }
    }

    /// Strongest eligible category not already used this turn.
    ///
    /// Applies the relative guard so a weak runner-up cannot win solely because
    /// a dominant category already spoke.
    pub fn top_category_excluding(
        &self,
        excluded: &[AiriThinkingFillerCategory],
    ) -> Option<AiriThinkingFillerCategory> {
        let result = self.flush();
        let strongest = SPECIFIC_CATEGORIES
            .iter()
            .map(|&category| result.scores.get(category).max(0))
            .max()
            .unwrap_or(0);

        let mut best = None;
        let mut highest_net = 0;
        for &category in &SPECIFIC_CATEGORIES {
            if excluded.contains(&category) {
                continue;
            }
            let net = result.scores.get(category);
            if net as f64 >= self.threshold
                && net as f64 >= 0.5 * strongest as f64
                && net > highest_net
            {
                highest_net = net;
                best = Some(category);
            }
        }
        best
    }
}

/// Lifecycle phase of one pacing turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacingPhase {
    /// Pacing disabled; no opportunity can be armed.
    Idle,
    /// Waiting for the next opportunity's deadline.
    Staging,
    /// A filler was selected and handed off, but has not started yet.
    FillerArmed,
    /// The selected filler has started playing.
    FillerActive,
    /// Answer onset closed pacing; a playing filler may still finish.
    AnswerReady,
    /// The turn is settled and no further transitions are accepted.
    Settled,
}

/// Which opportunity the caller is evaluating.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opportunity {
    /// The initial cached opportunity at `t0 + deadline`.
    Initial,
    /// A later opportunity at `next_eligible_at_ms`.
    Interval,
}

/// Why an armed filler was disarmed before it started.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelReason {
    /// A usable answer literal or answer audio arrived.
    AnswerArrived,
    /// Inference failed.
    InferenceError,
    /// The turn was invalidated or superseded.
    Invalidated,
    /// The assistant turn ended.
    AssistantEnd,
}

/// A cancellation to hand to the (future) cue owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CancelOutcome {
    /// Reason for the cancellation.
    pub reason: CancelReason,
    /// Monotonic attempt id that was disarmed.
    pub attempt: u32,
}

/// Result of a filler ending on the (future) audio clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisarmOutcome {
    /// Another opportunity may be armed after the repeat interval.
    Rearmed,
    /// The commit budget or cutoff latched pacing closed.
    Closed,
    /// No filler was active, so nothing changed.
    Ignored,
}

/// A filler opportunity selected by the decision layer.
///
/// No cue text is emitted here: `filler_index` points into the card's
/// [`AiriPacing::fillers`] list for the future consumer to read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FillerSelection {
    /// Monotonic attempt id within this turn (1-based).
    pub attempt: u32,
    /// Selected category.
    pub category: AiriThinkingFillerCategory,
    /// Index of an enabled, matching cached filler on the card, if any.
    pub filler_index: Option<usize>,
    /// Preparation budget for an uncached filler phrase, in milliseconds.
    pub max_prepare_ms: u64,
    /// Preparation budget for a future dynamic aside, in milliseconds.
    pub max_aside_ms: u64,
}

/// Pure arm/deadline turn state machine.
///
/// All timing is supplied by the caller in milliseconds; there are no timers,
/// async work, wire types, or speech/cue side effects.
#[derive(Debug, Clone)]
pub struct TurnPacing {
    policy: AiriPacing,
    deadline: InitialDeadline,
    phase: PacingPhase,
    t0_ms: u64,
    classifier: CategoryClassifier,
    attempts: u32,
    committed: u32,
    spoken: u32,
    used_categories: Vec<AiriThinkingFillerCategory>,
    armed_attempt: Option<u32>,
    next_eligible_at_ms: Option<u64>,
    initial_arm_done: bool,
    pacing_closed: bool,
    last_transition_ms: u64,
}

impl TurnPacing {
    /// Dispatch a turn at `t0_ms`, freezing the deadline from `samples`.
    pub fn new(policy: &AiriPacing, samples: &TtftWindow, t0_ms: u64) -> Self {
        let deadline = calculate_initial_deadline(policy, samples);
        let (phase, next_eligible_at_ms) =
            if !policy.enabled {
                (PacingPhase::Idle, None)
            } else if deadline == InitialDeadline::Disabled {
                (
                    PacingPhase::Staging,
                    Some(t0_ms.saturating_add(ms_or(
                        policy.pacing_interval_ms,
                        DEFAULT_PACING_INTERVAL_MS,
                    ))),
                )
            } else {
                (PacingPhase::Staging, None)
            };

        Self {
            policy: policy.clone(),
            deadline,
            phase,
            t0_ms,
            classifier: CategoryClassifier::new(policy),
            attempts: 0,
            committed: 0,
            spoken: 0,
            used_categories: Vec::new(),
            armed_attempt: None,
            next_eligible_at_ms,
            initial_arm_done: false,
            pacing_closed: false,
            last_transition_ms: t0_ms,
        }
    }

    /// Frozen initial deadline for this turn.
    pub fn deadline(&self) -> InitialDeadline {
        self.deadline
    }

    /// Current phase.
    pub fn phase(&self) -> PacingPhase {
        self.phase
    }

    /// Turn start time supplied at dispatch.
    pub fn t0_ms(&self) -> u64 {
        self.t0_ms
    }

    /// Time of the most recent accepted transition.
    pub fn last_transition_ms(&self) -> u64 {
        self.last_transition_ms
    }

    /// Earliest time for an interval opportunity, if one is scheduled.
    pub fn next_eligible_at_ms(&self) -> Option<u64> {
        self.next_eligible_at_ms
    }

    /// Filler attempts started this turn.
    pub fn attempts(&self) -> u32 {
        self.attempts
    }

    /// Fillers committed to a (future) cue this turn.
    pub fn committed(&self) -> u32 {
        self.committed
    }

    /// Fillers reported as started on the (future) audio clock.
    pub fn spoken(&self) -> u32 {
        self.spoken
    }

    /// Whether pacing is latched closed for this turn.
    pub fn is_closed(&self) -> bool {
        self.pacing_closed
    }

    /// Categories already used this turn.
    pub fn used_categories(&self) -> &[AiriThinkingFillerCategory] {
        &self.used_categories
    }

    /// Whether the initial deadline has elapsed.
    pub fn initial_opportunity_due(&self, now_ms: u64) -> bool {
        match self.deadline {
            InitialDeadline::Disabled => false,
            InitialDeadline::AfterMs(delay) => now_ms >= self.t0_ms.saturating_add(delay),
        }
    }

    /// Feed hidden reasoning into the bounded classifier.
    pub fn observe_reasoning(&mut self, chunk: &str) -> ClassificationResult {
        self.classifier.consume(chunk)
    }

    /// Reset the category-evidence window between opportunities.
    pub fn reset_evidence(&mut self) {
        self.classifier.reset();
    }

    fn max_fillers(&self) -> u32 {
        finite_or(self.policy.max_fillers_per_turn, 3.0)
            .round()
            .max(1.0)
            .min(8.0) as u32
    }

    fn max_attempts(&self) -> u32 {
        2 * self.max_fillers()
    }

    fn close(&mut self) {
        self.pacing_closed = true;
        self.next_eligible_at_ms = None;
    }

    /// Fire an opportunity: select a filler and transition to `FillerArmed`.
    ///
    /// Returns `None` when the phase, deadline, commit cap, attempt cap, or a
    /// zero uncached-preparation budget forbids another filler.
    pub fn arm_opportunity(&mut self, now_ms: u64, kind: Opportunity) -> Option<FillerSelection> {
        if !self.policy.enabled || self.pacing_closed || self.phase != PacingPhase::Staging {
            return None;
        }

        let max_fillers = self.max_fillers();
        if self.committed >= max_fillers {
            self.close();
            self.phase = PacingPhase::Settled;
            self.last_transition_ms = now_ms;
            return None;
        }
        if self.attempts >= self.max_attempts() {
            return None;
        }

        match kind {
            Opportunity::Initial => {
                if self.initial_arm_done || !self.initial_opportunity_due(now_ms) {
                    return None;
                }
            }
            Opportunity::Interval => {
                if !self.initial_arm_done && self.deadline != InitialDeadline::Disabled {
                    return None;
                }
                let eligible = self.next_eligible_at_ms?;
                if now_ms < eligible {
                    return None;
                }
            }
        }

        let mut category = self
            .classifier
            .top_category_excluding(&self.used_categories)
            .unwrap_or(AiriThinkingFillerCategory::Generic);
        let fillers = self.policy.fillers.as_deref().unwrap_or(&[]);
        let mut filler_index = fillers
            .iter()
            .position(|filler| filler.enabled && filler.category == category);
        if filler_index.is_none() && category != AiriThinkingFillerCategory::Generic {
            category = AiriThinkingFillerCategory::Generic;
            filler_index = fillers
                .iter()
                .position(|filler| filler.enabled && filler.category == category);
        }

        let max_prepare_ms = ms_or(
            self.policy.max_filler_synthesis_budget_ms,
            DEFAULT_FILLER_SYNTHESIS_BUDGET_MS,
        );
        if filler_index.is_none() && max_prepare_ms == 0 {
            // No cached phrase and no budget to prepare one: stay silent.
            return None;
        }

        self.attempts += 1;
        self.committed += 1;
        self.used_categories.push(category);
        self.armed_attempt = Some(self.attempts);
        self.phase = PacingPhase::FillerArmed;
        self.last_transition_ms = now_ms;
        self.next_eligible_at_ms = None;
        if kind == Opportunity::Initial {
            self.initial_arm_done = true;
        }
        if self.committed >= max_fillers {
            self.close();
        }

        Some(FillerSelection {
            attempt: self.attempts,
            category,
            filler_index,
            max_prepare_ms,
            max_aside_ms: ms_or(
                self.policy.max_synthesis_budget_ms,
                DEFAULT_SYNTHESIS_BUDGET_MS,
            ),
        })
    }

    /// Record a skipped initial opportunity and schedule the next interval.
    ///
    /// Without this, a skipped initial would leave interval opportunities
    /// unreachable; it does not consume the commit budget.
    pub fn skip_initial(&mut self, now_ms: u64) {
        if self.policy.enabled
            && !self.pacing_closed
            && self.phase == PacingPhase::Staging
            && self.deadline != InitialDeadline::Disabled
            && !self.initial_arm_done
        {
            self.initial_arm_done = true;
            self.last_transition_ms = now_ms;
            self.classifier.reset();
            self.next_eligible_at_ms = Some(now_ms.saturating_add(ms_or(
                self.policy.pacing_interval_ms,
                DEFAULT_PACING_INTERVAL_MS,
            )));
        }
    }

    /// Report that an armed filler actually started (Armed → Active).
    pub fn fire(&mut self, now_ms: u64) -> bool {
        if self.phase != PacingPhase::FillerArmed {
            return false;
        }
        self.phase = PacingPhase::FillerActive;
        self.spoken += 1;
        self.last_transition_ms = now_ms;
        true
    }

    /// Report that a playing filler ended (Active → Staging or Settled).
    pub fn disarm(&mut self, now_ms: u64) -> DisarmOutcome {
        if self.phase != PacingPhase::FillerActive {
            return DisarmOutcome::Ignored;
        }
        self.armed_attempt = None;
        self.last_transition_ms = now_ms;
        self.classifier.reset();

        if self.pacing_closed
            || self.committed >= self.max_fillers()
            || self.attempts >= self.max_attempts()
        {
            self.close();
            self.phase = PacingPhase::Settled;
            return DisarmOutcome::Closed;
        }

        self.phase = PacingPhase::Staging;
        self.next_eligible_at_ms = Some(now_ms.saturating_add(ms_or(
            self.policy.pacing_interval_ms,
            DEFAULT_PACING_INTERVAL_MS,
        )));
        DisarmOutcome::Rearmed
    }

    /// Record first usable answer onset; disarm an armed but unstarted filler.
    pub fn on_answer(&mut self, now_ms: u64) -> Option<CancelOutcome> {
        self.close();
        self.last_transition_ms = now_ms;
        let was_armed = self.phase == PacingPhase::FillerArmed;
        if was_armed {
            self.armed_attempt = None;
            self.phase = PacingPhase::AnswerReady;
            Some(CancelOutcome {
                reason: CancelReason::AnswerArrived,
                attempt: self.attempts,
            })
        } else if self.phase == PacingPhase::Staging {
            self.phase = PacingPhase::AnswerReady;
            None
        } else {
            // A committed or playing filler finishes; answer playback queues behind it.
            None
        }
    }

    /// Cancel the turn; disarm an armed but unstarted filler.
    pub fn cancel(&mut self, reason: CancelReason, now_ms: u64) -> Option<CancelOutcome> {
        let was_armed = self.phase == PacingPhase::FillerArmed;
        self.close();
        self.phase = PacingPhase::Settled;
        self.last_transition_ms = now_ms;
        if was_armed {
            self.armed_attempt = None;
            Some(CancelOutcome {
                reason,
                attempt: self.attempts,
            })
        } else {
            None
        }
    }

    /// Settle the turn without a separate cancellation outcome.
    pub fn settle(&mut self, now_ms: u64) {
        self.close();
        self.phase = PacingPhase::Settled;
        self.last_transition_ms = now_ms;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cards::AiriThinkingFiller;

    fn window(samples: &[f64]) -> TtftWindow {
        let mut ring = TtftWindow::new();
        for sample in samples {
            assert!(ring.push(*sample));
        }
        ring
    }

    fn card_policy(max_fillers: f64) -> AiriPacing {
        AiriPacing {
            enabled: true,
            max_fillers_per_turn: Some(max_fillers),
            fillers: Some(vec![
                AiriThinkingFiller {
                    text: "Hmm, let me see.".into(),
                    category: AiriThinkingFillerCategory::Generic,
                    enabled: true,
                },
                AiriThinkingFiller {
                    text: "Let me work through the steps.".into(),
                    category: AiriThinkingFillerCategory::Analytical,
                    enabled: true,
                },
                AiriThinkingFiller {
                    text: "I remember something like that.".into(),
                    category: AiriThinkingFillerCategory::Memory,
                    enabled: true,
                },
            ]),
            ..Default::default()
        }
    }

    #[test]
    fn ttft_ring_is_bounded_and_rejects_invalid_samples() {
        let mut ring = TtftWindow::with_capacity(3);
        assert!(ring.is_empty());
        assert!(!ring.push(f64::NAN));
        assert!(!ring.push(f64::INFINITY));
        assert!(!ring.push(-1.0));
        assert!(ring.is_empty());

        for value in [100.0, 200.0, 300.0, 400.0] {
            assert!(ring.push(value));
        }
        assert_eq!(ring.len(), 3);
        assert_eq!(ring.iter().collect::<Vec<_>>(), vec![200.0, 300.0, 400.0]);
        ring.clear();
        assert!(ring.is_empty());
    }

    #[test]
    fn ema_and_percentiles_stay_within_sample_bounds() {
        let ring = window(&[900.0, 1200.0, 1500.0, 1800.0, 2100.0]);
        let min = ring.percentile(0.0).unwrap();
        let max = ring.percentile(1.0).unwrap();
        assert_eq!(min, 900.0);
        assert_eq!(max, 2100.0);

        let p90 = ring.percentile(0.9).unwrap();
        assert!(p90 >= min && p90 <= max);
        let (mu, deviation) = ring.ema_and_deviation().unwrap();
        assert!(mu >= min && mu <= max, "EMA {mu} escaped sample bounds");
        assert!(deviation >= 0.0);
        // Pin the exact EMA so alpha/clamp drift cannot hide in the wide band.
        assert!(
            (mu - 1434.2478280749883).abs() < 1e-6,
            "EMA {mu} drifted from the parity value"
        );

        assert!(TtftWindow::new().ema_and_deviation().is_none());
        assert!(TtftWindow::new().percentile(0.9).is_none());
    }

    #[test]
    fn deadline_defaults_bounds_and_ultra_fast_disable() {
        let policy = card_policy(3.0);
        assert_eq!(
            calculate_initial_deadline(&policy, &TtftWindow::new()),
            InitialDeadline::AfterMs(1800)
        );

        let fast = window(&[300.0, 320.0, 280.0]);
        assert_eq!(
            calculate_initial_deadline(&policy, &fast),
            InitialDeadline::Disabled
        );

        let slow = window(&[900.0, 1300.0, 1700.0, 2100.0]);
        let deadline = calculate_initial_deadline(&policy, &slow);
        let InitialDeadline::AfterMs(value) = deadline else {
            panic!("expected an armed deadline");
        };
        assert!((DEFAULT_ARM_MIN_MS as u64..=DEFAULT_ARM_MAX_MS as u64).contains(&value));

        // TS clamps min(max, value) then max(min, ...): inverted bounds yield min.
        let inverted = AiriPacing {
            arm_min_ms: Some(2500.0),
            arm_max_ms: Some(1000.0),
            ..card_policy(3.0)
        };
        assert_eq!(
            calculate_initial_deadline(&inverted, &slow),
            InitialDeadline::AfterMs(2500)
        );

        let disabled = AiriPacing {
            enabled: false,
            ..card_policy(3.0)
        };
        assert_eq!(
            calculate_initial_deadline(&disabled, &slow),
            InitialDeadline::Disabled
        );
    }

    #[test]
    fn classifier_detects_categories_and_negation() {
        let mut classifier = CategoryClassifier::new(&AiriPacing::default());

        assert_eq!(
            classifier
                .consume("Let me recall the previous conversation from yesterday ")
                .category,
            AiriThinkingFillerCategory::Memory
        );
        classifier.reset();
        assert_eq!(
            classifier.consume("I feel happy and tender ").category,
            AiriThinkingFillerCategory::Emotional
        );
        classifier.reset();
        assert_eq!(
            classifier.consume("Maybe, perhaps I am unsure ").category,
            AiriThinkingFillerCategory::Uncertain
        );
        classifier.reset();
        let negated = classifier.consume("I do not recall the previous conversation ");
        assert_eq!(negated.category, AiriThinkingFillerCategory::Generic);
        assert!(
            negated.scores.memory < 0,
            "negated memory evidence must be negative"
        );

        classifier.reset();
        assert_eq!(
            classifier
                .consume("Let me analyze and compute the formula ")
                .category,
            AiriThinkingFillerCategory::Analytical
        );
    }

    #[test]
    fn classifier_is_chunk_invariant_and_bounded() {
        let mut whole = CategoryClassifier::new(&AiriPacing::default());
        let expected = whole.consume("I remember the earlier memory ");

        let mut chunked = CategoryClassifier::new(&AiriPacing::default());
        let _ = chunked.consume("I rem");
        let actual = chunked.consume("ember the earlier memory ");
        assert_eq!(actual, expected);

        let mut bounded = CategoryClassifier::with_limits(1.0, 128);
        let oversized = format!("{} recall ", "x".repeat(500));
        let _ = bounded.consume(&oversized);
        assert_eq!(bounded.buffered_chars(), 128);
        assert_eq!(bounded.flush().category, AiriThinkingFillerCategory::Memory);
    }

    #[test]
    fn state_machine_arms_fires_and_disarms() {
        let policy = card_policy(2.0);
        let mut turn = TurnPacing::new(&policy, &window(&[1200.0, 1400.0]), 1000);
        assert_eq!(turn.phase(), PacingPhase::Staging);
        assert!(!turn.initial_opportunity_due(1000));

        let due = match turn.deadline() {
            InitialDeadline::AfterMs(delay) => 1000 + delay,
            InitialDeadline::Disabled => panic!("expected an armed deadline"),
        };
        assert!(turn.initial_opportunity_due(due));
        let selection = turn
            .arm_opportunity(due, Opportunity::Initial)
            .expect("initial opportunity should arm");
        assert_eq!(selection.attempt, 1);
        assert!(selection.filler_index.is_some());
        assert_eq!(turn.phase(), PacingPhase::FillerArmed);
        assert_eq!(turn.committed(), 1);
        assert!(turn
            .arm_opportunity(due + 1, Opportunity::Initial)
            .is_none());

        assert!(turn.fire(due + 10));
        assert_eq!(turn.phase(), PacingPhase::FillerActive);
        assert_eq!(turn.spoken(), 1);
        assert!(!turn.fire(due + 11));

        assert_eq!(turn.disarm(due + 900), DisarmOutcome::Rearmed);
        assert_eq!(turn.phase(), PacingPhase::Staging);
        let next = turn.next_eligible_at_ms().unwrap();
        assert!(turn
            .arm_opportunity(next - 1, Opportunity::Interval)
            .is_none());
        let second = turn
            .arm_opportunity(next, Opportunity::Interval)
            .expect("interval opportunity should arm");
        assert_eq!(second.attempt, 2);
        assert!(turn.fire(next + 1));
        assert_eq!(turn.disarm(next + 900), DisarmOutcome::Closed);
        assert_eq!(turn.phase(), PacingPhase::Settled);
        assert!(turn.is_closed());
    }

    #[test]
    fn skipped_initial_rearms_an_interval_opportunity() {
        let policy = card_policy(2.0);
        let samples = window(&[1200.0]);
        let mut turn = TurnPacing::new(&policy, &samples, 1000);
        assert!(turn.arm_opportunity(1000, Opportunity::Initial).is_none());
        assert_eq!(turn.committed(), 0);

        turn.skip_initial(1000);
        assert_eq!(turn.phase(), PacingPhase::Staging);
        let next = turn.next_eligible_at_ms().unwrap();
        assert!(turn
            .arm_opportunity(next - 1, Opportunity::Interval)
            .is_none());
        let selection = turn
            .arm_opportunity(next, Opportunity::Interval)
            .expect("rearmed interval opportunity should arm");
        assert_eq!(selection.attempt, 1);
    }

    #[test]
    fn answer_and_cancel_disarm_an_armed_filler() {
        let policy = card_policy(3.0);
        let samples = window(&[1200.0]);
        let due = match calculate_initial_deadline(&policy, &samples) {
            InitialDeadline::AfterMs(delay) => 1000 + delay,
            InitialDeadline::Disabled => panic!("expected an armed deadline"),
        };

        let mut answered = TurnPacing::new(&policy, &samples, 1000);
        let _ = answered.arm_opportunity(due, Opportunity::Initial);
        assert_eq!(
            answered.on_answer(due + 5),
            Some(CancelOutcome {
                reason: CancelReason::AnswerArrived,
                attempt: 1,
            })
        );
        assert_eq!(answered.phase(), PacingPhase::AnswerReady);
        assert!(answered.is_closed());
        assert!(answered
            .arm_opportunity(due + 99_999, Opportunity::Interval)
            .is_none());

        let mut canceled = TurnPacing::new(&policy, &samples, 1000);
        let _ = canceled.arm_opportunity(due, Opportunity::Initial);
        assert_eq!(
            canceled.cancel(CancelReason::Invalidated, due + 6),
            Some(CancelOutcome {
                reason: CancelReason::Invalidated,
                attempt: 1,
            })
        );
        assert_eq!(canceled.phase(), PacingPhase::Settled);

        // A committed filler finishes when the answer arrives.
        let mut playing = TurnPacing::new(&policy, &samples, 1000);
        let _ = playing.arm_opportunity(due, Opportunity::Initial);
        assert!(playing.fire(due + 1));
        assert!(playing.on_answer(due + 2).is_none());
        assert_eq!(playing.phase(), PacingPhase::FillerActive);
        assert_eq!(playing.disarm(due + 500), DisarmOutcome::Closed);
    }

    #[test]
    fn commit_and_attempt_caps_are_enforced() {
        let policy = card_policy(1.0);
        let samples = window(&[1200.0]);
        let due = match calculate_initial_deadline(&policy, &samples) {
            InitialDeadline::AfterMs(delay) => 1000 + delay,
            InitialDeadline::Disabled => panic!("expected an armed deadline"),
        };
        let mut turn = TurnPacing::new(&policy, &samples, 1000);
        assert!(turn.arm_opportunity(due, Opportunity::Initial).is_some());
        assert!(turn.fire(due + 1));
        assert_eq!(turn.disarm(due + 100), DisarmOutcome::Closed);
        assert_eq!(turn.committed(), 1);
        assert!(turn.attempts() <= 2 * turn.max_fillers());
        assert!(turn
            .arm_opportunity(due + 99_999, Opportunity::Interval)
            .is_none());
    }

    #[test]
    fn zero_preparation_budget_skips_uncached_filler() {
        let mut policy = card_policy(2.0);
        policy.fillers = None;
        policy.max_filler_synthesis_budget_ms = Some(0.0);
        let samples = window(&[1200.0]);
        let due = match calculate_initial_deadline(&policy, &samples) {
            InitialDeadline::AfterMs(delay) => 1000 + delay,
            InitialDeadline::Disabled => panic!("expected an armed deadline"),
        };
        let mut turn = TurnPacing::new(&policy, &samples, 1000);
        assert!(turn.arm_opportunity(due, Opportunity::Initial).is_none());
        assert_eq!(turn.committed(), 0);
        assert_eq!(turn.phase(), PacingPhase::Staging);
    }

    #[test]
    fn selection_prefers_strongest_unused_category() {
        let policy = card_policy(3.0);
        let samples = window(&[1200.0]);
        let due = match calculate_initial_deadline(&policy, &samples) {
            InitialDeadline::AfterMs(delay) => 1000 + delay,
            InitialDeadline::Disabled => panic!("expected an armed deadline"),
        };
        let mut turn = TurnPacing::new(&policy, &samples, 1000);

        let _ = turn.observe_reasoning("Let me analyze and compute the formula ");
        let first = turn
            .arm_opportunity(due, Opportunity::Initial)
            .expect("initial opportunity should arm");
        assert_eq!(first.category, AiriThinkingFillerCategory::Analytical);

        assert!(turn.fire(due + 1));
        let _ = turn.disarm(due + 100);
        let next = turn.next_eligible_at_ms().unwrap();
        let _ = turn.observe_reasoning("I recall the previous history ");
        let second = turn
            .arm_opportunity(next, Opportunity::Interval)
            .expect("interval opportunity should arm");
        assert_eq!(second.category, AiriThinkingFillerCategory::Memory);
        assert_eq!(
            turn.used_categories(),
            &[
                AiriThinkingFillerCategory::Analytical,
                AiriThinkingFillerCategory::Memory,
            ]
        );
    }
}
