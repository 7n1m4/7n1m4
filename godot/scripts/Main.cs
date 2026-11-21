using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Godot;
using AnimaPet.Net;
using AnimaPet.Renderers;

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
/// it forwards <c>lip_sync.rms</c> → <see cref="IPetRenderer.SetLipSync"/> and
/// <c>emotion.tag</c> → <see cref="IPetRenderer.SetEmotion"/>; it does not
/// persist or reinterpret those events. Connection status and the latest chat
/// delta are reflected in the scene's labels for the pet window.
/// </para>
/// </summary>
public partial class Main : Node2D
{
    private IPetRenderer? _renderer;
    private DaemonClient? _daemon;
    private CancellationTokenSource? _pumpCts;
    private CancellationTokenSource? _heartbeatCts;
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

        GD.Print($"[AnimaPet] renderer spike ready; daemon endpoint: {DaemonClient.DefaultEndpoint}");

        // Start the daemon connection. The auth token is read from the
        // daemon-owned server-channel/config.json (same path the daemon
        // uses); pass an explicit token to DaemonClient if that file is
        // unavailable (e.g. a non-Linux host before the daemon has run).
        _ = ConnectToDaemonAsync();
    }

    private async Task ConnectToDaemonAsync()
    {
        try
        {
            _daemon = new DaemonClient();
            _stateHandler = (_, state) => UpdateStatus(state.ToString());
            _eventHandler = OnDaemonEvent;
            _daemon.StateChanged += _stateHandler;
            _daemon.EventReceived += _eventHandler;
            await _daemon.ConnectAsync().ConfigureAwait(true);

            // Pet topics plus chat deltas so the pet can react to streamed text.
            var topics = new[]
            {
                EventTopics.LipSyncRms,
                EventTopics.EmotionTag,
                EventTopics.TokenDelta,
                EventTopics.PresenceChanged,
                EventTopics.StatusChanged,
            };
            await _daemon.SubscribeAsync(topics).ConfigureAwait(true);
            UpdateStatus(_daemon.State.ToString());
            GD.Print($"[AnimaPet] daemon connected; subscribed to {string.Join(", ", topics)}");

            // Pump events. Godot object access from background threads is
            // unsafe; UI updates are marshalled via CallDeferred below.
            _pumpCts = new CancellationTokenSource();
            _ = _daemon.PumpAsync(_pumpCts.Token);

            // One real caller per capability group so the client's RPC claim is
            // exercised at runtime, not just asserted in the parity table.
            _heartbeatCts = new CancellationTokenSource();
            await ProbeCapabilitiesAsync(_heartbeatCts.Token).ConfigureAwait(true);
            _ = _daemon.RunHeartbeatAsync(_heartbeatCts.Token);
        }
        catch (Exception ex)
        {
            // The daemon may not be running yet; log and keep the window alive
            // so the user sees the pet even before the core is up.
            GD.PrintErr($"[AnimaPet] daemon connection failed: {ex.Message}");
            UpdateStatus($"Failed: {ex.Message}");
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
        if (data is LipSyncRmsData lip)
        {
            _renderer?.SetLipSync(lip.Level);
            return;
        }

        if (data is EmotionTagData emotion && emotion.Kind == CueKind.Emotion)
        {
            _renderer?.SetEmotion(emotion.Tag, emotion.Intensity);
            if (_expressionLabel is not null)
                _expressionLabel.Text = $"{emotion.Tag} ({emotion.Intensity:0.00})";
            return;
        }

        if (data is TokenDeltaData token)
        {
            // Chat deltas drive the pet's expression/text surface.
            if (_expressionLabel is not null)
                _expressionLabel.Text = token.Delta;
            return;
        }

        if (data is StatusChangedData status)
        {
            UpdateStatus(status.CoreAvailable ? "Connected" : "Core unavailable");
            return;
        }
    }

    /// <summary>
    /// Fire one RPC per capability group so chat/settings/providers/vault/etc.
    /// are genuinely wired to the daemon, not just marked "implemented" in the
    /// parity table. A failing probe is logged and skipped; it never blocks
    /// startup or the heartbeat that follows. The chat probe deliberately uses
    /// a short debug message so the stream path is exercised too.
    /// </summary>
    private async Task ProbeCapabilitiesAsync(CancellationToken cancellationToken)
    {
        if (_daemon is null)
            return;

        var probes = new (string Label, Func<DaemonClient, CancellationToken, Task<JsonElement>>)[]
        {
            ("core.status", (d, ct) => d.CoreStatusAsync(ct)),
            ("chat.send", (d, ct) => d.ChatSendAsync("debug", "[AnimaPet] capability probe", ct)),
            ("chat.cancel", (d, ct) => d.ChatCancelAsync("debug", ct)),
            ("providers.list", (d, ct) => d.ProvidersListAsync(ct)),
            ("settings.get", (d, ct) => d.SettingsGetAsync("core", ct)),
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
                GD.PrintErr($"[AnimaPet] {label} probe failed: {ex.Message}");
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
    }

    public override void _Process(double delta)
    {
        _renderer?.Process(delta);
    }

    public override void _ExitTree()
    {
        _pumpCts?.Cancel();
        _heartbeatCts?.Cancel();
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
    }
}
