using System;
using System.Globalization;

namespace AnimaPet.Speech;

/// <summary>Process configuration for the Godot client's local speech engine.</summary>
public static class SpeechSampleRate
{
    public const string EnvironmentVariable = "PIPER_SAMPLE_RATE";

    /// <summary>
    /// Resolve the Piper WAV sample rate. Invalid overrides fail loudly instead
    /// of silently decoding every voice at the wrong rate.
    /// </summary>
    public static int ResolvePiperSampleRate(string? envValue, int fallback = 22050)
    {
        if (string.IsNullOrWhiteSpace(envValue))
            return fallback;
        if (!int.TryParse(envValue.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var rate)
            || rate <= 0)
            throw new FormatException(
                $"{EnvironmentVariable} must be a positive integer (got '{envValue}').");
        return rate;
    }
}
