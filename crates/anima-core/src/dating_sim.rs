// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure Amagami dating-sim state and tick core, ported from the Vue reference
//! `packages/stage-ui/src/stores/dating-sim.ts:28-49,163-196,502-508,593-622`.
//!
//! This module owns no store, daemon verb, DTO, wire type, persistence, event,
//! clock/rAF loop, inference hook, or terminal hook. The only "outcome" is a
//! returned value from a pure query.

/// The eight Amagami-inspired metrics of the Vue store's `variables` record.
///
/// Every value mirrors the TypeScript `number` as `f64`. Defaults are exact;
/// construction and the generic setter never clamp.
#[derive(Debug, Clone, PartialEq)]
pub struct Variables {
    /// `Intimacy`.
    pub intimacy: f64,
    /// `Tension`.
    pub tension: f64,
    /// `ActionPoints`.
    pub action_points: f64,
    /// `TimeOfDay` (24-hour format).
    pub time_of_day: f64,
    /// `Timer` (choice countdown).
    pub timer: f64,
    /// `positiveScore`.
    pub positive_score: f64,
    /// `negativeScore`.
    pub negative_score: f64,
    /// `turnsElapsed`.
    pub turns_elapsed: f64,
}

impl Default for Variables {
    fn default() -> Self {
        Self {
            intimacy: 0.0,
            tension: 50.0,
            action_points: 5.0,
            time_of_day: 12.0,
            timer: 0.0,
            positive_score: 0.0,
            negative_score: 0.0,
            turns_elapsed: 0.0,
        }
    }
}

/// Typed key for one metric, standing in for the TS record's string keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Variable {
    /// `Intimacy`.
    Intimacy,
    /// `Tension`.
    Tension,
    /// `ActionPoints`.
    ActionPoints,
    /// `TimeOfDay`.
    TimeOfDay,
    /// `Timer`.
    Timer,
    /// `positiveScore`.
    PositiveScore,
    /// `negativeScore`.
    NegativeScore,
    /// `turnsElapsed`.
    TurnsElapsed,
}

/// Strict mood classification from the Vue `mood` computed property.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoodState {
    /// `t < 30`.
    Low,
    /// Neither high nor low.
    Normal,
    /// `t > 60` (without the max precondition).
    High,
    /// `i > 80 && t > 80`.
    Max,
}

/// Result of one countdown tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimerOutcome {
    /// The countdown is still running, or no countdown was active.
    Pending,
    /// The countdown just reached zero; the caller owns the timeout reaction.
    Fired,
}

impl Variables {
    fn slot(&self, variable: Variable) -> &f64 {
        match variable {
            Variable::Intimacy => &self.intimacy,
            Variable::Tension => &self.tension,
            Variable::ActionPoints => &self.action_points,
            Variable::TimeOfDay => &self.time_of_day,
            Variable::Timer => &self.timer,
            Variable::PositiveScore => &self.positive_score,
            Variable::NegativeScore => &self.negative_score,
            Variable::TurnsElapsed => &self.turns_elapsed,
        }
    }

    fn slot_mut(&mut self, variable: Variable) -> &mut f64 {
        match variable {
            Variable::Intimacy => &mut self.intimacy,
            Variable::Tension => &mut self.tension,
            Variable::ActionPoints => &mut self.action_points,
            Variable::TimeOfDay => &mut self.time_of_day,
            Variable::Timer => &mut self.timer,
            Variable::PositiveScore => &mut self.positive_score,
            Variable::NegativeScore => &mut self.negative_score,
            Variable::TurnsElapsed => &mut self.turns_elapsed,
        }
    }

    /// Raw getter (TS `getVariable`): no clamping or normalization.
    pub fn get(&self, variable: Variable) -> f64 {
        *self.slot(variable)
    }

    /// Raw setter (TS `setVariable`): no clamping, even for Intimacy/Tension.
    pub fn set(&mut self, variable: Variable, value: f64) {
        *self.slot_mut(variable) = value;
    }

    /// Apply a delta. Only Intimacy and Tension are clamped to `0..100`,
    /// mirroring the two TS delta sites (`evaluateParameters` and the DSL
    /// intimacy bridge); every other metric stays raw.
    pub fn apply_delta(&mut self, variable: Variable, delta: f64) {
        match variable {
            Variable::Intimacy | Variable::Tension => {
                let slot = self.slot_mut(variable);
                *slot = (*slot + delta).clamp(0.0, 100.0);
            }
            other => *self.slot_mut(other) += delta,
        }
    }

    /// Classify the current metrics into a mood, using the TS strict
    /// comparisons (`> 80`, `> 60`, `< 30`) with no inclusive boundaries.
    pub fn mood(&self) -> MoodState {
        if self.intimacy > 80.0 && self.tension > 80.0 {
            MoodState::Max
        } else if self.tension > 60.0 {
            MoodState::High
        } else if self.tension < 30.0 {
            MoodState::Low
        } else {
            MoodState::Normal
        }
    }

    /// Advance the choice countdown by `dt` seconds.
    ///
    /// Callers must supply a finite, non-negative `dt`. Floors at zero and
    /// reports [`TimerOutcome::Fired`] when it lands on zero. A countdown that
    /// is not running never fires (TS gates on `Timer > 0`).
    pub fn tick_timer(&mut self, dt: f64) -> TimerOutcome {
        if self.timer <= 0.0 {
            return TimerOutcome::Pending;
        }
        self.timer = (self.timer - dt).max(0.0);
        if self.timer == 0.0 {
            TimerOutcome::Fired
        } else {
            TimerOutcome::Pending
        }
    }
}

/// Pure dating-sim state: an enabled flag plus the eight metrics.
#[derive(Debug, Clone, PartialEq)]
pub struct DatingSim {
    /// Whether the dating sim is active (TS `enabled`).
    pub enabled: bool,
    /// The eight Amagami metrics.
    pub variables: Variables,
}

impl Default for DatingSim {
    fn default() -> Self {
        Self {
            enabled: false,
            variables: Variables::default(),
        }
    }
}

impl DatingSim {
    /// Activate the dating sim (no IPC preset or rAF loop is started here).
    pub fn enable(&mut self) {
        self.enabled = true;
    }

    /// Deactivate and restore all eight metric defaults (TS `disable`).
    pub fn disable(&mut self) {
        self.enabled = false;
        self.reset();
    }

    /// Mirror TS `toggleDatingSim`: disabling resets, enabling does not.
    pub fn toggle(&mut self) {
        if self.enabled {
            self.disable();
        } else {
            self.enable();
        }
    }

    /// Restore the exact eight metric defaults, leaving `enabled` untouched.
    pub fn reset(&mut self) {
        self.variables = Variables::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mood_thresholds_match_ts_boundaries() {
        let cases = [
            (81.0, 81.0, MoodState::Max),    // i > 80 && t > 80
            (90.0, 70.0, MoodState::High),   // t > 60
            (90.0, 20.0, MoodState::Low),    // t < 30
            (50.0, 60.0, MoodState::Normal), // strict t > 60, strict t < 30
            (80.0, 81.0, MoodState::High),   // i == 80 does not qualify for max
            (50.0, 30.0, MoodState::Normal), // t == 30 is not < 30
            (81.0, 80.0, MoodState::High),   // t == 80 is not > 80
        ];
        for (intimacy, tension, expected) in cases {
            let variables = Variables {
                intimacy,
                tension,
                ..Variables::default()
            };
            assert_eq!(variables.mood(), expected, "i={intimacy} t={tension}");
        }
    }

    #[test]
    fn defaults_match_ts_variables_exactly() {
        let v = Variables::default();
        assert_eq!(
            (
                v.intimacy,
                v.tension,
                v.action_points,
                v.time_of_day,
                v.timer,
                v.positive_score,
                v.negative_score,
                v.turns_elapsed,
            ),
            (0.0, 50.0, 5.0, 12.0, 0.0, 0.0, 0.0, 0.0)
        );
    }

    #[test]
    fn get_set_round_trip_distinguishes_all_eight_slots() {
        let values = [
            (Variable::Intimacy, 1.0),
            (Variable::Tension, 2.0),
            (Variable::ActionPoints, 3.0),
            (Variable::TimeOfDay, 4.0),
            (Variable::Timer, 5.0),
            (Variable::PositiveScore, 6.0),
            (Variable::NegativeScore, 7.0),
            (Variable::TurnsElapsed, 8.0),
        ];
        let mut v = Variables::default();
        for (key, value) in values {
            v.set(key, value);
        }
        // Distinct values make a swapped slot mapping observable through the
        // public fields, not just through get()'s own mapping.
        assert_eq!(
            (
                v.intimacy,
                v.tension,
                v.action_points,
                v.time_of_day,
                v.timer,
                v.positive_score,
                v.negative_score,
                v.turns_elapsed,
            ),
            (1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)
        );
        for (key, value) in values {
            assert_eq!(v.get(key), value, "getter mismatch for {key:?}");
        }
    }

    #[test]
    fn deltas_clamp_only_intimacy_and_tension() {
        let mut v = Variables::default();

        v.apply_delta(Variable::Intimacy, -10.0);
        assert_eq!(v.intimacy, 0.0, "intimacy lower clamp");
        v.apply_delta(Variable::Intimacy, 150.0);
        assert_eq!(v.intimacy, 100.0, "intimacy upper clamp");

        v.apply_delta(Variable::Tension, 100.0);
        assert_eq!(v.tension, 100.0, "tension upper clamp");
        v.apply_delta(Variable::Tension, -200.0);
        assert_eq!(v.tension, 0.0, "tension lower clamp");

        // Non Intimacy/Tension deltas are unclamped.
        v.apply_delta(Variable::ActionPoints, 1000.0);
        assert_eq!(v.action_points, 1005.0);
        v.apply_delta(Variable::ActionPoints, -2000.0);
        assert_eq!(v.action_points, -995.0);

        // The generic setter stays raw, even for Intimacy/Tension.
        v.set(Variable::Intimacy, -7.0);
        assert_eq!(v.intimacy, -7.0);
        v.set(Variable::Tension, 500.0);
        assert_eq!(v.tension, 500.0);
        assert_eq!(v.get(Variable::Intimacy), -7.0);
    }

    #[test]
    fn tick_timer_floors_at_zero_and_fires_at_zero() {
        let mut v = Variables::default();
        v.set(Variable::Timer, 10.0);

        assert_eq!(v.tick_timer(3.0), TimerOutcome::Pending);
        assert_eq!(v.timer, 7.0);
        assert_eq!(v.tick_timer(5.0), TimerOutcome::Pending);
        assert_eq!(v.timer, 2.0);
        assert_eq!(v.tick_timer(10.0), TimerOutcome::Fired);
        assert_eq!(v.timer, 0.0, "timer floors at zero");

        // No countdown running: nothing fires.
        assert_eq!(v.tick_timer(1.0), TimerOutcome::Pending);

        // Overshoot also floors and fires exactly once.
        v.set(Variable::Timer, 2.0);
        assert_eq!(v.tick_timer(5.0), TimerOutcome::Fired);
        assert_eq!(v.timer, 0.0);
    }

    #[test]
    fn lifecycle_toggle_disable_and_reset_restore_defaults() {
        let mut sim = DatingSim::default();
        assert!(!sim.enabled);

        sim.enable();
        assert!(sim.enabled);
        sim.variables.set(Variable::Intimacy, 81.0);
        sim.variables.set(Variable::Timer, 9.0);
        sim.variables.set(Variable::ActionPoints, 0.0);

        sim.disable();
        assert!(!sim.enabled);
        assert_eq!(
            sim.variables,
            Variables::default(),
            "disable restores all defaults"
        );

        sim.toggle();
        assert!(sim.enabled);
        sim.toggle();
        assert!(!sim.enabled);
        assert_eq!(sim.variables, Variables::default());

        sim.enable();
        sim.variables.set(Variable::Tension, 99.0);
        sim.reset();
        assert_eq!(sim.variables, Variables::default());
        assert!(sim.enabled, "reset leaves the enabled flag untouched");
    }
}
