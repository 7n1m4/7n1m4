// SPDX-License-Identifier: GPL-3.0-or-later
//! Pure parsing seams ported from the TypeScript `tool-bridge` module.
//!
//! Deliberately no tool registry, daemon verb, wire type, IPC, SSE, or
//! MCP/ACP caller: this module only recognizes markers, leniently parses
//! JSON, and decodes key/value argument strings.

use serde_json::{json, Map, Value};

/// Outcome of [`recognize_tool_marker`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkerRecognition {
    /// No marker matched.
    None,
    /// A marker matched but could not be interpreted.
    Malformed {
        /// The exact substring that matched.
        matched_text: String,
        /// Human-readable reason for rejection.
        reason: String,
    },
    /// A usable tool-call marker.
    Candidate {
        /// The exact substring that matched.
        matched_text: String,
        /// Recognized tool name.
        tool_name: String,
        /// Raw, trimmed argument text.
        arguments_text: String,
    },
}

fn is_ascii_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn is_key_char(c: char) -> bool {
    is_ascii_word(c) || c == '-'
}

/// The JavaScript `\s` character class (used by the ported regexes).
fn is_js_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\n' | '\r' | '\u{000b}' | '\u{000c}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

fn skip_js_space(s: &str, mut i: usize) -> usize {
    while i < s.len() {
        let c = s[i..].chars().next().expect("char boundary");
        if is_js_space(c) {
            i += c.len_utf8();
        } else {
            break;
        }
    }
    i
}

/// Consume one or more `[\w-]` chars (JS `\w` is ASCII-only here).
fn take_key(s: &str, mut i: usize) -> Option<(String, usize)> {
    let start = i;
    while i < s.len() {
        let c = s[i..].chars().next().expect("char boundary");
        if is_key_char(c) {
            i += c.len_utf8();
        } else {
            break;
        }
    }
    if i == start {
        None
    } else {
        Some((s[start..i].to_string(), i))
    }
}

/// Lenient JSON parser with recovery for unclosed quotes, braces, brackets,
/// and truncated trailing keys. Returns an error only when both the primary
/// parse and the desperation cleanup fail.
pub fn try_parse_lenient_json(json: &str) -> Result<Value, String> {
    let mut sanitized = json.trim().to_string();
    if sanitized.is_empty() {
        return Ok(json!({}));
    }

    let open_quotes = sanitized.bytes().filter(|&b| b == b'"').count();
    if open_quotes % 2 != 0 {
        sanitized.push('"');
    }

    let open_braces = sanitized.bytes().filter(|&b| b == b'{').count();
    let close_braces = sanitized.bytes().filter(|&b| b == b'}').count();
    for _ in 0..open_braces.saturating_sub(close_braces) {
        sanitized.push('}');
    }

    let open_brackets = sanitized.bytes().filter(|&b| b == b'[').count();
    let close_brackets = sanitized.bytes().filter(|&b| b == b']').count();
    for _ in 0..open_brackets.saturating_sub(close_brackets) {
        sanitized.push(']');
    }

    match serde_json::from_str::<Value>(&sanitized) {
        Ok(value) => Ok(value),
        Err(original) => {
            if let Some(cut) = desperation_cut(&sanitized) {
                let mut desperation = sanitized[..cut].to_string();
                desperation.push('}');
                if let Ok(value) = serde_json::from_str::<Value>(&desperation) {
                    return Ok(value);
                }
            }
            Err(original.to_string())
        }
    }
}

/// Start index of the match of `,\s*"[\w-]+"[:\s]*"[^"]*$` in `s`, if any.
fn desperation_cut(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    for (comma, b) in bytes.iter().enumerate() {
        if *b != b',' {
            continue;
        }
        let mut p = skip_js_space(s, comma + 1);
        if bytes.get(p) != Some(&b'"') {
            continue;
        }
        p += 1;
        let key_start = p;
        while p < bytes.len() && is_key_char(bytes[p] as char) {
            p += 1;
        }
        if p == key_start || bytes.get(p) != Some(&b'"') {
            continue;
        }
        p += 1;
        while p < bytes.len() && (bytes[p] == b':' || is_js_space(bytes[p] as char)) {
            p += 1;
        }
        if bytes.get(p) != Some(&b'"') {
            continue;
        }
        p += 1;
        if bytes[p..].contains(&b'"') {
            continue;
        }
        return Some(comma);
    }
    None
}

/// The three capture groups of a matched marker dialect.
struct RawMarker {
    matched_text: String,
    group1: String,
    group2: String,
}

/// `<|([\w-]+):([^|]*?)(?:\|>|</tool_call>|$)>`
fn match_pipe(input: &str) -> Option<RawMarker> {
    const CLOSE: &str = "</tool_call>";
    for (start, _) in input.char_indices() {
        if !input[start..].starts_with("<|") {
            continue;
        }
        let Some((group1, mut p)) = take_key(input, start + 2) else {
            continue;
        };
        if !input[p..].starts_with(':') {
            continue;
        }
        p += 1;
        let g2_start = p;
        loop {
            if input[p..].starts_with("|>") {
                return Some(RawMarker {
                    matched_text: input[start..p + 2].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            if input[p..].starts_with(CLOSE) {
                return Some(RawMarker {
                    matched_text: input[start..p + CLOSE.len()].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            if p == input.len() {
                return Some(RawMarker {
                    matched_text: input[start..p].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            let c = input[p..].chars().next().expect("char boundary");
            if c == '|' {
                break;
            }
            p += c.len_utf8();
        }
    }
    None
}

/// `[call_tool:([\w-]+),([^\]]*?)(?:\]|</tool_call>|$)`
fn match_call_tool(input: &str) -> Option<RawMarker> {
    const PREFIX: &str = "[call_tool:";
    const CLOSE: &str = "</tool_call>";
    for (start, _) in input.char_indices() {
        if !input[start..].starts_with(PREFIX) {
            continue;
        }
        let Some((group1, mut p)) = take_key(input, start + PREFIX.len()) else {
            continue;
        };
        if !input[p..].starts_with(',') {
            continue;
        }
        p += 1;
        let g2_start = p;
        loop {
            if input[p..].starts_with(']') {
                return Some(RawMarker {
                    matched_text: input[start..p + 1].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            if input[p..].starts_with(CLOSE) {
                return Some(RawMarker {
                    matched_text: input[start..p + CLOSE.len()].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            if p == input.len() {
                return Some(RawMarker {
                    matched_text: input[start..p].to_string(),
                    group1,
                    group2: input[g2_start..p].to_string(),
                });
            }
            let c = input[p..].chars().next().expect("char boundary");
            if c == ']' {
                break;
            }
            p += c.len_utf8();
        }
    }
    None
}

/// `<tool_call>([\w-]+)\((.*?)\)</tool_call>` (dot matches newline).
fn match_function(input: &str) -> Option<RawMarker> {
    const PREFIX: &str = "<tool_call>";
    const CLOSE: &str = "</tool_call>";
    for (start, _) in input.char_indices() {
        if !input[start..].starts_with(PREFIX) {
            continue;
        }
        let Some((group1, mut p)) = take_key(input, start + PREFIX.len()) else {
            continue;
        };
        if !input[p..].starts_with('(') {
            continue;
        }
        p += 1;
        let g2_start = p;
        loop {
            if input[p..].starts_with(')') {
                let after = p + 1;
                if input[after..].starts_with(CLOSE) {
                    return Some(RawMarker {
                        matched_text: input[start..after + CLOSE.len()].to_string(),
                        group1,
                        group2: input[g2_start..p].to_string(),
                    });
                }
            }
            if p == input.len() {
                break;
            }
            let c = input[p..].chars().next().expect("char boundary");
            p += c.len_utf8();
        }
    }
    None
}

/// `<tool_call>(\{.*?\})</tool_call>` (dot matches newline).
fn match_json_tag(input: &str) -> Option<RawMarker> {
    const PREFIX: &str = "<tool_call>";
    const CLOSE: &str = "</tool_call>";
    for (start, _) in input.char_indices() {
        if !input[start..].starts_with(PREFIX) {
            continue;
        }
        let mut p = start + PREFIX.len();
        if !input[p..].starts_with('{') {
            continue;
        }
        let g1_start = p;
        p += 1;
        loop {
            if input[p..].starts_with('}') {
                let after = p + 1;
                if input[after..].starts_with(CLOSE) {
                    return Some(RawMarker {
                        matched_text: input[start..after + CLOSE.len()].to_string(),
                        group1: input[g1_start..=p].to_string(),
                        group2: String::new(),
                    });
                }
            }
            if p == input.len() {
                break;
            }
            let c = input[p..].chars().next().expect("char boundary");
            p += c.len_utf8();
        }
    }
    None
}

fn is_json_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|v| v != 0.0),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

/// Recognize bridged tool-call markers across four dialects, preserving the
/// original regex precedence: pipe, command, function, then JSON tag.
pub fn recognize_tool_marker(input: &str) -> MarkerRecognition {
    let Some(m) = match_pipe(input)
        .or_else(|| match_call_tool(input))
        .or_else(|| match_function(input))
        .or_else(|| match_json_tag(input))
    else {
        return MarkerRecognition::None;
    };

    let potential_json = m.group1.trim();
    if potential_json.starts_with('{') {
        match try_parse_lenient_json(potential_json) {
            Ok(parsed) => {
                let has_name = match &parsed {
                    Value::Object(obj) => obj.get("name").is_some_and(is_json_truthy),
                    _ => false,
                };
                if !has_name {
                    return MarkerRecognition::Malformed {
                        matched_text: m.matched_text,
                        reason: "Parsed JSON tool call tag missing required \"name\" property"
                            .to_string(),
                    };
                }
                let obj = parsed.as_object().expect("object with a name");
                let tool_name = match &obj["name"] {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                let arguments_text = match obj.get("arguments") {
                    Some(Value::String(s)) => s.clone(),
                    Some(Value::Null) | None => "{}".to_string(),
                    Some(other) => other.to_string(),
                };
                MarkerRecognition::Candidate {
                    matched_text: m.matched_text,
                    tool_name,
                    arguments_text,
                }
            }
            Err(e) => MarkerRecognition::Malformed {
                matched_text: m.matched_text,
                reason: format!("Failed to parse JSON tool call tag: {e}"),
            },
        }
    } else {
        MarkerRecognition::Candidate {
            matched_text: m.matched_text,
            tool_name: m.group1,
            arguments_text: m.group2.trim().to_string(),
        }
    }
}

/// Content and end offset of a `(?:"([^"]*)(?:"|$)|'([^']*)(?:'|$))` capture.
fn quoted_content(s: &str, quote_at: usize, quote: char) -> (&str, usize) {
    let content_start = quote_at + 1;
    let mut p = content_start;
    while p < s.len() {
        let c = s[p..].chars().next().expect("char boundary");
        if c == quote {
            return (&s[content_start..p], p + 1);
        }
        p += c.len_utf8();
    }
    (&s[content_start..], s.len())
}

fn parse_complex(raw: &str) -> Value {
    let sanitized = raw.replace('\'', "\"");
    let trimmed = sanitized.trim();
    let mut to_parse = trimmed.to_string();
    if to_parse.starts_with('{') && !to_parse.ends_with('}') {
        to_parse.push('}');
    }
    if to_parse.starts_with('[') && !to_parse.ends_with(']') {
        to_parse.push(']');
    }
    serde_json::from_str::<Value>(&to_parse).unwrap_or_else(|_| Value::String(raw.to_string()))
}

struct KvMatch {
    end: usize,
    key: String,
    value: Value,
}

/// Next match of the key/value regex at or after byte offset `from`.
fn next_kv(input: &str, from: usize) -> Option<KvMatch> {
    let bytes = input.as_bytes();
    for (offset, _) in input[from..].char_indices() {
        let start = from + offset;
        let mut p;
        if start == 0 {
            // The `^` alternative of `(?:^|[, \n\t]+)`.
            p = 0;
        } else {
            if !matches!(bytes[start], b',' | b' ' | b'\n' | b'\t') {
                continue;
            }
            p = start;
            while p < bytes.len() && matches!(bytes[p], b',' | b' ' | b'\n' | b'\t') {
                p += 1;
            }
        }

        let Some((key, after_key)) = take_key(input, p) else {
            continue;
        };
        p = skip_js_space(input, after_key);
        if !input[p..].starts_with(':') && !input[p..].starts_with('=') {
            continue;
        }
        p += 1;
        p = skip_js_space(input, p);

        if input[p..].starts_with('"') {
            let (content, end) = quoted_content(input, p, '"');
            return Some(KvMatch {
                end,
                key,
                value: Value::String(content.to_string()),
            });
        }
        if input[p..].starts_with('\'') {
            let (content, end) = quoted_content(input, p, '\'');
            return Some(KvMatch {
                end,
                key,
                value: Value::String(content.to_string()),
            });
        }

        let mut q = p;
        while q < bytes.len() && bytes[q].is_ascii_digit() {
            q += 1;
        }
        if q > p {
            let mut end = q;
            if bytes.get(q) == Some(&b'.') {
                let mut r = q + 1;
                while r < bytes.len() && bytes[r].is_ascii_digit() {
                    r += 1;
                }
                if r > q + 1 {
                    end = r;
                }
            }
            let number = input[p..end].parse::<f64>().unwrap_or(0.0);
            return Some(KvMatch {
                end,
                key,
                value: Value::from(number),
            });
        }

        if input[p..].starts_with("true") {
            return Some(KvMatch {
                end: p + 4,
                key,
                value: Value::Bool(true),
            });
        }
        if input[p..].starts_with("false") {
            return Some(KvMatch {
                end: p + 5,
                key,
                value: Value::Bool(false),
            });
        }

        if input[p..].starts_with('{') || input[p..].starts_with('[') {
            let mut end = p + 1;
            while end < bytes.len() && bytes[end] != b'\n' {
                end += 1;
            }
            return Some(KvMatch {
                end,
                key,
                value: parse_complex(&input[p..end]),
            });
        }
    }
    None
}

/// Equivalent of `.replace(/(\w+):/g, '"$1":')`.
fn quote_word_keys(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if is_ascii_word(bytes[i] as char) {
            let start = i;
            while i < bytes.len() && is_ascii_word(bytes[i] as char) {
                i += 1;
            }
            let run = &s[start..i];
            if bytes.get(i) == Some(&b':') {
                out.push('"');
                out.push_str(run);
                out.push_str("\":");
                i += 1;
            } else {
                out.push_str(run);
            }
        } else {
            let c = s[i..].chars().next().expect("char boundary");
            out.push(c);
            i += c.len_utf8();
        }
    }
    out
}

fn object_literal_fallback(arguments_text: &str, args: &mut Map<String, Value>) {
    let trimmed = arguments_text.trim();
    let mut cleaned = trimmed.to_string();
    if let Some(rest) = cleaned.strip_prefix('{') {
        cleaned = rest.to_string();
    }
    if let Some(rest) = cleaned.strip_suffix('}') {
        cleaned = rest.to_string();
    }
    cleaned = quote_word_keys(&cleaned).replace('\'', "\"");
    if trimmed.starts_with('{') && !cleaned.ends_with('}') {
        cleaned.push_str("\"}");
    }
    let wrapped = format!("{{{cleaned}}}");
    if let Ok(Value::Object(parsed)) = serde_json::from_str::<Value>(&wrapped) {
        for (k, v) in parsed {
            args.insert(k, v);
        }
    }
}

/// Decode a raw bridge argument string into key/value pairs, with an
/// object-literal fallback when no key/value pair is found.
pub fn parse_bridge_arguments(arguments_text: &str) -> Map<String, Value> {
    let mut args = Map::new();
    let mut from = 0;
    while let Some(m) = next_kv(arguments_text, from) {
        args.insert(m.key, m.value);
        from = m.end;
    }
    if args.is_empty() {
        object_literal_fallback(arguments_text, &mut args);
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_json_directly() {
        let input = r#"{"name": "test", "count": 42, "flag": true}"#;
        let result = try_parse_lenient_json(input).unwrap();
        assert_eq!(result["name"], json!("test"));
        assert_eq!(result["count"], json!(42));
        assert_eq!(result["flag"], json!(true));
    }

    #[test]
    fn returns_empty_object_for_empty_or_whitespace_strings() {
        assert_eq!(try_parse_lenient_json("").unwrap(), json!({}));
        assert_eq!(try_parse_lenient_json("   \n\t  ").unwrap(), json!({}));
    }

    #[test]
    fn recovers_from_unclosed_quotes_and_braces_at_end_of_stream() {
        let input = r#"{"name": "weather_lookup", "city": "Tokyo"#;
        let result = try_parse_lenient_json(input).unwrap();
        assert_eq!(result["city"], json!("Tokyo"));
        assert_eq!(result["name"], json!("weather_lookup"));
    }

    #[test]
    fn balances_unclosed_braces_and_brackets_when_closing_array_of_objects() {
        let input = r#"[{"id": 1}, {"id": 2"#;
        let result = try_parse_lenient_json(input).unwrap();
        assert_eq!(result.as_array().unwrap().len(), 2);
        assert_eq!(result[0], json!({"id": 1}));
        assert_eq!(result[1], json!({"id": 2}));
    }

    #[test]
    fn recovers_from_truncated_trailing_key_using_desperation_cleanup() {
        let input = r#"{"valid": 123, "partial_key": "unfinished"#;
        let result = try_parse_lenient_json(input).unwrap();
        assert!(result.is_object());
        assert_eq!(result["valid"], json!(123));
    }

    #[test]
    fn recognizes_standard_pipe_marker() {
        let input = "Here is the search: <|web_search:query=\"Vue 3 release\"|> and more text.";
        let m = recognize_tool_marker(input);
        assert_eq!(
            m,
            MarkerRecognition::Candidate {
                matched_text: "<|web_search:query=\"Vue 3 release\"|>".to_string(),
                tool_name: "web_search".to_string(),
                arguments_text: "query=\"Vue 3 release\"".to_string(),
            }
        );
    }

    #[test]
    fn recognizes_hybrid_pipe_marker() {
        let input = "<|calculator:expr=\"2 + 2\"</tool_call>";
        let m = recognize_tool_marker(input);
        assert_eq!(
            m,
            MarkerRecognition::Candidate {
                matched_text: "<|calculator:expr=\"2 + 2\"</tool_call>".to_string(),
                tool_name: "calculator".to_string(),
                arguments_text: "expr=\"2 + 2\"".to_string(),
            }
        );
    }

    #[test]
    fn recognizes_command_style_marker() {
        let input = "Let me call that for you: [call_tool:fetch_weather, location=\"London\"]";
        let m = recognize_tool_marker(input);
        assert_eq!(
            m,
            MarkerRecognition::Candidate {
                matched_text: "[call_tool:fetch_weather, location=\"London\"]".to_string(),
                tool_name: "fetch_weather".to_string(),
                arguments_text: "location=\"London\"".to_string(),
            }
        );
    }

    #[test]
    fn recognizes_function_style_marker() {
        let input = "<tool_call>get_time(timezone=\"EST\")</tool_call>";
        let m = recognize_tool_marker(input);
        assert_eq!(
            m,
            MarkerRecognition::Candidate {
                matched_text: "<tool_call>get_time(timezone=\"EST\")</tool_call>".to_string(),
                tool_name: "get_time".to_string(),
                arguments_text: "timezone=\"EST\"".to_string(),
            }
        );
    }

    #[test]
    fn recognizes_json_style_marker() {
        let input =
            r#"<tool_call>{"name": "query_db", "arguments": {"sql": "SELECT 1"}}</tool_call>"#;
        let m = recognize_tool_marker(input);
        match m {
            MarkerRecognition::Candidate {
                matched_text,
                tool_name,
                arguments_text,
            } => {
                assert_eq!(tool_name, "query_db");
                assert_eq!(
                    serde_json::from_str::<Value>(&arguments_text).unwrap(),
                    json!({"sql": "SELECT 1"})
                );
                assert_eq!(matched_text, input);
            }
            other => panic!("expected candidate, got {other:?}"),
        }
    }

    #[test]
    fn returns_malformed_when_json_style_marker_has_invalid_json_syntax() {
        let input = r#"<tool_call>{"name": unquoted_broken}</tool_call>"#;
        let m = recognize_tool_marker(input);
        match m {
            MarkerRecognition::Malformed {
                matched_text,
                reason,
            } => {
                assert_eq!(matched_text, input);
                assert!(!reason.is_empty());
            }
            other => panic!("expected malformed, got {other:?}"),
        }
    }

    #[test]
    fn returns_none_when_no_tool_marker_patterns_match() {
        assert_eq!(
            recognize_tool_marker("Just an ordinary conversational response."),
            MarkerRecognition::None
        );
        assert_eq!(
            recognize_tool_marker("Random brackets [like this] and {curly ones} without keywords"),
            MarkerRecognition::None
        );
    }

    #[test]
    fn captures_act_tags_as_candidate_for_runtime_resolution() {
        let m = recognize_tool_marker("<|ACT:smile|>");
        assert_eq!(
            m,
            MarkerRecognition::Candidate {
                matched_text: "<|ACT:smile|>".to_string(),
                tool_name: "ACT".to_string(),
                arguments_text: "smile".to_string(),
            }
        );
    }

    #[test]
    fn parses_key_value_pairs_with_double_and_single_quotes() {
        let args = parse_bridge_arguments("name=\"Alice\", nickname='Ally'");
        assert_eq!(
            Value::Object(args),
            json!({"name": "Alice", "nickname": "Ally"})
        );
    }

    #[test]
    fn parses_numeric_and_boolean_arguments() {
        let args = parse_bridge_arguments("count=5, price=19.99, available=true, archived=false");
        assert_eq!(args["count"].as_f64(), Some(5.0));
        assert_eq!(args["price"].as_f64(), Some(19.99));
        assert_eq!(args["available"].as_bool(), Some(true));
        assert_eq!(args["archived"].as_bool(), Some(false));
    }

    #[test]
    fn parses_nested_json_object_arguments() {
        let args = parse_bridge_arguments(r#"filter={"category": "books", "inStock": true}"#);
        assert_eq!(
            Value::Object(args),
            json!({"filter": {"category": "books", "inStock": true}})
        );
    }

    #[test]
    fn handles_unclosed_quote_truncation_gracefully() {
        let args = parse_bridge_arguments("query=\"how to parse json in type");
        assert_eq!(args["query"].as_str(), Some("how to parse json in type"));
    }

    #[test]
    fn falls_back_to_json_object_parser_for_object_literal_arguments() {
        let args = parse_bridge_arguments(r#"{ query: "test query", limit: 10 }"#);
        assert_eq!(
            Value::Object(args),
            json!({"query": "test query", "limit": 10.0})
        );
    }

    #[test]
    fn returns_empty_object_when_arguments_cannot_be_parsed_or_are_empty() {
        assert!(parse_bridge_arguments("").is_empty());
        assert!(parse_bridge_arguments("   ").is_empty());
    }
}
