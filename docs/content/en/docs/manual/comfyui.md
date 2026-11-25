---
title: Local Artistry with ComfyUI
description: >-
  How to connect your local ComfyUI instance to Anima, load custom workflows, and generate in-app desktop image widgets. Deprecated: image generation is disabled; this page is retained as the technical reference for the planned external SAI integration.
---

# Local Artistry with ComfyUI

> [!WARNING]
> **Deprecated — image generation is disabled.** AI-generated image generation in Anima is deprecated and stubbed: no new images are produced by any backend, ComfyUI included. Images you already generated remain available as read-only history in the image journal and Scene Vault. This page is kept as the technical reference for the planned external SAI integration, which will drive image control from outside Anima; the ComfyUI provider, `workflow_api.json` contract, and widget routing described below are the seam that integration targets. Do not file bugs against generation not working — it is disabled on purpose.

Historically, Anima featured a built-in **Artistry Engine** capable of generating background artwork, character selfies, and interactive scene illustrations. While cloud backends like Replicate and Nanobanana are supported, a local **ComfyUI** instance could be connected for local image generation directly on your GPU. That path is deprecated and stubbed (see the warning above); the setup steps below remain accurate for the external SAI integration that will replace it.

---

## 1. Prerequisites

Before connecting ComfyUI to Anima:
1. Ensure **ComfyUI** is installed and running on your PC (default address: `http://127.0.0.1:8188`).
2. Verify you can access the ComfyUI web interface in your browser and successfully generate an image with your desired checkpoint (e.g., SDXL, Pony, Flux, or Illustrious).

---

## 2. Setting Up the ComfyUI Provider

1. Open Anima and navigate to **Settings &rarr; Providers &rarr; Artistry (ComfyUI)**.
2. In the **Server URL** field, ensure `http://127.0.0.1:8188` is entered.
3. Click the **Test Connection** button. You should see a green checkmark confirming Anima can communicate with ComfyUI's WebSocket API.

---

## 3. Exporting Your Workflow (`workflow_api.json`)

To let Anima drive your ComfyUI generation, export your workflow in **API format**:

1. In ComfyUI, open **Settings** (the gear icon).
2. Enable **"Enable Dev mode Options"**.
3. A new button titled **"Save (API Format)"** will appear in the ComfyUI control panel.
4. Click **Save (API Format)** and save the `.json` file to your computer.

> [!IMPORTANT]
> **API Format vs. Standard Workflow**: Standard ComfyUI JSON files contain UI canvas layout data, which cannot be executed headless. You **must** export using **"Save (API Format)"**.

---

## 4. Tagging Prompt & Image Placeholders

Anima injects dynamic prompts and input images into your workflow using two placeholder tokens:

- `{{PROMPT}}`: Replaced with the character's generated positive prompt.
- `{{IMAGE}}`: (Optional for image-to-image/ControlNet) Replaced with the input image path or canvas buffer.

### How to Map Fields in Anima:
1. In **Settings &rarr; Modules &rarr; Artistry**, upload your exported `workflow_api.json`.
2. Anima will parse your nodes. In the **Exposed Fields** configuration:
   - Map your CLIP Text Encode (Prompt) node text input to `{{PROMPT}}`.
   - If using a negative prompt node, configure your default negative tags.
   - Map your Save Image / Preview Image node output.

---

## 5. Using Artistry in Conversations (Deprecated — generation is disabled)

Before generation was disabled, a connected ComfyUI instance produced artwork in several ways. All of them are stubbed now; the surfaces still exist and still display the read-only history of earlier images.

- **Direct Requests**: Ask Anima in chat: *"Draw a scenic sunset view of the beach"* or *"Take a selfie in your cozy room"*.
- **Autonomous Artistry**: If enabled, a background director loop evaluates significant narrative moments and silently generates matching atmospheric illustrations.
- **Desktop Art Widgets**: Generated images appear in the conversation stream and can be opened as floating desktop stickers, pinned to your screen, or set as your active stage background.
