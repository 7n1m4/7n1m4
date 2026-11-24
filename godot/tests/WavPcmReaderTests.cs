using System;
using System.IO;
using System.Text;
using Xunit;
using AnimaPet.Audio;

namespace AnimaPet.Tests;

public sealed class WavPcmReaderTests
{
    private static byte[] BuildWav(float[] samples, int sampleRate, ushort bits = 16, ushort channels = 1)
    {
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms, Encoding.ASCII, leaveOpen: true);
        // RIFF header
        bw.Write(Encoding.ASCII.GetBytes("RIFF"));
        bw.Write(0); // size placeholder
        bw.Write(Encoding.ASCII.GetBytes("WAVE"));
        // fmt chunk
        bw.Write(Encoding.ASCII.GetBytes("fmt "));
        bw.Write(16);
        bw.Write((ushort)1); // PCM
        bw.Write(channels);
        bw.Write(sampleRate);
        var blockAlign = (ushort)(channels * bits / 8);
        var byteRate = sampleRate * blockAlign;
        bw.Write(byteRate);
        bw.Write(blockAlign);
        bw.Write(bits);
        // data chunk
        bw.Write(Encoding.ASCII.GetBytes("data"));
        if (bits == 16)
        {
            var bytes = PcmEncoding.FloatsToPcm16(samples);
            bw.Write(bytes.Length);
            bw.Write(bytes);
        }
        else
        {
            throw new NotSupportedException();
        }
        // fix RIFF size
        var total = (int)ms.Length;
        ms.Seek(4, SeekOrigin.Begin);
        bw.Write(total - 8);
        ms.Seek(0, SeekOrigin.End);
        return ms.ToArray();
    }

    [Fact]
    public void RoundTrip_Pcm16()
    {
        var samples = new float[200];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = (float)Math.Sin(2 * Math.PI * i / 50.0);
        var wav = BuildWav(samples, 1000);
        var src = WavPcmReader.ReadBytes(wav);
        Assert.Equal(1000, src.SampleRate);
        Assert.Equal(samples.Length, src.Samples.Length);
        for (var i = 0; i < samples.Length; i++)
            Assert.True(Math.Abs(samples[i] - src.Samples[i]) < 1e-3f);
    }

    [Fact]
    public void Envelope_ViaTap()
    {
        var samples = new float[100];
        for (var i = 0; i < samples.Length; i++) samples[i] = 0.5f;
        var wav = BuildWav(samples, 1000);
        var src = WavPcmReader.ReadBytes(wav);
        var tap = new AmplitudeTap(src);
        int emissions = 0;
        float last = 0;
        tap.Amplitude += v => { emissions++; last = v; };
        tap.Process(src);
        tap.Complete();
        // 100 samples @ 50/window => 2 emissions
        Assert.Equal(2, emissions);
        Assert.True(last > 0.4f && last < 0.6f);
    }

    [Fact]
    public void Fixture_Tone_DecodesToSamePcmShape()
    {
        var tone = WavFixture.Tone();
        var src = WavPcmReader.ReadBytes(WavFixture.Pcm16Wav(tone));

        Assert.Equal(WavFixture.SampleRate, src.SampleRate);
        Assert.Equal(1, src.Channels);
        Assert.Equal(tone.Length, src.Samples.Length);
        // PCM16 round-trip quantizes each sample to within one LSB.
        var tolerance = 1f / short.MaxValue;
        for (var i = 0; i < tone.Length; i++)
            Assert.True(Math.Abs(tone[i] - src.Samples[i]) <= tolerance,
                $"sample {i}: expected {tone[i]}, decoded {src.Samples[i]}");
    }
}
