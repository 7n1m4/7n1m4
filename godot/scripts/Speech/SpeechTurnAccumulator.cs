using System;
using System.Collections.Generic;
using System.Text;
using AnimaPet.Net;

namespace AnimaPet.Speech;

/// <summary>
/// Collects streamed token deltas per chat turn. One client can watch several
/// concurrent sessions, so a single shared buffer would interleave their text
/// and speak a turn that never received a Final marker.
/// </summary>
public sealed class SpeechTurnAccumulator
{
    private readonly string _probeSession;
    private readonly Dictionary<(string SessionId, string MessageId), StringBuilder> _turns = new();

    public SpeechTurnAccumulator(string probeSession)
    {
        _probeSession = probeSession;
    }

    /// <summary>
    /// Records a delta; returns the completed turn text only on its Final
    /// event, after removing that turn from the accumulator. Capability probes
    /// are excluded. A fresh index 0 resets that turn (a retry can reuse the
    /// same message id).
    /// </summary>
    public string? Observe(TokenDeltaData token)
    {
        if (string.Equals(token.SessionId, _probeSession, StringComparison.OrdinalIgnoreCase))
            return null;

        var key = (token.SessionId, token.MessageId);
        if (token.Index == 0)
            _turns.Remove(key);
        if (!token.Final)
        {
            if (!_turns.TryGetValue(key, out var pending))
            {
                pending = new StringBuilder();
                _turns.Add(key, pending);
            }
            pending.Append(token.Delta);
            return null;
        }

        // The terminal event carries an empty delta, but include any text it
        // might carry instead of dropping it.
        var text = token.Delta;
        if (_turns.Remove(key, out var completed))
            text = completed.Append(token.Delta).ToString();
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }

    /// <summary>Discard incomplete turns, e.g. when the daemon connection drops.</summary>
    public void Clear() => _turns.Clear();

    /// <summary>Snapshot of in-progress turns (for tests/diagnostics).</summary>
    public IReadOnlyDictionary<(string SessionId, string MessageId), string> Snapshot()
    {
        var result = new Dictionary<(string, string), string>();
        foreach (var (key, text) in _turns)
            result.Add(key, text.ToString());
        return result;
    }
}
