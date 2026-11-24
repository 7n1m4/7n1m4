using System;
using System.IO;
using System.Text;
using AnimaPet.Audio;

namespace AnimaPet.Tests;

/// <summary>
/// Option C harness: builds a real, spec-shaped PCM16 WAVE byte stream from a
/// deterministic tone. No audio is faked — the bytes are decoded through the
/// same <see cref="WavPcmReader"/> the Piper engine uses, so tests exercise the
/// real decoder → tap → renderer path without requiring a downloaded model.
/// </summary>
internal static class WavFixture
{
    public const int SampleRate = 22050;
    public const float ToneAmplitude = 0.5f;
    public const float ToneFrequency = 220f;

    public const int WindowMs = 50;

    public static int WindowSamples(int sampleRate = SampleRate) =>
        sampleRate * WindowMs / 1000;

    /// <summary>Whole-window tone: no tiny tail level can skew the final RMS.</summary>
    public static float[] ToneForWindows(int windows, int sampleRate = SampleRate) =>
        Tone(sampleRate, windows * WindowSamples(sampleRate) / (double)sampleRate);

    public static float[] Tone(int sampleRate = SampleRate, double seconds = 0.5)
    {
        var count = (int)Math.Round(sampleRate * seconds);
        var samples = new float[count];
        for (var i = 0; i < count; i++)
            samples[i] = ToneAmplitude * (float)Math.Sin(2 * Math.PI * ToneFrequency * i / sampleRate);
        return samples;
    }

    public static float[] Silence(int sampleRate = SampleRate, double seconds = 0.5) =>
        new float[(int)Math.Round(sampleRate * seconds)];

    public static byte[] Pcm16Wav(float[] samples, int sampleRate = SampleRate, ushort channels = 1)
    {
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms, Encoding.ASCII, leaveOpen: true);
        bw.Write(Encoding.ASCII.GetBytes("RIFF"));
        bw.Write(0); // RIFF size, patched below
        bw.Write(Encoding.ASCII.GetBytes("WAVE"));
        bw.Write(Encoding.ASCII.GetBytes("fmt "));
        bw.Write(16);
        bw.Write((ushort)1); // PCM
        bw.Write(channels);
        bw.Write(sampleRate);
        var blockAlign = (ushort)(channels * sizeof(short));
        bw.Write(sampleRate * blockAlign); // byte rate
        bw.Write(blockAlign);
        bw.Write((ushort)16); // bits per sample
        bw.Write(Encoding.ASCII.GetBytes("data"));
        var pcm = PcmEncoding.FloatsToPcm16(samples);
        bw.Write(pcm.Length);
        bw.Write(pcm);
        var total = (int)ms.Length;
        ms.Seek(4, SeekOrigin.Begin);
        bw.Write(total - 8);
        return ms.ToArray();
    }
}
