using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// airi-hax: <c>chat.history</c> and <c>sessions.import</c> RPC callers.
///
/// <para>
/// Wire shapes are pinned to the Rust daemon registry:
/// <c>crates/anima-daemon/src/gateway.rs:936</c> (chat.history reads snake_case
/// <c>session_id</c>; reply is <c>{sessionId, messages:[{id, sessionId, role,
/// content, createdAt, metadata}]}</c>) and <c>gateway.rs:1153</c>
/// (sessions.import reads <c>jsonl</c>; reply is <c>SessionImportReply {status,
/// revision}</c>, <c>crates/anima-channel/src/wire.rs:442</c>). Reply shapes are
/// taken from the Rust-canonical golden fixtures under
/// <c>crates/anima-channel/fixtures/golden/</c> (copied to test output by the
/// csproj); the request builders are pinned inline.
/// </para>
/// </summary>
public sealed class ChatHistoryImportRpcTests
{
    private static JsonElement Frame(string json) =>
        JsonDocument.Parse(json).RootElement.Clone();

    private static JsonElement Serialize(object value) => Frame(JsonSerializer.Serialize(value));

    /// <summary>Loads a Rust-canonical golden fixture from the test output dir.</summary>
    private static JsonElement LoadGolden(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "golden", name);
        Assert.True(File.Exists(path), $"golden fixture not found: {path}");
        return Frame(File.ReadAllText(path));
    }

    // -----------------------------------------------------------------
    // Request builders: daemon field names, verbatim.
    // -----------------------------------------------------------------

    [Fact]
    public void ChatHistoryPayload_UsesDaemonFieldName()
    {
        var payload = Serialize(DaemonRpc.ChatHistoryPayload("s42"));
        Assert.Equal("s42", payload.GetProperty("session_id").GetString());
        Assert.False(payload.TryGetProperty("sessionId", out _));
    }

    [Fact]
    public void ChatHistoryPayload_NullSessionId_BecomesEmptyString()
    {
        var payload = Serialize(DaemonRpc.ChatHistoryPayload(null!));
        Assert.Equal("", payload.GetProperty("session_id").GetString());
    }

    [Fact]
    public void SessionsImportPayload_UsesDaemonFieldName()
    {
        // gateway.rs:1155-1158 reads "jsonl"; the reply's camelCase "status"
        // and "revision" must not leak into the request.
        const string snapshot = "{\"v\":1,\"messages\":[]}";
        var payload = Serialize(DaemonRpc.SessionsImportPayload(snapshot));
        Assert.Equal(snapshot, payload.GetProperty("jsonl").GetString());
        Assert.False(payload.TryGetProperty("status", out _));
        Assert.False(payload.TryGetProperty("revision", out _));
    }

    [Fact]
    public void SessionsImportPayload_NullSnapshot_BecomesEmptyString()
    {
        var payload = Serialize(DaemonRpc.SessionsImportPayload(null!));
        Assert.Equal("", payload.GetProperty("jsonl").GetString());
    }

    [Fact]
    public void DaemonRpc_AllActions_IncludesHistoryAndImport()
    {
        Assert.Contains(DaemonRpc.ChatHistory, DaemonRpc.AllActions);
        Assert.Contains(DaemonRpc.SessionsImport, DaemonRpc.AllActions);
        Assert.Equal("chat.history", DaemonRpc.ChatHistory);
        Assert.Equal("sessions.import", DaemonRpc.SessionsImport);
    }

    // -----------------------------------------------------------------
    // Wire-level callers: frame out, data in, no daemon required.
    // -----------------------------------------------------------------

    [Fact]
    public async Task ChatHistoryAsync_SendsDaemonShapedFrame_AndUnwrapsReplyData()
    {
        // Reply envelope mirrors gateway.rs:959 plus the SendRpc data unwrap:
        // the caller sees the data object {sessionId, messages}.
        var replyData = new
        {
            sessionId = "debug",
            messages = new[]
            {
                new { id = "m1", sessionId = "debug", role = "user", content = "hi", createdAt = 1L, metadata = (object?)null },
            },
        };
        var expected = JsonSerializer.Serialize(replyData);
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame($"{{\"type\":\"rpc\",\"id\":1,\"data\":{expected}}}")));

        var data = await client.ChatHistoryAsync("debug");

        Assert.Single(sent);
        using var frame = JsonDocument.Parse(sent[0]);
        Assert.Equal("rpc", frame.RootElement.GetProperty("type").GetString());
        Assert.Equal("chat.history", frame.RootElement.GetProperty("action").GetString());
        Assert.Equal("debug", frame.RootElement.GetProperty("payload").GetProperty("session_id").GetString());

        Assert.Equal("debug", data.GetProperty("sessionId").GetString());
        var messages = data.GetProperty("messages");
        Assert.Equal(1, messages.GetArrayLength());
        Assert.Equal("m1", messages[0].GetProperty("id").GetString());
        Assert.Equal("hi", messages[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task ChatHistoryAsync_EmptySessionId_StillSendsFrame_DaemonRejects()
    {
        // The caller does not pre-validate; the daemon owns the
        // "missing session_id" rejection (gateway.rs:942-944).
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame("{\"type\":\"rpc\",\"id\":1,\"data\":{\"sessionId\":\"\",\"messages\":[]}}")));

        var data = await client.ChatHistoryAsync(string.Empty);

        Assert.Single(sent);
        using var frame = JsonDocument.Parse(sent[0]);
        Assert.Equal("", frame.RootElement.GetProperty("payload").GetProperty("session_id").GetString());
        Assert.Equal("", data.GetProperty("sessionId").GetString());
        Assert.Equal(0, data.GetProperty("messages").GetArrayLength());
    }

    [Fact]
    public async Task SessionsImportAsync_SendsJsonlString_AndUnwrapsReplyData()
    {
        // sessions.import is gated (gateway.rs:1154): the scripted transport
        // models an approved daemon; a denied one answers an error frame,
        // which SendRpc surfaces as InvalidOperationException (pinned by
        // SendRpcCorrelationTests.SendRpc_ErrorFrame_IsNotParkedAndStillFailsTheCall).
        var snapshot = LoadGolden("event.token_delta.partial.json").GetRawText();
        var expected = LoadGolden("sessions.import.reply.json").GetRawText();
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame($"{{\"type\":\"rpc\",\"id\":1,\"data\":{expected}}}")));

        var data = await client.SessionsImportAsync(snapshot);

        Assert.Single(sent);
        using var frame = JsonDocument.Parse(sent[0]);
        Assert.Equal("sessions.import", frame.RootElement.GetProperty("action").GetString());
        Assert.Equal(snapshot, frame.RootElement.GetProperty("payload").GetProperty("jsonl").GetString());

        Assert.Equal("applied", data.GetProperty("status").GetString());
        Assert.Equal(1700000000123L, data.GetProperty("revision").GetInt64());
    }

    // -----------------------------------------------------------------
    // Full round-trips over the Rust-canonical golden fixtures.
    // -----------------------------------------------------------------

    [Fact]
    public async Task ChatHistory_RoundTrip_ReplaysPersistedTurns_FromGoldenFixtures()
    {
        // No Rust-canonical chat.history reply fixture exists in the golden
        // dir (the fixture worker covers only request/reply DTOs). If one
        // lands later it is adopted automatically; until then the reply is
        // derived from the guaranteed-present token_delta fixtures via the
        // exact gateway.rs:949-959 shape.
        var replyJson = TryLoadGolden("chat.history.reply.json") is { } loaded
            ? loaded.GetRawText()
            : BuildHistoryReplyFromTokenDeltaFixtures().GetRawText();

        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame($"{{\"type\":\"rpc\",\"id\":1,\"data\":{replyJson}}}")));

        var data = await client.ChatHistoryAsync("sess-abc");

        using var sentDoc = JsonDocument.Parse(sent[0]);
        Assert.Equal("chat.history", sentDoc.RootElement.GetProperty("action").GetString());
        Assert.Equal("sess-abc", sentDoc.RootElement.GetProperty("payload").GetProperty("session_id").GetString());

        // The persisted turns replay in order with their content intact.
        var messages = data.GetProperty("messages");
        Assert.Equal(2, messages.GetArrayLength());
        Assert.Equal("Hello", messages[0].GetProperty("content").GetString());
        Assert.Equal(" world", messages[1].GetProperty("content").GetString());
        foreach (var message in messages.EnumerateArray())
            Assert.Equal("sess-abc", message.GetProperty("sessionId").GetString());
    }

    [Fact]
    public async Task SessionsImport_RoundTrip_RestoresExportedSnapshot_FromGoldenFixture()
    {
        // An exported snapshot (any JSONL) is sent verbatim; the daemon
        // answers SessionImportReply {status, revision} (wire.rs:442-447).
        var snapshot = LoadGolden("event.token_delta.partial.json").GetRawText();
        var replyJson = TryLoadGolden("sessions.import.reply.json")?.GetRawText()
            ?? JsonSerializer.Serialize(new { status = "applied", revision = 1700000000123L });

        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame($"{{\"type\":\"rpc\",\"id\":1,\"data\":{replyJson}}}")));

        var data = await client.SessionsImportAsync(snapshot);

        using var sentDoc = JsonDocument.Parse(sent[0]);
        Assert.Equal("sessions.import", sentDoc.RootElement.GetProperty("action").GetString());
        Assert.Equal(snapshot, sentDoc.RootElement.GetProperty("payload").GetProperty("jsonl").GetString());

        // Round-trip proof: the daemon's verdict is readable and its shape is
        // one of the four documented statuses (wire.rs:443).
        var status = data.GetProperty("status").GetString();
        Assert.Contains(status, new[] { "applied", "duplicate", "older", "conflict" });
        Assert.True(data.GetProperty("revision").GetInt64() > 0);
    }

    // -----------------------------------------------------------------
    // Fixture helpers.
    // -----------------------------------------------------------------

    private static JsonElement? TryLoadGolden(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "golden", name);
        return File.Exists(path) ? Frame(File.ReadAllText(path)) : null;
    }

    /// <summary>
    /// Builds a chat.history reply body with the exact gateway.rs:949-959
    /// shape from the two guaranteed-present token_delta golden fixtures,
    /// so the replay round-trip is proven even before the Rust-side
    /// chat.history reply fixture lands.
    /// </summary>
    private static JsonElement BuildHistoryReplyFromTokenDeltaFixtures()
    {
        var first = LoadGolden("event.token_delta.partial.json").GetProperty("data");
        var second = LoadGolden("event.token_delta.final.json").GetProperty("data");

        static object Turn(JsonElement data) => new
        {
            id = data.GetProperty("message_id").GetString(),
            sessionId = data.GetProperty("session_id").GetString(),
            role = "assistant",
            content = data.GetProperty("delta").GetString(),
            createdAt = data.GetProperty("ts_ms").GetInt64(),
            metadata = (object?)null,
        };

        return Frame(JsonSerializer.Serialize(new
        {
            sessionId = first.GetProperty("session_id").GetString(),
            messages = new[] { Turn(first), Turn(second) },
        }));
    }
}