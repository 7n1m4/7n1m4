using System;
using System.Collections.Generic;
using AnimaPet.Net;
using AnimaPet.Speech;
using Xunit;

namespace AnimaPet.Tests;

public sealed class SpeechTurnAccumulatorTests
{
    private static TokenDeltaData Delta(
        string session, string message, string text, ulong index, bool final = false) =>
        new(session, message, text, index, final, 0, 0);

    [Fact]
    public void InterleavedTurns_EachSpeakOnlyTheirOwnDeltas()
    {
        var acc = new SpeechTurnAccumulator("debug");
        Assert.Null(acc.Observe(Delta("s1", "m1", "Hello ", 0)));
        Assert.Null(acc.Observe(Delta("s2", "m2", "Bonjour ", 0)));
        Assert.Null(acc.Observe(Delta("s1", "m1", "world", 1)));
        Assert.Null(acc.Observe(Delta("s2", "m2", "monde", 1)));
        Assert.Equal("Bonjour monde", acc.Observe(Delta("s2", "m2", "", 2, final: true)));
        Assert.Equal("Hello world", acc.Observe(Delta("s1", "m1", "", 2, final: true)));
        Assert.Empty(acc.Snapshot());
    }

    [Fact]
    public void TurnRestart_ReplacesAccumulatedDeltasForThatKeyOnly()
    {
        var acc = new SpeechTurnAccumulator("debug");
        Assert.Null(acc.Observe(Delta("s1", "m1", "stale", 0)));
        Assert.Null(acc.Observe(Delta("s2", "m2", "keep", 0)));
        Assert.Null(acc.Observe(Delta("s1", "m1", "fresh ", 0)));
        Assert.Null(acc.Observe(Delta("s1", "m1", "text", 1)));
        Assert.Equal("fresh text", acc.Observe(Delta("s1", "m1", "", 2, final: true)));
        Assert.Equal("keep", acc.Observe(Delta("s2", "m2", "", 1, final: true)));
    }

    [Fact]
    public void ProbeSession_AndFinalWithoutText_AreIgnored()
    {
        var acc = new SpeechTurnAccumulator("DEBUG");
        Assert.Null(acc.Observe(Delta("debug", "m0", "probe", 0)));
        Assert.Null(acc.Observe(Delta("debug", "m0", "", 1, final: true)));
        Assert.Null(acc.Observe(Delta("s1", "m1", "", 0, final: true)));
        Assert.Empty(acc.Snapshot());

        // An empty message id is still a distinct turn key.
        Assert.Null(acc.Observe(Delta("s1", "", "empty-id", 0)));
        Assert.Equal("empty-id", acc.Observe(Delta("s1", "", "", 1, final: true)));
    }

    [Fact]
    public void AbandonedTurns_CanBeDiscardedOnReconnect()
    {
        var acc = new SpeechTurnAccumulator("debug");
        Assert.Null(acc.Observe(Delta("s1", "m1", "half heard", 0)));
        Assert.Single(acc.Snapshot());
        acc.Clear();
        Assert.Empty(acc.Snapshot());
        Assert.Equal("next", acc.Observe(Delta("s1", "m2", "next", 0, final: true)));
    }
}
