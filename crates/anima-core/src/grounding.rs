// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Pure grounding-context formatter and assembler.
//!
//! Rust port of `packages/stage-ui/src/stores/chat/grounding-assembler.ts`.
//! It formats retrieved context (vision analysis, sensor telemetry, memory,
//! topics, Director scratchpad, salience) into system-prompt blocks, applies
//! the TypeScript per-block and total character budgets, and joins the
//! surviving blocks in insertion order. No async, store, or UI dependencies.

/// Default total character budget for all assembled blocks (`7000` in TS).
pub const DEFAULT_MAX_TOTAL_CHARS: usize = 7000;
/// Default per-block character cap before truncation (`2500` in TS).
pub const DEFAULT_MAX_PER_BLOCK_CHARS: usize = 2500;

/// Character budgets applied by [`assemble`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GroundingBudget {
    /// Maximum characters across all assembled blocks.
    pub max_total_chars: usize,
    /// Maximum characters kept from any single block before truncation.
    pub max_per_block_chars: usize,
}

impl Default for GroundingBudget {
    fn default() -> Self {
        Self {
            max_total_chars: DEFAULT_MAX_TOTAL_CHARS,
            max_per_block_chars: DEFAULT_MAX_PER_BLOCK_CHARS,
        }
    }
}

impl From<usize> for GroundingBudget {
    fn from(max_total_chars: usize) -> Self {
        Self {
            max_total_chars,
            ..Self::default()
        }
    }
}

/// Preformatted date label attached to a semantic memory record.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GroundingDateInfo {
    /// Human-readable label; takes precedence over the record timestamp.
    pub formatted_label: Option<String>,
}

/// One retrieved long-term memory record.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SemanticMemoryItem {
    /// Record kind (`raw`, `user_turn`, `assistant_turn`, `kg_claim`, ...).
    pub kind: Option<String>,
    /// Display title; `Memory` when absent.
    pub title: Option<String>,
    /// Record body text.
    pub content: String,
    /// Stable record id (kept for parity with the TS shape).
    pub id: Option<String>,
    /// Creation time as an ISO-8601 string or epoch-milliseconds string.
    pub created_at: Option<String>,
    /// Event time as an ISO-8601 string or epoch-milliseconds string.
    pub timestamp: Option<String>,
    /// Retrieval score (kept for parity with the TS shape).
    pub score: Option<f64>,
    /// Whether this record is a knowledge-graph claim.
    pub is_kg_claim: bool,
    /// Subject of a knowledge-graph triple.
    pub subject: Option<String>,
    /// Predicate of a knowledge-graph triple.
    pub predicate: Option<String>,
    /// Object of a knowledge-graph triple.
    pub object: Option<String>,
    /// Preformatted date metadata for the triple line.
    pub date_info: Option<GroundingDateInfo>,
    /// Proof-bundle claim id (kept for parity with the TS shape).
    pub claim_id: Option<String>,
    /// Proof-bundle sub-goal shown in the episodic meta line.
    pub sub_goal: Option<String>,
}

/// An active conceptual thread and its retrieval weight.
#[derive(Debug, Clone, PartialEq)]
pub struct RecentTopicItem {
    /// Topic label.
    pub topic: String,
    /// Activation weight, rendered with two decimals.
    pub weight: f64,
}

/// Late-layer salience deltas for the current turn.
#[derive(Debug, Clone, PartialEq)]
pub struct SalienceMetrics {
    /// Cosine deltas beginning at layer L9.
    pub late_layer_deltas: Vec<f64>,
    /// Mean cosine delta across the measured layers.
    pub late_layer_mean: f64,
    /// Whether the salience gate classified the turn as hot.
    pub hot: bool,
}

/// A single piece of retrieved context to inject into a system prompt.
#[derive(Debug, Clone, PartialEq)]
pub enum GroundingBlock {
    /// Objective vision-model description of an attached image.
    Vlm {
        /// The vision model's analysis text.
        analysis: String,
    },
    /// Current environmental sensor telemetry.
    Environmental {
        /// Serialized sensor payload.
        sensor_payload: String,
    },
    /// Short-term memory daily continuity text (used verbatim).
    ShortTermMemory {
        /// Preformatted continuity block from `ShortTermMemoryService`.
        context: String,
    },
    /// Lifetime memory artifact text (used verbatim).
    LifetimeMemory {
        /// Preformatted lifetime artifact text.
        context: String,
    },
    /// Retrieved semantic / long-term memory records.
    SemanticMemories {
        /// Records to render as KG facts and episodic memories.
        memories: Vec<SemanticMemoryItem>,
    },
    /// Active recent conversation topics.
    RecentTopics {
        /// Topics with their activation weights.
        topics: Vec<RecentTopicItem>,
    },
    /// Director-managed visual scene state.
    DirectorScratchpad {
        /// Visual/spatial description.
        scratchpad: String,
    },
    /// Emotional/physical state deltas from the salience gate.
    SalienceTelemetry {
        /// Late-layer delta metrics.
        metrics: SalienceMetrics,
    },
}

impl GroundingBlock {
    /// Build a short-term-memory block from preformatted continuity text.
    pub fn short_term_memory(context: impl Into<String>) -> Self {
        Self::ShortTermMemory {
            context: context.into(),
        }
    }
}

/// Format an attached-image analysis block.
pub fn format_vlm_block(analysis: &str) -> String {
    format!("[IMAGE ANALYSIS]\nThe user attached an image. The following is an objective visual description generated by a vision model to inform your response. React naturally as the character — do not narrate or reference this block directly:\n---\n{analysis}")
}

/// Format an environmental telemetry block.
pub fn format_environmental_block(sensor_payload: &str) -> String {
    format!("[ENVIRONMENTAL AWARENESS]\nThe following telemetry describes your current environmental context. Use it to stay grounded in the user's reality and inform your response. You may reference specific values (like time or active applications) if relevant to the conversation, but avoid a dry, technical recitation of the data.\n---\n{sensor_payload}")
}

/// Format a short-term-memory block. The context is already formatted upstream.
pub fn format_short_term_memory_block(context: &str) -> String {
    context.to_string()
}

/// Format a lifetime-memory block. The context is already formatted upstream.
pub fn format_lifetime_memory_block(context: &str) -> String {
    context.to_string()
}

/// Format retrieved semantic memories, separating knowledge-graph facts from
/// episodic and verbatim dialogue records.
pub fn format_semantic_memories_block(memories: &[SemanticMemoryItem]) -> String {
    let is_kg = |m: &SemanticMemoryItem| m.is_kg_claim || m.kind.as_deref() == Some("kg_claim");
    let kg_claims: Vec<&SemanticMemoryItem> = memories.iter().filter(|m| is_kg(m)).collect();
    let episodic: Vec<&SemanticMemoryItem> = memories.iter().filter(|m| !is_kg(m)).collect();

    let mut sections: Vec<String> = Vec::new();

    if !kg_claims.is_empty() {
        let claims = kg_claims
            .iter()
            .map(|c| {
                let date = c
                    .date_info
                    .as_ref()
                    .and_then(|d| d.formatted_label.as_deref())
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .or_else(|| {
                        c.timestamp
                            .as_deref()
                            .and_then(|t| t.split('T').next())
                            .filter(|s| !s.is_empty())
                            .map(str::to_string)
                    })
                    .map(|label| format!(" [{label}]"))
                    .unwrap_or_default();
                match (
                    c.subject.as_deref().filter(|s| !s.is_empty()),
                    c.predicate.as_deref().filter(|s| !s.is_empty()),
                    c.object.as_deref().filter(|s| !s.is_empty()),
                ) {
                    (Some(subject), Some(predicate), Some(object)) => {
                        format!("• {subject} ➔ {predicate} ➔ {object}{date}")
                    }
                    _ => format!("• {}", c.content),
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!("[CONFIRMED KNOWLEDGE GRAPH FACTS]\n{claims}"));
    }

    if !episodic.is_empty() {
        let has_dialogue = episodic.iter().any(|m| {
            matches!(
                m.kind.as_deref(),
                Some("raw" | "user_turn" | "assistant_turn")
            )
        });
        let section_header = if !kg_claims.is_empty() {
            if has_dialogue {
                "[VERBATIM DIALOGUE MEMORIES]\n"
            } else {
                "[EPISODIC & JOURNAL MEMORIES]\n"
            }
        } else {
            ""
        };
        let items = episodic
            .iter()
            .map(|m| {
                let kind = m
                    .kind
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Journal");
                let title = m
                    .title
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Memory");
                let mut meta = String::new();
                if let Some(raw) = m
                    .timestamp
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .or_else(|| m.created_at.as_deref().filter(|s| !s.is_empty()))
                {
                    if let Some(date) = format_date_meta(raw) {
                        meta.push_str(&format!(" [{date}]"));
                    }
                }
                if let Some(sub_goal) = m.sub_goal.as_deref().filter(|s| !s.is_empty()) {
                    meta.push_str(&format!(" (Sub-goal: \"{sub_goal}\")"));
                }
                format!("[{}] {}{}\n{}", kind.to_uppercase(), title, meta, m.content)
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        sections.push(format!("{section_header}{items}"));
    }

    let content = sections.join("\n\n---\n\n");
    format!("[GROUNDED LONG-TERM MEMORIES]\nThe following long-term memory records from your history were retrieved based on the user's latest query. Use these memories to inform your response and maintain context continuity. Keep references to them natural and contextual:\n---\n{content}")
}

/// Format active recent topics with two-decimal weights.
pub fn format_recent_topics_block(topics: &[RecentTopicItem]) -> String {
    let formatted = topics
        .iter()
        .map(|t| format!("{} (weight: {:.2})", t.topic, t.weight))
        .collect::<Vec<_>>()
        .join(", ");
    format!("[RECENT TOPICS]\nYou have the following topics and conceptual threads active in your recent memory. Use them to maintain awareness of what has been discussed lately:\n---\n{formatted}")
}

/// Format the Director's visual scene state.
pub fn format_director_scratchpad_block(scratchpad: &str) -> String {
    format!("[VISUAL STATE BOARD]\nThe following telemetry describes your current visual and spatial context, managed by the Director. Use this description to remain verbally aligned with your current surroundings, outfit, or held items. Keep references natural and contextual:\n---\n{scratchpad}")
}

/// Format salience-gate deltas as an in-character instruction.
pub fn format_salience_telemetry_block(metrics: &SalienceMetrics) -> String {
    let layer_report = metrics
        .late_layer_deltas
        .iter()
        .enumerate()
        .map(|(i, d)| format!("L{}={:.3}", 9 + i, d))
        .collect::<Vec<_>>()
        .join(" ");
    format!("[SALIENCE TELEMETRY]\nThis turn marks an emotional/physical beat. Recent-turn state deltas (late layers L9–L11 cosine Δh) = {layer_report}; mean Δcos = {:.3}; verdict={}. Keep a natural, in-character tone; do NOT narrate the numbers to the user.", metrics.late_layer_mean, if metrics.hot { "hot" } else { "elevated" })
}

/// Dispatch one block to its formatter, preserving the block's own text.
pub fn format_grounding_block(block: &GroundingBlock) -> String {
    match block {
        GroundingBlock::Vlm { analysis } => format_vlm_block(analysis),
        GroundingBlock::Environmental { sensor_payload } => {
            format_environmental_block(sensor_payload)
        }
        GroundingBlock::ShortTermMemory { context } => format_short_term_memory_block(context),
        GroundingBlock::LifetimeMemory { context } => format_lifetime_memory_block(context),
        GroundingBlock::SemanticMemories { memories } => format_semantic_memories_block(memories),
        GroundingBlock::RecentTopics { topics } => format_recent_topics_block(topics),
        GroundingBlock::DirectorScratchpad { scratchpad } => {
            format_director_scratchpad_block(scratchpad)
        }
        GroundingBlock::SalienceTelemetry { metrics } => format_salience_telemetry_block(metrics),
    }
}

/// Format every block in order.
pub fn build_grounding_messages(blocks: &[GroundingBlock]) -> Vec<String> {
    blocks.iter().map(format_grounding_block).collect()
}

/// Apply the per-block cap and the global character budget, mirroring
/// `budgetGroundingMessages`. Blocks past an exhausted budget are dropped;
/// truncation markers are appended in the same places as the TS source.
pub fn budget_grounding_messages(
    messages: &[String],
    max_total_chars: usize,
    max_per_block_chars: usize,
) -> Vec<String> {
    let mut remaining = max_total_chars;
    let mut budgeted = Vec::new();

    for message in messages {
        if remaining == 0 {
            break;
        }

        // Budget is counted in Unicode scalars; TS uses UTF-16 code units.
        // These blocks emit mostly BMP text, so the two agree in practice.
        let mut content = message.clone();
        if content.chars().count() > max_per_block_chars {
            content = format!(
                "{}\n[...truncated to fit budget]",
                truncate_chars(&content, max_per_block_chars)
            );
        }

        if content.chars().count() > remaining {
            if remaining > 200 {
                content = format!(
                    "{}\n[...truncated to fit total budget]",
                    truncate_chars(&content, remaining)
                );
                budgeted.push(content);
            }
            break;
        }

        remaining -= content.chars().count();
        budgeted.push(content);
    }

    budgeted
}

/// Format, budget, and join grounding blocks into one system-prompt string.
///
/// Blocks are joined with a blank line. A bare [`usize`] budget is treated as
/// the total-character budget with the default per-block cap.
pub fn assemble<B, T>(blocks: T, budget: B) -> String
where
    B: Into<GroundingBudget>,
    T: AsRef<[GroundingBlock]>,
{
    let budget = budget.into();
    let messages = build_grounding_messages(blocks.as_ref());
    budget_grounding_messages(
        &messages,
        budget.max_total_chars,
        budget.max_per_block_chars,
    )
    .join("\n\n")
}

fn truncate_chars(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

/// Render a TS-style `toISOString().replace('T', ' ').substring(0, 16)` meta tag.
fn format_date_meta(raw: &str) -> Option<String> {
    if raw.contains('T') {
        parse_iso_minute(raw)
    } else if let Ok(epoch_ms) = raw.trim().parse::<i64>() {
        iso_minute(epoch_ms)
    } else {
        parse_date_only(raw)
    }
}

fn parse_date_only(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    if bytes.len() < 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let year = raw.get(0..4)?.parse().ok()?;
    let month = raw.get(5..7)?.parse().ok()?;
    let day = raw.get(8..10)?.parse().ok()?;
    let days = days_from_civil(year, month, day);
    iso_minute(days * 86_400_000)
}

fn parse_iso_minute(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    if bytes.len() < 16
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
    {
        return None;
    }
    let year = raw.get(0..4)?.parse().ok()?;
    let month = raw.get(5..7)?.parse().ok()?;
    let day = raw.get(8..10)?.parse().ok()?;
    let hour: i64 = raw.get(11..13)?.parse().ok()?;
    let minute: i64 = raw.get(14..16)?.parse().ok()?;
    if hour > 23 || minute > 59 {
        return None;
    }

    // `new Date(iso)` converts an explicit offset to UTC before toISOString.
    let mut offset_minutes = 0;
    let tail = &raw[11..];
    if let Some(index) = tail.find(|c| c == '+' || c == '-') {
        let sign_index = 11 + index;
        let sign = if bytes[sign_index] == b'-' { -1 } else { 1 };
        let offset = &raw[sign_index + 1..];
        let offset_hour: i64 = offset.get(0..2)?.parse().ok()?;
        let offset_minute: i64 = if offset.as_bytes().get(2) == Some(&b':') {
            offset.get(3..5)?.parse().ok()?
        } else {
            offset.get(2..4)?.parse().ok()?
        };
        offset_minutes = sign * (offset_hour * 60 + offset_minute);
    }

    let days = days_from_civil(year, month, day);
    let epoch_ms = days * 86_400_000 + (hour * 60 + minute - offset_minutes) * 60_000;
    iso_minute(epoch_ms)
}

fn iso_minute(epoch_ms: i64) -> Option<String> {
    let days = epoch_ms.div_euclid(86_400_000);
    let minute_of_day = epoch_ms.rem_euclid(86_400_000) / 60_000;
    let (year, month, day) = civil_from_days(days);
    Some(format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}",
        minute_of_day / 60,
        minute_of_day % 60
    ))
}

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let mp = i64::from(month) + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { y + 1 } else { y }, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn salience() -> SalienceMetrics {
        SalienceMetrics {
            late_layer_deltas: vec![0.12, -0.34, 0.56],
            late_layer_mean: 0.34,
            hot: true,
        }
    }

    #[test]
    fn headers_match_typescript_source() {
        let blocks = [
            (
                GroundingBlock::Vlm {
                    analysis: "a".into(),
                },
                "[IMAGE ANALYSIS]",
            ),
            (
                GroundingBlock::Environmental {
                    sensor_payload: "s".into(),
                },
                "[ENVIRONMENTAL AWARENESS]",
            ),
            (
                GroundingBlock::ShortTermMemory {
                    context: "[PAST CONTINUITY / DAILY SUMMARIES]".into(),
                },
                "[PAST CONTINUITY / DAILY SUMMARIES]",
            ),
            (
                GroundingBlock::LifetimeMemory {
                    context: "[LIFETIME MEMORY]".into(),
                },
                "[LIFETIME MEMORY]",
            ),
            (
                GroundingBlock::SemanticMemories { memories: vec![] },
                "[GROUNDED LONG-TERM MEMORIES]",
            ),
            (
                GroundingBlock::RecentTopics { topics: vec![] },
                "[RECENT TOPICS]",
            ),
            (
                GroundingBlock::DirectorScratchpad {
                    scratchpad: "v".into(),
                },
                "[VISUAL STATE BOARD]",
            ),
            (
                GroundingBlock::SalienceTelemetry {
                    metrics: salience(),
                },
                "[SALIENCE TELEMETRY]",
            ),
        ];
        for (block, header) in blocks {
            assert!(
                format_grounding_block(&block).starts_with(header),
                "missing header {header:?}"
            );
        }

        assert_eq!(
            format_vlm_block("a cat"),
            "[IMAGE ANALYSIS]\nThe user attached an image. The following is an objective visual description generated by a vision model to inform your response. React naturally as the character — do not narrate or reference this block directly:\n---\na cat"
        );
        assert_eq!(
            format_recent_topics_block(&[RecentTopicItem {
                topic: "gardening".into(),
                weight: 0.5,
            }]),
            "[RECENT TOPICS]\nYou have the following topics and conceptual threads active in your recent memory. Use them to maintain awareness of what has been discussed lately:\n---\ngardening (weight: 0.50)"
        );
        assert_eq!(
            format_salience_telemetry_block(&salience()),
            "[SALIENCE TELEMETRY]\nThis turn marks an emotional/physical beat. Recent-turn state deltas (late layers L9–L11 cosine Δh) = L9=0.120 L10=-0.340 L11=0.560; mean Δcos = 0.340; verdict=hot. Keep a natural, in-character tone; do NOT narrate the numbers to the user."
        );
        assert_eq!(format_short_term_memory_block("ctx"), "ctx");
        assert_eq!(format_lifetime_memory_block("ctx"), "ctx");
    }

    #[test]
    fn semantic_memories_render_kg_facts_and_episodic_records() {
        let kg = SemanticMemoryItem {
            is_kg_claim: true,
            subject: Some("Ada".into()),
            predicate: Some("likes".into()),
            object: Some("tea".into()),
            timestamp: Some("2026-11-25T09:30:00Z".into()),
            ..SemanticMemoryItem::default()
        };
        let dialogue = SemanticMemoryItem {
            kind: Some("user_turn".into()),
            title: Some("Yesterday".into()),
            content: "We planted roses".into(),
            timestamp: Some("2026-11-25T09:30:00Z".into()),
            sub_goal: Some("garden".into()),
            ..SemanticMemoryItem::default()
        };
        let out = assemble(
            &[GroundingBlock::SemanticMemories {
                memories: vec![kg, dialogue],
            }],
            GroundingBudget::default(),
        );
        assert!(out.starts_with("[GROUNDED LONG-TERM MEMORIES]\nThe following long-term memory records from your history were retrieved based on the user's latest query. Use these memories to inform your response and maintain context continuity. Keep references to them natural and contextual:\n---\n"));
        assert!(out.contains("[CONFIRMED KNOWLEDGE GRAPH FACTS]\n• Ada ➔ likes ➔ tea [2026-11-25]"));
        assert!(out.contains("\n\n---\n\n[VERBATIM DIALOGUE MEMORIES]\n"));
        assert!(out.contains(
            "[USER_TURN] Yesterday [2026-11-25 09:30] (Sub-goal: \"garden\")\nWe planted roses"
        ));
    }

    #[test]
    fn semantic_memories_formatter_emits_one_header_for_all_items() {
        // chat.rs maps search hits straight into items; a second header from
        // the old build_prompt_block wrapper must not reappear inside content.
        let items = vec![
            SemanticMemoryItem {
                kind: Some("journal".into()),
                content: "The user's cat is named Miso".into(),
                ..SemanticMemoryItem::default()
            },
            SemanticMemoryItem {
                kind: Some("summary".into()),
                content: "Talked about the cat again".into(),
                ..SemanticMemoryItem::default()
            },
        ];
        let out = format_semantic_memories_block(&items);
        assert_eq!(out.matches("[GROUNDED LONG-TERM MEMORIES]").count(), 1);
        assert!(
            !out.contains("Relevant memories (retrieved automatically"),
            "{out}"
        );
        assert!(
            out.contains("[JOURNAL] Memory\nThe user's cat is named Miso"),
            "{out}"
        );
        assert!(
            out.contains("[SUMMARY] Memory\nTalked about the cat again"),
            "{out}"
        );
    }

    #[test]
    fn assemble_preserves_block_order() {
        let blocks = vec![
            GroundingBlock::Vlm {
                analysis: "a".into(),
            },
            GroundingBlock::Environmental {
                sensor_payload: "s".into(),
            },
            GroundingBlock::ShortTermMemory {
                context: "stmm".into(),
            },
            GroundingBlock::LifetimeMemory {
                context: "life".into(),
            },
            GroundingBlock::SemanticMemories { memories: vec![] },
            GroundingBlock::RecentTopics { topics: vec![] },
            GroundingBlock::DirectorScratchpad {
                scratchpad: "d".into(),
            },
            GroundingBlock::SalienceTelemetry {
                metrics: salience(),
            },
        ];
        let out = assemble(&blocks, GroundingBudget::default());
        let headers = [
            "[IMAGE ANALYSIS]",
            "[ENVIRONMENTAL AWARENESS]",
            "stmm",
            "life",
            "[GROUNDED LONG-TERM MEMORIES]",
            "[RECENT TOPICS]",
            "[VISUAL STATE BOARD]",
            "[SALIENCE TELEMETRY]",
        ];
        let mut previous = 0;
        for header in headers {
            let position = out[previous..].find(header).expect("block missing") + previous;
            assert!(position >= previous, "block out of order: {header}");
            previous = position + header.len();
        }
        assert!(out.contains("life\n\n[GROUNDED LONG-TERM MEMORIES]"));
    }

    #[test]
    fn budget_truncates_per_block_then_drops_exhausted_blocks() {
        let out = assemble(
            &[
                GroundingBlock::Vlm {
                    analysis: "x".repeat(200),
                },
                GroundingBlock::DirectorScratchpad {
                    scratchpad: "never rendered".into(),
                },
            ],
            GroundingBudget {
                max_total_chars: 7000,
                max_per_block_chars: 50,
            },
        );
        assert_eq!(out.matches("[...truncated to fit budget]").count(), 2);
        assert!(!out.contains("never rendered"));

        // A single block larger than the remaining budget is trimmed and the
        // remaining blocks are skipped.
        let out = assemble(
            &[GroundingBlock::Vlm {
                analysis: "y".repeat(500),
            }],
            300,
        );
        assert!(out.contains("\n[...truncated to fit total budget]"));
        assert_eq!(
            out.chars().count(),
            300 + 1 + "[...truncated to fit total budget]".len()
        );

        // Budgets of 200 or less cannot fit the truncation marker, so the
        // block is dropped entirely.
        assert_eq!(
            assemble(
                &[GroundingBlock::Vlm {
                    analysis: "z".repeat(500),
                }],
                150,
            ),
            ""
        );
    }

    #[test]
    fn assemble_with_no_blocks_is_empty() {
        assert_eq!(assemble(&[], GroundingBudget::default()), "");
        assert_eq!(assemble(Vec::<GroundingBlock>::new(), 7000), "");
    }
}
