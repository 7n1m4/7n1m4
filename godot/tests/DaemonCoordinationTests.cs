using System;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// Verifies that pet-to-Flutter coordination flows exclusively through daemon
/// events, with no direct client-to-client channel.
/// </summary>
public sealed class DaemonCoordinationTests
{
    [Fact]
    public void PetTopics_AreExactlyFourTopics()
    {
        // The pet subscribes to exactly the four daemon-owned topics.
        var expected = new[]
        {
            EventTopics.LipSyncRms,
            EventTopics.EmotionTag,
            EventTopics.PresenceChanged,
            EventTopics.StatusChanged,
        };
        Assert.Equal(expected, EventTopics.PetTopics);
    }

    [Fact]
    public void PetTopics_AreAllKnown()
    {
        // All topics must be recognized by the daemon.
        Assert.All(EventTopics.PetTopics, topic =>
            Assert.True(EventTopics.IsKnown(topic),
                $"PetTopics contains unknown topic: {topic}"));
    }

    [Fact]
    public void DaemonClient_HasNoDirectClientChannel()
    {
        // DaemonClient must only expose the daemon WS endpoint — no direct
        // client-to-client transport.
        Assert.Equal("ws://127.0.0.1:6121", DaemonClient.DefaultEndpoint);
    }

    [Fact]
    public void DaemonClient_MembersHaveNoForbiddenNames()
    {
        // The DaemonClient type must not expose any method or property that
        // could be used for direct client-to-client communication.
        var type = typeof(DaemonClient);
        var publicMembers = type.GetMembers(
            System.Reflection.BindingFlags.Public |
            System.Reflection.BindingFlags.Instance |
            System.Reflection.BindingFlags.Static);

        var forbiddenPatterns = new[] { "broadcast", "ipc", "postMessage", "directChannel", "peer" };
        foreach (var member in publicMembers)
        {
            foreach (var pattern in forbiddenPatterns)
            {
                Assert.False(
                    member.Name.IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0,
                    $"DaemonClient exposes member '{member.Name}' matching forbidden pattern '{pattern}'. " +
                    "Coordination must flow through daemon only.");
            }
        }
    }
}