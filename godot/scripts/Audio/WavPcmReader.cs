using System;
using System.IO;
using System.Text;

namespace AnimaPet.Audio
{
    /// <summary>
    /// Option C test harness: decodes a WAV file into an <see cref="IPcmSource"/>.
    /// Supports PCM (format 1) 16-bit and 32-bit, and IEEE float (format 3)
    /// 32-bit. No external decoder dependency; suitable for deterministic
    /// envelope tests and as the fallback PCM source for the lip-sync driver.
    /// </summary>
    public static class WavPcmReader
    {
        public static IPcmSource ReadFile(string path)
        {
            using var fs = File.OpenRead(path);
            return ReadStream(fs);
        }

        public static IPcmSource ReadBytes(byte[] bytes)
        {
            using var ms = new MemoryStream(bytes);
            return ReadStream(ms);
        }

        public static IPcmSource ReadStream(Stream stream)
        {
            using var br = new BinaryReader(stream, Encoding.ASCII, leaveOpen: true);
            // RIFF header
            if (new string(br.ReadChars(4)) != "RIFF") throw new InvalidDataException("Not a RIFF file.");
            br.ReadInt32(); // file size
            if (new string(br.ReadChars(4)) != "WAVE") throw new InvalidDataException("Not a WAVE file.");

            ushort audioFormat = 0;
            ushort channels = 0;
            int sampleRate = 0;
            ushort bitsPerSample = 0;
            byte[]? pcmData = null;

            while (stream.Position < stream.Length)
            {
                var chunkId = new string(br.ReadChars(4));
                var chunkSize = br.ReadInt32();
                if (chunkSize < 0) throw new InvalidDataException("Bad chunk size.");
                if (chunkId == "fmt ")
                {
                    audioFormat = br.ReadUInt16();
                    channels = br.ReadUInt16();
                    sampleRate = br.ReadInt32();
                    br.ReadInt32(); // byte rate
                    br.ReadUInt16(); // block align
                    bitsPerSample = br.ReadUInt16();
                    // skip any extra fmt bytes
                    var consumed = 16;
                    if (chunkSize > consumed)
                        br.ReadBytes(chunkSize - consumed);
                }
                else if (chunkId == "data")
                {
                    pcmData = br.ReadBytes(chunkSize);
                }
                else
                {
                    br.ReadBytes(chunkSize);
                }
                // word-align
                if (chunkSize % 2 == 1 && stream.Position < stream.Length)
                    br.ReadByte();
            }

            if (pcmData is null) throw new InvalidDataException("No data chunk.");
            if (channels == 0 || sampleRate == 0) throw new InvalidDataException("Missing fmt chunk.");

            float[] samples;
            if (audioFormat == 1) // PCM
            {
                if (bitsPerSample == 16)
                    samples = PcmEncoding.Pcm16BytesToFloats(pcmData);
                else if (bitsPerSample == 8)
                {
                    samples = new float[pcmData.Length];
                    for (var i = 0; i < pcmData.Length; i++)
                        samples[i] = (pcmData[i] - 128) / 128f;
                }
                else
                    throw new NotSupportedException($"PCM {bitsPerSample}-bit not supported.");
            }
            else if (audioFormat == 3) // IEEE float
            {
                if (bitsPerSample == 32)
                {
                    samples = new float[pcmData.Length / 4];
                    Buffer.BlockCopy(pcmData, 0, samples, 0, pcmData.Length);
                }
                else
                    throw new NotSupportedException($"Float {bitsPerSample}-bit not supported.");
            }
            else
                throw new NotSupportedException($"Audio format {audioFormat} not supported.");

            // If multi-channel, downmix to mono by averaging (matches tap source rate).
            if (channels > 1)
            {
                var mono = new float[samples.Length / channels];
                for (var i = 0; i < mono.Length; i++)
                {
                    float acc = 0f;
                    for (var c = 0; c < channels; c++)
                        acc += samples[i * channels + c];
                    mono[i] = acc / channels;
                }
                samples = mono;
            }

            return new PcmBuffer(samples, sampleRate, 1);
        }
    }
}
