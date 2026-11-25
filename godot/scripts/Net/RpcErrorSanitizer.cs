using System;
using System.Net.WebSockets;

namespace AnimaPet.Net;

/// <summary>
/// Maps transport and RPC failures to short fixed strings safe for the pet
/// window and the Godot output log. Handler errors can carry URLs, config
/// paths or credential-shaped text; matching is done on known failure kinds
/// only, never by copying the original text.
/// </summary>
public static class RpcErrorSanitizer
{
    public const string GenericMessage = "Connection failed. Check the daemon and retry.";

    private const string TransportMessage =
        "Could not reach the daemon. Check the host and port, then retry.";
    private const string AuthMessage =
        "The daemon rejected the connection. Check the auth token.";
    private const string TimeoutMessage = "The daemon did not respond in time. Please retry.";
    private const string ActionMessage =
        "The daemon refused this action. Ask the operator to enable it.";
    private const string RequestMessage = "The daemon could not complete the request.";

    public static string UserMessage(Exception? error)
    {
        if (error is WebSocketException)
            return TransportMessage;

        var text = error?.Message ?? string.Empty;
        if (text.Contains("invalid_token", StringComparison.OrdinalIgnoreCase)
            || text.StartsWith("daemon auth failed", StringComparison.OrdinalIgnoreCase))
            return AuthMessage;
        if (text.Contains("timed out", StringComparison.OrdinalIgnoreCase)
            || text.Contains("timeout", StringComparison.OrdinalIgnoreCase))
            return TimeoutMessage;
        if (text.Contains("actions are disabled", StringComparison.OrdinalIgnoreCase))
            return ActionMessage;
        if (text.Contains("rpc_not_implemented", StringComparison.OrdinalIgnoreCase)
            || text.Contains("rpc_unknown_method", StringComparison.OrdinalIgnoreCase)
            || text.Contains("rpc_bad_payload", StringComparison.OrdinalIgnoreCase)
            || text.Contains("rpc_bad_topics", StringComparison.OrdinalIgnoreCase)
            || text.Contains("rpc_bad_topic", StringComparison.OrdinalIgnoreCase))
            return RequestMessage;
        return GenericMessage;
    }
}
