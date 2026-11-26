// SPDX-License-Identifier: GPL-3.0-or-later

//! Daemon-side façade over the `anima-channel` Wave 0 event bus.
//!
//! Every daemon service publishes through [`EventPublisher`] instead of
//! importing channel wire types directly. The wrapper builds the typed
//! payloads (with `seq`/`ts_ms` left at `0` — [`EventBus::publish`] stamps the
//! process-wide monotonic sequence and unix-millisecond timestamp) and fans
//! out to subscribed connection lanes. Publishing never touches a socket.
//!
//! One publisher is owned by [`crate::gateway::Gateway`] and cloned into each
//! bind and each D-Bus handler, so every clone shares the same bus and the
//! same coarse-health dedupe state. This is what keeps rebinds from emitting
//! stale events and stops `core.status` RPCs from echoing an unchanged health
//! snapshot as a fresh "change".

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anima_channel::{
    ChannelServer, EventBus, EventPayload, EventTopic, GatewayEvent, CANONICAL_EMOTION_KEYS,
};
use serde_json::Value;

/// Neutral actor used when a cue arrives without an explicit `actor=` field.
/// The daemon has no card/actor registry on this path yet; renderers treat the
/// id as an opaque routing key, never as a morph name or DSL command.
const DEFAULT_ACTOR_ID: &str = "default";
/// Bound the incremental marker buffer so an unterminated model marker cannot
/// grow publisher state without limit. Markers longer than this are dropped.
const MAX_PENDING_CUE_LEN: usize = 256;

/// Broad class of an `emotion.tag` cue, mirrored from the channel wire
/// vocabulary so a future audio/expression service never imports
/// `anima_channel::CueKind` (or any channel type) to publish a cue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DaemonCueKind {
    /// Facial expression / emotion key.
    Emotion,
    /// Body motion — must not be dispatched to a facial morph.
    Motion,
    /// Visual effect — must not be dispatched to a facial morph.
    Vfx,
}

impl From<DaemonCueKind> for anima_channel::CueKind {
    fn from(value: DaemonCueKind) -> Self {
        match value {
            DaemonCueKind::Emotion => Self::Emotion,
            DaemonCueKind::Motion => Self::Motion,
            DaemonCueKind::Vfx => Self::Vfx,
        }
    }
}

/// Last published coarse-health snapshot: `(core_available, store_available,
/// store_health)`. Compared by value so a repeated, unchanged health reading
/// is not reported as a new `status.changed` event.
type StatusKey = (bool, bool, String);

/// Cloneable publisher handle shared by all daemon services.
///
/// Clones share both the underlying [`EventBus`] and the dedupe state (via
/// `Arc`), so publishing from one clone is visible to every subscriber lane
/// registered on the server's bus.
#[derive(Clone)]
pub struct EventPublisher {
    bus: EventBus,
    last_status: Arc<Mutex<Option<StatusKey>>>,
    /// Incremental ACT-marker state shared by all clones, keyed by the
    /// publishing turn so concurrent turns of one session cannot parse into
    /// one another's `<|ACT:…|>` buffer. Entries are removed on a terminal
    /// delta or when the turn is cancelled/errored.
    cue_parsers: Arc<Mutex<HashMap<TurnKey, CueParser>>>,
}

/// Identity of one assistant turn. `message_id` comes from the token stream;
/// a terminal cancel/error before the first delta carries an empty id, so
/// `(session_id, message_id)` identifies that terminal notification.
type TurnKey = (String, String);

/// One renderer-neutral acting cue extracted from a streamed ACT marker.
#[derive(Debug, Clone, PartialEq)]
struct ActCue {
    actor_id: String,
    kind: DaemonCueKind,
    tag: String,
    intensity: f32,
    duration_ms: Option<u64>,
}

/// Carries an incomplete `<|ACT:…|>` tail across token deltas.
#[derive(Debug, Default)]
struct CueParser {
    pending: String,
}

impl CueParser {
    fn feed(&mut self, delta: &str, final_: bool) -> Vec<ActCue> {
        let mut buf = std::mem::take(&mut self.pending);
        buf.push_str(delta);
        let mut cues = Vec::new();
        let mut cursor = 0;

        while let Some(rel) = buf[cursor..].find("<|ACT:") {
            let start = cursor + rel;
            let body_start = start + "<|ACT:".len();
            match buf[body_start..].find("|>") {
                Some(end_rel) => {
                    let end = body_start + end_rel;
                    cues.extend(parse_act_body(&buf[body_start..end]));
                    cursor = end + 2;
                }
                None => {
                    // Unterminated marker: keep the tail only while the stream
                    // continues and the text stays within the bounded buffer.
                    if !final_ {
                        let tail = &buf[start..];
                        if tail.len() <= MAX_PENDING_CUE_LEN {
                            self.pending = tail.to_string();
                        }
                    }
                    break;
                }
            }
        }
        cues
    }
}

/// Parse the official short ACT form: `<|ACT:emotion="happy",intensity="0.8",duration="3"|>`.
/// The JSON-chaining form is intentionally out of scope; it is skipped rather
/// than guessed at. Only bounded, identifier-shaped tags become events.
fn parse_act_body(body: &str) -> Vec<ActCue> {
    let mut kind_and_tag: Vec<(DaemonCueKind, String)> = Vec::new();
    let mut actor_id = DEFAULT_ACTOR_ID.to_string();
    let mut intensity = 0.7_f32;
    let mut duration_ms = None;

    for field in body.split(',') {
        let Some((key, raw_value)) = field.split_once('=') else {
            continue;
        };
        let value = raw_value.trim().trim_matches(['"', '\'']).trim();
        match key.trim().to_ascii_lowercase().as_str() {
            "emotion" | "motion" | "vfx" => {
                let kind = match key.trim().to_ascii_lowercase().as_str() {
                    "motion" => DaemonCueKind::Motion,
                    "vfx" => DaemonCueKind::Vfx,
                    _ => DaemonCueKind::Emotion,
                };
                if let Some(tag) = normalize_cue_tag(value, kind) {
                    kind_and_tag.push((kind, tag));
                }
            }
            "actor" => {
                if is_safe_tag(value) {
                    actor_id = value.to_ascii_lowercase();
                }
            }
            "intensity" => {
                if let Ok(parsed) = value.parse::<f32>() {
                    if parsed.is_finite() {
                        intensity = parsed.clamp(0.0, 1.0);
                    }
                }
            }
            // Short-form `duration="3"` is seconds per the ACT spec; the wire
            // field is milliseconds. `duration_ms` is accepted as an explicit
            // millisecond override.
            "duration" => {
                if let Ok(seconds) = value.parse::<f32>() {
                    if seconds.is_finite() && (0.0..=60.0).contains(&seconds) {
                        duration_ms = Some((seconds * 1000.0).round() as u64);
                    }
                }
            }
            "duration_ms" => {
                if let Ok(ms) = value.parse::<u64>() {
                    duration_ms = Some(ms.min(60_000));
                }
            }
            _ => {}
        }
    }

    kind_and_tag
        .into_iter()
        .map(|(kind, tag)| ActCue {
            actor_id: actor_id.clone(),
            kind,
            tag,
            intensity,
            duration_ms,
        })
        .collect()
}

fn is_safe_tag(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn normalize_cue_tag(value: &str, kind: DaemonCueKind) -> Option<String> {
    if !is_safe_tag(value) {
        return None;
    }
    let lower = value.to_ascii_lowercase();
    if kind == DaemonCueKind::Emotion {
        if let Some(canonical) = CANONICAL_EMOTION_KEYS.iter().find(|key| **key == lower) {
            return Some((*canonical).to_string());
        }
    }
    Some(lower)
}

impl std::fmt::Debug for EventPublisher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EventPublisher")
            .field("subscribers", &self.bus.subscriber_count())
            .field("last_status", &self.last_status)
            .finish_non_exhaustive()
    }
}

impl EventPublisher {
    /// Wrap an externally owned bus.
    pub fn new(bus: EventBus) -> Self {
        Self {
            bus,
            last_status: Arc::new(Mutex::new(None)),
            cue_parsers: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Build a publisher over the bus a `ChannelServer` is configured with.
    /// Prefer this when a server already owns the bus; the gateway owns the
    /// canonical bus and injects it into every bind, so both handles agree.
    pub fn from_server(server: &ChannelServer) -> Self {
        Self::new(server.event_bus())
    }

    /// Borrow the underlying bus (for diagnostics and server injection).
    pub fn bus(&self) -> &EventBus {
        &self.bus
    }

    /// Coarse count of live subscriber lanes (no per-topic query exists).
    pub fn subscriber_count(&self) -> usize {
        self.bus.subscriber_count()
    }

    fn publish(&self, topic: EventTopic, data: EventPayload, id: Option<Value>) {
        let event = GatewayEvent::new(topic, data);
        let event = match id {
            Some(id) => event.with_id(id),
            None => event,
        };
        self.bus.publish(event);
    }

    /// Publish a coarse, secret-free core-health snapshot.
    ///
    /// Returns `true` when the snapshot was actually published and `false`
    /// when it matched the last published value (a misleading repeat). The
    /// payload mirrors `CoreStatusReply`: no tokens, paths, prompts or config.
    pub fn status_changed(
        &self,
        core_available: bool,
        store_available: bool,
        store_health: impl Into<String>,
        id: Option<Value>,
    ) -> bool {
        let store_health = store_health.into();
        let key: StatusKey = (core_available, store_available, store_health.clone());
        {
            let mut last = self
                .last_status
                .lock()
                .expect("event publisher status lock poisoned");
            if last.as_ref() == Some(&key) {
                return false;
            }
            *last = Some(key);
        }
        self.publish(
            EventTopic::StatusChanged,
            EventPayload::StatusChanged(anima_channel::StatusChangedData {
                core_available,
                store_available,
                store_health,
                seq: 0,
                ts_ms: 0,
            }),
            id,
        );
        true
    }

    /// Publish a notice that a settings section changed on the daemon side.
    ///
    /// Carries only the section name: clients must re-read through
    /// `settings.get` rather than trusting values in the event.
    pub fn settings_changed(&self, section: impl Into<String>) {
        self.publish(
            EventTopic::SettingsChanged,
            EventPayload::SettingsChanged(anima_channel::SettingsChangedData {
                section: section.into(),
                seq: 0,
                ts_ms: 0,
            }),
            None,
        );
    }

    /// Publish a connectivity/availability transition for `subject`.
    pub fn presence_changed(
        &self,
        subject: impl Into<String>,
        state: impl Into<String>,
        id: Option<Value>,
    ) {
        self.publish(
            EventTopic::PresenceChanged,
            EventPayload::PresenceChanged(anima_channel::PresenceChangedData {
                subject: subject.into(),
                state: state.into(),
                seq: 0,
                ts_ms: 0,
            }),
            id,
        );
    }

    /// Publish one streamed chat token and any renderer-neutral ACT cues that
    /// the token completes. The gateway's `chat.send` pump already calls this
    /// on every real LLM delta, so ACT markers in production model output
    /// become `emotion.tag` events without the gateway importing wire types.
    ///
    /// The raw token is still published verbatim; only the derived cue is
    /// normalized, bounded and secret-free (identifier-shaped tag, no text,
    /// no provider data). A marker split across deltas is buffered until its
    /// `|>` terminator arrives; an unterminated marker is dropped at `final_`
    /// or on an explicit `cancelled`/`error` terminal reason.
    pub fn token_delta(
        &self,
        session_id: impl Into<String>,
        message_id: impl Into<String>,
        delta: impl Into<String>,
        index: u64,
        final_: bool,
        reason: Option<String>,
        id: Option<Value>,
    ) {
        let session_id = session_id.into();
        let message_id = message_id.into();
        let delta = delta.into();
        self.publish(
            EventTopic::TokenDelta,
            EventPayload::TokenDelta(anima_channel::TokenDeltaData {
                session_id: session_id.clone(),
                message_id: message_id.clone(),
                delta: delta.clone(),
                index,
                final_,
                seq: 0,
                ts_ms: 0,
                reason: reason.clone(),
            }),
            id.clone(),
        );

        // Explicit error/cancel deltas are terminal too: they may arrive
        // without `final_`, and must not strand a half-parsed marker.
        let terminal = final_ || matches!(reason.as_deref(), Some("cancelled" | "error"));
        let turn: TurnKey = (session_id.clone(), message_id);
        let cues = {
            let mut parsers = self
                .cue_parsers
                .lock()
                .expect("event publisher cue parser lock poisoned");
            let cues = parsers
                .entry(turn.clone())
                .or_default()
                .feed(&delta, terminal);
            if terminal {
                if reason.as_deref() == Some("cancelled") && turn.1.is_empty() {
                    // `chat.cancel` publishes a session-level terminal with no
                    // message id: clear every turn of that session.
                    parsers.retain(|(session, _), _| session != &turn.0);
                } else {
                    parsers.remove(&turn);
                }
            }
            cues
        };
        for cue in cues {
            self.emotion_tag(
                Some(session_id.clone()),
                cue.actor_id,
                cue.tag,
                cue.kind,
                cue.intensity,
                cue.duration_ms,
                id.clone(),
            );
        }
    }

    /// Publish one discrete expression cue for an actor.
    ///
    /// `session_id` is `Some` for cues derived from a chat turn; renderers use
    /// it to ignore cues from sessions other than the active one.
    pub fn emotion_tag(
        &self,
        session_id: Option<String>,
        actor_id: impl Into<String>,
        tag: impl Into<String>,
        kind: DaemonCueKind,
        intensity: f32,
        duration_ms: Option<u64>,
        id: Option<Value>,
    ) {
        self.publish(
            EventTopic::EmotionTag,
            EventPayload::EmotionTag(anima_channel::EmotionTagData {
                session_id,
                actor_id: actor_id.into(),
                tag: tag.into(),
                kind: kind.into(),
                intensity,
                duration_ms,
                seq: 0,
                ts_ms: 0,
            }),
            id,
        );
    }

    /// Publish one lip-sync RMS sample for an actor.
    pub fn lip_sync_rms(&self, actor_id: impl Into<String>, level: f32, id: Option<Value>) {
        self.publish(
            EventTopic::LipSyncRms,
            EventPayload::LipSyncRms(anima_channel::LipSyncRmsData {
                actor_id: actor_id.into(),
                level,
                seq: 0,
                ts_ms: 0,
            }),
            id,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anima_channel::EventLane;

    #[test]
    fn settings_changed_publishes_section_without_values() {
        let (publisher, lane) = subscribed_publisher();
        publisher.settings_changed("captions");
        let event = lane.drain().into_iter().next().expect("settings event");
        assert_eq!(event.topic, EventTopic::SettingsChanged);
        let json = serde_json::to_value(&event.data).unwrap();
        assert_eq!(json["section"], "captions");
        assert!(json.get("settings").is_none());
    }

    fn subscribed_publisher() -> (EventPublisher, EventLane) {
        let bus = EventBus::with_defaults();
        let lane = bus.new_lane();
        lane.subscribe(EventTopic::ALL);
        bus.register_lane(&lane);
        (EventPublisher::new(bus), lane)
    }

    #[test]
    fn status_changed_maps_fields_bus_stamps_seq_ts_and_has_no_secrets() {
        let (publisher, lane) = subscribed_publisher();
        assert!(publisher.status_changed(true, true, "ok", None));
        assert_eq!(publisher.subscriber_count(), 1);

        let drained = lane.drain();
        assert_eq!(drained.len(), 1);
        let event = &drained[0];
        assert_eq!(event.topic, EventTopic::StatusChanged);
        assert!(event.id.is_none());
        let EventPayload::StatusChanged(data) = &event.data else {
            panic!("expected StatusChanged payload, got {:?}", event.data);
        };
        assert!(data.core_available);
        assert!(data.store_available);
        assert_eq!(data.store_health, "ok");
        assert_eq!(data.seq, 0, "first event starts at sequence zero");
        assert!(data.ts_ms > 0, "bus must stamp a unix-millisecond ts");

        let obj = serde_json::to_value(&event.data).unwrap();
        let obj = obj.as_object().unwrap();
        for forbidden in [
            "authToken",
            "auth_token",
            "dbusToken",
            "apiKey",
            "api_key",
            "secret",
            "prompt",
            "config",
            "token",
            "path",
        ] {
            assert!(!obj.contains_key(forbidden), "forbidden field: {forbidden}");
        }
    }

    #[test]
    fn status_changed_dedupes_until_the_snapshot_changes() {
        let (publisher, lane) = subscribed_publisher();
        assert!(publisher.status_changed(true, true, "ok", None));
        assert!(
            !publisher.status_changed(true, true, "ok", None),
            "unchanged health must not be re-emitted"
        );
        assert_eq!(lane.len(), 1);

        assert!(publisher.status_changed(false, false, "unavailable", None));
        let drained = lane.drain();
        assert_eq!(drained.len(), 2);
        let EventPayload::StatusChanged(data) = &drained[1].data else {
            panic!("expected StatusChanged payload");
        };
        assert!(!data.core_available);
        assert_eq!(data.store_health, "unavailable");
        assert_eq!(data.seq, 1, "sequence advances across distinct events");
    }

    #[test]
    fn presence_changed_maps_subject_and_state_with_correlation_id() {
        let (publisher, lane) = subscribed_publisher();
        let id = serde_json::json!({ "turn": 7 });
        publisher.presence_changed("gateway", "online", Some(id.clone()));
        let drained = lane.drain();
        assert_eq!(drained.len(), 1);
        let event = &drained[0];
        assert_eq!(event.topic, EventTopic::PresenceChanged);
        assert_eq!(event.id, Some(id));
        let EventPayload::PresenceChanged(data) = &event.data else {
            panic!("expected PresenceChanged payload");
        };
        assert_eq!(data.subject, "gateway");
        assert_eq!(data.state, "online");
        assert_eq!(data.seq, 0);
        assert!(data.ts_ms > 0);
    }

    #[test]
    fn token_delta_emotion_tag_and_lip_sync_rms_map_to_their_topics() {
        let (publisher, lane) = subscribed_publisher();
        publisher.token_delta("session", "message", "hi", 2, true, None, None);
        publisher.emotion_tag(
            None,
            "actor",
            "happy",
            DaemonCueKind::Motion,
            0.5,
            Some(120),
            None,
        );
        publisher.lip_sync_rms("actor", 0.25, None);

        let drained = lane.drain();
        assert_eq!(drained.len(), 3);
        assert_eq!(drained[0].topic, EventTopic::TokenDelta);
        let EventPayload::TokenDelta(token) = &drained[0].data else {
            panic!("expected TokenDelta");
        };
        assert_eq!(token.session_id, "session");
        assert_eq!(token.message_id, "message");
        assert_eq!(token.delta, "hi");
        assert_eq!(token.index, 2);
        assert!(token.final_);
        let obj = serde_json::to_value(&drained[0].data).unwrap();
        assert_eq!(obj["final"], true, "wire name is `final`");

        assert_eq!(drained[1].topic, EventTopic::EmotionTag);
        let EventPayload::EmotionTag(tag) = &drained[1].data else {
            panic!("expected EmotionTag");
        };
        assert_eq!(tag.actor_id, "actor");
        assert_eq!(tag.tag, "happy");
        assert_eq!(tag.kind, anima_channel::CueKind::Motion);
        assert_eq!(tag.intensity, 0.5);
        assert_eq!(tag.duration_ms, Some(120));
        assert!(tag.session_id.is_none());

        assert_eq!(drained[2].topic, EventTopic::LipSyncRms);
        let EventPayload::LipSyncRms(rms) = &drained[2].data else {
            panic!("expected LipSyncRms");
        };
        assert_eq!(rms.actor_id, "actor");
        assert_eq!(rms.level, 0.25);

        for (i, event) in drained.iter().enumerate() {
            assert_eq!(event.data.topic(), event.topic);
            let (seq, ts_ms) = match &event.data {
                EventPayload::TokenDelta(d) => (d.seq, d.ts_ms),
                EventPayload::EmotionTag(d) => (d.seq, d.ts_ms),
                EventPayload::LipSyncRms(d) => (d.seq, d.ts_ms),
                EventPayload::PresenceChanged(d) => (d.seq, d.ts_ms),
                EventPayload::SettingsChanged(d) => (d.seq, d.ts_ms),
                EventPayload::StatusChanged(d) => (d.seq, d.ts_ms),
            };
            assert_eq!(seq, i as u64);
            assert!(ts_ms > 0);
        }
    }

    #[test]
    fn token_delta_carries_terminal_reason_and_omits_it_for_streaming() {
        let (publisher, lane) = subscribed_publisher();
        publisher.token_delta("s1", "m1", "partial", 0, false, None, None);
        for reason in ["complete", "cancelled", "error"] {
            publisher.token_delta("s1", "m1", "", 1, true, Some(reason.into()), None);
        }

        let drained = lane.drain();
        let reasons: Vec<Option<String>> = drained
            .iter()
            .map(|event| match &event.data {
                EventPayload::TokenDelta(data) => data.reason.clone(),
                other => panic!("expected TokenDelta, got {:?}", other),
            })
            .collect();
        assert_eq!(
            reasons,
            vec![
                None,
                Some("complete".into()),
                Some("cancelled".into()),
                Some("error".into())
            ]
        );
        let wire = serde_json::to_value(&drained[1].data).unwrap();
        assert_eq!(wire["reason"], "complete");
        let wire = serde_json::to_value(&drained[0].data).unwrap();
        assert!(!wire.as_object().unwrap().contains_key("reason"));
    }

    #[test]
    fn concurrent_turns_of_one_session_keep_split_act_markers_separate() {
        let (publisher, lane) = subscribed_publisher();
        // Two turns of the same session interleave while each marker is split
        // across deltas. A session-keyed parser concatenates the tails and
        // emits nothing; a turn-keyed parser emits both cues in completion
        // order.
        publisher.token_delta("s1", "m1", "<|ACT:emotion=\"calm\"", 0, false, None, None);
        publisher.token_delta("s1", "m2", "<|ACT:motion=\"wave\"", 0, false, None, None);
        publisher.token_delta("s1", "m1", "|>", 1, false, None, None);
        publisher.token_delta("s1", "m2", "|>", 1, true, None, None);

        let drained = lane.drain();
        let cues: Vec<_> = drained
            .iter()
            .filter_map(|event| match &event.data {
                EventPayload::EmotionTag(data) => Some(data.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(cues.len(), 2, "each turn must parse its own marker");
        assert_eq!(cues[0].tag, "calm");
        assert_eq!(cues[1].tag, "wave");
        let order: Vec<_> = drained
            .iter()
            .map(|event| match &event.data {
                EventPayload::TokenDelta(data) => {
                    format!("token:{}:{}", data.message_id, data.delta)
                }
                EventPayload::EmotionTag(data) => format!("cue:{}", data.tag),
                other => panic!("unexpected event: {other:?}"),
            })
            .collect();
        assert_eq!(
            order,
            vec![
                "token:m1:<|ACT:emotion=\"calm\"",
                "token:m2:<|ACT:motion=\"wave\"",
                "token:m1:|>",
                "cue:calm",
                "token:m2:|>",
                "cue:wave",
            ],
            "token events keep their order; a cue follows the delta that completes it"
        );
    }

    #[test]
    fn explicit_error_and_cancel_clear_the_turns_parser_state() {
        let publisher = {
            let bus = EventBus::with_defaults();
            EventPublisher::new(bus)
        };
        // An unterminated marker is buffered by the error turn; a later turn
        // with the same session and message id must not inherit that tail.
        publisher.token_delta("s1", "m1", "<|ACT:emotion=\"angry\"", 0, false, None, None);
        publisher.token_delta("s1", "m1", "", 1, false, Some("error".into()), None);
        publisher.token_delta("s1", "m1", "<|ACT:motion=\"wave\"|>", 0, false, None, None);
        publisher.token_delta("s1", "m1", "", 1, false, Some("cancelled".into()), None);
        assert!(
            publisher
                .cue_parsers
                .lock()
                .expect("cue parser lock poisoned")
                .is_empty(),
            "error/cancel terminal paths must not strand parser state"
        );
    }

    #[test]
    fn session_cancel_clears_all_inflight_turns_of_that_session() {
        let publisher = EventPublisher::new(EventBus::with_defaults());
        publisher.token_delta("s1", "m1", "<|ACT:emotion=\"calm\"", 0, false, None, None);
        publisher.token_delta("s1", "m2", "<|ACT:motion=\"wave\"", 0, false, None, None);
        publisher.token_delta("other", "m3", "<|ACT:vfx=\"fire\"", 0, false, None, None);
        // `chat.cancel` has no message id: it must clear the buffered turns
        // of s1 without touching another session.
        publisher.token_delta("s1", "", "", 0, true, Some("cancelled".into()), None);
        let parsers = publisher
            .cue_parsers
            .lock()
            .expect("cue parser lock poisoned");
        assert_eq!(parsers.len(), 1, "only the other session may remain");
        assert!(parsers.keys().all(|(session, _)| session == "other"));
    }

    #[test]
    fn act_cues_route_by_kind_and_unterminated_markers_are_dropped() {
        let (publisher, lane) = subscribed_publisher();
        publisher.token_delta(
            "s1",
            "m1",
            "<|ACT:motion=\"wave\",duration=\"2\"|>",
            0,
            false,
            None,
            None,
        );
        publisher.token_delta("s1", "m1", "<|ACT:vfx=\"fire\"|>", 1, false, None, None);
        // A complete marker from a second session proves the cue inherits the
        // emitting turn's id rather than a hardcoded first-session value.
        publisher.token_delta("s2", "m2", "<|ACT:emotion=\"calm\"|>", 0, false, None, None);
        publisher.token_delta("s2", "m2", "<|ACT:emotion=\"angry\"", 1, false, None, None);
        publisher.token_delta("s2", "m2", "", 2, true, None, None);

        let drained = lane.drain();
        let cues: Vec<_> = drained
            .iter()
            .filter_map(|event| match &event.data {
                EventPayload::EmotionTag(data) => Some(data),
                _ => None,
            })
            .collect();
        assert_eq!(cues.len(), 3, "unterminated marker must not emit a cue");
        assert_eq!(cues[0].tag, "wave");
        assert_eq!(cues[0].session_id.as_deref(), Some("s1"));
        assert_eq!(cues[0].kind, anima_channel::CueKind::Motion);
        assert_eq!(cues[0].duration_ms, Some(2000));
        assert_eq!(cues[1].tag, "fire");
        assert_eq!(cues[1].session_id.as_deref(), Some("s1"));
        assert_eq!(cues[1].kind, anima_channel::CueKind::Vfx);
        assert_eq!(cues[2].tag, "calm");
        assert_eq!(cues[2].session_id.as_deref(), Some("s2"));
        assert_eq!(cues[2].kind, anima_channel::CueKind::Emotion);
    }

    #[test]
    fn from_server_publishes_onto_the_servers_bus() {
        let config = anima_channel::ChannelConfig::healed();
        let server = anima_channel::ChannelServer::bind("127.0.0.1", 0, &config).unwrap();
        let publisher = EventPublisher::from_server(&server);
        let lane = server.event_bus().new_lane();
        lane.subscribe(EventTopic::ALL);
        server.event_bus().register_lane(&lane);

        publisher.presence_changed("screen", "offline", None);
        let drained = lane.drain();
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].topic, EventTopic::PresenceChanged);
    }

    #[test]
    fn all_cue_kinds_map_without_importing_wire_types_at_call_sites() {
        assert_eq!(
            anima_channel::CueKind::from(DaemonCueKind::Emotion),
            anima_channel::CueKind::Emotion
        );
        assert_eq!(
            anima_channel::CueKind::from(DaemonCueKind::Motion),
            anima_channel::CueKind::Motion
        );
        assert_eq!(
            anima_channel::CueKind::from(DaemonCueKind::Vfx),
            anima_channel::CueKind::Vfx
        );
    }
}
