using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Godot;
using AnimaPet.Audio;
using AnimaPet.Net;
using AnimaPet.Renderers;
using AnimaPet.Speech;

namespace AnimaPet;

/// <summary>
/// Spike entry scene. Owns exactly one renderer at a time, connects to the
/// Rust daemon gateway, subscribes to pet event topics, and routes decoded
/// daemon events into the active renderer. The window stays alive
/// independently of the Flutter control surface; closing Flutter must not tear
/// this process down (pivot invariant 2,
/// docs/design-flutter-godot-pivot.md:132).
///
/// <para>
/// The daemon is the single owner of state. This scene holds view state only:
/// it forwards <c>emotion.tag</c> → <see cref="IPetRenderer.SetEmotion"/>; it does not
/// persist or reinterpret those events. Connection status and the latest chat
/// delta are reflected in the scene's labels for the pet window.
/// </para>
/// </summary>
public partial class Main : Node2D
{
    private IPetRenderer? _renderer;
    private ITtsEngine? _ttsEngine;
    private LocalSpeechPipeline? _speechPipeline;
    private AudioStreamPlayer? _speechPlayer;
    private CancellationTokenSource? _speechCts;
    private Task? _speechTask;
    private readonly SpeechTurnAccumulator _speechTurns = new(ReadOnlyProbeSession);
    private DaemonClient? _daemon;
    private CancellationTokenSource? _pumpCts;
    private CancellationTokenSource? _heartbeatCts;
    private CancellationTokenSource? _reconnectCts;
    private Label? _statusLabel;
    private Label? _expressionLabel;
    private EventHandler<DaemonConnectionState>? _stateHandler;
    private EventHandler<DaemonEventArgs>? _eventHandler;

    public override void _Ready()
    {
        // Window appearance is configured declaratively in project.godot
        // (borderless, per-pixel transparency, always-on-top). No runtime
        // DisplayServer calls are needed for the spike.
        _statusLabel = GetNodeOrNull<Label>("StatusLabel");
        _expressionLabel = GetNodeOrNull<Label>("ExpressionLabel");
        if (_statusLabel is not null)
            _statusLabel.Text = "Disconnected";

        // Construct the view renderer up front. This is purely local (the
        // factory only records the config on the generic renderer), so it
        // cannot trigger card/model generation before the daemon connects.
        // Without this, _renderer stays null and lip-sync/emotion events and
        // the per-frame Process tick are all silent no-ops.
        LoadCard(new CardRenderConfig(
            PetRenderBackend.Live2d, "res://cards/default.model3.json"));

        // Speech is client-local: the daemon has no speaker, and it never
        // publishes lip_sync.rms (docs/decision-bridge-scope.md). The only
        // engine asset needed here is a locally installed Piper binary/model;
        // without PIPER_MODEL this scene still runs, but speech stays silent.
        _speechPlayer = new AudioStreamPlayer { Name = "LocalSpeechPlayer" };
        AddChild(_speechPlayer);
        _ttsEngine = CreateLocalTtsEngine();
        RebuildSpeechPipeline();

        GD.Print($"[AnimaPet] renderer spike ready; daemon endpoint: {DaemonClient.DefaultEndpoint}");

        // Start the daemon connection. The auth token is read from the
        // daemon-owned server-channel/config.json (same path the daemon
        // uses); pass an explicit token to DaemonClient if that file is
        // unavailable (e.g. a non-Linux host before the daemon has run).
        _reconnectCts = new CancellationTokenSource();
        _ = ConnectToDaemonAsync();
    }

    private static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Session id used only by the read-only startup capability probe
    /// (<c>chat.history</c>). No turn is ever started for it, so it is also the
    /// <see cref="SpeechTurnAccumulator"/> filter value; it must not be a name a real
    /// session could carry, or a genuine turn would be silently dropped.
    /// </summary>
    private const string ReadOnlyProbeSession = "anima-pet-probe";

    /// <summary>
    /// Connect, subscribe and stay connected. A daemon restart closes the WS;
    /// the pump/heartbeat flip state to Disconnected, which releases the wait
    /// below and makes us tear down and build a fresh client (a fresh socket,
    /// since a ClientWebSocket cannot be reopened) and re-subscribe. Keeps the
    /// window alive while the daemon is down.
    /// </summary>
    private async Task ConnectToDaemonAsync()
    {
        var loopCts = _reconnectCts!;
        while (!loopCts.IsCancellationRequested)
        {
            var disconnected = new TaskCompletionSource(
                TaskCreationOptions.RunContinuationsAsynchronously);
            using var stopRegistration = loopCts.Token.Register(() => disconnected.TrySetResult());
            DaemonClient? daemon = null;
            CancellationTokenSource? pumpCts = null;
            CancellationTokenSource? heartbeatCts = null;
            try
            {
                daemon = new DaemonClient();
                _daemon = daemon;
                _stateHandler = (_, state) =>
                {
                    UpdateStatus(state.ToString());
                    if (state is DaemonConnectionState.Disconnected or DaemonConnectionState.Failed)
                        disconnected.TrySetResult();
                };
                _eventHandler = OnDaemonEvent;
                daemon.StateChanged += _stateHandler;
                daemon.EventReceived += _eventHandler;
                await daemon.ConnectAsync().ConfigureAwait(true);

                // Pet topics plus chat deltas so the pet can react to streamed
                // text. lip_sync.rms is deliberately absent: the RMS samples
                // are produced here from local TTS playback, not by the daemon.
                var topics = new[]
                {
                    EventTopics.EmotionTag,
                    EventTopics.TokenDelta,
                    EventTopics.PresenceChanged,
                    EventTopics.StatusChanged,
                };
                await daemon.SubscribeAsync(topics).ConfigureAwait(true);
                UpdateStatus(daemon.State.ToString());
                GD.Print($"[AnimaPet] daemon connected; subscribed to {string.Join(", ", topics)}");

                // Pump events. Godot object access from background threads is
                // unsafe; UI updates are marshalled via CallDeferred below.
                pumpCts = new CancellationTokenSource();
                _pumpCts = pumpCts;
                _ = daemon.PumpAsync(pumpCts.Token);

                // One real read-only caller per capability group so the client's
                // RPC claim is exercised at runtime, not just asserted in the
                // parity table.
                heartbeatCts = new CancellationTokenSource();
                _heartbeatCts = heartbeatCts;
                await ProbeCapabilitiesAsync(heartbeatCts.Token).ConfigureAwait(true);
                _ = daemon.RunHeartbeatAsync(heartbeatCts.Token);

                // Hold this connection until the daemon drops or we shut down.
                await disconnected.Task.ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                // Shutdown; the loop condition below ends the retry cycle.
            }
            catch (Exception ex)
            {
                // The daemon may not be running yet; log and keep the window
                // alive so the user sees the pet even before the core is up.
                var safeError = RpcErrorSanitizer.UserMessage(ex);
                GD.PrintErr($"[AnimaPet] daemon connection failed: {safeError}");
                System.Diagnostics.Debug.WriteLine($"[AnimaPet] daemon connection failure detail: {ex}");
                UpdateStatus($"Failed: {safeError}");
            }
            finally
            {
                pumpCts?.Cancel();
                heartbeatCts?.Cancel();
                if (daemon is not null)
                {
                    daemon.StateChanged -= _stateHandler;
                    daemon.EventReceived -= _eventHandler;
                    daemon.Dispose();
                }
                _daemon = null;
            }

            if (loopCts.IsCancellationRequested)
                break;
            GD.Print($"[AnimaPet] daemon connection lost; retrying in {ReconnectDelay.TotalSeconds}s");
            try
            {
                await Task.Delay(ReconnectDelay, loopCts.Token).ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private void OnDaemonEvent(object? sender, DaemonEventArgs e)
    {
        // The pump may raise this off the Godot main thread, so marshal all
        // renderer + UI work (including Godot node access) onto the main loop.
        var data = e.Data;
        Callable.From(() => HandleEvent(data)).CallDeferred();
    }

    private void HandleEvent(object? data)
    {
        if (data is EmotionTagData emotion && emotion.Kind == CueKind.Emotion)
        {
            _renderer?.SetEmotion(emotion.Tag, emotion.Intensity);
            if (_expressionLabel is not null)
                _expressionLabel.Text = $"{emotion.Tag} ({emotion.Intensity:0.00})";
            return;
        }

        if (data is TokenDeltaData token)
        {
            // Chat deltas drive the pet's expression/text surface and provide
            // the text for client-local synthesis. The daemon sends text only;
            // audio is produced and played here (no daemon audio subscription).
            if (_expressionLabel is not null)
                _expressionLabel.Text = token.Delta;
            // Turns are keyed by (session, message): concurrent sessions must
            // not interleave their text or speak a turn that never finalized.
            var completed = _speechTurns.Observe(token);
            if (completed is not null)
                Speak(completed);
            return;
        }

        if (data is StatusChangedData status)
        {
            UpdateStatus(status.CoreAvailable ? "Connected" : "Core unavailable");
            return;
        }
    }

    /// <summary>
    /// Fire one read-only RPC per capability group so chat/settings/providers/
    /// vault/etc. are genuinely wired to the daemon, not just marked
    /// "implemented" in the parity table. Every probe runs on each reconnect,
    /// so mutating verbs are forbidden here: chat.send would persist a junk
    /// turn and spend a provider call, and chat.cancel would broadcast a fake
    /// final token. chat.history is the read-only chat-lane probe instead. A
    /// failing probe is logged and skipped; it never blocks startup or the
    /// heartbeat that follows.
    /// </summary>
    private async Task ProbeCapabilitiesAsync(CancellationToken cancellationToken)
    {
        if (_daemon is null)
            return;

        var probes = new (string Label, Func<DaemonClient, CancellationToken, Task<JsonElement>>)[]
        {
            ("core.status", (d, ct) => d.CoreStatusAsync(ct)),
            ("chat.history", (d, ct) => d.ChatHistoryAsync(ReadOnlyProbeSession, ct)),
            ("providers.list", (d, ct) => d.ProvidersListAsync(ct)),
            ("settings.get", (d, ct) => d.SettingsGetAsync("general", ct)),
            ("vault.status", (d, ct) => d.VaultStatusAsync(ct)),
            ("stmm.list", (d, ct) => d.StmmListAsync(50, ct)),
            ("journal.search", (d, ct) => d.JournalSearchAsync("AnimaPet", 50, ct)),
            ("retrieval.status", (d, ct) => d.RetrievalStatusAsync(ct)),
            ("cards.list", (d, ct) => d.CardsListAsync(ct)),
            ("sessions.list", (d, ct) => d.SessionsListAsync(ct)),
        };

        foreach (var (label, call) in probes)
        {
            if (cancellationToken.IsCancellationRequested)
                return;
            try
            {
                var reply = await call(_daemon, cancellationToken).ConfigureAwait(true);
                GD.Print($"[AnimaPet] {label}: {reply.ValueKind}");
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                GD.PrintErr($"[AnimaPet] {label} probe failed: {RpcErrorSanitizer.UserMessage(ex)}");
                System.Diagnostics.Debug.WriteLine($"[AnimaPet] {label} probe failure detail: {ex}");
            }
        }
    }

    private void UpdateStatus(string text)
    {
        Callable.From(() => DoUpdateStatus(text)).CallDeferred();
    }

    private void DoUpdateStatus(string text)
    {
        if (_statusLabel is not null)
            _statusLabel.Text = text;
    }

    /// <summary>Swap the active plugin when a card's backend choice changes.</summary>
    public void LoadCard(CardRenderConfig config)
    {
        _renderer?.Dispose();
        _renderer = PetRendererFactory.Create(config);
        _renderer.Initialize(config);
        RebuildSpeechPipeline();
    }

    private static ITtsEngine? CreateLocalTtsEngine()
    {
        // Opt in by supplying a locally installed Piper model. Download and
        // license notes live in docs/guide-client-local-tts-runtime.md; no
        // binary or model is committed to the repo.
        var model = System.Environment.GetEnvironmentVariable("PIPER_MODEL");
        if (string.IsNullOrWhiteSpace(model))
        {
            GD.Print("[AnimaPet] local TTS disabled: set PIPER_MODEL (and optionally PIPER_PATH) to enable speech");
            return null;
        }
        var piper = System.Environment.GetEnvironmentVariable("PIPER_PATH");
        var sampleRate = SpeechSampleRate.ResolvePiperSampleRate(
            System.Environment.GetEnvironmentVariable(SpeechSampleRate.EnvironmentVariable));
        return new PiperTtsEngine(piper, model, sampleRate);
    }

    private void RebuildSpeechPipeline()
    {
        _speechPipeline?.Dispose();
        _speechPipeline = _ttsEngine is null || _renderer is null
            ? null
            : new LocalSpeechPipeline(_ttsEngine, _renderer);
    }

    /// <summary>
    /// Speak locally from any scene script, with or without a daemon: engine
    /// PCM is tapped into the renderer and the same samples are queued for
    /// physical playback on the Godot audio server.
    /// </summary>
    public void Speak(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        Callable.From(() => { _speechTask = SpeakLocalAsync(text); }).CallDeferred();
    }

    private async Task SpeakLocalAsync(string text)
    {
        if (_speechPipeline is null) return;

        if (_speechCts is not null)
        {
            // A superseded utterance must not hold the mouth open while the
            // new one synthesizes. Zero is silence, not a fabricated sample.
            _speechCts.Cancel();
            _speechPlayer?.Stop();
            _renderer?.SetLipSync(0f);
            // Do not dispose here: the canceled call may still be awaiting a
            // token registration from this source; let GC collect it instead.
        }
        _speechCts = new CancellationTokenSource();
        var cancellation = _speechCts.Token;

        try
        {
            // Godot's synchronization context resumes this continuation on the
            // main thread, so the tap/renderer sink and node access stay there.
            var pcm = await _speechPipeline.SpeakAsync(text, cancellationToken: cancellation).ConfigureAwait(true);
            if (cancellation.IsCancellationRequested || _speechPlayer is null) return;
            PlayPcm(pcm);
        }
        catch (OperationCanceledException)
        {
            // A newer utterance replaced this one; its PCM was deliberately
            // discarded, so no stale amplitude reaches the renderer. The
            // release of the old mouth state is already queued above.
        }
        catch (Exception ex)
        {
            GD.PrintErr($"[AnimaPet] local speech failed: {ex.Message}");
        }
    }

    private void PlayPcm(IPcmSource pcm)
    {
        _speechPlayer!.Stop();
        var stream = new AudioStreamWav
        {
            Format = AudioStreamWav.FormatEnum.Format16Bits,
            MixRate = pcm.SampleRate,
            Stereo = false,
            Data = PcmEncoding.FloatsToPcm16(pcm.Samples),
        };
        _speechPlayer.Stream = stream;
        _speechPlayer.Play();
    }

    public override void _Process(double delta)
    {
        _renderer?.Process(delta);
    }

    public override void _ExitTree()
    {
        _reconnectCts?.Cancel();
        _pumpCts?.Cancel();
        _heartbeatCts?.Cancel();
        var speechCts = _speechCts;
        speechCts?.Cancel();
        _speechCts = null;
        var speechTask = _speechTask;
        _speechTask = null;
        _speechTurns.Clear();
        _speechPlayer?.Stop();
        _speechPlayer?.QueueFree();
        _speechPlayer = null;
        _speechPipeline?.Dispose();
        _speechPipeline = null;
        if (_daemon is not null)
        {
            if (_stateHandler is not null) _daemon.StateChanged -= _stateHandler;
            if (_eventHandler is not null) _daemon.EventReceived -= _eventHandler;
            _ = _daemon.DisconnectAsync();
            _daemon.Dispose();
            _daemon = null;
        }
        _renderer?.Dispose();
        _renderer = null;

        if (speechCts is not null)
            _ = DisposeSpeechCtsAfterAsync(speechTask, speechCts);
    }

    /// <summary>
    /// Canceling a token never waits for its registrations, so disposing its
    /// source while SpeakLocalAsync is still awaiting one races with that
    /// call. Dispose only once the in-flight utterance finishes, without
    /// blocking Godot's shutdown path. SpeakLocalAsync logs its own failures.
    /// </summary>
    private static async Task DisposeSpeechCtsAfterAsync(Task? speechTask, CancellationTokenSource speechCts)
    {
        try
        {
            if (speechTask is not null)
                await speechTask.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Shutdown must not surface a fault from the canceled utterance;
            // SpeakLocalAsync already reports synthesis failures.
        }
        finally
        {
            speechCts.Dispose();
        }
    }
}
