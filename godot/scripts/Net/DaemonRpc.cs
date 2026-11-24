using System;
using System.Collections.Generic;
using System.Text.Json;

namespace AnimaPet.Net;

/// <summary>
/// Wire names and payload shapes for the daemon's typed RPC action family
/// (<c>crates/anima-daemon/src/gateway.rs</c> handler registry) plus the
/// transport-level ping frame (<c>crates/anima-channel</c> accepts
/// <c>{"type":"ping"}</c> and answers <c>{"type":"pong"}</c>).
///
 /// Kept pure managed so frame construction can be unit-tested without a
/// socket; <see cref="DaemonClient.SendRpc"/> is the only transport consumer.
/// </summary>
internal static class DaemonRpc
{
    internal const string ChatSend = "chat.send";
    internal const string ChatCancel = "chat.cancel";
    internal const string ChatHistory = "chat.history";
    internal const string CoreStatus = "core.status";
    internal const string ProvidersList = "providers.list";
    internal const string SettingsGet = "settings.get";
    internal const string SettingsSet = "settings.set";
    internal const string VaultStatus = "vault.status";
    internal const string StmmList = "stmm.list";
    internal const string StmmRebuild = "stmm.rebuild";
    internal const string JournalAppend = "journal.append";
    internal const string JournalSearch = "journal.search";
    internal const string RetrievalStatus = "retrieval.status";
    internal const string CardsList = "cards.list";
    internal const string CardsGet = "cards.get";
    internal const string CardsImport = "cards.import";
    internal const string SessionsList = "sessions.list";
    internal const string SessionsExport = "sessions.export";
    internal const string SessionsImport = "sessions.import";

    /// <summary>Every RPC action the Godot client claims to support.</summary>
    internal static readonly string[] AllActions =
    {
        ChatSend, ChatCancel, CoreStatus, ProvidersList, SettingsGet, SettingsSet,
        VaultStatus, StmmList, StmmRebuild, JournalAppend, JournalSearch,
        RetrievalStatus, CardsList, CardsGet, CardsImport, SessionsList, SessionsExport,
        ChatHistory, SessionsImport,
    };

    private const string RpcType = "rpc";
    private const string EventType = "event";
    private const string PingType = "ping";
    private const string PongType = "pong";
    private const string ErrorType = "error";

    /// <summary>Serializes to <c>{}</c>; Rust dispatch treats omitted payloads as empty objects.</summary>
    private static readonly object EmptyPayload = new Dictionary<string, object>();

    /// <summary>Build a client RPC frame. <paramref name="id"/> is echoed by the daemon.</summary>
    internal static object Frame(string action, object? payload, object? id) =>
        new { type = RpcType, action, payload = payload ?? EmptyPayload, id };

    /// <summary>Build the transport heartbeat frame (not an RPC).</summary>
    internal static object PingFrame() => new { type = PingType };

    internal static object SessionPayload(string sessionId) => new { session_id = sessionId ?? string.Empty };

    internal static object ChatSendPayload(string sessionId, string content) =>
        new { sessionId = sessionId ?? string.Empty, content = content ?? string.Empty };

    /// <summary>
    /// <c>chat.history</c> request payload. The daemon reads the snake_case
    /// <c>session_id</c> key (<c>crates/anima-daemon/src/gateway.rs:938</c>),
    /// so this reuses <see cref="SessionPayload"/>; a missing/empty id is
    /// rejected by the daemon with <c>missing session_id</c>.
    /// </summary>
    internal static object ChatHistoryPayload(string sessionId) => SessionPayload(sessionId);

    /// <summary>
    /// <c>sessions.import</c> request payload: an exported JSONL snapshot as a
    /// single string under <c>jsonl</c> (<c>gateway.rs:1155</c>). An empty
    /// string is sent as-is; the daemon reports the parse/import outcome in a
    /// <c>SessionImportReply</c> (<c>status</c> + <c>revision</c>).
    /// </summary>
    internal static object SessionsImportPayload(string jsonl) => new { jsonl = jsonl ?? string.Empty };

    internal static object SectionPayload(string section) =>
        new { section = section ?? string.Empty };

    internal static object SettingsSetPayload(string section, object settings) =>
        new { section = section ?? string.Empty, settings = settings ?? EmptyPayload };

    internal static object LimitPayload(int limit) => new { limit = limit < 1 ? 1 : limit };

    internal static object JournalAppendPayload(string content, string kind) =>
        new { content = content ?? string.Empty, kind = string.IsNullOrWhiteSpace(kind) ? "note" : kind };

    internal static object JournalSearchPayload(string query, int limit) =>
        new { query = query ?? string.Empty, limit = limit < 1 ? 1 : limit };

    internal static object CardGetPayload(string id) => new { id = id ?? string.Empty };

    internal static object CardsImportPayload(object card) => new { card = card ?? EmptyPayload };

    /// <summary>True for daemon-initiated event frames (pump traffic).</summary>
    internal static bool IsEvent(JsonElement frame) =>
        HasType(frame, EventType);

    /// <summary>True for a transport pong or a successful <c>runtime.ping</c> RPC data payload.</summary>
    internal static bool IsPong(JsonElement frame)
    {
        if (HasType(frame, PongType))
            return true;
        if (!HasType(frame, RpcType))
            return false;
        var data = Data(frame);
        return data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty("pong", out var pong)
            && pong.ValueKind == JsonValueKind.True;
    }

    internal static bool IsError(JsonElement frame) => HasType(frame, ErrorType);

    /// <summary>True for an RPC reply that reports failure in the reply object itself.</summary>
    internal static bool IsFailedReply(JsonElement frame) =>
        HasType(frame, RpcType)
        && frame.TryGetProperty("ok", out var ok)
        && ok.ValueKind == JsonValueKind.False;

    /// <summary>Extract the <c>data</c> object of an RPC reply, or <c>undefined</c>.</summary>
    internal static JsonElement Data(JsonElement reply) =>
        reply.ValueKind == JsonValueKind.Object && reply.TryGetProperty("data", out var data)
            ? data.Clone()
            : default;

    private static bool HasType(JsonElement frame, string type) =>
        frame.ValueKind == JsonValueKind.Object
        && frame.TryGetProperty("type", out var t)
        && t.ValueKind == JsonValueKind.String
        && t.GetString() == type;
}
