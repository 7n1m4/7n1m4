using System;
using System.Threading;
using System.Threading.Tasks;

namespace AnimaPet.Audio
{
    public interface IPcmSource
    {
        int SampleRate { get; }
        int Channels { get; }
        float[] Samples { get; }
    }

    public sealed record PcmBuffer(float[] Samples, int SampleRate, int Channels = 1) : IPcmSource;

    public interface ITtsEngine
    {
        string Id { get; }

        /// <summary>Sample rate of every buffer returned by this engine.</summary>
        int SampleRate { get; }

        Task<IPcmSource> SynthesizeAsync(string text, string? voice = null, CancellationToken cancellationToken = default);
    }

    public static class PcmEncoding
    {
        public static byte[] FloatsToPcm16(ReadOnlySpan<float> samples)
        {
            var bytes = new byte[samples.Length * sizeof(short)];
            for (var i = 0; i < samples.Length; i++)
            {
                var clamped = Math.Clamp(samples[i], -1f, 1f);
                var value = (short)Math.Round(clamped * short.MaxValue);
                bytes[i * 2] = (byte)(value & 0xFF);
                bytes[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
            }
            return bytes;
        }

        public static float[] Pcm16BytesToFloats(ReadOnlySpan<byte> bytes)
        {
            var count = bytes.Length / sizeof(short);
            var samples = new float[count];
            for (var i = 0; i < count; i++)
            {
                var raw = (short)(bytes[i * 2] | (bytes[i * 2 + 1] << 8));
                samples[i] = raw / (float)short.MaxValue;
            }
            return samples;
        }
    }
}
