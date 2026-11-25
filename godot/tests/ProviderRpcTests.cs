using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// airi-zeuj: <c>providers.save</c> and <c>providers.delete</c> RPC callers.
///
/// <para>
/// Wire shapes are pinned to the Rust daemon: <c>providers.save</c> reads
/// <c>id</c>/<c>kind</c>/<c>enabled</c>/<c>model</c>/<c>baseUrl</c>/<c>apiKey</c>
/// plus the literal boolean <c>rotateSecrets</c>
/// (<c>crates/anima-daemon/src/core.rs:296-374</c>,
/// <c>crates/anima-daemon/src/gateway.rs:141-146,749</c>) and answers
/// <c>{ok, id}</c> without echoing the key; <c>providers.delete</c> reads
/// <c>id</c> and answers <c>{ok, deleted}</c> (<c>gateway.rs:766-779</c>).
/// Both are gated actions, so a denied daemon answers an error frame that
/// <c>SendRpc</c> surfaces as <see cref="InvalidOperationException"/>.
/// </para>
/// </summary>
public sealed class ProviderRpcTests
{
    private static JsonElement Frame(string json) =>
        JsonDocument.Parse(json).RootElement.Clone();

    private static JsonElement Serialize(object value) => Frame(JsonSerializer.Serialize(value));

    /// <summary>Runs one call against a scripted transport and returns the sent frame plus reply data.</summary>
    private static async Task<(JsonElement Sent, JsonElement Data)> CallAsync(
        Func<DaemonClient, CancellationToken, Task<JsonElement>> call,
        string replyData)
    {
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame($"{{\"type\":\"rpc\",\"id\":1,\"data\":{replyData}}}")));

        var data = await call(client, CancellationToken.None);

        Assert.Single(sent);
        return (Frame(sent[0]), data);
    }

    /// <summary>
    /// Runs <paramref name="call"/> against a client whose every reply is the
    /// daemon's <c>actions_disabled</c> error frame. A fresh client is used per
    /// call because an error frame also fails the connection, so the same
    /// client cannot serve a second request.
    /// </summary>
    private static async Task<InvalidOperationException> DeniedAsync(
        Func<DaemonClient, Task<JsonElement>> call)
    {
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame(
                "{\"type\":\"error\",\"error\":{\"code\":\"actions_disabled\",\"message\":\"actions disabled\"}}")));

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() => call(client));
        Assert.Single(sent);
        return ex;
    }

    // -----------------------------------------------------------------
    // Request builders: daemon field names, verbatim.
    // -----------------------------------------------------------------

    [Fact]
    public void ProvidersSavePayload_UsesDaemonFieldNames()
    {
        var payload = Serialize(DaemonRpc.ProvidersSavePayload(
            "p1", "open-ai-compatible", "gpt-x", "https://example.test/v1", true, "TOP-SECRET"));

        Assert.Equal("p1", payload.GetProperty("id").GetString());
        Assert.Equal("open-ai-compatible", payload.GetProperty("kind").GetString());
        Assert.Equal("gpt-x", payload.GetProperty("model").GetString());
        Assert.Equal("https://example.test/v1", payload.GetProperty("baseUrl").GetString());
        Assert.True(payload.GetProperty("enabled").GetBoolean());
        Assert.Equal("TOP-SECRET", payload.GetProperty("apiKey").GetString());
        // Rotation is opt-in and off by default: a plain save must not claim it.
        Assert.False(payload.GetProperty("rotateSecrets").GetBoolean());
        // The daemon accepts no other spelling of these keys.
        Assert.False(payload.TryGetProperty("base_url", out _));
        Assert.False(payload.TryGetProperty("api_key", out _));
        Assert.False(payload.TryGetProperty("providerId", out _));
    }

    [Fact]
    public void ProvidersSavePayload_RotationFlag_IsAlwaysALiteralBoolean()
    {
        // gateway.rs:141-146 fails closed on "true"/1/false; the builder can
        // only ever emit a JSON boolean, so a caller cannot smuggle a string.
        var rotating = Serialize(DaemonRpc.ProvidersSavePayload(
            "p1", "open-ai-compatible", "gpt-x", "", false, "NEW-KEY", rotateSecrets: true));
        Assert.Equal(JsonValueKind.True, rotating.GetProperty("rotateSecrets").ValueKind);

        var notRotating = Serialize(DaemonRpc.ProvidersSavePayload(
            "p1", "open-ai-compatible", "gpt-x", "", false, "NEW-KEY"));
        Assert.Equal(JsonValueKind.False, notRotating.GetProperty("rotateSecrets").ValueKind);
    }

    [Fact]
    public void ProvidersSavePayload_NullArguments_BecomeEmptyStrings()
    {
        var payload = Serialize(DaemonRpc.ProvidersSavePayload(null!, null!, null!, null!, false, null!));

        Assert.Equal("", payload.GetProperty("id").GetString());
        Assert.Equal("", payload.GetProperty("kind").GetString());
        Assert.Equal("", payload.GetProperty("model").GetString());
        Assert.Equal("", payload.GetProperty("baseUrl").GetString());
        Assert.Equal("", payload.GetProperty("apiKey").GetString());
    }

    [Fact]
    public void ProvidersDeletePayload_UsesDaemonFieldName()
    {
        var payload = Serialize(DaemonRpc.ProvidersDeletePayload("p1"));

        Assert.Equal("p1", payload.GetProperty("id").GetString());
        Assert.Single(payload.EnumerateObject());
    }

    [Fact]
    public void DaemonRpc_AllActions_IncludesProviderMutations()
    {
        Assert.Contains(DaemonRpc.ProvidersSave, DaemonRpc.AllActions);
        Assert.Contains(DaemonRpc.ProvidersDelete, DaemonRpc.AllActions);
        Assert.Equal("providers.save", DaemonRpc.ProvidersSave);
        Assert.Equal("providers.delete", DaemonRpc.ProvidersDelete);
    }

    // -----------------------------------------------------------------
    // Wire-level callers: frame out, data in, no daemon required.
    // -----------------------------------------------------------------

    [Fact]
    public async Task ProvidersSaveAsync_SendsDaemonShapedFrame_AndUnwrapsId()
    {
        var (sent, data) = await CallAsync(
            (client, ct) => client.SendRpc(
                DaemonRpc.ProvidersSave,
                DaemonRpc.ProvidersSavePayload(
                    "p-new", "llama-cpp", "qwen", "http://localhost:11434/v1", true, "TOP-SECRET"),
                ct),
            "{\"ok\":true,\"id\":\"p-new\"}");

        Assert.Equal("rpc", sent.GetProperty("type").GetString());
        Assert.Equal("providers.save", sent.GetProperty("action").GetString());
        var payload = sent.GetProperty("payload");
        Assert.Equal("p-new", payload.GetProperty("id").GetString());
        Assert.Equal("llama-cpp", payload.GetProperty("kind").GetString());
        Assert.Equal("qwen", payload.GetProperty("model").GetString());
        Assert.Equal("http://localhost:11434/v1", payload.GetProperty("baseUrl").GetString());
        Assert.True(payload.GetProperty("enabled").GetBoolean());
        Assert.Equal("TOP-SECRET", payload.GetProperty("apiKey").GetString());

        // The reply carries {ok, id} only; the key is never echoed back.
        Assert.True(data.GetProperty("ok").GetBoolean());
        Assert.Equal("p-new", data.GetProperty("id").GetString());
        Assert.False(data.TryGetProperty("apiKey", out _));
    }

    [Fact]
    public async Task ProvidersSaveAsync_PartialUpdate_OmitsCredentialsAndKeepsEnabled()
    {
        // Toggling `enabled` must not send a (possibly empty) key: the daemon
        // preserves the stored credential on a PATCH (core.rs:326-364).
        var (sent, _) = await CallAsync(
            (client, ct) => client.SendRpc(
                DaemonRpc.ProvidersSave,
                DaemonRpc.ProvidersSavePayload("p1", "open-ai-compatible", null!, null!, false, null!),
                ct),
            "{\"ok\":true,\"id\":\"p1\"}");

        var payload = sent.GetProperty("payload");
        Assert.Equal("p1", payload.GetProperty("id").GetString());
        Assert.Equal("open-ai-compatible", payload.GetProperty("kind").GetString());
        Assert.False(payload.GetProperty("enabled").GetBoolean());
        Assert.Equal("", payload.GetProperty("apiKey").GetString());
    }

    [Fact]
    public async Task ProvidersDeleteAsync_SendsId_AndUnwrapsDeletedFlag()
    {
        var (sent, data) = await CallAsync(
            (client, ct) => client.SendRpc(
                DaemonRpc.ProvidersDelete, DaemonRpc.ProvidersDeletePayload("p1"), ct),
            "{\"ok\":true,\"deleted\":true}");

        Assert.Equal("providers.delete", sent.GetProperty("action").GetString());
        Assert.Equal("p1", sent.GetProperty("payload").GetProperty("id").GetString());

        Assert.True(data.GetProperty("ok").GetBoolean());
        Assert.True(data.GetProperty("deleted").GetBoolean());
    }

    [Fact]
    public async Task ProvidersDeleteAsync_MissingRow_ReportsDeletedFalse()
    {
        // The daemon answers {ok, deleted:false} rather than an error when no
        // row matched, so the caller must read the flag instead of assuming.
        var (_, data) = await CallAsync(
            (client, ct) => client.SendRpc(
                DaemonRpc.ProvidersDelete, DaemonRpc.ProvidersDeletePayload("gone"), ct),
            "{\"ok\":true,\"deleted\":false}");

        Assert.True(data.GetProperty("ok").GetBoolean());
        Assert.False(data.GetProperty("deleted").GetBoolean());
    }

    [Fact]
    public async Task ProvidersDeleteAsync_EmptyId_IsRejectedByTheDaemon()
    {
        // The caller does not pre-validate; the daemon owns the "missing id"
        // rejection (gateway.rs:771-774), which arrives as an error frame.
        var sent = new List<string>();
        Task Send(string json, CancellationToken _) { sent.Add(json); return Task.CompletedTask; }
        using var client = new DaemonClient(Send,
            _ => Task.FromResult(Frame(
                "{\"type\":\"rpc\",\"id\":1,\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"missing id\"}}")));

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            client.SendRpc(DaemonRpc.ProvidersDelete, DaemonRpc.ProvidersDeletePayload(""), CancellationToken.None));

        Assert.Contains("missing id", ex.Message, StringComparison.Ordinal);
        using var sentDoc = JsonDocument.Parse(sent[0]);
        Assert.Equal("", sentDoc.RootElement.GetProperty("payload").GetProperty("id").GetString());
    }

    [Fact]
    public async Task ProvidersMutations_BlockedByActionGate_SurfaceTheDaemonError()
    {
        // Both mutations are gated (gateway.rs:750,767): a daemon with
        // allowActions off answers an error frame, never a silent success.
        var save = await DeniedAsync(client => client.SendRpc(
            DaemonRpc.ProvidersSave,
            DaemonRpc.ProvidersSavePayload("p1", "open-ai-compatible", null!, null!, true, null!)));
        var delete = await DeniedAsync(client => client.SendRpc(
            DaemonRpc.ProvidersDelete, DaemonRpc.ProvidersDeletePayload("p1")));

        Assert.Contains("actions disabled", save.Message, StringComparison.Ordinal);
        Assert.Contains("actions disabled", delete.Message, StringComparison.Ordinal);
    }
}