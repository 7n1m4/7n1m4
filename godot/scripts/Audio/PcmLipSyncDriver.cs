using System;
using AnimaPet.Renderers;

namespace AnimaPet.Audio
{
    /// <summary>
    /// Bridges a PCM-derived <see cref="AmplitudeTap"/> into an
    /// <see cref="IPetRenderer"/> by forwarding each amplitude level to
    /// <see cref="IPetRenderer.SetLipSync"/>. Owns the tap's lifetime wiring
    /// only; playback/PCM production is supplied by an <see cref="ITtsEngine"/>
    /// or an Option-C audio-file decoder.
    /// </summary>
    public sealed class PcmLipSyncDriver : IDisposable
    {
        private readonly IPetRenderer _renderer;
        private readonly AmplitudeTap _tap;
        private bool _disposed;

        public PcmLipSyncDriver(IPetRenderer renderer, AmplitudeTap tap)
        {
            _renderer = renderer ?? throw new ArgumentNullException(nameof(renderer));
            _tap = tap ?? throw new ArgumentNullException(nameof(tap));
            _tap.Amplitude += OnAmplitude;
        }

        public PcmLipSyncDriver(IPetRenderer renderer, int sampleRate, int windowMs = AmplitudeTap.DefaultWindowMs)
            : this(renderer, new AmplitudeTap(sampleRate, windowMs))
        {
        }

        public AmplitudeTap Tap => _tap;

        public IPetRenderer Renderer => _renderer;

        /// <summary>Feed a PCM source through the tap and into the renderer.</summary>
        public void Feed(IPcmSource source)
        {
            if (source is null) throw new ArgumentNullException(nameof(source));
            _tap.Process(source);
            _tap.Complete();
        }

        /// <summary>Feed raw samples through the tap and into the renderer.</summary>
        public void Feed(ReadOnlySpan<float> samples)
        {
            _tap.Process(samples);
            _tap.Complete();
        }

        private void OnAmplitude(float level)
        {
            if (_disposed) return;
            _renderer.SetLipSync(level);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _tap.Amplitude -= OnAmplitude;
        }
    }
}
