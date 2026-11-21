namespace AnimaPet.Renderers;

/// <summary>
/// Generic renderer occupying the VRM card slot.
 ///
 /// NOTICE: no godot-vrm / MToon addon is vendored in this spike, so this does
 /// NOT load a .vrm or drive blend shapes — it exposes scale/tint/animation
 /// state that the scene applies to a placeholder node.
 /// </summary>
public sealed class VrmRenderer : GenericPetRenderer
{
    /// <inheritdoc/>
    public override string BackendId => "vrm.generic";
}
