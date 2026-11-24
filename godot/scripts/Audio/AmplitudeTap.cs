using System;

namespace AnimaPet.Audio
{
    public sealed class AmplitudeTap
    {
        public const int DefaultWindowMs = 50;
        public const int MinWindowMs = 5;

        private readonly int _sampleRate;
        private readonly int _windowSamples;
        private readonly Action<float>? _sink;

        private float _acc;
        private int _count;
        private bool _finished;
        private bool _aborted;
        private bool _doneEmitted;

        private readonly object _gate = new();

        public AmplitudeTap(int sampleRate, int windowMs = DefaultWindowMs, Action<float>? amplitudeSink = null)
        {
            if (sampleRate <= 0)
                throw new ArgumentOutOfRangeException(nameof(sampleRate), "sampleRate must be positive.");

            var clampedWindowMs = Math.Max(MinWindowMs, windowMs);
            _sampleRate = sampleRate;
            _windowSamples = Math.Max(1, sampleRate * clampedWindowMs / 1000);
            _sink = amplitudeSink;
        }

        public AmplitudeTap(IPcmSource source, int windowMs = DefaultWindowMs, Action<float>? amplitudeSink = null)
            : this(source.SampleRate, windowMs, amplitudeSink)
        {
        }

        public int SampleRate => _sampleRate;
        public int WindowSamples => _windowSamples;
        public int WindowMs => _windowSamples * 1000 / _sampleRate;

        public bool IsAborted
        {
            get => _aborted;
            set => _aborted = value;
        }

        public bool IsCompleted => _finished;
        public bool DoneEmitted => _doneEmitted;
        public int EmissionCount { get; private set; }

        public event Action<float>? Amplitude;
        public event Action? Done;
        public event Action? Aborted;

        public void Abort()
        {
            _aborted = true;
            Aborted?.Invoke();
        }

        public void Reset()
        {
            lock (_gate)
            {
                _acc = 0f;
                _count = 0;
                _finished = false;
                _doneEmitted = false;
                EmissionCount = 0;
            }
        }

        public float Push(float sample)
        {
            if (_aborted)
                return sample;

            lock (_gate)
            {
                _acc += sample * sample;
                _count++;
                if (_count >= _windowSamples)
                    FlushWindowLocked();
            }
            return sample;
        }

        public void Process(ReadOnlySpan<float> samples)
        {
            for (var i = 0; i < samples.Length; i++)
                Push(samples[i]);
        }

        public void Process(IPcmSource source) => Process(source.Samples);

        public void Flush()
        {
            lock (_gate)
            {
                if (_count == 0) return;
                FlushWindowLocked();
            }
        }

        public void Complete()
        {
            lock (_gate)
            {
                if (_finished) return;

                if (_count > 0)
                FlushWindowLocked();

                _finished = true;

                if (!_aborted && !_doneEmitted)
                {
                    _doneEmitted = true;
                    Done?.Invoke();
                }
            }
        }

        private void FlushWindowLocked()
        {
            if (_count == 0) return;

            var mean = _acc / _count;
            var level = MathF.Sqrt(mean);
            if (float.IsNaN(level) || float.IsInfinity(level))
                level = 0f;
            level = Math.Clamp(level, 0f, 1f);

            _acc = 0f;
            _count = 0;
            EmissionCount++;

            Amplitude?.Invoke(level);
            _sink?.Invoke(level);
        }
    }
}
