using System;
using AnimaPet.Audio;
using AnimaPet.Speech;
using Xunit;

namespace AnimaPet.Tests;

public sealed class SpeechSampleRateTests : IDisposable
{
    private readonly string? _original;

    public SpeechSampleRateTests()
    {
        _original = Environment.GetEnvironmentVariable("PIPER_SAMPLE_RATE");
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("PIPER_SAMPLE_RATE", _original);
    }

    [Theory]
    [InlineData(null, 22050)]
    [InlineData("", 22050)]
    [InlineData("   ", 22050)]
    [InlineData("16000", 16000)]
    [InlineData(" 48000 ", 48000)]
    public void ResolvePiperSampleRate_UsesDefaultUnlessValidOverride(string? env, int expected)
    {
        Environment.SetEnvironmentVariable("PIPER_SAMPLE_RATE", env);
        Assert.Equal(expected, SpeechSampleRate.ResolvePiperSampleRate(env));
    }

    [Fact]
    public void PiperEngine_UsesEnvironmentResolvedRate_WithoutRunningABinary()
    {
        Environment.SetEnvironmentVariable("PIPER_SAMPLE_RATE", "16000");
        var rate = SpeechSampleRate.ResolvePiperSampleRate(
            Environment.GetEnvironmentVariable(SpeechSampleRate.EnvironmentVariable));
        var engine = new PiperTtsEngine(modelPath: "not-read.onnx", sampleRate: rate);
        Assert.Equal(16000, engine.SampleRate);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("abc")]
    [InlineData("22050.5")]
    [InlineData("99999999999999999999")]
    public void ResolvePiperSampleRate_RejectsInvalidOverrides(string env)
    {
        Environment.SetEnvironmentVariable("PIPER_SAMPLE_RATE", env);
        var ex = Assert.Throws<FormatException>(() => SpeechSampleRate.ResolvePiperSampleRate(env));
        Assert.Contains("PIPER_SAMPLE_RATE", ex.Message);
    }
}
