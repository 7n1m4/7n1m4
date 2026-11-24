using System;
using Xunit;
using AnimaPet.Audio;

namespace AnimaPet.Tests;

public sealed class AmplitudeTapTests
{
    [Fact]
    public void WindowSize_MatchesSampleRate()
    {
        var tap = new AmplitudeTap(1000);
        Assert.Equal(50, tap.WindowSamples);
    }

    [Fact]
    public void FullWindow_EmitsRms()
    {
        var tap = new AmplitudeTap(1000);
        float? last = null;
        tap.Amplitude += v => last = v;
        for (var i = 0; i < 50; i++) tap.Push(1f);
        Assert.Equal(1, tap.EmissionCount);
        Assert.Equal(1f, last!.Value, 4);
    }

    [Fact]
    public void PartialTail_FlushesOnComplete()
    {
        var tap = new AmplitudeTap(1000);
        float? last = null;
        tap.Amplitude += v => last = v;
        for (var i = 0; i < 25; i++) tap.Push(0.5f);
        Assert.Equal(0, tap.EmissionCount);
        tap.Complete();
        Assert.Equal(1, tap.EmissionCount);
        Assert.NotNull(last);
    }

    [Fact]
    public void Aborted_DrainsSilently_NoDone()
    {
        var tap = new AmplitudeTap(1000);
        tap.Abort();
        for (var i = 0; i < 100; i++) tap.Push(1f);
        Assert.Equal(0, tap.EmissionCount);
        tap.Complete();
        Assert.False(tap.DoneEmitted);
    }

    [Fact]
    public void Complete_EmitsExactlyOneDone()
    {
        var tap = new AmplitudeTap(1000);
        int done = 0;
        tap.Done += () => done++;
        tap.Complete();
        tap.Complete();
        Assert.Equal(1, done);
    }

    [Fact]
    public void Level_ClampedToOne()
    {
        var tap = new AmplitudeTap(1000);
        float? last = null;
        tap.Amplitude += v => last = v;
        for (var i = 0; i < 50; i++) tap.Push(2f);
        Assert.Equal(1f, last!.Value);
    }

    [Fact]
    public void Process_IPcmSource_Works()
    {
        var samples = new float[60];
        for (var i = 0; i < samples.Length; i++) samples[i] = 0.25f;
        var src = new PcmBuffer(samples, 1000);
        var tap = new AmplitudeTap(src);
        int emissions = 0;
        tap.Amplitude += _ => emissions++;
        tap.Process(src);
        tap.Complete();
        // 60 samples -> 1 full window + 10 tail
        Assert.Equal(2, emissions);
    }
}
