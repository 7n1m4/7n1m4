using System;
using System.Globalization;

namespace AnimaPet.Renderers;

/// <summary>
/// RGBA tint as plain floats. Kept free of Godot types so the renderer
/// boundary stays pure managed and unit-testable off-engine; the scene maps
/// this onto <c>Godot.Color</c> before assigning <c>Node2D.Modulate</c>.
/// </summary>
public readonly record struct RendererTint(float R, float G, float B, float A)
{
    public static RendererTint Neutral => new(1f, 1f, 1f, 1f);

    /// <summary>Linear blend toward <paramref name="target"/> by <paramref name="amount"/> in [0,1].</summary>
    public RendererTint Blend(RendererTint target, float amount)
    {
        var t = Math.Clamp(amount, 0f, 1f);
        return new RendererTint(
            R + (target.R - R) * t,
            G + (target.G - G) * t,
            B + (target.B - B) * t,
            A + (target.A - A) * t);
    }
}

/// <summary>
/// Honest fallback renderer. No real VRM / Live2D backend asset is vendored in
/// this spike (no godot-vrm / MToon addon, no GDCubism extension), so instead
/// of throwing or no-oping this translates the daemon's lip-sync amplitude and
/// emotion key into observable node state: <see cref="Scale"/>,
/// <see cref="Modulate"/> and <see cref="AnimationKey"/>. The entry scene
/// applies those values to a generic Godot node; a future real backend can
/// override the same state mapping without changing the event boundary.
/// </summary>
public abstract class GenericPetRenderer : IPetRenderer
{
    /// <summary>Secondary scale added per unit of smoothed lip-sync weight.</summary>
    public const float MouthOpenScale = 0.25f;

    /// <summary>Extra scale added per unit of emotion intensity.</summary>
    public const float EmotionScaleBoost = 0.08f;

    private readonly LipSyncSmoother _smoother = new();
    private float _emotionIntensity;
    private bool _disposed;

    /// <inheritdoc/>
    public abstract string BackendId { get; }

    /// <summary>True after <see cref="Initialize"/> supplied a card config.</summary>
    public bool IsInitialized { get; private set; }

    /// <summary>True after <see cref="Dispose"/>; all further calls throw.</summary>
    public bool IsDisposed => _disposed;

    /// <summary>The configured (not loaded) model path.</summary>
    public string? AssetPath { get; private set; }

    /// <summary>Smoothed speech amplitude in [0,1] (attack/decay from <see cref="LipSyncSmoother"/>).</summary>
    public float LipSyncWeight => _smoother.Weight;

    /// <summary>Node scale derived from lip-sync weight and emotion intensity.</summary>
    public float Scale { get; private set; } = 1f;

    /// <summary>Node tint derived from the current emotion key and intensity.</summary>
    public RendererTint Modulate { get; private set; } = RendererTint.Neutral;

    /// <summary>Normalized emotion key (lowercase; "neutral" when unset).</summary>
    public string EmotionKey { get; private set; } = "neutral";

    /// <summary>AnimationPlayer-style clip key combining emotion and mouth state.</summary>
    public string AnimationKey { get; private set; } = "neutral|0.00";

    /// <summary>Number of <see cref="Process"/> ticks observed (diagnostics).</summary>
    public int ProcessedFrames { get; private set; }

    /// <inheritdoc/>
    public void Initialize(CardRenderConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        ThrowIfDisposed();

        AssetPath = config.AssetPath;
        IsInitialized = true;
        EmotionKey = "neutral";
        _emotionIntensity = 0f;
        ProcessedFrames = 0;
        Refresh();
    }

    /// <inheritdoc/>
    public void SetLipSync(float level)
    {
        ThrowIfDisposed();
        _smoother.SetRms(float.IsNaN(level) ? 0f : level);
        Refresh();
    }

    /// <inheritdoc/>
    public void SetEmotion(string tag, float intensity)
    {
        ThrowIfDisposed();
        EmotionKey = string.IsNullOrWhiteSpace(tag) ? "neutral" : tag.Trim().ToLowerInvariant();
        _emotionIntensity = float.IsNaN(intensity) ? 0f : Math.Clamp(intensity, 0f, 1f);
        Refresh();
    }

    /// <inheritdoc/>
    public void Process(double delta)
    {
        ThrowIfDisposed();
        // A bad frame must not tear down the pet; clamp to zero instead of
        // letting LipSyncSmoother.Tick throw on a negative delta.
        var weight = _smoother.Tick((float)(delta < 0d ? 0d : delta));
        Scale = 1f + MouthOpenScale * weight + EmotionScaleBoost * _emotionIntensity;
        Modulate = RendererTint.Neutral.Blend(TintFor(EmotionKey), _emotionIntensity);
        RefreshAnimationKey();
        ProcessedFrames++;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _disposed = true;
    }

    private void Refresh()
    {
        Scale = 1f + MouthOpenScale * _smoother.Weight + EmotionScaleBoost * _emotionIntensity;
        Modulate = RendererTint.Neutral.Blend(TintFor(EmotionKey), _emotionIntensity);
        RefreshAnimationKey();
    }

    private void RefreshAnimationKey()
    {
        AnimationKey = EmotionKey + "|" + _smoother.Weight.ToString("0.00", CultureInfo.InvariantCulture);
    }

    private static RendererTint TintFor(string key) => key switch
    {
        "happy" or "joy" or "smile" or "excited" => new RendererTint(1f, 0.92f, 0.60f, 1f),
        "sad" or "sorrow" or "cry" => new RendererTint(0.60f, 0.75f, 1f, 1f),
        "angry" or "rage" or "mad" => new RendererTint(1f, 0.55f, 0.50f, 1f),
        "surprised" or "surprise" or "shocked" => new RendererTint(1f, 1f, 0.70f, 1f),
        "afraid" or "fear" or "fearful" => new RendererTint(0.75f, 0.65f, 1f, 1f),
        _ => RendererTint.Neutral,
    };

    private void ThrowIfDisposed()
    {
        if (_disposed)
            throw new ObjectDisposedException(GetType().Name);
    }
}
