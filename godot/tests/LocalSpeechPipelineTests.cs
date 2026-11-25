using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using AnimaPet.Audio;
using AnimaPet.Renderers;

namespace AnimaPet.Tests;

/// <summary>
/// End-to-end proof of the client-local speech path:
/// engine → real PCM → WAVE decode → RMS tap → renderer sink → observable
/// scale / animation key. No daemon connection or microphone is involved.
/// </summary>
public sealed class LocalSpeechPipelineTests
{
    /// <summary>
    /// xunit v2 resolves <see cref="FactAttribute.Skip"/> at discovery time.
    /// Deriving the attribute lets the missing-asset case be reported as a
    /// genuine skip with an opt-in reason, instead of a passing test that
    /// returns before exercising real Piper.
    /// </summary>
    private sealed class RealPiperFactAttribute : FactAttribute
    {
        public RealPiperFactAttribute()
        {
            if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("PIPER_MODEL")))
            {
                Skip = "Opt-in: set PIPER_MODEL (and optionally PIPER_PATH) to run the real-Piper pipeline test; no model or fake audio is used unless assets are supplied.";
            }
        }
    }

    private static readonly CardRenderConfig RendererConfig =
        new(PetRenderBackend.Vrm, "res://models/test.vrm");

    private sealed class FixtureEngine : ITtsEngine
    {
        private readonly byte[] _wav;

        public FixtureEngine(byte[] wav, int sampleRate = WavFixture.SampleRate)
        {
            _wav = wav;
            SampleRate = sampleRate;
        }

        public string Id => "wav-fixture";
        public int SampleRate { get; }
        public string? LastText { get; private set; }
        public int Calls { get; private set; }

        public Task<IPcmSource> SynthesizeAsync(
            string text, string? voice = null, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            LastText = text;
            Calls++;
            return Task.FromResult(WavPcmReader.ReadBytes(_wav));
        }
    }

    private static (GenericPetRenderer Renderer, LocalSpeechPipeline Pipeline, FixtureEngine Engine) CreatePipeline(
        byte[] wav)
    {
        var engine = new FixtureEngine(wav);
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        renderer.Initialize(RendererConfig);
        return (renderer, new LocalSpeechPipeline(engine, renderer), engine);
    }

    [Fact]
    public async Task Engine_WavDecode_Tap_Renderer_ProducesObservableLipSync()
    {
        // ROOT CAUSE:
        // Before airi-0v8 the Godot renderer had an RMS sink but no producer:
        // Main.cs never synthesized audio and subscribed to a daemon topic the
        // daemon does not publish (docs/decision-bridge-scope.md). This test
        // pins the corrected path: decoded PCM's RMS must drive the renderer's
        // scale and animation key, with no daemon audio or fake amplitudes.
        // Ten whole 50 ms windows: a partial tail near a sine zero crossing
        // would make the final (smoothed) RMS unrepresentative of the tone.
        var tone = WavFixture.ToneForWindows(10);
        var (renderer, pipeline, engine) = CreatePipeline(WavFixture.Pcm16Wav(tone));
        using (pipeline)
        {
            var pcm = await pipeline.SpeakAsync("hello from local TTS");

            Assert.Equal("hello from local TTS", engine.LastText);
            Assert.Equal(tone.Length, pcm.Samples.Length);
            Assert.Equal(WavFixture.SampleRate, pcm.SampleRate);

            // Ten 50 ms non-overlapping windows, no partial tail.
            Assert.Equal(10, pipeline.Tap.EmissionCount);
            Assert.True(pipeline.Tap.IsCompleted);

            renderer.Process(0.016);
            Assert.InRange(renderer.LipSyncWeight, 0.2f, 0.7f);
            // 0.5-amplitude sine → RMS ≈ 0.354 → scale ≈ 1 + 0.25 × 0.354.
            Assert.True(renderer.Scale > 1.05f, "tone RMS must visibly scale the renderer");
            Assert.StartsWith("neutral|", renderer.AnimationKey);
            Assert.NotEqual("neutral|0.00", renderer.AnimationKey);
        }
    }

    [Fact]
    public async Task Silence_FromEngine_DoesNotOpenMouth()
    {
        var (renderer, pipeline, _) = CreatePipeline(WavFixture.Pcm16Wav(WavFixture.Silence()));
        using (pipeline)
        {
            await pipeline.SpeakAsync("silence");
            renderer.Process(0.016);

            Assert.Equal(0f, renderer.LipSyncWeight);
            Assert.Equal(1f, renderer.Scale);
            Assert.Equal("neutral|0.00", renderer.AnimationKey);
        }
    }

    private sealed class CancelingEngine : ITtsEngine
    {
        public string Id => "canceling-fixture";
        public int SampleRate => WavFixture.SampleRate;

        public async Task<IPcmSource> SynthesizeAsync(
            string text, string? voice = null, CancellationToken cancellationToken = default)
        {
            // Simulate a slow engine returning real PCM after cancellation:
            // the pipeline must discard it before it reaches the tap.
            await Task.Delay(30, CancellationToken.None).ConfigureAwait(true);
            return WavPcmReader.ReadBytes(WavFixture.Pcm16Wav(WavFixture.Tone(seconds: 0.2)));
        }
    }

    [Fact]
    public async Task SupersededUtterance_DoesNotFeedStaleRms()
    {
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        renderer.Initialize(RendererConfig);
        using var pipeline = new LocalSpeechPipeline(new CancelingEngine(), renderer);
        using var cts = new CancellationTokenSource();

        var stale = pipeline.SpeakAsync("old utterance", cancellationToken: cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => stale);

        Assert.Equal(0, pipeline.Tap.EmissionCount);
        renderer.Process(0.016);
        Assert.Equal(0f, renderer.LipSyncWeight);
        Assert.Equal(1f, renderer.Scale);
    }

    [Fact]
    public async Task CancellationDuringFeed_StopsBeforeStaleRmsFlush()
    {
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        renderer.Initialize(RendererConfig);
        using var cts = new CancellationTokenSource();
        using var pipeline = new LocalSpeechPipeline(
            new FixtureEngine(WavFixture.Pcm16Wav(WavFixture.Tone(seconds: 1.0))), renderer);

        // Cancel from inside the tap's first window instead of racing a timer:
        // the next feed chunk must observe cancellation before tail flush.
        pipeline.Tap.Amplitude += _ => cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => pipeline.SpeakAsync("long utterance", cancellationToken: cts.Token));

        // First 4096-sample chunk holds 3 full 1102-sample windows; the
        // callback cancels during the third, so no later chunk is processed.
        Assert.InRange(pipeline.Tap.EmissionCount, 1, 3);
        Assert.False(pipeline.Tap.IsCompleted, "a canceled utterance must not flush a tail window");
        renderer.Process(0.016);
    }

    [Fact]
    public async Task DisposedPipeline_StopsFeedingRenderer_WhileNewPipelineWorks()
    {
        var engine = new FixtureEngine(WavFixture.Pcm16Wav(WavFixture.ToneForWindows(10)));
        var first = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        first.Initialize(RendererConfig);
        using var oldPipeline = new LocalSpeechPipeline(engine, first);
        using var secondPipeline = new LocalSpeechPipeline(engine, first);

        await secondPipeline.SpeakAsync("new sink");
        first.Process(0.016);
        Assert.True(first.Scale > 1.05f);

        oldPipeline.Dispose();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => oldPipeline.SpeakAsync("old sink"));
    }

    [Fact]
    public async Task EngineRateMismatch_FailsLoudly_NoFakePcm()
    {
        var engine = new FixtureEngine(WavFixture.Pcm16Wav(WavFixture.Tone()), sampleRate: 44100);
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        renderer.Initialize(RendererConfig);
        using var pipeline = new LocalSpeechPipeline(engine, renderer);

        await Assert.ThrowsAsync<InvalidDataException>(() => pipeline.SpeakAsync("mismatch"));
        Assert.Equal(0, pipeline.Tap.EmissionCount);
        Assert.Equal(1f, renderer.Scale);
    }

    /// <summary>
    /// Minimal stand-in for the piper CLI: a POSIX script that records the
    /// output path it was given, writes a real WAV there, then exercises the
    /// process-lifecycle branch under test (large stderr, child process, etc.).
    /// No downloaded model or real piper binary is involved.
    /// </summary>
    private sealed class FakePiper : IDisposable
    {
        private readonly string _directory;

        public string ExecutablePath { get; }
        public string ModelPath { get; }
        public string OutputPathLog { get; }
        public string PidLog { get; }
        public string ChildPidLog { get; }

        public FakePiper(byte[] wav, string tail, bool spawnChild = false)
        {
            if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS())
                throw new PlatformNotSupportedException("fake piper uses a POSIX shell script");

            _directory = Path.Combine(Path.GetTempPath(), $"piper-thh-{Guid.NewGuid():N}");
            Directory.CreateDirectory(_directory);
            var wavPath = Path.Combine(_directory, "voice.wav");
            File.WriteAllBytes(wavPath, wav);
            ModelPath = Path.Combine(_directory, "voice.onnx");
            File.WriteAllText(ModelPath, "fake model");
            OutputPathLog = Path.Combine(_directory, "output-path.log");
            PidLog = Path.Combine(_directory, "pid.log");
            ChildPidLog = Path.Combine(_directory, "child.pid");
            ExecutablePath = Path.Combine(_directory, "piper.sh");

            var childLines = spawnChild
                ? $"\nsleep 30 &\nchild=$!\nprintf '%s' \"$child\" > '{ChildPidLog}'\n"
                : string.Empty;
            File.WriteAllText(ExecutablePath, $"""
                #!/bin/sh
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --model) shift 2;;
                    --output_file) out="$2"; shift 2;;
                    *) shift;;
                  esac
                done
                printf '%s' "$out" > '{OutputPathLog}'
                cp '{wavPath}' "$out"
                printf '%s' "$$" > '{PidLog}'
                {childLines}{tail}
                """);
            if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
            {
                File.SetUnixFileMode(ExecutablePath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
                    UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
                    UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            }
        }

        public string ReadOutputPath() => File.ReadAllText(OutputPathLog);

        public void Dispose()
        {
            try { Directory.Delete(_directory, recursive: true); } catch { }
        }
    }

    private static async Task<T> WithTimeoutAsync<T>(Task<T> task)
    {
        // A stderr-pipe deadlock must fail the test, not hang the runner.
        var completed = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(5)));
        Assert.Same(task, completed);
        return await task;
    }

    private static async Task WaitForFileAsync(string path)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!File.Exists(path) && DateTime.UtcNow < deadline)
            await Task.Delay(10);
        Assert.True(File.Exists(path), $"fake piper did not create {path}");
    }

    private static async Task AssertProcessGoneAsync(int pid)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                if (process.HasExited) return;
            }
            catch (ArgumentException)
            {
                return;
            }
            await Task.Delay(20);
        }
        Assert.Fail($"piper child process {pid} is still running");
    }

    private static bool FakePiperSupported =>
        OperatingSystem.IsLinux() || OperatingSystem.IsMacOS();

    [Fact]
    public async Task Piper_DrainsStderrWhileRunning_NoDeadlock()
    {
        if (!FakePiperSupported) return;

        // More than one OS pipe buffer: reading stderr only after WaitForExitAsync
        // would block the child forever here.
        using var fake = new FakePiper(
            WavFixture.Pcm16Wav(WavFixture.Tone(seconds: 0.1)),
            "head -c 1048576 /dev/zero 1>&2");
        var engine = new PiperTtsEngine(fake.ExecutablePath, fake.ModelPath);

        var pcm = await WithTimeoutAsync(engine.SynthesizeAsync("hello"));

        Assert.Equal(WavFixture.SampleRate, pcm.SampleRate);
        Assert.False(File.Exists(fake.ReadOutputPath()));
    }

    [Fact]
    public async Task Piper_NonZeroExit_ReportsDrainedStderr()
    {
        if (!FakePiperSupported) return;

        using var fake = new FakePiper(
            WavFixture.Pcm16Wav(WavFixture.Tone(seconds: 0.1)),
            "printf 'piper synthetic failure\\n' 1>&2\nhead -c 1048576 /dev/zero 1>&2\nexit 3");
        var engine = new PiperTtsEngine(fake.ExecutablePath, fake.ModelPath);

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => WithTimeoutAsync(engine.SynthesizeAsync("hello")));

        Assert.Contains("piper exited 3", ex.Message);
        Assert.Contains("piper synthetic failure", ex.Message);
        Assert.False(File.Exists(fake.ReadOutputPath()));
    }

    [Fact]
    public async Task Piper_RejectsDecodedRateMismatch()
    {
        if (!FakePiperSupported) return;

        var wav = WavFixture.Pcm16Wav(WavFixture.Tone(sampleRate: 44100, seconds: 0.1), sampleRate: 44100);
        using var fake = new FakePiper(wav, "exit 0");
        var engine = new PiperTtsEngine(fake.ExecutablePath, fake.ModelPath);

        var ex = await Assert.ThrowsAsync<InvalidDataException>(
            () => WithTimeoutAsync(engine.SynthesizeAsync("hello")));

        Assert.Contains("22050", ex.Message);
        Assert.Contains("44100", ex.Message);
        Assert.False(File.Exists(fake.ReadOutputPath()));
    }

    [Fact]
    public async Task Piper_Cancellation_KillsTreeAndDeletesTempWav()
    {
        if (!FakePiperSupported) return;

        using var fake = new FakePiper(
            WavFixture.Pcm16Wav(WavFixture.Tone(seconds: 0.1)),
            "wait \"$child\"",
            spawnChild: true);
        var engine = new PiperTtsEngine(fake.ExecutablePath, fake.ModelPath);
        using var cts = new CancellationTokenSource();

        var synth = engine.SynthesizeAsync("hello", cancellationToken: cts.Token);
        await WaitForFileAsync(fake.ChildPidLog);
        var outPath = fake.ReadOutputPath();
        await WaitForFileAsync(outPath);
        var pid = int.Parse(File.ReadAllText(fake.PidLog));
        var childPid = int.Parse(File.ReadAllText(fake.ChildPidLog));

        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => WithTimeoutAsync(synth));

        Assert.False(File.Exists(outPath), "temp WAV must be deleted after cancellation");
        await AssertProcessGoneAsync(pid);
        await AssertProcessGoneAsync(childPid);
    }

    [RealPiperFact]
    public async Task RealPiper_TextToPcmToRenderer_WhenLocalAssetsArePresent()
    {
        var modelPath = Environment.GetEnvironmentVariable("PIPER_MODEL")!;
        // PIPER_PATH is optional: PiperTtsEngine falls back to `piper` on PATH.
        var engine = new PiperTtsEngine(Environment.GetEnvironmentVariable("PIPER_PATH"), modelPath);
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(RendererConfig);
        renderer.Initialize(RendererConfig);
        using var pipeline = new LocalSpeechPipeline(engine, renderer);

        var pcm = await pipeline.SpeakAsync("The quick brown fox jumps over the lazy dog.");
        Assert.True(pcm.Samples.Length > 0, "real Piper output must contain PCM samples");
        Assert.Equal(pcm.SampleRate, pipeline.Tap.SampleRate);

        renderer.Process(0.016);
        Assert.True(pipeline.Tap.EmissionCount > 0);
        Assert.True(renderer.LipSyncWeight > 0f, "real speech RMS must reach the renderer");
        Assert.True(renderer.Scale > 1f);
    }
}
