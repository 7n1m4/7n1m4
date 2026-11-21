using System;
using System.IO;
using System.Text.Json;
using Xunit;
using AnimaPet.Net;

namespace AnimaPet.Tests;

/// <summary>
/// Golden-fixture tests for <see cref="EventPayloadDecoder"/> (D5,
/// <c>docs/decision-client-bindings.md</c>). The fixtures are the Rust-canonical
/// frames in <c>crates/anima-channel/fixtures/golden/</c>, copied into the test
/// output by <c>AnimaPet.Tests.csproj</c>. Each is a full
/// <c>{"type":"event","topic":…,"data":…}</c> envelope; the decoder consumes its
/// <c>data</c> object and must round-trip it into the matching typed record.
/// Using the Rust fixtures (rather than hand-written ones) pins the real wire
/// field names, including snake_case <c>status.changed</c> fields.
/// </summary>
public sealed class EventPayloadDecoderTests
{
    private static string GoldenDir()
    {
        // AppContext.BaseDirectory points at the test bin output dir; the
        // golden frames are copied there by the csproj <None Include> rule.
        var dir = Path.Combine(AppContext.BaseDirectory, "golden");
        Assert.True(Directory.Exists(dir), $"golden fixtures directory not found: {dir}");
        return dir;
    }

    private static JsonElement LoadGoldenFrame(string name)
    {
        var path = Path.Combine(GoldenDir(), name + ".json");
        Assert.True(File.Exists(path), $"golden fixture not found: {path}");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        return doc.RootElement.Clone();
    }

    private static JsonElement GoldenData(string name)
    {
        var frame = LoadGoldenFrame(name);
        Assert.Equal(JsonValueKind.Object, frame.ValueKind);
        Assert.Equal("event", frame.GetProperty("type").GetString());
        return frame.GetProperty("data").Clone();
    }

    private static object? DecodeGolden(string name, string topic) =>
        EventPayloadDecoder.Decode(topic, GoldenData(name));

    [Theory]
    [InlineData("event.lip_sync_rms.silence", EventTopics.LipSyncRms)]
    [InlineData("event.lip_sync_rms.basic", EventTopics.LipSyncRms)]
    [InlineData("event.lip_sync_rms.peak", EventTopics.LipSyncRms)]
    public void LipSyncRms_RoundTrips(string fixture, string topic)
    {
        var decoded = Assert.IsType<LipSyncRmsData>(DecodeGolden(fixture, topic));
        var src = GoldenData(fixture);

        Assert.Equal(src.GetProperty("actor_id").GetString(), decoded.ActorId);
        Assert.Equal(src.GetProperty("level").GetSingle(), decoded.Level);
        Assert.Equal(src.GetProperty("seq").GetUInt64(), decoded.Seq);
        Assert.Equal(src.GetProperty("ts_ms").GetUInt64(), decoded.TsMs);
    }

    [Fact]
    public void EmotionTag_Emotion_WithDuration_RoundTrips()
    {
        var decoded = Assert.IsType<EmotionTagData>(
            DecodeGolden("event.emotion_tag.emotion", EventTopics.EmotionTag));

        Assert.Equal("character-7", decoded.ActorId);
        Assert.Equal("happy", decoded.Tag);
        Assert.Equal(CueKind.Emotion, decoded.Kind);
        Assert.Equal(0.8f, decoded.Intensity, precision: 4);
        Assert.Equal(3000UL, decoded.DurationMs);
        Assert.Equal(42UL, decoded.Seq);
        Assert.Equal(1700000000200UL, decoded.TsMs);
    }

    [Fact]
    public void EmotionTag_Motion_WithoutDuration_RoundTrips()
    {
        var decoded = Assert.IsType<EmotionTagData>(
            DecodeGolden("event.emotion_tag.motion_no_duration", EventTopics.EmotionTag));

        Assert.Equal("character-7", decoded.ActorId);
        Assert.Equal("wave", decoded.Tag);
        Assert.Equal(CueKind.Motion, decoded.Kind);
        Assert.Equal(0.6f, decoded.Intensity, precision: 4);
        Assert.Null(decoded.DurationMs);
        Assert.Equal(43UL, decoded.Seq);
    }

    [Fact]
    public void EmotionTag_Vfx_RoundTrips()
    {
        var decoded = Assert.IsType<EmotionTagData>(
            DecodeGolden("event.emotion_tag.vfx", EventTopics.EmotionTag));
        Assert.Equal(CueKind.Vfx, decoded.Kind);
        Assert.Equal("sparkle", decoded.Tag);
        Assert.Equal(1.0f, decoded.Intensity, precision: 4);
        Assert.Equal(1500UL, decoded.DurationMs);
    }

    [Theory]
    [InlineData("event.presence_changed.online", "online")]
    [InlineData("event.presence_changed.offline", "offline")]
    public void PresenceChanged_RoundTrips(string fixture, string expectedState)
    {
        var decoded = Assert.IsType<PresenceChangedData>(
            DecodeGolden(fixture, EventTopics.PresenceChanged));
        var src = GoldenData(fixture);

        Assert.Equal("user-42", decoded.Subject);
        Assert.Equal(expectedState, decoded.State);
        Assert.Equal(src.GetProperty("seq").GetUInt64(), decoded.Seq);
        Assert.Equal(src.GetProperty("ts_ms").GetUInt64(), decoded.TsMs);
    }

    [Fact]
    public void StatusChanged_Healthy_RoundTrips()
    {
        // The Rust golden frame uses snake_case field names. Reading camelCase
        // here used to decode a healthy daemon to false/false/"".
        var decoded = Assert.IsType<StatusChangedData>(
            DecodeGolden("event.status_changed.healthy", EventTopics.StatusChanged));
        var src = GoldenData("event.status_changed.healthy");

        Assert.True(decoded.CoreAvailable);
        Assert.True(decoded.StoreAvailable);
        Assert.Equal("ok", decoded.StoreHealth);
        Assert.Equal(src.GetProperty("seq").GetUInt64(), decoded.Seq);
        Assert.Equal(src.GetProperty("ts_ms").GetUInt64(), decoded.TsMs);
    }

    [Fact]
    public void StatusChanged_Unhealthy_RoundTrips()
    {
        var decoded = Assert.IsType<StatusChangedData>(
            DecodeGolden("event.status_changed.unhealthy", EventTopics.StatusChanged));
        Assert.False(decoded.CoreAvailable);
        Assert.False(decoded.StoreAvailable);
        Assert.Equal("unavailable", decoded.StoreHealth);
    }

    [Theory]
    [InlineData("event.token_delta.partial")]
    [InlineData("event.token_delta.final")]
    public void TokenDelta_RoundTrips(string fixture)
    {
        var decoded = Assert.IsType<TokenDeltaData>(
            DecodeGolden(fixture, EventTopics.TokenDelta));
        var src = GoldenData(fixture);

        Assert.Equal(src.GetProperty("session_id").GetString(), decoded.SessionId);
        Assert.Equal(src.GetProperty("message_id").GetString(), decoded.MessageId);
        Assert.Equal(src.GetProperty("delta").GetString(), decoded.Delta);
        Assert.Equal(src.GetProperty("index").GetUInt64(), decoded.Index);
        Assert.Equal(src.GetProperty("final").GetBoolean(), decoded.Final);
        Assert.Equal(src.GetProperty("seq").GetUInt64(), decoded.Seq);
        Assert.Equal(src.GetProperty("ts_ms").GetUInt64(), decoded.TsMs);
    }

    [Fact]
    public void UnknownTopic_ReturnsNull()
    {
        var data = JsonDocument.Parse("{}").RootElement;
        Assert.Null(EventPayloadDecoder.Decode("does.not.exist", data));
    }

    [Fact]
    public void NonObjectData_ReturnsNull()
    {
        var data = JsonDocument.Parse("[1,2,3]").RootElement;
        Assert.Null(EventPayloadDecoder.Decode(EventTopics.LipSyncRms, data));
    }

    [Fact]
    public void MissingFields_DegradeToDefaults()
    {
        // A frame missing optional/required fields must not throw; fields
        // absent from the wire degrade to defaults so a new field never
        // crashes the pet.
        var data = JsonDocument.Parse("{}").RootElement;
        var decoded = Assert.IsType<LipSyncRmsData>(
            EventPayloadDecoder.Decode(EventTopics.LipSyncRms, data));
        Assert.Equal(string.Empty, decoded.ActorId);
        Assert.Equal(0f, decoded.Level);
        Assert.Equal(0UL, decoded.Seq);
    }

    [Fact]
    public void UnknownEmotionKind_DegradesToEmotion()
    {
        var data = JsonDocument.Parse(
            """{"actor_id":"a","tag":"t","kind":"future-kind","intensity":0.5}""")
            .RootElement;
        var decoded = Assert.IsType<EmotionTagData>(
            EventPayloadDecoder.Decode(EventTopics.EmotionTag, data));
        Assert.Equal(CueKind.Emotion, decoded.Kind);
    }

    [Fact]
    public void StringLevel_IsParsedAsFloat()
    {
        // Defensive: some producers may send numeric strings.
        var data = JsonDocument.Parse(
            """{"actor_id":"a","level":"0.5","seq":1,"ts_ms":2}""")
            .RootElement;
        var decoded = Assert.IsType<LipSyncRmsData>(
            EventPayloadDecoder.Decode(EventTopics.LipSyncRms, data));
        Assert.Equal(0.5f, decoded.Level, precision: 4);
    }

    [Fact]
    public void EveryGoldenFrame_IsValidEnvelope()
    {
        foreach (var path in Directory.EnumerateFiles(GoldenDir(), "event.*.json"))
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var frame = doc.RootElement;
            Assert.Equal(JsonValueKind.Object, frame.ValueKind);
            Assert.Equal("event", frame.GetProperty("type").GetString());
            Assert.False(string.IsNullOrEmpty(frame.GetProperty("topic").GetString()));
            Assert.Equal(JsonValueKind.Object, frame.GetProperty("data").ValueKind);
        }
    }
}
