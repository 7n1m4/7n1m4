using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AnimaPet.Audio
{
    /// <summary>
    /// Option B seam: Piper (piper-tts) on-device synth. Produces raw PCM by
    /// shelling out to a locally installed `piper` binary and decoding the
    /// resulting WAV via <see cref="WavPcmReader"/>. No proprietary binaries or
    /// model files are committed; the engine requires:
    ///   1. A `piper` executable on PATH (or `PiperPath`).
    ///   2. A voice model `.onnx` + its `.onnx.json` (downloaded assets).
    /// Fetch step (run once, outside the repo):
    ///   - Install piper: https://github.com/rhasspy/piper/releases
    ///   - Download a voice: https://huggingface.co/rhasspy/piper-voices
    ///     e.g. en_US-lessac-medium.onnx (+ .onnx.json)
    ///   - Set PIPER_MODEL to the .onnx path (or pass via constructor).
    /// </summary>
    public sealed class PiperTtsEngine : ITtsEngine
    {
        public string Id => "piper";

        public string PiperPath { get; }
        public string ModelPath { get; }

        public PiperTtsEngine(string? piperPath = null, string? modelPath = null)
        {
            PiperPath = piperPath
                ?? Environment.GetEnvironmentVariable("PIPER_PATH")
                ?? "piper";
            ModelPath = modelPath
                ?? Environment.GetEnvironmentVariable("PIPER_MODEL")
                ?? string.Empty;
            if (string.IsNullOrWhiteSpace(ModelPath))
                throw new ArgumentException(
                    "Piper model path is required (PIPER_MODEL env or constructor).", nameof(modelPath));
        }

        public async Task<IPcmSource> SynthesizeAsync(
            string text, string? voice = null, CancellationToken cancellationToken = default)
        {
            if (string.IsNullOrWhiteSpace(text))
                throw new ArgumentException("text must not be empty.", nameof(text));
            if (!File.Exists(ModelPath))
                throw new FileNotFoundException("Piper model not found.", ModelPath);

            var outPath = Path.Combine(Path.GetTempPath(), $"piper-{Guid.NewGuid():N}.wav");
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = PiperPath,
                    Arguments = $"--model \"{ModelPath}\" --output_file \"{outPath}\"",
                    RedirectStandardInput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                using var proc = Process.Start(psi)
                    ?? throw new InvalidOperationException("Failed to start piper.");
                await proc.StandardInput.WriteAsync(text);
                proc.StandardInput.Close();
                await proc.WaitForExitAsync(cancellationToken);
                if (proc.ExitCode != 0)
                {
                    var err = await proc.StandardError.ReadToEndAsync(cancellationToken);
                    throw new InvalidOperationException($"piper exited {proc.ExitCode}: {err}");
                }
                return WavPcmReader.ReadFile(outPath);
            }
            finally
            {
                try { if (File.Exists(outPath)) File.Delete(outPath); } catch { }
            }
        }
    }
}
