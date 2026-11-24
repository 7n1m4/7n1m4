using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using AnimaPet.Renderers;

namespace AnimaPet.Audio
{
    /// <summary>
    /// Client-owned speech path: <see cref="ITtsEngine"/> → PCM →
    /// <see cref="AmplitudeTap"/> → <see cref="PcmLipSyncDriver"/> →
    /// <see cref="IPetRenderer.SetLipSync"/>. The daemon supplies neither the
    /// audio nor the RMS frames (docs/decision-bridge-scope.md), so this
    /// service works with no daemon connection at all.
    /// </summary>
    /// <remarks>
    /// Pure managed code — no Godot types — so the whole path is testable off
    /// engine. The Godot scene hosts the physical player that plays the same
    /// samples the tap consumes.
    /// </remarks>
    public sealed class LocalSpeechPipeline : IDisposable
    {
        private readonly ITtsEngine _engine;
        private readonly PcmLipSyncDriver _driver;
        private bool _disposed;

        public LocalSpeechPipeline(ITtsEngine engine, IPetRenderer renderer)
        {
            _engine = engine ?? throw new ArgumentNullException(nameof(engine));
            if (renderer is null) throw new ArgumentNullException(nameof(renderer));
            _driver = new PcmLipSyncDriver(renderer, engine.SampleRate);
        }

        public ITtsEngine Engine => _engine;
        public PcmLipSyncDriver Driver => _driver;
        public IPetRenderer Renderer => _driver.Renderer;
        public AmplitudeTap Tap => _driver.Tap;

        /// <summary>
        /// Synthesize locally, then tap the returned PCM into the renderer.
        /// The returned source is the exact mono buffer the caller's audio
        /// player should play; the tap reads those same samples, never a
        /// synthetic amplitude.
        /// </summary>
        public async Task<IPcmSource> SpeakAsync(
            string text, string? voice = null, CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            // Keep the continuation on the caller's context: the driver's
            // renderer sink must observe utterances in request order (Godot
            // resumes this on the main loop; tests await on their own context).
            var synthesized = await _engine.SynthesizeAsync(text, voice, cancellationToken).ConfigureAwait(true)
                ?? throw new InvalidOperationException("TTS engine returned no PCM source.");

            // A superseded utterance may finish synthesis after cancellation;
            // it must never flush stale RMS into the renderer.
            cancellationToken.ThrowIfCancellationRequested();
            if (synthesized.SampleRate <= 0)
                throw new InvalidDataException("TTS PCM source has no sample rate.");
            if (synthesized.SampleRate != _engine.SampleRate)
                throw new InvalidDataException(
                    $"TTS engine declared {_engine.SampleRate} Hz but returned {synthesized.SampleRate} Hz PCM.");

            var pcm = ToMono(synthesized);
            _driver.Feed(pcm, cancellationToken);
            return pcm;
        }

        /// <summary>WavPcmReader already downmixes; this covers other engines.</summary>
        private static IPcmSource ToMono(IPcmSource source)
        {
            if (source.Channels <= 1) return source;
            if (source.Samples.Length % source.Channels != 0)
                throw new InvalidDataException("Interleaved PCM sample count is not a multiple of its channel count.");

            var mono = new float[source.Samples.Length / source.Channels];
            for (var i = 0; i < mono.Length; i++)
            {
                var acc = 0f;
                for (var c = 0; c < source.Channels; c++)
                    acc += source.Samples[i * source.Channels + c];
                mono[i] = acc / source.Channels;
            }
            return new PcmBuffer(mono, source.SampleRate, 1);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _driver.Dispose();
        }
    }
}
