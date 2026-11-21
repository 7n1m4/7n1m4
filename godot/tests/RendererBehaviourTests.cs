using System;
using Xunit;
using AnimaPet.Renderers;

namespace AnimaPet.Tests;

/// <summary>
/// The two renderer slots are honest generic renderers (no real VRM/Live2D
/// backend is vendored). These tests pin the observable side effects so a
/// future regression back into throwing stubs or silent no-ops is caught.
/// </summary>
public sealed class RendererBehaviourTests
{
    private static readonly CardRenderConfig VrmConfig =
        new(PetRenderBackend.Vrm, "res://models/test.vrm");

    private static readonly CardRenderConfig Live2dConfig =
        new(PetRenderBackend.Live2d, "res://models/test.model3.json");

    [Fact]
    public void VrmRenderer_Initialize_RecordsConfigAndStartsNeutral()
    {
        var renderer = new VrmRenderer();
        renderer.Initialize(VrmConfig);

        Assert.Equal("vrm.generic", renderer.BackendId);
        Assert.True(renderer.IsInitialized);
        Assert.False(renderer.IsDisposed);
        Assert.Equal(VrmConfig.AssetPath, renderer.AssetPath);
        Assert.Equal(1f, renderer.Scale);
        Assert.Equal(RendererTint.Neutral, renderer.Modulate);
        Assert.Equal("neutral|0.00", renderer.AnimationKey);
    }

    [Fact]
    public void VrmRenderer_LipSyncAndProcess_DriveScaleAndAnimationKey()
    {
        var renderer = new VrmRenderer();
        renderer.Initialize(VrmConfig);

        renderer.SetLipSync(0.9f);
        renderer.Process(0.016);

        Assert.InRange(renderer.LipSyncWeight, 0.8f, 1f);
        Assert.True(renderer.Scale > 1.1f,
            "lip-sync amplitude must produce an observable scale change");
        Assert.Equal("neutral|0.90", renderer.AnimationKey);
        Assert.Equal(1, renderer.ProcessedFrames);
    }

    [Fact]
    public void VrmRenderer_Silence_DecaysScaleBackToRest()
    {
        var renderer = new VrmRenderer();
        renderer.Initialize(VrmConfig);
        renderer.SetLipSync(1f);
        renderer.Process(0.016);

        renderer.SetLipSync(0f);
        for (var i = 0; i < 60; i++)
            renderer.Process(0.016);

        Assert.True(renderer.LipSyncWeight < 0.05f);
        Assert.InRange(renderer.Scale, 0.99f, 1.02f);
        Assert.Equal(61, renderer.ProcessedFrames);
    }

    [Fact]
    public void VrmRenderer_Emotion_DrivesTintAndEmotionKey()
    {
        var renderer = new VrmRenderer();
        renderer.Initialize(VrmConfig);

        renderer.SetEmotion(" HAPPY ", 0.8f);
        renderer.Process(0.016);

        Assert.Equal("happy", renderer.EmotionKey);
        Assert.StartsWith("happy|", renderer.AnimationKey);
        Assert.Equal(1f, renderer.Modulate.R);
        Assert.InRange(renderer.Modulate.G, 0.93f, 0.94f); // 1 -> 0.92 by 0.8
        Assert.True(renderer.Scale > 1.05f, "emotion intensity must also affect scale");
    }

    [Fact]
    public void Live2dRenderer_ProducesDistinctObservableTintWithoutThrowing()
    {
        var renderer = new Live2dRenderer();
        renderer.Initialize(Live2dConfig);
        renderer.SetEmotion("sad", 1f);
        renderer.SetLipSync(0.5f);
        renderer.Process(0.016);

        Assert.Equal("live2d.generic", renderer.BackendId);
        Assert.Equal("sad", renderer.EmotionKey);
        Assert.True(renderer.Modulate.B > renderer.Modulate.R,
            "sad emotion must produce a visibly blue tint");
        Assert.True(renderer.Scale > 1.1f);
        Assert.StartsWith("sad|", renderer.AnimationKey);
    }

    [Fact]
    public void Factory_SelectsHonestGenericRenderers()
    {
        var vrm = PetRendererFactory.Create(VrmConfig);
        var live2d = PetRendererFactory.Create(Live2dConfig);

        Assert.IsType<VrmRenderer>(vrm);
        Assert.IsType<Live2dRenderer>(live2d);
        Assert.EndsWith(".generic", vrm.BackendId);
        Assert.EndsWith(".generic", live2d.BackendId);
    }

    [Fact]
    public void Dispose_IsIdempotentAndGuardsFurtherCalls()
    {
        var renderer = (GenericPetRenderer)PetRendererFactory.Create(Live2dConfig);
        renderer.Dispose();
        renderer.Dispose();

        Assert.True(renderer.IsDisposed);
        Assert.Throws<ObjectDisposedException>(() => renderer.Process(0.016));
        Assert.Throws<ObjectDisposedException>(() => renderer.SetLipSync(0.5f));
        Assert.Throws<ObjectDisposedException>(() => renderer.SetEmotion("happy", 1f));
    }

    [Fact]
    public void RendererTint_Blend_ClampsAmount()
    {
        var baseTint = new RendererTint(0f, 0f, 0f, 1f);
        var target = new RendererTint(1f, 1f, 1f, 1f);

        Assert.Equal(baseTint, baseTint.Blend(target, -2f));
        Assert.Equal(target, baseTint.Blend(target, 4f));
        Assert.Equal(new RendererTint(0.5f, 0.5f, 0.5f, 1f), baseTint.Blend(target, 0.5f));
    }
}
