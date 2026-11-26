// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Pure recent-topic extraction and scoring.
//!
//! Rust port of the pure logic in
//! `packages/stage-ui/src/stores/chat/recent-topics.ts`: stopword filtering,
//! unigram/bigram extraction (minimum token length three), recency decay,
//! echo-chip triple weighting, and the top-ten selection. The caller supplies
//! the three text sources in the same order as the TypeScript store; this
//! module owns no store, async, or UI dependencies and returns
//! [`RecentTopicItem`] values ready for the grounding block formatter.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use crate::grounding::RecentTopicItem;

/// Stopwords skipped by both extraction and echo-chip phrase scoring.
///
/// Same membership as the TypeScript `STOPWORDS` set (which lists duplicates).
static STOPWORDS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    [
        "the",
        "and",
        "but",
        "for",
        "not",
        "you",
        "was",
        "this",
        "that",
        "with",
        "have",
        "your",
        "about",
        "from",
        "they",
        "what",
        "then",
        "them",
        "some",
        "there",
        "their",
        "would",
        "could",
        "should",
        "will",
        "are",
        "were",
        "been",
        "has",
        "had",
        "its",
        "into",
        "just",
        "more",
        "only",
        "other",
        "than",
        "these",
        "those",
        "upon",
        "very",
        "when",
        "where",
        "which",
        "who",
        "why",
        "how",
        "here",
        "now",
        "any",
        "each",
        "few",
        "many",
        "same",
        "such",
        "too",
        "out",
        "off",
        "our",
        "his",
        "her",
        "she",
        "him",
        "itself",
        "ours",
        "yours",
        "hers",
        "themselves",
        "am",
        "is",
        "be",
        "being",
        "having",
        "do",
        "does",
        "did",
        "doing",
        "a",
        "an",
        "if",
        "or",
        "because",
        "as",
        "until",
        "while",
        "of",
        "at",
        "by",
        "against",
        "between",
        "through",
        "during",
        "before",
        "after",
        "above",
        "below",
        "to",
        "up",
        "down",
        "in",
        "on",
        "over",
        "under",
        "again",
        "further",
        "once",
        "all",
        "both",
        "most",
        "no",
        "nor",
        "own",
        "so",
        "s",
        "t",
        "can",
        "don",
        "d",
        "ll",
        "m",
        "o",
        "re",
        "ve",
        "y",
        "ain",
        "aren",
        "couldn",
        "didn",
        "doesn",
        "hadn",
        "hasn",
        "haven",
        "isn",
        "ma",
        "mightn",
        "mustn",
        "needn",
        "shan",
        "shouldn",
        "wasn",
        "weren",
        "won",
        "wouldn",
        "like",
        "going",
        "think",
        "know",
        "want",
        "make",
        "good",
        "well",
        "much",
        "people",
        "time",
        "still",
        "one",
        "get",
        "got",
        "look",
        "see",
        "come",
        "take",
        "say",
        "tell",
        "give",
        "find",
        "use",
        "way",
        "day",
        "thing",
        "back",
        "also",
        "even",
        "really",
        "something",
        "anything",
        "everything",
        "someone",
        "anyone",
        "everyone",
        "somewhere",
        "anywhere",
        "everywhere",
        "little",
        "yes",
        "yeah",
        "okay",
        "right",
        "please",
        "thanks",
        "thank",
        "sorry",
        "hello",
        "hi",
        "hey",
        "gurl",
        "kitty",
        "dude",
        "bro",
        "man",
        "guy",
        "girl",
        "boy",
        "woman",
        "men",
        "women",
        "gonna",
        "wanna",
        "gotta",
        "let",
        "us",
        "me",
        "my",
        "myself",
        "we",
        "ourselves",
        "yourself",
        "yourselves",
        "himself",
        "herself",
    ]
    .into_iter()
    .collect()
});

/// A candidate produced by [`extract_text_topics`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedTopic {
    /// Lowercased, cleaned topic label.
    pub topic: String,
    /// Whether the label is a two-word phrase rather than a single word.
    pub is_bigram: bool,
}

/// Text sources scored by [`score_recent_topics`].
///
/// Each source is kept in the order used by the TypeScript store so distances
/// can be derived from the index exactly as before. Role/metadata filtering is
/// the caller's responsibility; only eligible texts belong here.
#[derive(Debug, Clone, Default)]
pub struct RecentTopicsInput {
    /// User/assistant turn texts, oldest first (`distance = len - 1 - index`).
    pub turns: Vec<String>,
    /// Short-term-memory daily summaries (`distance = 20 + index * 10`).
    pub summaries: Vec<String>,
    /// Echo-chip phrases, newest first (`distance = index * 5`).
    pub echo_chips: Vec<String>,
}

/// Lowercase a phrase and drop everything except letters, numbers and spaces,
/// then collapse whitespace. Rust port of `cleanPhrase`.
pub fn clean_phrase(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    normalized(&text.to_lowercase())
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Extract unigram and bigram candidates from a text. Rust port of
/// `extractTextTopics`: tokens shorter than three characters and stopwords are
/// skipped, and bigrams join two consecutive non-stopword tokens.
pub fn extract_text_topics(text: &str) -> Vec<ExtractedTopic> {
    if text.is_empty() {
        return Vec::new();
    }
    let clean = normalized(&text.to_lowercase());
    let words: Vec<&str> = clean
        .split_whitespace()
        .filter(|word| word.chars().count() >= 3)
        .collect();

    let mut topics = Vec::new();
    for word in &words {
        if !is_stopword(word) {
            topics.push(ExtractedTopic {
                topic: (*word).to_string(),
                is_bigram: false,
            });
        }
    }
    for pair in words.windows(2) {
        if !is_stopword(pair[0]) && !is_stopword(pair[1]) {
            topics.push(ExtractedTopic {
                topic: format!("{} {}", pair[0], pair[1]),
                is_bigram: true,
            });
        }
    }
    topics
}

/// Score the supplied sources and return the ten highest-weight topics.
///
/// Text sources use base weight `1.0` with a `0.5` unigram / `1.5` bigram
/// multiplier; echo chips keep their full phrase at `3.0 * 1.5`. All scores are
/// scaled by `max(0.1, 1 - distance * 0.01)`. Ties keep first-seen order,
/// matching JavaScript's stable `Array#sort`.
pub fn score_recent_topics(input: &RecentTopicsInput) -> Vec<RecentTopicItem> {
    let mut scores = ScoreBoard::default();

    let total_turns = input.turns.len();
    for (index, content) in input.turns.iter().enumerate() {
        let distance = total_turns - 1 - index;
        add_topics(&mut scores, &extract_text_topics(content), 1.0, distance);
    }

    for (index, summary) in input.summaries.iter().enumerate() {
        let distance = 20 + index * 10;
        add_topics(&mut scores, &extract_text_topics(summary), 1.0, distance);
    }

    for (index, chip) in input.echo_chips.iter().enumerate() {
        let phrase = clean_phrase(chip);
        if phrase.is_empty() || is_stopword(&phrase) {
            continue;
        }
        scores.add(&phrase, 3.0 * 1.5 * decay(index * 5));
    }

    let mut topics: Vec<RecentTopicItem> = scores
        .entries
        .into_iter()
        .map(|(topic, weight)| RecentTopicItem { topic, weight })
        .collect();
    topics.sort_by(|a, b| b.weight.total_cmp(&a.weight));
    topics.truncate(10);
    topics
}

/// Replace non-letter/number/space characters with spaces, as the TS regex
/// `[^\p{L}\p{N}\s]+` does.
fn normalized(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_alphanumeric() || c.is_whitespace() {
                c
            } else {
                ' '
            }
        })
        .collect()
}

fn is_stopword(word: &str) -> bool {
    STOPWORDS.contains(word)
}

fn decay(distance: usize) -> f64 {
    (1.0 - distance as f64 * 0.01).max(0.1)
}

fn add_topics(
    scores: &mut ScoreBoard,
    extracted: &[ExtractedTopic],
    base_weight: f64,
    distance: usize,
) {
    let decayed = decay(distance);
    for item in extracted {
        // Bigrams outweigh single words to prioritise multi-word topics.
        let multiplier = if item.is_bigram { 1.5 } else { 0.5 };
        scores.add(&item.topic, base_weight * multiplier * decayed);
    }
}

/// Weighted topics plus a topic -> slot index, preserving first-seen order.
#[derive(Default)]
struct ScoreBoard {
    entries: Vec<(String, f64)>,
    index: HashMap<String, usize>,
}

impl ScoreBoard {
    fn add(&mut self, topic: &str, score: f64) {
        if let Some(&slot) = self.index.get(topic) {
            self.entries[slot].1 += score;
        } else {
            let slot = self.entries.len();
            self.index.insert(topic.to_string(), slot);
            self.entries.push((topic.to_string(), score));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < 1e-9,
            "expected {expected}, got {actual}"
        );
    }

    fn weight(topics: &[RecentTopicItem], topic: &str) -> Option<f64> {
        topics
            .iter()
            .find(|item| item.topic == topic)
            .map(|item| item.weight)
    }

    #[test]
    fn stopword_filtering() {
        let extracted = extract_text_topics("The garden and the roses");
        let labels: Vec<&str> = extracted.iter().map(|item| item.topic.as_str()).collect();
        assert_eq!(labels, ["garden", "roses"]);
        assert!(labels.iter().all(|label| !is_stopword(label)));

        // Echo-chip phrases that are a single stopword are skipped too.
        let scored = score_recent_topics(&RecentTopicsInput {
            echo_chips: vec!["the".into(), "gardening".into()],
            ..Default::default()
        });
        assert_eq!(scored.len(), 1);
        assert_eq!(scored[0].topic, "gardening");
    }

    #[test]
    fn bigram_weighting() {
        // A single turn at distance 0 has decay 1.0: unigrams score 0.5 and
        // the bigram scores 1.5 (three times a unigram).
        let scored = score_recent_topics(&RecentTopicsInput {
            turns: vec!["garden roses".into()],
            ..Default::default()
        });
        close(weight(&scored, "garden").expect("garden missing"), 0.5);
        close(weight(&scored, "roses").expect("roses missing"), 0.5);
        close(
            weight(&scored, "garden roses").expect("bigram missing"),
            1.5,
        );
        assert_eq!(scored.first().expect("no topics").topic, "garden roses");
    }

    #[test]
    fn decay_floor_is_point_one() {
        close(decay(90), 0.1);
        close(decay(500), 0.1);
        close(decay(50), 0.5);
        assert!(decay(0) > decay(10));

        // Echo chip 19 sits at distance 19 * 5 = 95, below the floor:
        // 3.0 * 1.5 * 0.1 = 0.45. Earlier empty chips are skipped but still
        // advance the index.
        let mut chips = vec![String::new(); 19];
        chips.push("gardening".into());
        let scored = score_recent_topics(&RecentTopicsInput {
            echo_chips: chips,
            ..Default::default()
        });
        assert_eq!(scored.len(), 1);
        close(scored[0].weight, 0.45);
    }

    #[test]
    fn empty_input() {
        assert_eq!(clean_phrase(""), "");
        assert_eq!(clean_phrase("   "), "");
        assert!(extract_text_topics("").is_empty());
        assert!(extract_text_topics("!! ??").is_empty());
        assert!(score_recent_topics(&RecentTopicsInput::default()).is_empty());
    }

    #[test]
    fn top_ten_cap() {
        let chips: Vec<String> = (0..15).map(|i| format!("phrase{i:02}")).collect();
        let scored = score_recent_topics(&RecentTopicsInput {
            echo_chips: chips,
            ..Default::default()
        });
        assert_eq!(scored.len(), 10);
        assert_eq!(scored[0].topic, "phrase00");
        assert_eq!(scored[9].topic, "phrase09");
        assert!(scored
            .windows(2)
            .all(|pair| pair[0].weight >= pair[1].weight));
    }
}
