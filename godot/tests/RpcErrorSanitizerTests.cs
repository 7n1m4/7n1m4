using System;
using System.Net.WebSockets;
using AnimaPet.Net;
using Xunit;

namespace AnimaPet.Tests;

public sealed class RpcErrorSanitizerTests
{
    [Fact]
    public void UserMessage_WebSocketFailure_IsGenericConnectionHint()
    {
        var message = RpcErrorSanitizer.UserMessage(
            new WebSocketException("wss://user:secret@host:6121/ws refused /home/vi/config.json"));

        Assert.DoesNotContain("secret", message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/home/", message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Could not reach the daemon. Check the host and port, then retry.", message);
    }

    [Fact]
    public void UserMessage_KnownFailures_MapToShortSafeText()
    {
        Assert.Equal(
            "The daemon rejected the connection. Check the auth token.",
            RpcErrorSanitizer.UserMessage(new InvalidOperationException("daemon auth failed: invalid_token token=abc")));
        Assert.Equal(
            "The daemon did not respond in time. Please retry.",
            RpcErrorSanitizer.UserMessage(new InvalidOperationException("ping timed out: no pong within 00:00:10")));
        Assert.Equal(
            "The daemon refused this action. Ask the operator to enable it.",
            RpcErrorSanitizer.UserMessage(new InvalidOperationException("core.status failed: gateway actions are disabled (set allowActions=true to enable)")));
        Assert.Equal(
            "The daemon could not complete the request.",
            RpcErrorSanitizer.UserMessage(new InvalidOperationException("renderer.x failed: rpc_not_implemented path=/etc/secret")));
    }

    [Fact]
    public void UserMessage_UnknownHandlerError_IsFixedGenericText()
    {
        var message = RpcErrorSanitizer.UserMessage(
            new InvalidOperationException("cards.import failed: key=abc123 at /home/vi/.config/airi/config.json"));

        Assert.Equal("Connection failed. Check the daemon and retry.", message);
        Assert.DoesNotContain("abc123", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void UserMessage_NullException_IsGeneric()
    {
        Assert.Equal("Connection failed. Check the daemon and retry.", RpcErrorSanitizer.UserMessage(null!));
    }
}
