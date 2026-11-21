namespace AnimaPet.Renderers;

/// <summary>
/// Generic renderer occupying the Live2D card slot.
 ///
 /// NOTICE: the GDCubism GDExtension is not vendored in this spike, so this
 /// does NOT load a .model3.json or drive Cubism parameters — it exposes
 /// scale/tint/animation state that the scene applies to a placeholder node.
 /// </summary>
public sealed class Live2dRenderer : GenericPetRenderer
{
    /// <inheritdoc/>
    public override string BackendId => "live2d.generic";
}
