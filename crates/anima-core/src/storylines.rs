// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Pure dating-sim storyline presets, frozen from the Vue reference at
//! `packages/stage-ui/src/constants/dating-sim/storylines.ts:1-135`.
//!
//! This module owns the catalog plus a pure dating-sim mini-script interpreter;
//! it owns no store, daemon verb, wire type, persistence, LLM hook or UI state.
//! Each preset carries
//! the nine narrative fields declared by the TypeScript `StorylinePreset`
//! interface, and the array retains the Vue declaration order. The unit tests
//! check internal structure and a few spot values only; they do not verify
//! byte-for-byte parity with the TypeScript source.
//! A later Flutter/daemon consumer may bind these values; freezing them in
//! Rust alone does not make any renderer agree with Vue.

/// One pinned dating-sim storyline preset (the nine `StorylinePreset` fields).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorylinePreset {
    /// Stable catalog id (`StorylinePreset.id`).
    pub id: &'static str,
    /// Display title (`StorylinePreset.title`).
    pub title: &'static str,
    /// Setup premise (`StorylinePreset.premise`).
    pub premise: &'static str,
    /// Scene description (`StorylinePreset.scene`).
    pub scene: &'static str,
    /// Terms of encounter (`StorylinePreset.termsOfEncounter`).
    pub terms_of_encounter: &'static str,
    /// Suggested appearances (`StorylinePreset.appearances`).
    pub appearances: &'static str,
    /// Positive outcome beat (`StorylinePreset.positiveOutcome`).
    pub positive_outcome: &'static str,
    /// Negative outcome beat (`StorylinePreset.negativeOutcome`).
    pub negative_outcome: &'static str,
    /// Cover image asset path (`StorylinePreset.coverImage`).
    pub cover_image: &'static str,
}

/// The storyline catalog in its exact Vue declaration order (11 presets).
pub static STORYLINE_PRESETS: [StorylinePreset; 11] = [
    StorylinePreset {
        id: "roommate_crush",
        title: "Roommate Crush",
        premise: "Living together has always been comfortable, but lately, the user has been sensing something more—a secret tension that suggests a mutual crush, or at least a deep desire on their part to escape the friend zone.",
        scene: "The setting is a cozy shared apartment, where casual moments in the kitchen or late-night conversations on the couch create an electric but unspoken chemistry.",
        terms_of_encounter: "Through careful teasing, subtle flirting, and perfectly timed moments of vulnerability, the user must push the dynamic beyond friendship without making things awkward or ruining the balance of their cohabitation.",
        appearances: "loose crop top, tiny pajama short shorts, lingerie, fluffy socks, bare legs, oversized cardigan slipping off shoulder, tousled hair",
        positive_outcome: "The tension finally breaks in the right way—whether it's an intense gaze held for too long, an innocent touch that lingers, or an unexpected confession. With a knowing smirk, the character invites the user into their room, the door closing behind them for a night that changes everything.",
        negative_outcome: "The user's attempt completely backfires—whether by being too obvious, too desperate, or mistiming the moment. In an unfortunate twist, the character discovers an embarrassing secret the user never wanted revealed. Horrified and flustered, the character laughs awkwardly, firmly cementing the user in the forever friend category.",
        cover_image: "dating-sim-concepts/pastel_roommate_crush_bigrbear_00001_.png",
    },
    StorylinePreset {
        id: "unpaid_rent",
        title: "The Unpaid Rent",
        premise: "The user, as the landlord, has been patient for too long, but the character still hasn't paid their overdue rent. It's time to collect—one way or another.",
        scene: "The setting is the character's messy apartment, dishes piled in the sink, unopened bills scattered on the counter. The air is tense as the user finally decides to confront them about their debt.",
        terms_of_encounter: "With negotiation skills, persistence, and maybe a little charm, the user must convince the character to take responsibility—whether through persuasion, pressure, or offering alternative 'arrangements' to settle the debt.",
        appearances: "cropped tank top, bra with cleavage, sweatpants, visible midriff, old band t-shirt thrown over, messy bun, faint coffee stain on top",
        positive_outcome: "After much back-and-forth, the character finally caves, agreeing to a rather unique repayment plan—they become the user's devoted girlfriend, handling chores and making sure the apartment is always spotless.",
        negative_outcome: "The conversation goes horribly wrong. Instead of paying up, they report the user to the authorities, making up a wild story about 'landlord harassment.' The user is escorted out in handcuffs, while the character continues living rent-free.",
        cover_image: "dating-sim-concepts/pastel_final_the_unpaid_rent_bigrbear_run2_00001_.png",
    },
    StorylinePreset {
        id: "fitness_coach",
        title: "The Fitness Coach",
        premise: "The user gets the rare opportunity to privately teach fitness moves to the character, guiding them through an intense workout session where the boundaries between training and teasing blur.",
        scene: "The setting is a sleek private gym. A large mirror reflects every movement, making the tension even more palpable.",
        terms_of_encounter: "With charm, wit, and just the right amount of confidence, the user must turn a routine fitness lesson into something more—playful teasing, suggestive corrections, and moments of charged physical closeness.",
        appearances: "pink leggings, fitted sports bra, feminine-colored top bra, cleavage, high-waisted gym shorts, shiny tight shorts, sneakers, ponytail, sweat glistening on skin",
        positive_outcome: "The heat of the workout evolves into a different kind of intensity. A postural correction becomes something much closer, shifting the lesson from fitness to something far more intimate.",
        negative_outcome: "A disastrous misstep ruins everything. The user fumbles a demonstration or splits their shorts wide open, leaving them exposed and humiliated while the character laughs and snaps a photo before walking out.",
        cover_image: "dating-sim-concepts/pastel_final_the_fitness_coach_bigrbear_run2_00001_.png",
    },
    StorylinePreset {
        id: "boss_favor",
        title: "The Boss's Favor",
        premise: "The user, as the boss, has been professional, but the character—one of their employees—has a problem that needs fixing. Desperate for a way out, they knock on the executive office door.",
        scene: "The setting is the user's executive office, sleek and professional. Papers are neatly stacked, a computer screen glows softly, and the air is thick with authority.",
        terms_of_encounter: "With confidence, negotiation skills, and a commanding presence, the user must decide how to handle the predicament—granting leniency, pushing for accountability, or offering a personal arrangement.",
        appearances: "tight pencil skirt, white blouse, unbuttoned top, black stockings, high heels, fitted blazer, wavy hair",
        positive_outcome: "The character caves, agreeing to a unique deal—pledging to be the user's personal assistant in every way that matters, both in and out of the office.",
        negative_outcome: "The user pushes too hard, or the character flips the situation—storming out and reporting the user to HR. The user finds themselves under investigation, their authority crumbling.",
        cover_image: "dating-sim-concepts/pastel_final_the_boss_s_favor_bigrbear_run2_00001_.png",
    },
    StorylinePreset {
        id: "pros_workshop",
        title: "The Pro's Workshop",
        premise: "As a skilled mechanic, you handle all kinds of clients. But when the character arrives with a vehicle that desperately needs fixing, she realizes she can't afford the repair bill.",
        scene: "The setting is the user's workshop, metal tools scattered across a well-worn workbench, and the hum of machinery in the background.",
        terms_of_encounter: "With confidence and negotiation, the user must decide whether to insist on full payment, offer a compromise, or push the character toward a more personal arrangement in exchange for a discount.",
        appearances: "denim shorts, tight crop top, midriff exposed, sports bra visible, tousled hair, sneakers",
        positive_outcome: "After tense back-and-forth, the character caves and agrees to an unconventional deal—repaying her debt by staying at the user's beck and call.",
        negative_outcome: "The conversation takes a bad turn. Instead of negotiating, she snaps—storming out and filing a complaint, putting your workshop's reputation at risk.",
        cover_image: "dating-sim-concepts/pastel_fixes_the_pro_s_workshop_bigrbear_run3_00001_.png",
    },
    StorylinePreset {
        id: "study_session",
        title: "The Study Session",
        premise: "The user gets the rare opportunity to privately tutor the character, guiding them through a difficult subject where the line between studying and teasing begins to blur.",
        scene: "The setting is a quiet study room or a dimly lit dorm, a cluttered desk covered in notebooks and textbooks. The character sits close, twirling a pen between their fingers.",
        terms_of_encounter: "The user must balance keeping the character focused on the material with reciprocating their subtle, distracting advances without ruining the lesson.",
        appearances: "pleated mini skirt, thigh-high stockings, tight button-up shirt, unbuttoned top, short-sleeved cardigan, glasses, playful smirk, knee-high boots",
        positive_outcome: "The session shifts from academics to intimate exploration, proving that private tutoring has unexpected extracurricular benefits.",
        negative_outcome: "The user fails to capture the character's interest or makes an awkward comment, leading to them packing up their books and leaving early, maintaining the distance.",
        cover_image: "dating-sim-concepts/pastel_grind_the_study_session_bigrbear_run7_00001_.png",
    },
    StorylinePreset {
        id: "fake_taxi",
        title: "The Fake Taxi",
        premise: "The user is behind the wheel of a taxi, driving the character through countryside roads. The character reveals she's struggling financially, opening the door for persuasion.",
        scene: "The setting is a winding road through vast open fields, the hum of the engine blending with the golden sunset over the empty road ahead.",
        terms_of_encounter: "Through smooth talk, you try to convince her that you have a solution. Whether she buys into the story or sees through it determines the outcome.",
        appearances: "short summer dress, thin straps, deep neckline, bare shoulders, smooth legs, strappy sandals, anklet, messy bun",
        positive_outcome: "Desperate for a break, she entertains the idea. The taxi pulls off into a secluded spot, and the ride becomes much more than just a trip.",
        negative_outcome: "The character is unconvinced. She scoffs, crosses her arms, and rolls her eyes, telling the user to keep it professional and just drive.",
        cover_image: "dating-sim-concepts/pastel_fixes_the_fake_taxi_bigrbear_run2_00001_.png",
    },
    StorylinePreset {
        id: "bad_taxi",
        title: "The Bad Taxi",
        premise: "You are a suave taxi driver shuttling a passenger between the city and the countryside. Along the long rides, every conversation has the potential to build an ongoing arrangement.",
        scene: "Neon city lights give way to winding country roads under a starry sky. The taxi's interior has soft ambient lighting, creating a close, intimate setting.",
        terms_of_encounter: "With charm and strategic persuasion, you propose a unique arrangement: regular, discreet rides that promise more than safe passage.",
        appearances: "tailored blazer, lace top, high-waisted trousers, slim belt, minimalist necklace, structured jacket",
        positive_outcome: "Enthralled by the idea of a dependable yet passionate rendezvous, she agrees to turn their encounters into a regular, exciting ritual.",
        negative_outcome: "Reluctant yet compliant, she agrees to a fleeting tryst that, while charged, leaves both parties aware it won't extend into a regular arrangement.",
        cover_image: "dating-sim-concepts/pastel_the_bad_taxi_bigrbear_00001_.png",
    },
    StorylinePreset {
        id: "obsessed_fan",
        title: "The Obsessed Fan",
        premise: "The user, a respected public figure, has caught the attention of a dangerously devoted fan who refuses to accept rejection, determined to make him hers.",
        scene: "A private café corner or dimly lit lounge. She sits close, eyes locked onto you, her obsession palpable.",
        terms_of_encounter: "Keep control, rejecting without provoking, playing hard to get to shift the power dynamic and ensure she craves you without trapping you.",
        appearances: "pastel color-blocked hoodie, denim shorts, multi-colored cyan/orange eyes",
        positive_outcome: "You transform her obsession into a controlled, secret affair. She learns to respect your terms, relishing hidden moments without risk.",
        negative_outcome: "A misstep turns her devotion to fury. Exposing your secrets and blackmailing you, your life unravels under her constant watch.",
        cover_image: "dating-sim-concepts/pastel_the_obsessed_fan_bigrbear_00001_.png",
    },
    StorylinePreset {
        id: "therapist",
        title: "The Therapist",
        premise: "As a therapist, you take on a patient suffering from hyper-relational urges who fixates entirely on you, her doctor, as her ultimate desire.",
        scene: "A quiet therapy office, warm and professional, yet thick with tension. She leans forward, her words laced with innuendo.",
        terms_of_encounter: "Walk a razor-thin line—rejecting her could trigger a breakdown, while giving in betrays your ethical code. Guide her impulses carefully.",
        appearances: "fitted sweater, pencil skirt, stockings, glasses, neat hair",
        positive_outcome: "You channel her impulses into a balanced relationship based on trust. Her obsession transforms into genuine, stable love.",
        negative_outcome: "A hard rejection sends her spiraling. The resulting breakdown and fallout revokes your medical license and ruins your reputation.",
        cover_image: "dating-sim-concepts/pastel_final_therapist_bigrbear_run7_00001_.png",
    },
    StorylinePreset {
        id: "desert_island",
        title: "The Desert Island",
        premise: "Stranded on a remote island, you secure food and shelter, while the character resorts to flirtation to access your camp resources.",
        scene: "A sunbaked shore littered with wreckage. The user's camp is well-organized, while the character lands nearby, watching.",
        terms_of_encounter: "See through the act, challenging her to contribute to the camp survival rather than just flirting for free access.",
        appearances: "Sun-kissed skin, tousled hair, and a deliberately adjusted torn outfit.",
        positive_outcome: "She slowly falls for your strength and capability, her survival strategy turning into genuine, balanced love.",
        negative_outcome: "You push too hard and she turns vengeful, sabotaging supplies. When rescue arrives, she frames you as a dangerous survivalist.",
        cover_image: "dating-sim-concepts/pastel_fixes_the_desert_island_bigrbear_run1_00001_.png",
    },
];

/// Look up a storyline preset by its catalog id.
///
/// Unknown ids return `None`; callers apply their own fallback, just as the
/// Vue source indexes the array directly when no id is supplied.
pub fn storyline_preset(id: &str) -> Option<&'static StorylinePreset> {
    STORYLINE_PRESETS.iter().find(|preset| preset.id == id)
}

/// Named numeric variables backing the dating-sim mini-script (TS
/// `variables.value` record). A missing name reads as `0.0`, matching the TS
/// `getVariable` fallback of `variables.value[name] || 0`.
pub type ScriptVariables = std::collections::HashMap<String, f64>;

/// A pure output effect of [`execute_script`], named after the Live2D DSL cue
/// verbs in `packages/live2d-runtime/src/dsl/command-parser.ts:54-80`. Unlike
/// the Vue source, no event is dispatched: the caller owns every side effect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScriptCue {
    /// `start_mtn`: trigger a motion by its raw DSL target.
    StartMotion(String),
    /// `clear_exp`: clear all expressions.
    ClearExpression,
    /// `motions`: enable (`true`) or disable (`false`) idle motions.
    Motions(bool),
    /// `change_cos`: hot-swap the model with the given target descriptor.
    ChangeCos(String),
}

impl ScriptCue {
    /// The DSL cue verb this effect corresponds to.
    pub fn cue_name(&self) -> &'static str {
        match self {
            Self::StartMotion(_) => "start_mtn",
            Self::ClearExpression => "clear_exp",
            Self::Motions(_) => "motions",
            Self::ChangeCos(_) => "change_cos",
        }
    }
}

/// `Number.parseFloat`-like conversion: the longest leading numeric prefix,
/// or NaN when there is none. Trailing junk is ignored, as in TypeScript.
fn parse_float(raw: &str) -> f64 {
    let trimmed = raw.trim_start();
    // JS parseFloat only accepts the exact `Infinity` spelling; Rust's parser
    // also accepts case-insensitive `inf`/`infinity`/`nan`, which must stay NaN.
    let body = trimmed
        .strip_prefix('-')
        .or_else(|| trimmed.strip_prefix('+'))
        .unwrap_or(trimmed);
    let word_len = body.bytes().take_while(u8::is_ascii_alphabetic).count();
    if word_len > 0 {
        return if body[..word_len].starts_with("Infinity") {
            if trimmed.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            }
        } else {
            f64::NAN
        };
    }
    for end in (1..=trimmed.len()).rev() {
        if !trimmed.is_char_boundary(end) {
            continue;
        }
        if let Ok(value) = trimmed[..end].parse::<f64>() {
            return value;
        }
    }
    f64::NAN
}

/// TS `getVariable`: `variables.value[name] || 0`. NaN and `-0` are falsy and
/// collapse to `0`; Infinity is truthy and survives unchanged.
fn get_variable(variables: &ScriptVariables, name: &str) -> f64 {
    let value = variables.get(name).copied().unwrap_or(0.0);
    if value == 0.0 || value.is_nan() {
        0.0
    } else {
        value
    }
}

/// Find the first `/rand\((\d+),(\d+)\)/` match: digits only and unanchored at
/// the end, so signs are rejected and trailing junk after `)` is ignored.
/// Bounds are f64 (JS numbers are f64), so no script input can overflow.
fn parse_rand_bounds(expr: &str) -> Option<(f64, f64)> {
    let mut search = expr;
    while let Some(idx) = search.find("rand(") {
        let rest = &search[idx + "rand(".len()..];
        if let Some(bounds) = parse_bounds_pair(rest) {
            return Some(bounds);
        }
        search = rest;
    }
    None
}

fn parse_bounds_pair(rest: &str) -> Option<(f64, f64)> {
    let min_len = rest.bytes().take_while(u8::is_ascii_digit).count();
    if min_len == 0 {
        return None;
    }
    let after_min = &rest[min_len..];
    let after_comma = after_min.strip_prefix(',')?;
    let max_len = after_comma.bytes().take_while(u8::is_ascii_digit).count();
    if max_len == 0 {
        return None;
    }
    if !after_comma[max_len..].starts_with(')') {
        return None;
    }
    Some((
        rest[..min_len].parse::<f64>().ok()?,
        after_comma[..max_len].parse::<f64>().ok()?,
    ))
}

/// Pure port of TS `evaluateCondition`. `None` or an empty condition passes;
/// a statement that is not `<var> <op> <number>` with a known operator fails.
pub fn evaluate_condition(variables: &ScriptVariables, condition: Option<&str>) -> bool {
    let Some(condition) = condition else {
        return true;
    };
    if condition.is_empty() {
        return true;
    }
    let parts: Vec<&str> = condition.split(' ').collect();
    if parts.len() < 3 {
        return false;
    }
    let current = get_variable(variables, parts[0]);
    let target = parse_float(parts[2]);
    match parts[1] {
        "equal" => current == target,
        "greater" => current > target,
        "less" => current < target,
        "greater_eq" => current >= target,
        "less_eq" => current <= target,
        _ => false,
    }
}

/// Pure port of TS `executeAssignment`. `rng` replaces `Math.random()` and must
/// return a value in `[0, 1)`; all mutation stays inside `variables`.
pub fn execute_assignment<F>(variables: &mut ScriptVariables, code: &str, rng: F)
where
    F: Fn() -> f64,
{
    let parts: Vec<&str> = code.split(' ').collect();
    if parts.len() < 3 {
        return;
    }
    let name = parts[0];
    let op = parts[1];
    let expr = parts[2..].join(" ");
    let current = get_variable(variables, name);

    match op {
        "assign" => {
            if expr.starts_with("rand(") {
                if let Some((min, max)) = parse_rand_bounds(&expr) {
                    // JS does this in f64: no integer overflow for huge bounds.
                    let value = (rng() * ((max - min) + 1.0)).floor() + min;
                    variables.insert(name.to_string(), value);
                }
                // A malformed rand(...) is ignored, like the TS regex miss.
            } else {
                variables.insert(name.to_string(), parse_float(&expr));
            }
        }
        "add" => {
            variables.insert(name.to_string(), current + parse_float(&expr));
        }
        "subtract" => {
            variables.insert(name.to_string(), current - parse_float(&expr));
        }
        _ => {}
    }
}

/// Pure port of TS `executeScript`: split on `;`, trim, and emit one
/// [`ScriptCue`] per recognised command; unknown and blank statements vanish.
pub fn execute_script(script: &str) -> Vec<ScriptCue> {
    let mut cues = Vec::new();
    for raw in script.split(';') {
        let cmd = raw.trim();
        if cmd.is_empty() {
            continue;
        }
        if let Some(target) = cmd.strip_prefix("start_mtn") {
            cues.push(ScriptCue::StartMotion(target.trim().to_string()));
        } else if cmd.starts_with("clear_exp") {
            cues.push(ScriptCue::ClearExpression);
        } else if let Some(rest) = cmd.strip_prefix("motions ") {
            if rest.starts_with("enable") {
                cues.push(ScriptCue::Motions(true));
            } else if rest.starts_with("disable") {
                cues.push(ScriptCue::Motions(false));
            }
        } else if let Some(target) = cmd.strip_prefix("change_cos") {
            cues.push(ScriptCue::ChangeCos(target.trim().to_string()));
        }
    }
    cues
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_count_and_spot_values() {
        assert_eq!(STORYLINE_PRESETS.len(), 11);
        assert_eq!(
            STORYLINE_PRESETS.first().expect("non-empty").id,
            "roommate_crush"
        );
        assert_eq!(
            STORYLINE_PRESETS.last().expect("non-empty").id,
            "desert_island"
        );

        // A few values pinned from the TS source, not a mirrored full catalog.
        let therapist = storyline_preset("therapist").expect("therapist preset");
        assert_eq!(therapist.title, "The Therapist");
        assert_eq!(
            therapist.premise,
            "As a therapist, you take on a patient suffering from hyper-relational urges who fixates entirely on you, her doctor, as her ultimate desire."
        );
        assert_eq!(
            therapist.cover_image,
            "dating-sim-concepts/pastel_final_therapist_bigrbear_run7_00001_.png"
        );
    }

    #[test]
    fn lookup_hits_every_id_and_rejects_unknown() {
        for preset in &STORYLINE_PRESETS {
            assert_eq!(
                storyline_preset(preset.id),
                Some(preset),
                "catalog lookup failed for {}",
                preset.id
            );
        }
        assert!(storyline_preset("unknown").is_none());
    }

    #[test]
    fn ids_and_cover_images_are_well_formed() {
        let mut seen = std::collections::HashSet::new();
        for preset in &STORYLINE_PRESETS {
            assert!(seen.insert(preset.id), "duplicate id: {}", preset.id);
            for field in [
                preset.id,
                preset.title,
                preset.premise,
                preset.scene,
                preset.terms_of_encounter,
                preset.appearances,
                preset.positive_outcome,
                preset.negative_outcome,
                preset.cover_image,
            ] {
                assert!(!field.is_empty(), "empty field on {}", preset.id);
            }
            assert!(
                preset.cover_image.starts_with("dating-sim-concepts/"),
                "unexpected cover image path on {}",
                preset.id
            );
            assert!(
                preset.cover_image.ends_with(".png"),
                "unexpected cover image extension on {}",
                preset.id
            );
        }
    }

    #[test]
    fn evaluate_condition_matches_ts_operators() {
        let mut vars = ScriptVariables::new();
        vars.insert("intimacy".to_string(), 50.0);
        let cases = [
            ("intimacy equal 50", true),
            ("intimacy greater 49", true),
            ("intimacy less 50", false),
            ("intimacy greater_eq 50", true),
            ("intimacy less_eq 49", false),
        ];
        for (condition, expected) in cases {
            assert_eq!(
                evaluate_condition(&vars, Some(condition)),
                expected,
                "{condition}"
            );
        }
    }

    #[test]
    fn evaluate_condition_fallbacks_match_ts() {
        let vars = ScriptVariables::new();
        let cases: &[(Option<&str>, bool)] = &[
            (None, true),
            (Some(""), true),
            (Some("intimacy greater"), false), // too few parts
            (Some("intimacy unknown 5"), false),
            (Some("missing equal 0"), true), // missing var reads as 0
            (Some("missing greater 0"), false),
            (Some("intimacy equal not_a_number"), false), // NaN compares false
        ];
        for (condition, expected) in cases {
            assert_eq!(
                evaluate_condition(&vars, *condition),
                *expected,
                "{condition:?}"
            );
        }
    }

    fn rng_zero() -> f64 {
        0.0
    }
    fn rng_half() -> f64 {
        0.5
    }
    fn rng_high() -> f64 {
        0.999999
    }

    #[test]
    fn execute_assignment_table() {
        let cases: &[(&str, fn() -> f64, f64)] = &[
            ("x assign 42", rng_zero, 42.0),
            ("x assign 42abc", rng_zero, 42.0),
            ("x assign -3.5", rng_zero, -3.5),
            ("x add 5", rng_zero, 5.0),
            ("x subtract 5", rng_zero, -5.0),
            ("x assign rand(1,3)", rng_zero, 1.0),
            ("x assign rand(1,3)", rng_half, 2.0),
            ("x assign rand(1,3)", rng_high, 3.0),
        ];
        for (code, rng, expected) in cases {
            let mut vars = ScriptVariables::new();
            execute_assignment(&mut vars, code, rng);
            assert_eq!(vars.get("x"), Some(expected), "{code}");
        }
    }

    #[test]
    fn execute_assignment_accumulates_and_ignores_bad_input() {
        let mut vars = ScriptVariables::new();
        vars.insert("x".to_string(), 10.0);
        execute_assignment(&mut vars, "x add 5", rng_zero);
        assert_eq!(vars["x"], 15.0);
        execute_assignment(&mut vars, "x subtract 3", rng_zero);
        assert_eq!(vars["x"], 12.0);

        execute_assignment(&mut vars, "x add", rng_zero); // too few parts
        execute_assignment(&mut vars, "x multiply 2", rng_zero); // unknown op
        execute_assignment(&mut vars, "x assign rand(foo)", rng_zero); // bad rand
        assert_eq!(vars["x"], 12.0);
    }

    #[test]
    fn nan_reads_collapse_to_zero_like_ts_or_fallback() {
        let mut vars = ScriptVariables::new();
        vars.insert("x".to_string(), f64::NAN);

        execute_assignment(&mut vars, "x add 5", rng_zero);
        assert_eq!(vars["x"], 5.0, "NaN || 0 then add");

        vars.insert("x".to_string(), f64::NAN);
        assert!(
            evaluate_condition(&vars, Some("x equal 0")),
            "NaN || 0 == 0"
        );
        assert!(
            evaluate_condition(&vars, Some("x greater -1")),
            "NaN || 0 > -1"
        );

        vars.insert("x".to_string(), f64::INFINITY);
        assert!(
            evaluate_condition(&vars, Some("x greater 0")),
            "Infinity survives || 0"
        );
    }

    #[test]
    fn parse_float_infinity_spellings_match_js() {
        assert_eq!(parse_float("Infinity"), f64::INFINITY);
        assert_eq!(parse_float("-Infinity"), f64::NEG_INFINITY);
        assert_eq!(parse_float("Infinityabc"), f64::INFINITY);
        assert!(parse_float("inf").is_nan());
        assert!(parse_float("infinity").is_nan());
        assert!(parse_float("-inf").is_nan());
        assert!(parse_float("nan").is_nan());
    }

    #[test]
    fn rand_bounds_match_unanchored_digit_regex_and_do_not_overflow() {
        let mut vars = ScriptVariables::new();
        vars.insert("x".to_string(), 99.0);

        execute_assignment(&mut vars, "x assign rand(1,3)abc", rng_zero);
        assert_eq!(vars["x"], 1.0, "trailing junk after ')' is ignored");

        execute_assignment(&mut vars, "x assign rand(-1,3)", rng_zero);
        assert_eq!(vars["x"], 1.0, "signed bounds do not match the regex");
        execute_assignment(&mut vars, "x assign rand(+1,3)", rng_zero);
        assert_eq!(vars["x"], 1.0, "signed bounds do not match the regex");

        execute_assignment(&mut vars, "x assign rand(0,9223372036854775807)", rng_zero);
        assert_eq!(vars["x"], 0.0, "i64::MAX bound must not panic or drop");
        execute_assignment(&mut vars, "x assign rand(0,9223372036854775807)", rng_high);
        assert!(vars["x"] >= 0.0 && vars["x"] <= 9_223_372_036_854_775_807.0);

        vars.insert("x".to_string(), 99.0);
        execute_assignment(
            &mut vars,
            "x assign rand(0,99999999999999999999999999999999999999999999999999999)",
            rng_half,
        );
        assert!(vars["x"] > 1e50, "bounds past u128::MAX must not drop");

        vars.insert("x".to_string(), 99.0);
        let saturated = format!("x assign rand(0,{})", "9".repeat(400));
        execute_assignment(&mut vars, &saturated, rng_half);
        assert!(
            vars["x"].is_infinite(),
            "f64 saturation must not drop assignment"
        );
    }

    #[test]
    fn execute_script_emits_dsl_cues() {
        let script = " start_mtn B40 ; clear_exp ; motions enable ; motions disable ; change_cos model1.json ; unknown_verb 42 ; ; start_mtn Sound#1:011 ";
        let cues = execute_script(script);
        assert_eq!(cues.len(), 6);
        assert_eq!(cues[0], ScriptCue::StartMotion("B40".to_string()));
        assert_eq!(cues[1], ScriptCue::ClearExpression);
        assert_eq!(cues[2], ScriptCue::Motions(true));
        assert_eq!(cues[3], ScriptCue::Motions(false));
        assert_eq!(cues[4], ScriptCue::ChangeCos("model1.json".to_string()));
        assert_eq!(cues[5], ScriptCue::StartMotion("Sound#1:011".to_string()));
        assert!(execute_script("").is_empty());
        assert!(execute_script(" ; ; ").is_empty());
    }

    #[test]
    fn cue_names_match_dsl_verbs() {
        assert_eq!(
            ScriptCue::StartMotion("x".to_string()).cue_name(),
            "start_mtn"
        );
        assert_eq!(ScriptCue::ClearExpression.cue_name(), "clear_exp");
        assert_eq!(ScriptCue::Motions(true).cue_name(), "motions");
        assert_eq!(
            ScriptCue::ChangeCos("m.json".to_string()).cue_name(),
            "change_cos"
        );
    }
}
