using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// airi-bno: a daemon that accepts a socket but never answers an RPC used to
/// leave SendRpc (and the renderer waiting on it) stuck. The per-call deadline
/// must cancel the linked token handed to the transport without cancelling a
/// caller token that is still live.
/// </summary>
public sealed class RpcTimeoutTests
{
    [Fact]
    public async Task SendRpc_NonRespondingTransport_TimesOut()
    {
        using var callCts = new CancellationTokenSource();
        var sendStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken sendToken = default;

        Task Send(string json, CancellationToken ct)
        {
            sendToken = ct;
            sendStarted.TrySetResult();
            return Task.CompletedTask;
        }

        // The fake transport never produces a reply; only shutdown can end it.
        async Task<JsonElement> Receive(CancellationToken ct)
        {
            await Task.Delay(Timeout.Infinite, ct).ConfigureAwait(false);
            throw new OperationCanceledException(ct);
        }

        using var client = new DaemonClient(Send, Receive)
        {
            SendRpcTimeout = TimeSpan.FromMilliseconds(80),
        };

        var call = client.CoreStatusAsync(callCts.Token);
        await sendStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
        Assert.True(sendToken.IsCancellationRequested);
        Assert.False(callCts.IsCancellationRequested);
    }

    [Fact]
    public async Task SendRpc_CallerCancellation_StillAbortsTheCall()
    {
        var receiveStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        async Task<JsonElement> Receive(CancellationToken ct)
        {
            receiveStarted.TrySetResult();
            await Task.Delay(Timeout.Infinite, ct).ConfigureAwait(false);
            throw new OperationCanceledException(ct);
        }

        using var client = new DaemonClient((_, _) => Task.CompletedTask, Receive);
        using var callCts = new CancellationTokenSource();

        var call = client.CoreStatusAsync(callCts.Token);
        await receiveStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        callCts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
    }
}
