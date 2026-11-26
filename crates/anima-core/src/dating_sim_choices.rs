// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure parsing/evaluation of LLM-generated dating-sim payloads, ported from
//! the Vue reference `packages/stage-ui/src/stores/dating-sim.ts:297-310,423-439,476-490`.
//!
//! Like [`crate::dating_sim`], this module owns no store, verb, wire type,
//! event, clock, inference call, or consumer. Every entry point takes raw text
//! plus current values and returns a value or an error.

use serde_json::Value;

/// Why a generated payload could not be interpreted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    /// The response had no `{ ... }` span (TS: `No JSON object found in response`).
    #[error("No JSON object found in response")]
    NoJsonObject,
    /// The extracted span was not valid JSON.
    #[error("Invalid JSON object: {0}")]
    InvalidJson(String),
    /// The object did not contain a `topics` array.
    #[error("Missing `topics` array in response")]
    MissingTopics,
}

/// Return the first `{` through the last `}` of `raw`, matching the TS regex
/// `/\{[\s\S]*\}/` (greedy, so nested objects stay whole). Preamble and
/// postamble outside that span are ignored.
pub fn extract_json_object(raw: &str) -> Result<&str, ParseError> {
    let first = raw.find('{').ok_or(ParseError::NoJsonObject)?;
    let last = raw.rfind('}').ok_or(ParseError::NoJsonObject)?;
    if last < first {
        return Err(ParseError::NoJsonObject);
    }
    Ok(&raw[first..=last])
}

/// One generated choice option (the TS `Choice` fields the LLM path fills).
#[derive(Debug, Clone, PartialEq)]
pub struct LiveChoice {
    /// Stable id derived from the option's index (`t0`..`t3`).
    pub id: String,
    /// Option text; empty when an object topic has no string `text`.
    pub text: String,
    /// `positiveScoreChange`; zero for a plain-string topic.
    pub positive_score_change: f64,
    /// `negativeScoreChange`; zero for a plain-string topic.
    pub negative_score_change: f64,
}

/// The parsed initial/live choice payload.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveChoiceSet {
    /// Scene subtitle; empty string when the response omits it.
    pub subtitle: String,
    /// At most four options, ids `t0`..`t3`.
    pub choices: Vec<LiveChoice>,
}

/// Parse an initial/live choice generation response.
///
/// Mirrors TS `topics.slice(0, 4).map(...)`: string topics carry zero weights,
/// object topics read `text`/`positive`/`negative` with zero defaults, and ids
/// are `t{index}`. Only pure text-to-value conversion happens here.
pub fn parse_choices(raw: &str) -> Result<LiveChoiceSet, ParseError> {
    let object: Value = serde_json::from_str(extract_json_object(raw)?)
        .map_err(|err| ParseError::InvalidJson(err.to_string()))?;
    let topics = object
        .get("topics")
        .and_then(Value::as_array)
        .ok_or(ParseError::MissingTopics)?;
    let subtitle = object
        .get("subtitle")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();

    let choices = topics
        .iter()
        .take(4)
        .enumerate()
        .map(|(index, topic)| {
            let (text, positive, negative) = match topic {
                Value::String(text) => (text.clone(), 0.0, 0.0),
                Value::Object(_) => (
                    topic
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    topic.get("positive").and_then(Value::as_f64).unwrap_or(0.0),
                    topic.get("negative").and_then(Value::as_f64).unwrap_or(0.0),
                ),
                _ => (String::new(), 0.0, 0.0),
            };
            LiveChoice {
                id: format!("t{index}"),
                text,
                positive_score_change: positive,
                negative_score_change: negative,
            }
        })
        .collect();

    Ok(LiveChoiceSet { subtitle, choices })
}

/// Result of applying an `evaluateParameters` payload to current metrics.
#[derive(Debug, Clone, PartialEq)]
pub struct ParameterOutcome {
    /// New `Intimacy` value.
    pub intimacy: f64,
    /// New `Tension` value.
    pub tension: f64,
    /// Broadcast mood, when the response supplied a non-empty string.
    pub mood: Option<String>,
}

/// Parse an `evaluateParameters` response and compute the new metric values.
///
/// TS clamps with `Math.max(0, Math.min(100, current + change))`. The prompt's
/// suggested `-20..20` window is advisory only: any magnitude is accepted and
/// only the resulting value is clamped. Missing/non-numeric changes leave the
/// corresponding current value untouched.
pub fn evaluate_parameters(
    raw: &str,
    intimacy: f64,
    tension: f64,
) -> Result<ParameterOutcome, ParseError> {
    let object: Value = serde_json::from_str(extract_json_object(raw)?)
        .map_err(|err| ParseError::InvalidJson(err.to_string()))?;
    let changed = |current: f64, key: &str| {
        object
            .get(key)
            .and_then(Value::as_f64)
            .map_or(current, |delta| (current + delta).clamp(0.0, 100.0))
    };
    Ok(ParameterOutcome {
        intimacy: changed(intimacy, "intimacyChange"),
        tension: changed(tension, "tensionChange"),
        mood: object
            .get("mood")
            .and_then(Value::as_str)
            .filter(|mood| !mood.is_empty())
            .map(str::to_owned),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_json_object_ignores_preamble_and_postamble() {
        let raw = r#"Let me think...
{"subtitle":"Hi","topics":[{"text":"a","positive":1,"negative":0}]}
That's my answer."#;
        let extracted = extract_json_object(raw).unwrap();
        assert_eq!(
            extracted,
            r#"{"subtitle":"Hi","topics":[{"text":"a","positive":1,"negative":0}]}"#
        );
        // Nested braces: greedy first-{ to last-} keeps the whole object.
        assert_eq!(parse_choices(raw).unwrap().choices.len(), 1);
    }

    #[test]
    fn parse_choices_keeps_only_first_four_with_t_ids() {
        let raw = r#"{"subtitle":"Hello","topics":["one","two","three","four","five","six"]}"#;
        let parsed = parse_choices(raw).unwrap();
        assert_eq!(parsed.subtitle, "Hello");
        let ids: Vec<_> = parsed.choices.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["t0", "t1", "t2", "t3"]);
        let texts: Vec<_> = parsed.choices.iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, ["one", "two", "three", "four"]);
    }

    #[test]
    fn parse_choices_distinguishes_plain_strings_from_weighted_objects() {
        let raw =
            r#"{"subtitle":"Hi","topics":["plain",{"text":"weighted","positive":2,"negative":0}]}"#;
        let parsed = parse_choices(raw).unwrap();
        assert_eq!(parsed.choices[0].text, "plain");
        assert_eq!(
            (
                parsed.choices[0].positive_score_change,
                parsed.choices[0].negative_score_change,
            ),
            (0.0, 0.0)
        );
        assert_eq!(parsed.choices[1].text, "weighted");
        assert_eq!(
            (
                parsed.choices[1].positive_score_change,
                parsed.choices[1].negative_score_change,
            ),
            (2.0, 0.0)
        );
    }

    #[test]
    fn parse_choices_without_braces_returns_explicit_error() {
        let err = parse_choices("Here are four great options, no JSON at all.").unwrap_err();
        assert_eq!(err.to_string(), "No JSON object found in response");
    }

    #[test]
    fn evaluate_parameters_clamps_only_to_zero_and_one_hundred() {
        // The prompt advertises -20..20, but -999 must reach 0, not -20.
        let low = evaluate_parameters(
            r#"{"intimacyChange":-999,"tensionChange":-999,"mood":"sad"}"#,
            30.0,
            40.0,
        )
        .unwrap();
        assert_eq!(low.intimacy, 0.0);
        assert_eq!(low.tension, 0.0);
        assert_eq!(low.mood.as_deref(), Some("sad"));

        let high = evaluate_parameters(r#"{"intimacyChange":999,"tensionChange":999}"#, 30.0, 40.0)
            .unwrap();
        assert_eq!(high.intimacy, 100.0);
        assert_eq!(high.tension, 100.0);
        assert_eq!(high.mood, None);

        // Absent/non-numeric changes leave the current values untouched.
        let none = evaluate_parameters(r#"{"mood":"happy"}"#, 30.0, 40.0).unwrap();
        assert_eq!((none.intimacy, none.tension), (30.0, 40.0));
        assert_eq!(none.mood.as_deref(), Some("happy"));
    }
}
