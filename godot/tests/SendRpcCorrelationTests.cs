using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// Regression for F6: <see cref="DaemonClient.SendRpc"/> used to allocate a
/// correlation id but read the next non-event frame regardless of that id. With
/// the pump, probes and heartbeat all reading one socket, a pong (or another
/// call's reply) could be consumed by the wrong caller, which then reported
/// success with empty data while the real reply went to a later caller.
/// </summary>
public sealed class SendRpcCorrelationTests
{
    private static JsonElement Frame(string json) =>
        JsonDocument.Parse(json).RootElement.Clone();

    [Fact]
    public async Task SendRpc_TwoInFlightCalls_EachGetTheirOwnReply()
    {
        // Frames deliberately out of order: a pong first (the frame that used
        // to be stolen), then call B's reply, then call A's reply.
        var frames = new Queue<JsonElement>(new[]
        {
            Frame("""{"type":"pong"}"""),
            Frame("""{"type":"rpc","id":2,"ok":true,"data":{"which":"B"}}"""),
            Frame("""{"type":"rpc","id":1,"ok":true,"data":{"which":"A"}}"""),
        });

        // Both calls must be in flight before any frame is delivered, so the
        // test exercises the concurrent-read path rather than a serial one.
        var bothSent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sendCount = 0;
        var received = 0;

        Task Send(string json, CancellationToken ct)
        {
            if (Interlocked.Increment(ref sendCount) == 2)
                bothSent.TrySetResult();
            return Task.CompletedTask;
        }

        async Task<JsonElement> Receive(CancellationToken ct)
        {
            if (Interlocked.Increment(ref received) <= 2)
                await bothSent.Task.ConfigureAwait(false);
            lock (frames)
            {
                Assert.NotEmpty(frames); // the loop must never read past the scripted frames
                return frames.Dequeue();
            }
        }

        using var client = new DaemonClient(Send, Receive);

        // Call A runs synchronously up to its first (blocking) receive, so it
        // claims id 1; call B is launched while A is parked and claims id 2.
        var callA = client.ChatSendAsync("debug", "A");
        Assert.False(callA.IsCompleted);
        var callB = client.ChatSendAsync("debug", "B");
        Assert.False(callB.IsCompleted);
        bothSent.TrySetResult();

        var a = await callA;
        var b = await callB;

        Assert.Equal("A", a.GetProperty("which").GetString());
        Assert.Equal("B", b.GetProperty("which").GetString());
        Assert.Equal(3, received); // pong + both replies were read; none lost
    }

    [Fact]
    public async Task PingAsync_DoesNotStealAReplyParkedForAnotherRpc()
    {
        // A's read parks B's reply before A's own arrives. A subsequent heartbeat
        // ping must ignore that parked reply and take the pong instead, so B can
        // still collect its own reply afterwards.
        var frames = new Queue<JsonElement>(new[]
        {
            Frame("""{"type":"rpc","id":2,"ok":true,"data":{"which":"B"}}"""),
            Frame("""{"type":"rpc","id":1,"ok":true,"data":{"which":"A"}}"""),
            Frame("""{"type":"pong"}"""),
        });

        Task<JsonElement> Receive(CancellationToken ct)
        {
            lock (frames)
            {
                Assert.NotEmpty(frames);
                return Task.FromResult(frames.Dequeue());
            }
        }

        using var client = new DaemonClient((_, _) => Task.CompletedTask, Receive);

        var a = await client.ChatSendAsync("debug", "A"); // parks B's reply, returns A's
        await client.PingAsync();                          // must take the pong, not id=2
        var b = await client.ChatSendAsync("debug", "B"); // collects the parked id=2

        Assert.Equal("A", a.GetProperty("which").GetString());
        Assert.Equal("B", b.GetProperty("which").GetString());
        Assert.NotNull(client.LastPongAtUtc);
    }

    [Fact]
    public async Task SendRpc_CompletesWhileEventPumpIsWaitingForAFrame()
    {
        // The event pump's receive used to hold _receiveLock across the blocking
        // ReceiveAsync, so a concurrent SendRpc could never read its own reply.
        // Here the pump is parked first and its next frame is the RPC reply
        // (no event ever arrives) — the RPC must still complete.
        var deliver = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reply = Frame("""{"type":"rpc","id":1,"ok":true,"data":{"ok":true}}""");
        var reads = 0;

        async Task<JsonElement> Receive(CancellationToken ct)
        {
            if (Interlocked.Increment(ref reads) == 1)
            {
                await deliver.Task.ConfigureAwait(false);
                return reply;
            }
            // No event arrives; the pump stays parked. Under the old lock this
            // is where the RPC deadlocked (pump held the lock and parked the
            // reply before reading again).
            await Task.Delay(Timeout.Infinite, ct).ConfigureAwait(false);
            throw new OperationCanceledException(ct);
        }

        using var client = new DaemonClient((_, _) => Task.CompletedTask, Receive);

        var pump = client.ReceiveOneAsync();
        await Task.Yield(); // let the first receive reach its blocking await

        var rpc = client.CoreStatusAsync();
        Assert.False(rpc.IsCompleted);

        deliver.TrySetResult();
        var data = await rpc.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(data.GetProperty("ok").GetBoolean());
        Assert.False(pump.IsCompleted); // still waiting for an event, not starved
    }

    [Fact]
    public async Task SendRpc_ErrorFrame_IsNotParkedAndStillFailsTheCall()
    {
        var frames = new Queue<JsonElement>(new[]
        {
            Frame("""{"type":"error","error":{"message":"nope"}}"""),
        });

        using var client = new DaemonClient(
            (_, _) => Task.CompletedTask,
            (_) =>
            {
                lock (frames)
                {
                    Assert.NotEmpty(frames);
                    return Task.FromResult(frames.Dequeue());
                }
            });

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => client.CoreStatusAsync());
        Assert.Contains("nope", ex.Message);
    }
}
