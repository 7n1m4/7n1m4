using System;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// Pins the generic RPC caller, the typed capability methods, and the
/// application-level heartbeat of <see cref="DaemonClient"/>. Frame builders
/// are tested directly so no live daemon is needed.
/// </summary>
public sealed class RpcAndHeartbeatTests
{
    private static readonly string[] ExpectedActions =
    {
        "chat.send", "chat.cancel", "core.status", "providers.list",
        "settings.get", "settings.set", "vault.status", "stmm.list",
        "stmm.rebuild", "journal.append", "journal.search", "retrieval.status",
        "cards.list", "cards.get", "cards.import", "sessions.list", "sessions.export",
    };

    private static JsonElement Serialize(object value)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(value));
        return doc.RootElement.Clone();
    }

    [Fact]
    public void DaemonRpc_ExposesEveryGatewayAction()
    {
        Assert.Equal(ExpectedActions.OrderBy(x => x), DaemonRpc.AllActions.OrderBy(x => x));
    }

    [Fact]
    public void DaemonRpc_Frame_SerializesActionPayloadAndCorrelationId()
    {
        var frame = Serialize(DaemonRpc.Frame(
            DaemonRpc.ChatSend, DaemonRpc.ChatSendPayload("s1", "hi"), 7));

        Assert.Equal("rpc", frame.GetProperty("type").GetString());
        Assert.Equal("chat.send", frame.GetProperty("action").GetString());
        Assert.Equal(7, frame.GetProperty("id").GetInt32());
        Assert.Equal("s1", frame.GetProperty("payload").GetProperty("session_id").GetString());
        Assert.Equal("hi", frame.GetProperty("payload").GetProperty("content").GetString());
    }

    [Fact]
    public void DaemonRpc_Frame_OmitsNullPayloadAsEmptyObject()
    {
        var frame = Serialize(DaemonRpc.Frame(DaemonRpc.CoreStatus, null, null));
        Assert.Equal(JsonValueKind.Object, frame.GetProperty("payload").ValueKind);
        Assert.Empty(frame.GetProperty("payload").EnumerateObject());
        Assert.Equal(JsonValueKind.Null, frame.GetProperty("id").ValueKind);
    }

    [Fact]
    public void DaemonRpc_PingFrame_IsTransportPing()
    {
        var frame = Serialize(DaemonRpc.PingFrame());
        Assert.Equal("ping", frame.GetProperty("type").GetString());
        Assert.False(frame.TryGetProperty("action", out _));
    }

    [Fact]
    public void DaemonRpc_RecognizesPongErrorAndFailedReplies()
    {
        var pong = JsonDocument.Parse("""{"type":"pong"}""").RootElement;
        var rpcPong = JsonDocument.Parse("""{"type":"rpc","data":{"pong":true}}""").RootElement;
        var error = JsonDocument.Parse("""{"type":"error","error":{"message":"nope"}}""").RootElement;
        var failed = JsonDocument.Parse("""{"type":"rpc","ok":false,"error":{"message":"bad"}}""").RootElement;
        var eventFrame = JsonDocument.Parse("""{"type":"event","topic":"lip_sync.rms"}""").RootElement;

        Assert.True(DaemonRpc.IsPong(pong));
        Assert.True(DaemonRpc.IsPong(rpcPong));
        Assert.False(DaemonRpc.IsPong(eventFrame));
        Assert.True(DaemonRpc.IsError(error));
        Assert.True(DaemonRpc.IsFailedReply(failed));
        Assert.True(DaemonRpc.IsEvent(eventFrame));
    }

    [Fact]
    public void DaemonRpc_Data_ExtractsReplyData()
    {
        var reply = JsonDocument.Parse("""{"type":"rpc","data":{"ok":true}}""").RootElement;
        Assert.True(DaemonRpc.Data(reply).GetProperty("ok").GetBoolean());
        Assert.Equal(JsonValueKind.Undefined,
            DaemonRpc.Data(JsonDocument.Parse("{}").RootElement).ValueKind);
    }

    [Fact]
    public void DaemonClient_ExposesGenericCallerAndEveryTypedCapability()
    {
        var type = typeof(DaemonClient);
        string[] methods =
        {
            "SendRpc", "PingAsync", "RunHeartbeatAsync",
            "ChatSendAsync", "ChatCancelAsync", "CoreStatusAsync", "ProvidersListAsync",
            "SettingsGetAsync", "SettingsSetAsync", "VaultStatusAsync",
            "StmmListAsync", "StmmRebuildAsync", "JournalAppendAsync", "JournalSearchAsync",
            "RetrievalStatusAsync", "CardsListAsync", "CardsGetAsync", "CardsImportAsync",
            "SessionsListAsync", "SessionsExportAsync",
            "SubscribeAsync", "UnsubscribeAsync",
        };
        foreach (var name in methods)
        {
            Assert.NotNull(type.GetMethod(name, BindingFlags.Public | BindingFlags.Instance));
        }
    }

    [Fact]
    public void DaemonClient_PreservesEventSubscriptionSurface()
    {
        var type = typeof(DaemonClient);
        Assert.NotNull(type.GetEvent("EventReceived"));
        Assert.NotNull(type.GetEvent("StateChanged"));
        Assert.Equal(DaemonConnectionState.Disconnected, new DaemonClient("token").State);
    }

    [Fact]
    public void DaemonClient_HeartbeatDefaults_AreSet()
    {
        using var client = new DaemonClient("token");
        Assert.Equal(TimeSpan.FromSeconds(30), DaemonClient.DefaultHeartbeatInterval);
        Assert.Equal(DaemonClient.DefaultHeartbeatInterval, client.HeartbeatInterval);
        Assert.Null(client.LastPongAtUtc);
    }

    [Fact]
    public async Task DaemonClient_RpcAndPing_RequireAnAuthenticatedConnection()
    {
        using var client = new DaemonClient("token");
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.SendRpc("core.status"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.PingAsync());
    }

    [Fact]
    public void DaemonRpc_PayloadBuilders_MatchGatewayFieldNames()
    {
        var search = Serialize(DaemonRpc.JournalSearchPayload("term", 12));
        Assert.Equal("term", search.GetProperty("query").GetString());
        Assert.Equal(12, search.GetProperty("limit").GetInt32());

        var settings = Serialize(DaemonRpc.SettingsSetPayload("core", new { theme = "dark" }));
        Assert.Equal("core", settings.GetProperty("section").GetString());
        Assert.Equal("dark", settings.GetProperty("settings").GetProperty("theme").GetString());

        var export = Serialize(DaemonRpc.SessionPayload("s42"));
        Assert.Equal("s42", export.GetProperty("session_id").GetString());
    }
}
