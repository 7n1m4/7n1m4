# Custom 3D & 2D Avatars

How VRM, Live2D, Spine, and MMD models are loaded, customized, and tuned in code.

## Supported Model Formats

| Format | Technology | Dimensions | Best For |
| :--- | :--- | :--- | :--- |
| **VRM (.vrm)** | Three.js / WebGL / WebGPU | 3D | Full 3D avatars with spring-bone physics, dynamic lighting, customizable outfits, and rich VRMA animation support. |
| **Live2D (.model3.json)** | PixiJS / Cubism Core WASM | 2.5D | High-fidelity layered 2D anime art with fluid breathing, eye tracking, and expressiveness. |
| **Spine (.skel / .json)** | PixiJS Spine Runtime | 2D | Game sprites, chibi characters, and stylized 2D animations. |
| **MMD (.pmx)** | Three.js MMDLoader | 3D | MikuMikuDance community models and legacy 3D assets. |

## Code Homes

- Model customizer editor (expression mapping, idle animation, outfits): [`packages/stage-ui/src/components/scenarios/settings/model-settings/ModelCustomizer.vue`](ModelCustomizer.vue) and sibling renderers (`vrm.vue`, `live2d.vue`, `spine.vue`, `mmd.vue`).
- Rehearsal room: [`apps/stage-tamagotchi/src/renderer/components/chat/chat_rehearsal.vue`](../../../../../../../apps/stage-tamagotchi/src/renderer/components/chat/chat_rehearsal.vue).
- Renderer runtimes: [`packages/stage-ui-three/`](../../../../../../stage-ui-three) (VRM), [`packages/stage-ui-live2d/`](../../../../../../stage-ui-live2d), [`packages/stage-ui-spine/`](../../../../../../stage-ui-spine), [`packages/stage-ui-mmd/`](../../../../../../stage-ui-mmd).

## Importing a Custom Model

1. Open **Settings &rarr; Character &rarr; Vessel / Display Model**.
2. Click **"Import Model"** or drag-and-drop your model files directly into the window:
   - For **VRM**: Select your `.vrm` file.
   - For **Live2D**: Select the entire model folder or a `.zip` archive containing the `.model3.json` file, textures, and motion files.
   - For **Spine**: Select the `.skel` / `.json`, `.atlas`, and `.png` sprite sheet files together.
3. Anima will load the model into the stage preview and automatically extract all embedded blendshapes, motion tracks, and textures.

## Customizing Expressions & Animations (Model Customizer)

Once your model is loaded, click the **"Customize Model"** button to open the embedded capability editor:

- **Expression Mapping**: Map model blendshapes (e.g., `Joy`, `Angry`, `Sorrow`, `Surprised`, `Blink`) to Anima's standard emotion vocabulary. This ensures that when Anima emits an `<|ACT:emotion="happy"|>` token, your custom model smiles naturally.
- **Default Idle Animation**: Choose which `.vrma` motion or resting posture the avatar adopts when waiting.
- **Random Motion Cycles**: Enable motion cycling to let your avatar occasionally shift weight, stretch, or glance around naturally during downtime.
- **Costumes & Outfits**: For VRM models with multi-mesh wardrobes or Live2D models with multiple costume layers, toggle individual parts on or off to create custom outfits.

## The Rehearsal Room

To test how your model responds to acting cues:
1. Open the **Rehearsal Room** in Studio.
2. Click any emotion, gesture, or speech prompt button.
3. Watch the avatar perform the blendshape transitions and animations in real time with zero LLM API cost.

## Performance Tuning & Optimization

If you are running Anima alongside demanding PC games or on lower-spec hardware:

- **Target Framerate**: In **Settings &rarr; Appearance & Stage**, cap the renderer to **30 FPS** or **60 FPS** to reduce GPU load.
- **WASM Memory Optimization**: For Live2D models, enable **Texture Subsampling** in Stage settings to lower VRAM usage.
- **Physics Quality**: For VRM models, adjust **Spring Bone Substeps** to balance hair/cloth physics fidelity against CPU usage.
