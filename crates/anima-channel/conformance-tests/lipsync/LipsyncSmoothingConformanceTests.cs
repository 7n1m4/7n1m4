// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.IO;
using System.Text.Json;
using AnimaPet.Renderers;
using Xunit;

namespace AnimaConformanceTests;

/// <summary>
/// C# leg of the lip-sync smoothing conformance fixture (airi-2z6). Each
/// step's expected weight is the exact f32 emitted by the Rust smoother for
/// <c>crates/anima-channel/fixtures/lipsync/smoothing.basic.json</c>.
/// </summary>
public sealed class LipsyncSmoothingConformanceTests
{
    private readonly record struct Step(float Rms, float Dt, float ExpectedWeight);

    private static (float DecaySeconds, Step[] Steps) LoadFixture()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "lipsync", "smoothing.basic.json");
        Assert.True(File.Exists(path), $"lipsync fixture not found: {path}");
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        Assert.Equal("lipsync-smoothing-v1", root.GetProperty("schema").GetString());
        var decay = root.GetProperty("decay_seconds").GetSingle();
        var steps = new Step[root.GetProperty("steps").GetArrayLength()];
        var i = 0;
        foreach (var element in root.GetProperty("steps").EnumerateArray())
        {
            steps[i++] = new Step(
                element.GetProperty("rms").GetSingle(),
                element.GetProperty("dt").GetSingle(),
                element.GetProperty("expected_weight").GetSingle());
        }
        return (decay, steps);
    }

    private static void AssertSameFloat(float expected, float actual, string context)
    {
        Assert.True(
            BitConverter.SingleToUInt32Bits(expected) == BitConverter.SingleToUInt32Bits(actual),
            $"{context}: expected f32 bits {BitConverter.SingleToUInt32Bits(expected):x8}, got {BitConverter.SingleToUInt32Bits(actual):x8}");
    }

    [Fact]
    public void GodotSmoothing_MatchesSharedFixture()
    {
        var (decay, steps) = LoadFixture();
        AssertSameFloat(LipSyncSmoother.DecaySeconds, decay, "decay_seconds");

        var smoother = new LipSyncSmoother();
        for (var i = 0; i < steps.Length; i++)
        {
            var step = steps[i];
            smoother.SetRms(step.Rms);
            var weight = smoother.Tick(step.Dt);
            AssertSameFloat(step.ExpectedWeight, weight, $"step {i} ({step}) weight");
            AssertSameFloat(weight, smoother.Weight, $"step {i} Weight property");
        }
    }
}
