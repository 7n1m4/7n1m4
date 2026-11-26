// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Pure helpers for bounded chat-history compaction.
//!
//! Ported from the TypeScript store
//! `packages/stage-ui/src/stores/chat/compaction.ts` (the free functions at
//! lines 18-109). Nothing here touches the database, the provider registry, or
//! the event bus: these functions only inspect message-shaped values and
//! return new values. The TS code operates on `any`; this module uses the
//! small explicit [`CompactionMessage`] shape instead.

/// Post-compaction target ceiling as a fraction of the context threshold.
///
/// Mirrors `WINNOW_TARGET_BUDGET_RATIO` in the TS store: winnowed sessions
/// keep 75% of the budget so later turns still have headroom.
pub const WINNOW_TARGET_BUDGET_RATIO: f64 = 0.75;

/// Number of messages bundled into one winnow window (the TS `windowSize`
/// default).
pub const WINNOW_WINDOW_SIZE: usize = 2;

/// Role label used for non-user messages (the TS `characterName` default).
pub const DEFAULT_CHARACTER_NAME: &str = "Assistant";

/// One entry of a multi-modal message's `content` array.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagePart {
    /// The part discriminator; only `"text"` parts contribute any text.
    pub part_type: String,
    /// The textual payload of the part.
    pub text: String,
}

/// The two content shapes the TS helpers accept: a string or an array of parts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MessageContent {
    /// Plain string content (`typeof msg.content === 'string'`).
    Text(String),
    /// Array-of-parts content (`Array.isArray(msg.content)`).
    Parts(Vec<MessagePart>),
}

/// Minimal message shape used by the pure compaction helpers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionMessage {
    /// Role string; exactly `"user"` gets the `"User"` window label, every
    /// other role uses the supplied character name.
    pub role: String,
    /// Message content, either a plain string or a list of content parts.
    pub content: MessageContent,
}

impl CompactionMessage {
    /// Build a plain-text message (the common case for persisted history).
    pub fn text(role: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: role.into(),
            content: MessageContent::Text(content.into()),
        }
    }
}

/// A winnow turn window: a few consecutive messages and their rendered lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WinnowTurnWindow {
    /// Stable id of the form `w0`, `w1`, … in creation order.
    pub id: String,
    /// Rendered window text (`"User: …\nAssistant: …"`).
    pub text: String,
    /// Messages bundled into this window, in their original order.
    pub messages: Vec<CompactionMessage>,
}

/// Extract a message's text for token estimation and window rendering.
///
/// Mirrors `extractCompactionMessageText`: a missing message yields an empty
/// string; string content is returned verbatim; array content contributes
/// only parts whose discriminator is `"text"` (their `text` field is a
/// `String` by construction here, matching TS's `typeof part.text ===
/// 'string'` guard), joined with `\n`; any other shape yields an empty string.
pub fn extract_compaction_message_text(msg: Option<&CompactionMessage>) -> String {
    let Some(msg) = msg else {
        return String::new();
    };
    match &msg.content {
        MessageContent::Text(text) => text.clone(),
        MessageContent::Parts(parts) => parts
            .iter()
            .filter(|part| part.part_type == "text")
            .map(|part| part.text.clone())
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

/// Estimate the token cost of a piece of text.
///
/// This is the Rust stand-in for `estimateTokens` from
/// `@proj-anima/stage-shared`, which the TS store imports as a dependency. It
/// reproduces the TS heuristic exactly: CJK code points cost one token each,
/// the remainder is costed at `ceil(utf16_units / 4)`, and even blank text
/// costs one token. JS string length is UTF-16 code units, so astral code
/// points (emoji, CJK Ext-B) count as two units in the total while being
/// counted once by the CJK code-point loop; the TS helper subtracts that
/// code-point count from the UTF-16 length, and so do we.
fn estimate_tokens(text: &str) -> usize {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return 1;
    }
    let mut cjk = 0usize;
    for ch in trimmed.chars() {
        if is_cjk(ch as u32) {
            cjk += 1;
        }
    }
    // TS `trimmed.length` counts UTF-16 code units, not Unicode scalars.
    let total = trimmed.encode_utf16().count();
    let non_cjk = total - cjk;
    (cjk + (non_cjk + 3) / 4).max(1)
}

/// CJK ranges used by the TS `estimateTokens` helper.
fn is_cjk(cp: u32) -> bool {
    (0x4E00..=0x9FFF).contains(&cp) // CJK Unified Ideographs
        || (0x3400..=0x4DBF).contains(&cp) // CJK Ext-A
        || (0x20000..=0x2A6DF).contains(&cp) // CJK Ext-B
        || (0xF900..=0xFAFF).contains(&cp) // CJK Compatibility Ideographs
        || (0x3000..=0x303F).contains(&cp) // CJK Symbols and Punctuation
        || (0x3040..=0x309F).contains(&cp) // Hiragana
        || (0x30A0..=0x30FF).contains(&cp) // Katakana
        || (0xAC00..=0xD7AF).contains(&cp) // Hangul Syllables
}

/// Estimate the total token cost of a list of messages.
///
/// Mirrors `estimateMessageListTokens`: each message's extracted text is
/// costed with the local [`estimate_tokens`] heuristic (the Rust counterpart
/// of the TS `estimateTokens` dependency) and the costs are summed.
pub fn estimate_message_list_tokens(messages: &[CompactionMessage]) -> usize {
    messages
        .iter()
        .map(|msg| estimate_tokens(&extract_compaction_message_text(Some(msg))))
        .sum()
}

/// Group messages into sequential windows of `window_size` non-empty turns.
///
/// Mirrors `buildWinnowCompactionWindows`: messages whose extracted text is
/// empty after trimming are skipped, each remaining message becomes a
/// `"User: …"` or `"<character_name>: …"` line, and windows flush once
/// `window_size` messages have accumulated (plus one final partial flush).
/// Ids are `w0`, `w1`, … in creation order. TS defaults are
/// [`WINNOW_WINDOW_SIZE`] (2) and [`DEFAULT_CHARACTER_NAME`] ("Assistant").
pub fn build_winnow_compaction_windows(
    to_compact: &[CompactionMessage],
    character_name: &str,
    window_size: usize,
) -> Vec<WinnowTurnWindow> {
    let mut windows: Vec<WinnowTurnWindow> = Vec::new();
    let mut current_msgs: Vec<CompactionMessage> = Vec::new();
    let mut current_lines: Vec<String> = Vec::new();

    fn flush(
        windows: &mut Vec<WinnowTurnWindow>,
        current_msgs: &mut Vec<CompactionMessage>,
        current_lines: &mut Vec<String>,
    ) {
        if current_msgs.is_empty() {
            return;
        }
        windows.push(WinnowTurnWindow {
            id: format!("w{}", windows.len()),
            text: current_lines.join("\n"),
            messages: std::mem::take(current_msgs),
        });
        current_lines.clear();
    }

    for msg in to_compact {
        let text = extract_compaction_message_text(Some(msg));
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let role_label = if msg.role == "user" {
            "User"
        } else {
            character_name
        };
        current_msgs.push(msg.clone());
        current_lines.push(format!("{role_label}: {text}"));
        if current_msgs.len() >= window_size {
            flush(&mut windows, &mut current_msgs, &mut current_lines);
        }
    }
    flush(&mut windows, &mut current_msgs, &mut current_lines);
    windows
}

/// Keep the newest candidates that fit a bounded token budget.
///
/// Mirrors `capWinnowSurvivorsToBudget`: with no threshold (or a zero one), or
/// no candidates, the candidates are returned unchanged. The budget is
/// `floor(threshold * target_ratio) - base_tokens`; when nothing is left the
/// result is empty. Otherwise messages are walked newest-first and kept when
/// their estimated cost fits the remaining budget; the selection is then
/// reversed back into the candidates' original order.
pub fn cap_winnow_survivors_to_budget(
    candidates: &[CompactionMessage],
    base_tokens: usize,
    threshold: Option<usize>,
    target_ratio: f64,
) -> Vec<CompactionMessage> {
    let Some(threshold) = threshold else {
        return candidates.to_vec();
    };
    if threshold == 0 || candidates.is_empty() {
        return candidates.to_vec();
    }

    let max_allowed = (threshold as f64 * target_ratio).floor() as usize;
    let mut remaining = max_allowed.saturating_sub(base_tokens);
    if remaining == 0 {
        return Vec::new();
    }

    let mut selected: Vec<CompactionMessage> = Vec::new();
    for msg in candidates.iter().rev() {
        let cost = estimate_tokens(&extract_compaction_message_text(Some(msg)));
        if cost <= remaining {
            selected.push(msg.clone());
            remaining -= cost;
        }
    }
    selected.reverse();
    selected
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(entries: &[(&str, &str)]) -> MessageContent {
        MessageContent::Parts(
            entries
                .iter()
                .map(|(kind, text)| MessagePart {
                    part_type: (*kind).to_string(),
                    text: (*text).to_string(),
                })
                .collect(),
        )
    }

    #[test]
    fn extract_handles_null_string_and_part_content() {
        assert_eq!(extract_compaction_message_text(None), "");

        let string_msg = CompactionMessage::text("user", "hello\nworld");
        assert_eq!(
            extract_compaction_message_text(Some(&string_msg)),
            "hello\nworld"
        );

        let parts_msg = CompactionMessage {
            role: "user".into(),
            content: parts(&[
                ("image", "not text"),
                ("text", "first"),
                ("text", "second"),
                ("audio", "also not text"),
            ]),
        };
        assert_eq!(
            extract_compaction_message_text(Some(&parts_msg)),
            "first\nsecond"
        );

        let no_text_parts = CompactionMessage {
            role: "assistant".into(),
            content: parts(&[("image", "x")]),
        };
        assert_eq!(extract_compaction_message_text(Some(&no_text_parts)), "");
    }

    #[test]
    fn estimate_tokens_uses_chars_over_four_with_cjk_at_one_to_one() {
        assert_eq!(estimate_tokens(""), 1);
        assert_eq!(estimate_tokens("   \n"), 1);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcde"), 2);
        assert_eq!(estimate_tokens("hello world"), 3);
        assert_eq!(estimate_tokens("こんにちは"), 5);
        assert_eq!(estimate_tokens("你好世界hello"), 6);
        assert_eq!(estimate_tokens("  padded  "), 2);
    }

    #[test]
    fn estimate_tokens_counts_utf16_units_like_ts() {
        // Five emoji are five surrogate pairs: 10 UTF-16 units, no CJK
        // code points -> ceil(10 / 4) = 3.
        assert_eq!(estimate_tokens("🎉🎉🎉🎉🎉"), 3);
        // Five CJK Ext-B scalars are five CJK points but ten UTF-16 units:
        // 5 + ceil((10 - 5) / 4) = 7.
        assert_eq!(estimate_tokens("𠀀𠀁𠀂𠀃𠀄"), 7);
        // One astral non-CJK scalar still costs one rounded-up token.
        assert_eq!(estimate_tokens("🎉"), 1);
    }

    #[test]
    fn estimate_message_list_tokens_sums_extracted_text() {
        let messages = vec![
            CompactionMessage::text("user", "abcde"), // 2
            CompactionMessage::text("assistant", ""), // 1
            CompactionMessage {
                role: "user".into(),
                content: parts(&[("image", "ignored"), ("text", "abcd"), ("text", "efgh")]),
                // "abcd\nefgh" = 9 chars -> ceil(9/4) = 3
            },
        ];
        assert_eq!(estimate_message_list_tokens(&messages), 6);
        assert_eq!(estimate_message_list_tokens(&[]), 0);
    }

    #[test]
    fn windows_group_two_messages_with_role_labels() {
        let messages = vec![
            CompactionMessage::text("user", "hello"),
            CompactionMessage::text("assistant", "world"),
            CompactionMessage::text("user", "  "), // skipped
            CompactionMessage::text("assistant", "third"),
            CompactionMessage::text("user", "fourth"),
        ];
        let windows =
            build_winnow_compaction_windows(&messages, DEFAULT_CHARACTER_NAME, WINNOW_WINDOW_SIZE);

        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].id, "w0");
        assert_eq!(windows[0].text, "User: hello\nAssistant: world");
        assert_eq!(windows[0].messages, messages[0..2]);
        assert_eq!(windows[1].id, "w1");
        assert_eq!(windows[1].text, "Assistant: third\nUser: fourth");
        assert_eq!(windows[1].messages, messages[3..5]);
    }

    #[test]
    fn windows_use_custom_character_name_and_trim_part_text() {
        let messages = vec![
            CompactionMessage {
                role: "assistant".into(),
                content: parts(&[("text", "  from the character  ")]),
            },
            CompactionMessage::text("tool", "tool result"),
        ];
        let windows = build_winnow_compaction_windows(&messages, "Nova", 2);
        assert_eq!(windows.len(), 1);
        assert_eq!(
            windows[0].text,
            "Nova: from the character\nNova: tool result"
        );
    }

    #[test]
    fn windows_flush_a_final_partial_group() {
        let messages = vec![
            CompactionMessage::text("user", "one"),
            CompactionMessage::text("assistant", "two"),
            CompactionMessage::text("user", "three"),
        ];
        let windows = build_winnow_compaction_windows(&messages, "Assistant", 2);
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[1].text, "User: three");
        assert_eq!(windows[1].messages.len(), 1);
    }

    #[test]
    fn cap_returns_candidates_unchanged_without_a_usable_threshold() {
        let messages = vec![
            CompactionMessage::text("user", "a"),
            CompactionMessage::text("assistant", "b"),
        ];
        assert_eq!(
            cap_winnow_survivors_to_budget(&messages, 0, None, WINNOW_TARGET_BUDGET_RATIO),
            messages
        );
        assert_eq!(
            cap_winnow_survivors_to_budget(&messages, 0, Some(0), WINNOW_TARGET_BUDGET_RATIO),
            messages
        );
        assert!(
            cap_winnow_survivors_to_budget(&[], 0, Some(20), WINNOW_TARGET_BUDGET_RATIO).is_empty()
        );
    }

    #[test]
    fn cap_walks_newest_first_and_restores_original_order() {
        // 1, 2, 3, 4 and 20 tokens respectively; budget = floor(20*.75) = 15.
        let messages = vec![
            CompactionMessage::text("user", &"a".repeat(80)), // 20, skipped
            CompactionMessage::text("assistant", "bbbbbbbb"), // 2
            CompactionMessage::text("user", "cccccccccccc"),  // 3
            CompactionMessage::text("assistant", "dddddddddddddddd"), // 4
        ];
        let kept =
            cap_winnow_survivors_to_budget(&messages, 0, Some(20), WINNOW_TARGET_BUDGET_RATIO);
        assert_eq!(kept, messages[1..]);
    }

    #[test]
    fn cap_accounts_for_base_tokens_and_can_return_empty() {
        let messages = vec![
            CompactionMessage::text("user", "a"),                // 1
            CompactionMessage::text("user", "cccccccccccc"),     // 3
            CompactionMessage::text("user", "dddddddddddddddd"), // 4
        ];
        // budget 15 - 12 base = 3: reverse walk keeps only the 3-token message.
        let kept =
            cap_winnow_survivors_to_budget(&messages, 12, Some(20), WINNOW_TARGET_BUDGET_RATIO);
        assert_eq!(kept, vec![messages[1].clone()]);

        // budget 3 - 3 base = 0: nothing fits.
        assert!(
            cap_winnow_survivors_to_budget(&messages, 3, Some(4), WINNOW_TARGET_BUDGET_RATIO)
                .is_empty()
        );

        // base larger than the budget also yields nothing.
        assert!(cap_winnow_survivors_to_budget(
            &messages,
            100,
            Some(20),
            WINNOW_TARGET_BUDGET_RATIO
        )
        .is_empty());
    }

    #[test]
    fn cap_honors_a_custom_target_ratio() {
        let messages = vec![
            CompactionMessage::text("user", "a"),
            CompactionMessage::text("user", "b"),
        ];
        // floor(10 * 0.15) = 1 token: only the newest message fits.
        let kept = cap_winnow_survivors_to_budget(&messages, 0, Some(10), 0.15);
        assert_eq!(kept, vec![messages[1].clone()]);
    }
}
