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
    ///   1. A `piper` executable on PATH (or `PiperPath` / `PIPER_PATH`).
    ///   2. A voice model `.onnx` + its `.onnx.json` (downloaded assets).
    ///   Set `PIPER_MODEL` to the `.onnx` path (or pass via constructor).
    ///
    /// Fetch/install step (run once, outside the repo):
    ///   - Piper releases / build instructions: https://github.com/rhasspy/piper
    ///   - Voice models (Apache-2.0 / CC-BY-SA per voice card):
    ///     https://huggingface.co/rhasspy/piper-voices
    ///     e.g. en_US-lessac-medium.onnx (+ .onnx.json)
    /// Check the selected voice's Hugging Face model card for its license
    /// before shipping; no model artifact is committed here.
    ///
    /// Pass <c>--output_file</c> WAV through <see cref="WavPcmReader"/>, which
    /// is the same decode path used by the deterministic Option C test harness.
    /// </summary>
    public sealed class PiperTtsEngine : ITtsEngine
    {
        /// <summary>Default Piper CLI synthesis sample rate (22.05 kHz).</summary>
        public const int DefaultSampleRate = 22050;

        public string Id => "piper";

        public string PiperPath { get; }
        public string ModelPath { get; }

        /// <inheritdoc/>
        public int SampleRate { get; }

        public PiperTtsEngine(
            string? piperPath = null,
            string? modelPath = null,
            int sampleRate = DefaultSampleRate)
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
            if (sampleRate <= 0)
                throw new ArgumentOutOfRangeException(nameof(sampleRate), "sampleRate must be positive.");
            SampleRate = sampleRate;
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

                // Drain stderr from the moment the child starts: a piper that
                // fills the OS pipe would otherwise block forever while we wait
                // for exit. The drain is uncancelled so it always reaches EOF.
                var stderrTask = proc.StandardError.ReadToEndAsync();
                try
                {
                    await proc.StandardInput.WriteAsync(text).ConfigureAwait(false);
                    proc.StandardInput.Close();
                    await proc.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
                    var err = await stderrTask.ConfigureAwait(false);
                    if (proc.ExitCode != 0)
                        throw new InvalidOperationException($"piper exited {proc.ExitCode}: {err}");

                    var pcm = WavPcmReader.ReadFile(outPath);
                    if (pcm.SampleRate != SampleRate)
                        throw new InvalidDataException(
                            $"Piper declared {SampleRate} Hz but decoded WAV at {pcm.SampleRate} Hz.");
                    return pcm;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    KillProcessTree(proc);
                    // Uncancelled wait: deleting the temp WAV while the child
                    // can still write it would race the child's file handle.
                    await proc.WaitForExitAsync().ConfigureAwait(false);
                    try { await stderrTask.ConfigureAwait(false); } catch { }
                    throw;
                }
            }
            finally
            {
                try { if (File.Exists(outPath)) File.Delete(outPath); } catch { }
            }
        }

        private static void KillProcessTree(Process proc)
        {
            try
            {
                if (!proc.HasExited)
                    proc.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException) { } // exited between check and kill
            catch (AggregateException) { } // a grandchild may already be gone
        }
    }
}
