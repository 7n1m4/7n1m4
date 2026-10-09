<a href="https://github.com/7n1m4#readme_codebase">
  <img src="https://img.shields.io/badge/skip%to%20code-1e3a8a" alt="skip to code">
</a>
<img width="1122" height="1402" alt="anima-banner-v7" src="https://github.com/user-attachments/assets/0a518f8b-7f16-4976-b82b-ee6600b52545" />

##### 🗽🦅 readme_locale_en_021
╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Welcome to AnimAIOS Project! Please choose your language:
<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
  <h2>AnimAIOS — an <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>-based distro coming this fall for Linux Desktop, DroidDesk (Termux:X11), DroidDeck (Linux + Proton), Steam Deck (SteamOS), CyberDeck (Raspberry Pi), and Wearable (Concept).</h2>
    <p>Comes with software pre-optimized for your CPU using <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> repositories and <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>.</p>
    </p>
</sub>
</div>
<img width="1148" height="1370" alt="anima-banner-us-v2 1" src="https://github.com/user-attachments/assets/857c51a7-6cdb-4248-b06e-6cc01fdcb932" />  

## 🌙 The Vision

- **AIRI Companion Engine:** Your companion — AIRI. Ships fully pre-configured with her subsystem. Built on open-source philosophy: we deliver the best experience entirely through free community AI providers.
- **Dynamic Fallback System & BYOK:** Dynamic fallback system built directly into AIRI for seamless switching between free community AI providers. Keyless providers are pre-configured out of the box. Easy BYOK path to add your own keyed providers whenever you want more.
- **System Integration:** Hooks fully into the system, from basic stuff like notifications to fully managing your Linux via terminal in Agentic Mode
- **Context Awareness:** Your companion observes desktop activity to respond and interact proactively and she can also assume full desktop control in Agentic Mode
- **Modular Stage Layouts:** GTK4 widgets, interactively generated backgrounds through artistry module, and window layouts composed dynamically by characters
<!--
## 🖥️ Development

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>
</div>

### ☕ Prerequisites

- pnpm
- Node.js (Electron app)
- Rust (Tauri app)

### 🖱️ Quick Start

The current recommended desktop app is still the Electron version in `apps/stage-tamagotchi/`, while the Tauri port is actively being built in `apps/stage-tauri/`.

🍎🐧🪟 Electron desktop app:

```shell
pnpm i
pnpm dev:tamagotchi
```

🍎🐧 Tauri desktop app:

> [!IMPORTANT]
> 🚧 Under construction

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` checks the local Tauri scaffold, Rust toolchain, `cargo-tauri` CLI, and runs `cargo check`. Install the Tauri CLI first if needed:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Why Tauri

Tauri lets us keep the Vue 3 renderer and AIRI companion experience while replacing the Electron main process with a smaller Rust backend. That means lower idle memory use, smaller native bundles, better Linux desktop integration, and a cleaner path to shipping AIRI as a native mobile app.

The same migration is also our path to native Android and iOS AIRI builds over the next few months.

### ⌨️ Building for Linux (under construction)

```shell
cd apps/stage-tamagotchi
./build.sh           # Builds the .deb package in dist/
```

_(An optional PKGBUILD is located in `apps/stage-tamagotchi` to repackage the `.deb` into `.zst` for Arch/Manjaro/CachyOS/EndeavorOS)._
-->

## ✌🏻 Acknowledgements
- the original project [`moeru-ai/airi`](https://github.com/moeru-ai/airi)
  - and its awesome desktop-oriented fork! [`dasilva333/airi`](https://github.com/dasilva333/airi)
- everyone who visited this page :з 
- awesome community <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>
## 🚙 Roadmap

- [x] **Brain**
  - [x] _Artistry:_ Native image generation pipelines (Replicate, ComfyUI)
  - [ ] _Proactivity:_ Define triggers for autonomous companion interactions (heartbeats)
  - [ ] _Multi-tier memory:_ built-in AIRI memory system
    - [ ] _Per-character memory scoping_ that works with witnesses (multiple-character sharing the screen)
- [x] **Ears**
  - [x] Client-side speech recognition & talking detection
- [x] **Mouth**
  - [x] OpenAI-compatible speech providers with voice discovery
- [x] **Body**
  - [x] VRM support
    - [ ] LLM-driven expression controls, auto-blink and auto-look-at
    - [ ] LLM-driven emotions and idle-loops
  - [x] Live2D support
    - [ ] LLM-driven expression controls
- [x] **Desktop Stage**
  - [ ] Multiple characters sharing the screen (KISS 1 window per character)
  - [ ] Scene/background management per character
- [ ] **AnimAIOS (WIP)**
  - [x] System tray & screen capture integration
  - [ ] Generate native GTK4 windows instead of web widgets
  - [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) deep integration
    - [ ] Send recent context snapshot with each AIRI heartbeat
  - [ ] AIRI chatbox doubles as a system terminal with natural language detection (similar to Warp terminal)
- [ ] **Misc**
  - [ ] Add mcp/skills via natural language prompts
  - [ ] Native Wayland Support using Ozone platform flags

## 🤖 API Providers

- [x] Supported LLM providers: everything [xsai](https://github.com/moeru-ai/xsai) supports
- [ ] Supported TTS providers: TBD
- [ ] Supported Embedding providers: TBD
 - [ ] Dynamic fallback system built into AIRI for seamless switching between free community AI providers. Keyless providers pre-configured out of the box. Easy BYOK path to add your own keyed providers whenever you want more power. 🚀

##### 🌸⛩️ readme_locale_ja_030

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ AnimAIOS プロジェクトへようこそ！言語を選択してください:

<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
  <p>
    <h2><a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> ベースの AnimAIOS ディストリビューション。 この秋、あなたの Linux デスクトップ / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / サイバーデッキ (Raspberry Pi) / ウェアラブルへ (概念)。</h2>
    <p><a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> リポジトリと <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a> による CPU 最適化済みソフトウェアをプリインストール。</p>
</sub>
<img width="1122" height="1402" alt="anima-logo-ja-v9 4" src="https://github.com/user-attachments/assets/9f9fd731-582e-4897-8cff-0060d9076437" />  
</div>

## 🌙 ビジョン

- **AIRI コンパニオンエンジン:** あなたのコンパニオン — AIRI。サブシステムが完全プリインストール済み。オープンソース哲学に基づき、無料コミュニティ AI 提供者のみで最高の体験を届けます。
- **ダイナミック フォールバック システム:** AIRI に直接組み込まれた動的フォールバック機能により、複数の無料 AI プロバイダー間をシームレスに切り替え。キー不要プロバイダーはすぐに使用可能。BYOK で自分のキー付きプロバイダーも簡単に追加。
- **システム・インテグレーション:** 通知のようなベーシック機能から、エージェンティック・モードで Linux 全体をターミナル経由でフルマネージメントまで完全統合
- **コンテキスト・アウェアネス:** コンパニオンはデスクトップアクティビティをオブザーブし、プロアクティブにレスポンス＆インタラクション。さらにエージェンティック・モードではデスクトップ完全コントロールも可能
- **モジュラー・ステージ・レイアウト:** GTK4 ウィジェット、アーティストリーモジュールによるインタラクティブ生成バックグラウンド、そしてキャラクター自身がダイナミック構成するウィンドウレイアウト
<!--
## 🖥️ デベロップメント

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>
<br>
</div>

### ☕ プリリクイジット

- pnpm
- Node.js (Electron アプリ)
- Rust (Tauri アプリ)

### 🖱️ クイック・スタート

現在推奨されるデスクトップアプリは `apps/stage-tamagotchi/` の Electron バージョンです。
Tauri ポートは現在 `apps/stage-tauri/` にてアクティブ開発中。

🍎🐧🪟 Electron デスクトップアプリ:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Tauri デスクトップアプリ:

> [!IMPORTANT]
> 🚧 アンダーコンストラクション

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` はローカル Tauri スキャフォールド、Rust ツールチェーン、`cargo-tauri` CLI をチェックし、`cargo check` を実行します。
必要なら先に Tauri CLI をインストールしてください:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ なぜ Tauri なのか

Tauri により Vue 3 レンダラーと AIRI コンパニオン体験を維持したまま、Electron メインプロセスを軽量な Rust バックエンドへリプレイスできます。

これにより低アイドルメモリ使用量、小型ネイティブバンドル、より高度な Linux デスクトップインテグレーション、そして AIRI をネイティブモバイルアプリとしてデリバリーするためのクリーンなパスを実現します。

同じマイグレーションは、今後数ヶ月以内の Android / iOS ネイティブ AIRI ビルドへのロードマップでもあります。

### ⌨️ Linux ビルド (アンダーコンストラクション)

```shell
cd apps/stage-tamagotchi
./build.sh           # dist/ に .deb パッケージをビルド
```

_(Arch/Manjaro/CachyOS/EndeavorOS 用に `.deb` を `.zst` へリパッケージするオプショナル PKGBUILD は `apps/stage-tamagotchi` に配置されています。)_
-->

## ✌🏻 アクノレッジメント
* オリジナルプロジェクト [`moeru-ai/airi`](https://github.com/moeru-ai/airi)

  * そして素晴らしいデスクトップ指向フォーク [`dasilva333/airi`](https://github.com/dasilva333/airi)
* このページをビジットしてくれた全員 :з
* 素晴らしいコミュニティ <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>

## 🚙 ロードマップ

* [x] **ブレイン**

  * [x] *アーティストリー:* ネイティブ画像生成パイプライン (Replicate, ComfyUI)
  * [ ] *プロアクティビティ:* 自律型コンパニオンインタラクション用トリガー定義 (ハートビート)
  * [ ] *マルチティア・メモリー:* built-in AIRI memory system

    * [ ] ウィットネス対応キャラクター別メモリースコープ (複数キャラクターによるスクリーン共有)

* [x] **イヤーズ**

  * [x] クライアントサイド音声認識＆トーキング検出

* [x] **マウス**

  * [x] OpenAI コンパチブル音声プロバイダー＆ボイスディスカバリー

* [x] **ボディ**

  * [x] VRM サポート

    * [ ] LLM ドリブン表情コントロール、オートブリンク、オートルックアット
    * [ ] LLM ドリブン感情＆アイドルループ
  * [x] Live2D サポート

    * [ ] LLM ドリブン表情コントロール

* [x] **デスクトップ・ステージ**

  * [ ] 複数キャラクターによるスクリーン共有 (KISS: 1 キャラクター = 1 ウィンドウ)
  * [ ] キャラクター別シーン / バックグラウンドマネージメント

* [ ] **AnimAIOS (WIP)**

  * [x] システムトレイ＆スクリーンキャプチャインテグレーション
  * [ ] Web ウィジェットではなくネイティブ GTK4 ウィンドウ生成
  * [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) ディープインテグレーション

    * [ ] AIRI ハートビートごとに最新コンテキストスナップショット送信
  * [ ] AIRI チャットボックスを自然言語検出対応システムターミナル化 (Warp ターミナル風)

* [ ] **ミスク**

  * [ ] ナチュラルランゲージプロンプトによる MCP/スキル追加
  * [ ] Ozone プラットフォームフラグによるネイティブ Wayland サポート

## 🤖 API プロバイダー

* [x] 対応 LLM プロバイダー: [xsai](https://github.com/moeru-ai/xsai) がサポートする全て
* [ ] 対応 TTS プロバイダー: TBD
* [ ] 対応 Embedding プロバイダー: TBD
* [ ] AIRI に組み込まれたダイナミック フォールバック システム。複数の無料 AI プロバイダー間をシームレスに切り替え。オープンソース哲学に基づき、無料コミュニティ AI 提供者のみを活用。キーが不要なプロバイダーはすぐに使用可能。BYOK パスは常に利用可能 — 必要な時に自分の鍵付きプロバイダーを追加可能。 🚀

##### 🎤👘 readme_locale_ko_030

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ AnimAIOS 프로젝트에 오신 걸 환영합니다! 언어를 선택해 주세요:
<div align=center>
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
  <p>
    <h2><a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> 기반 AnimAIOS 디스트로. 이번 가을, 너의 Linux 데스크탑 / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / 사이버덱 / 웨어러블로 ㄱㄱ.</h2>
    <p><a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> 리포와 <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a> 기반 CPU 최적화 소프트웨어 기본 탑재.</p>
</sub>
<img width="1195" height="1316" alt="anima-logo-ko-v7 1" src="https://github.com/user-attachments/assets/21c2b883-8f67-4ed2-90dd-3eb170313c5a" />  
</div>

## 🌙 비전

- **AIRI 컴패니언 엔진:** AIRI. 완전한 서브시스템과 함께 사전 구성 완료. 오픈소스 철학에 기반하여 무료 커뮤니티 AI 제공자를 통해 최고의 경험을 제공합니다.
- **다이내믹 폴백 시스템:** AIRI에 직접 내장된 다이내믹 폴백 기능으로 여러 무료 AI 프로바이더 간 원활한 전환. 키 불필요 프로바이더 즉시 사용 가능. BYOK로 자신만의 키 프로바이더도 쉽게 추가.
- **시스템 인테그레이션:** 알림 같은 기본 기능부터 에이전틱 모드에서 터미널 기반 Linux 전체 풀 컨트롤까지 완전 통합
- **컨텍스트 어웨어:** 컴패니언이 데스크탑 활동을 관찰하고 알아서 리액션 & 인터랙션. 에이전틱 모드에서는 데스크탑 자체를 직접 조작 가능
- **모듈러 스테이지 레이아웃:** GTK4 위젯, 아티스트리 모듈 기반 인터랙티브 생성 배경, 그리고 캐릭터가 직접 다이나믹하게 구성하는 윈도우 레이아웃
<!--
## 🖥️ 개발

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>
</div>

### ☕ 필수 조건

* pnpm
* Node.js (Electron 앱)
* Rust (Tauri 앱)

### 🖱️ 빠른 시작

현재 추천 데스크탑 앱은 `apps/stage-tamagotchi/` 의 Electron 버전임.
Tauri 포트는 현재 `apps/stage-tauri/` 에서 열심히 개발 중.

🍎🐧🪟 Electron 데스크탑 앱:

```shell
pnpm i
pnpm dev:tamagotchi
```

🍎🐧 Tauri 데스크탑 앱:

> [!IMPORTANT]
> 🚧 아직 공사 중임

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` 는 로컬 Tauri 스캐폴드, Rust 툴체인, `cargo-tauri` CLI 체크하고 `cargo check` 돌림.
필요하면 먼저 Tauri CLI 설치:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ 왜 Tauri?

Tauri 덕분에 Vue 3 렌더러랑 AIRI 컴패니언 경험은 그대로 유지하면서 Electron 메인 프로세스를 가벼운 Rust 백엔드로 교체 가능함.

결과:
낮은 아이들 메모리 사용량, 작은 네이티브 번들, 더 깊은 Linux 데스크탑 통합, 그리고 AIRI를 네이티브 모바일 앱으로 가져가기 위한 깔끔한 루트 확보.

### ⌨️ Linux 빌드 (공사 중)

```shell
cd apps/stage-tamagotchi
./build.sh           # dist/ 에 .deb 패키지 빌드
```

_(Arch/Manjaro/CachyOS/EndeavorOS용 `.deb` → `.zst` 리패키징 옵션 PKGBUILD는 `apps/stage-tamagotchi` 안에 있음.)_
-->

## ✌🏻 감사의 말
* 오리지널 프로젝트 [`moeru-ai/airi`](https://github.com/moeru-ai/airi)

  * 그리고 개쩌는 데스크탑 지향 포크 [`dasilva333/airi`](https://github.com/dasilva333/airi)
* 여기까지 와준 모든 사람 :з 
* 갓벽한 커뮤니티 <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>

## 🚙 로드맵

* [x] **브레인**

  * [x] *아티스트리:* 네이티브 이미지 생성 파이프라인 (Replicate, ComfyUI)
  * [ ] *프로액티비티:* 자율 컴패니언 인터랙션 트리거 정의 (하트비트)
  * [ ] *멀티 티어 메모리:* built-in AIRI memory system

    * [ ] 캐릭터별 메모리 스코프 + 위트니스 지원 (여러 캐릭터 화면 공유)

* [x] **이어즈**

  * [x] 클라이언트 사이드 음성 인식 & 토킹 감지

* [x] **마우스**

  * [x] OpenAI 호환 음성 프로바이더 & 보이스 디스커버리

* [x] **바디**

  * [x] VRM 지원

    * [ ] LLM 기반 표정 컨트롤, 오토 블링크, 오토 룩앳
    * [ ] LLM 기반 감정 & 아이돌 루프
  * [x] Live2D 지원

    * [ ] LLM 기반 표정 컨트롤

* [x] **데스크탑 스테이지**

  * [ ] 멀티 캐릭터 화면 공유 (KISS: 캐릭터 하나 = 윈도우 하나)
  * [ ] 캐릭터별 씬 / 배경 관리

* [ ] **AnimAIOS (WIP)**

  * [x] 시스템 트레이 & 스크린 캡처 인테그레이션
  * [ ] 웹 위젯 말고 네이티브 GTK4 윈도우 생성
  * [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) 딥 인테그레이션

    * [ ] AIRI 하트비트마다 최신 컨텍스트 스냅샷 전송
  * [ ] AIRI 채팅박스를 자연어 감지 가능한 시스템 터미널로 변환 (Warp 터미널 느낌)

* [ ] **기타**

  * [ ] 자연어 프롬프트 기반 MCP/스킬 추가
  * [ ] Ozone 플랫폼 플래그 기반 네이티브 Wayland 지원

## 🤖 API 프로바이더

* [x] 지원 LLM 프로바이더: [xsai](https://github.com/moeru-ai/xsai)가 지원하는 모든 것
* [ ] 지원 TTS 프로바이더: TBD
* [ ] 지원 Embedding 프로바이더: TBD
- [ ] AIRI에 내장된 다이내믹 폴백 시스템. 여러 무료 AI 프로바이더 간 원활한 전환. 오픈소스 철학에 기반하여 무료 커뮤니티 AI 제공자만을 활용. 키가 없는 프로바이더는 즉시 사전 구성. BYOK 경로는 항상 사용 가능 — 필요할 때 자신의 키가 있는 프로바이더를 추가. 🚀

##### 🏮🐼 readme_locale_zh_030

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ 欢迎来到 AnimAIOS 项目！先选个语言开冲：

<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
    <h2>基于 <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> 的 AnimAIOS 发行版， 今秋登陆你的 Linux Desktop / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / Wearable (Concept)。</h2>
    <p><a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> Repo 和 <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a> 针对 CPU 深度优化的软件生态。</p>
<img width="1218" height="1292" alt="anima-logo-zh-v9 2" src="https://github.com/user-attachments/assets/77ad419a-9d19-4e23-9af6-a6246b650305" />  
</div>

## 🌙 Vision

- **AIRI Companion 引擎:** 你的 Companion — AIRI。附带完整子系统预配置。基于开源理念：通过免费社区 AI 提供者，为用户提供最佳体验。
- **动态回退系统:** 直接内置 AIRI 的动态回退功能，在多个免费 AI 提供者间无缝切换。无需密钥的提供者开箱即用。随时可通过 BYOK 轻松添加自带密钥提供者。
- **System Integration（系统级融合）:** 从基础 Notification 到 Agentic Mode 下通过 Terminal 完整管理你的 Linux，深度 Hook 整个系统
- **Context Awareness（上下文感知）:** Companion 会观察你的 Desktop Activity，主动响应和交互；在 Agentic Mode 下甚至可以接管完整 Desktop Control
- **Modular Stage Layouts（模块化舞台布局）:** GTK4 Widgets、通过 Artistry Module 动态生成的 Interactive Background，以及由角色动态组合的 Window Layouts
<!--
## 🖥️ 上强度开发

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ 环境要求

- pnpm
- Node.js (Electron App)
- Rust (Tauri App)

### 🖱️ 快速开始

目前推荐的 Desktop App 仍然是 `apps/stage-tamagotchi/` 下的 Electron 版本，
而 Tauri Port 正在 `apps/stage-tauri/` 持续开发中。

🍎🐧🪟 Electron Desktop App:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Tauri Desktop App:

> [!IMPORTANT]
> 🚧 施工中

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` 会检查本地 Tauri Scaffold、Rust Toolchain、`cargo-tauri` CLI，并执行 `cargo check`。

如果还没安装 Tauri CLI：

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Why Tauri

Tauri 让我们可以保留 Vue 3 Renderer 和 AIRI Companion Experience，
同时把 Electron Main Process 替换成更轻量的 Rust Backend。

这意味着：
更低 Idle Memory 占用、更小 Native Bundle、更好的 Linux Desktop Integration，
以及未来把 AIRI 打包成 Native Mobile App 的更干净路线。

### ⌨️ Linux Build（施工中）

```shell
cd apps/stage-tamagotchi
./build.sh           # 在 dist/ 中构建 .deb Package
```

_(可选 PKGBUILD 位于 `apps/stage-tamagotchi`，用于将 `.deb` Repackage 成 Arch/Manjaro/CachyOS/EndeavorOS 使用的 `.zst`)_
-->

## ✌🏻 鸣谢
* 原始项目 [`moeru-ai/airi`](https://github.com/moeru-ai/airi)

  * 以及超棒的 Desktop-oriented Fork！[`dasilva333/airi`](https://github.com/dasilva333/airi)
* 感谢每一个访问这里的人 :з
* 超棒社区 <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>

## 🚙 Roadmap

* [x] **Brain（大脑）**

  * [x] *Artistry:* Native Image Generation Pipeline（Replicate, ComfyUI）
  * [ ] *Proactivity:* 定义 Companion 自主交互 Trigger（Heartbeat）
  * [ ] *Multi-tier Memory:* built-in AIRI memory system

    * [ ] *Per-character Memory Scoping:* 支持 Witness 场景下的角色独立记忆（多角色共享屏幕）

* [x] **Ears（耳朵）**

  * [x] Client-side Speech Recognition & Talking Detection

* [x] **Mouth（嘴巴）**

  * [x] OpenAI-Compatible Speech Provider + Voice Discovery

* [x] **Body（身体）**

  * [x] VRM Support

    * [ ] LLM 驱动表情控制、自动眨眼、自动 Look-at
    * [ ] LLM 驱动 Emotion 和 Idle Loop
  * [x] Live2D Support

    * [ ] LLM 驱动 Expression Control

* [x] **Desktop Stage（桌面舞台）**

  * [ ] 多角色共享屏幕（KISS：一个角色一个窗口）
  * [ ] 每个角色独立 Scene / Background Management

* [ ] **AnimAIOS (WIP)**

  * [x] System Tray & Screen Capture Integration
  * [ ] 不再使用 Web Widget，直接生成 Native GTK4 Window
  * [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) 深度 Integration

    * [ ] 每次 AIRI Heartbeat 携带最新 Context Snapshot
  * [ ] AIRI Chatbox 变身 System Terminal，支持 Natural Language Detection（类似 Warp Terminal）

* [ ] **Misc**

  * [ ] 通过 Natural Language Prompt 添加 MCP / Skills
  * [ ] 使用 Ozone Platform Flags 实现 Native Wayland Support

## 🤖 API Providers

* [x] 支持 LLM Provider：所有 [xsai](https://github.com/moeru-ai/xsai) 支持的 Provider
* [ ] 支持 TTS Provider：TBD
* [ ] 支持 Embedding Provider：TBD
- [ ] AIRI 内置动态回退系统，在多个免费 AI 提供者间无缝切换。基于开源理念：完全通过免费社区 AI 提供者，为用户提供最佳体验。无需密钥的提供者开箱即配。 BYOK 路径随时可用 — 随时可携带自己的密钥提供者获取更强动力。 🚀

##### 🌴⚽ readme_locale_es_pt_039_419

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Bem-vindo ao projeto AnimAIOS! Escolha seu idioma:

<div align=center>
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
    <p>
    <h2>A distro AnimAIOS baseada no <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>, pro seu Desktop Linux / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / Wearable (Concept), chegando neste outono.</h2>
    <p>Já vem com os pacotes pré-otimizados pro seu CPU usando os repositórios do <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> e <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>.</p>
<img width="1122" height="1402" alt="anima-logo-pt-es-v10 4" src="https://github.com/user-attachments/assets/804aeaff-ee1d-4f2a-9e4b-959fd6b40b15" />  
</div>
## 🌙 La Visión | A Visão

- **Motor de Compañero AIRI | Motor de Companheiro AIRI:** Tu compañera — AIRI. Viene con su subsistema completo pre-configurado. Filosofía open-source: darte la mejor experiencia usando proveedores de IA comunitarios y gratuitos. | Sua companheira — AIRI. Vem com seu subsistema completo pré-configurado. Filosofia open source: dar a você a melhor experiência utilizando provedores de IA comunitários e gratuitos.
- **Sistema de Fallback Dinámico | Sistema de Fallback Dinâmico:** Fallback dinámico integrado directamente en AIRI para cambiar sin problemas entre múltiples proveedores de IA gratuitos. Proveedores sin clave listos desde el inicio. BYOK siempre disponible para añadir tus propios proveedores con clave. | Fallback dinâmico integrado diretamente no AIRI para alternar perfeitamente entre múltiplos provedores de IA gratuitos. Provedores sem chave prontos desde o início. BYOK sempre disponível para adicionar seus próprios provedores com chave.
- **Integración Total con el Sistema | Integração Total com o Sistema:** Se conecta directamente con todo el sistema, desde notificaciones hasta el control completo de Linux mediante la terminal en el Modo Agentic. | Conecta-se diretamente ao sistema inteiro, desde notificações até o controle completo do Linux pelo terminal no Modo Agentic.
- **Conciencia de Contexto | Consciência de Contexto:** Tu companion entiende lo que ocurre en el escritorio para responder e interactuar de forma proactiva, pudiendo también asumir el control completo del escritorio en el Modo Agentic. | Sua companion entende o que acontece no desktop para responder e interagir de forma proativa, podendo também assumir o controle completo do desktop no Modo Agentic.
- **Layouts Modulares de Stage | Layouts Modulares de Stage:** Widgets GTK4, fondos generados en tiempo real por el módulo de artistry y layouts de ventanas creados dinámicamente por cada personaje. | Widgets GTK4, backgrounds gerados em tempo real pelo módulo de artistry e layouts de janelas criados dinamicamente por cada personagem.
<!--
## 🖥️ Desarrollo | Desenvolvimento

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Requisitos previos | Pré-requisitos

* pnpm
* Node.js (aplicación Electron | aplicativo Electron)
* Rust (aplicación Tauri | aplicativo Tauri)

### 🖱️ Empezando Rápidamente | Começando Rapidamente

Actualmente, la versión recomendada sigue siendo la aplicación Electron en `apps/stage-tamagotchi/`, mientras que la migración a Tauri continúa en desarrollo activo en `apps/stage-tauri/`. | Atualmente, a versão recomendada ainda é o aplicativo Electron em `apps/stage-tamagotchi/`, enquanto a migração para Tauri está em desenvolvimento ativo em `apps/stage-tauri/`.

🍎🐧🪟 Aplicación de escritorio Electron | Aplicativo desktop Electron:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Aplicación de escritorio Tauri | Aplicativo desktop Tauri:

> [!IMPORTANT]
> 🚧 En desarrollo | Em desenvolvimento

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

El `./init.sh` verifica el entorno local de Tauri, la toolchain de Rust, la CLI `cargo-tauri` y ejecuta `cargo check`. | O `./init.sh` verifica o ambiente local do Tauri, a toolchain Rust, a CLI `cargo-tauri` e executa o `cargo check`.

En caso necesario, instala primero la CLI de Tauri: | Caso necessário, instala primeiro a CLI do Tauri:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ ¿Por qué Tauri? | Por que Tauri?

Tauri permite mantener el renderer en Vue 3 y toda la experiencia de la companion AIRI, reemplazando el proceso principal de Electron por un backend Rust mucho más ligero. | O Tauri permite manter o renderer em Vue 3 e toda a experiência da companion AIRI, substituindo o processo principal do Electron por um backend Rust muito mais leve.

Resultado: menor uso de RAM, binarios más pequeños, mejor integración con escritorios Linux y un camino más simple para lanzar AIRI como aplicación nativa en dispositivos móviles. | Resultado: menor uso de RAM, binários menores, melhor integração com desktops Linux e um caminho mais simples para lançar a AIRI como aplicativo nativo em dispositivos móveis.

Esta migración también es el primer paso para builds nativos de AIRI en Android e iOS durante los próximos meses. | Essa migração também é o primeiro passo para builds nativos da AIRI no Android e iOS nos próximos meses.

-->

## ✌🏻 Agradecimientos | Agradecimentos
* el proyecto original `moeru-ai/airi` | o projeto original `moeru-ai/airi`
* ¡y su fork enfocado en escritorio simplemente increíble! `dasilva333/airi` | e seu fork focado em desktop simplesmente incrível! `dasilva333/airi`
* a todos los que visitaron esta página :з | todos que visitaram esta página :з
* comunidad increíble <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20membros&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a> | comunidade incrível <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20membros&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>

## 🚙 Roadmap

* [x] **Cerebro | Cérebro**

* [x] *Artistry:* Pipelines nativos de generación de imágenes (Replicate, ComfyUI) | *Artistry:* Pipelines nativos de geração de imagem (Replicate, ComfyUI)

* [ ] *Proactividad:* Definir gatillos para interacciones autónomas de la companion (heartbeats) | *Proatividade:* Definir gatilhos para interações autônomas da companion (heartbeats)

* [ ] *Memoria en múltiples capas:* built-in AIRI memory system | *Memória em múltiplas camadas:* built-in AIRI memory system

* [ ] *Alcance de memoria por personaje* funcionando con witnesses (varios personajes compartiendo la pantalla) | *Escopo de memória por personagem* funcionando com witnesses (várias personagens compartilhando a tela)

* [x] **Oídos | Ouvidos**

* [x] Reconocimiento de voz local y detección de cuándo alguien está hablando | Reconhecimento de fala local e detecção de quando alguém está falando

* [x] **Boca | Boca**

* [x] Proveedores de voz compatibles con OpenAI con descubrimiento automático de voces | Provedores de voz compatíveis com OpenAI com descoberta automática de vozes

* [x] **Cuerpo | Corpo**

* [x] Soporte a VRM | Suporte a VRM

* [ ] Control de expresiones vía LLM, auto-blink y auto-look-at | Controle de expressões via LLM, auto-blink e auto-look-at

* [ ] Emociones e idle-loops generados por LLM | Emoções e idle-loops gerados por LLM

* [x] Soporte a Live2D | Suporte a Live2D

* [ ] Control de expresiones vía LLM | Controle de expressões via LLM

* [x] **Desktop Stage**

* [ ] Varios personajes compartiendo la pantalla (KISS: 1 ventana por personaje) | Várias personagens compartilhando a tela (KISS: 1 janela por personagem)

* [ ] Gestión de escena/fondo por personaje | Gerenciamento de cena/background por personagem

* [ ] **AnimAIOS (WIP)**

* [x] Integración con bandeja del sistema y captura de pantalla | Integração com bandeja do sistema e captura de tela

* [ ] Generar ventanas GTK4 nativas en lugar de widgets web | Gerar janelas GTK4 nativas em vez de widgets web

* [ ] Integración profunda con [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) | Integração profunda com [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux)

* [ ] Enviar una instantánea del contexto reciente a cada heartbeat de AIRI | Enviar um snapshot do contexto recente a cada heartbeat da AIRI

* [ ] El chat de AIRI también funciona como terminal del sistema con detección de lenguaje natural (estilo Warp) | O chat da AIRI também funciona como terminal do sistema com detecção de linguagem natural (estilo Warp)

* [ ] **Extras**

* [ ] Añadir MCP/skills usando prompts en lenguaje natural | Adicionar MCP/skills usando prompts em linguagem natural

* [ ] Soporte nativo a Wayland usando flags de la plataforma Ozone | Suporte nativo a Wayland usando flags da plataforma Ozone

## 🤖 Proveedores de API | Provedores de API

* [x] Proveedores LLM soportados: todo lo que xsai soporta | Provedores LLM suportados: tudo que o xsai suporta
* [ ] Proveedores TTS soportados: Próximamente™ | Provedores TTS suportados: Em breve™
* [ ] Proveedores de Embeddings: Próximamente™ | Provedores de Embeddings: Em breve™
- [ ] Sistema de fallback dinámico integrado en AIRI para cambiar sin problemas entre múltiples proveedores de IA gratuitos. Filosofía open source: lo mejor de la experiencia a través de proveedores comunitarios gratuitos. Proveedores sin clave pre-configurados. BYOK siempre disponible. 🚀 | Sistema de fallback dinâmico integrado no AIRI para alternar perfeitamente entre múltiplos provedores de IA gratuitos. Filosofia open source: a melhor experiência através de provedores comunitários gratuitos. Provedores sem chave pré-configurados. BYOK sempre disponível. 🚀

##### 🥐🍷 readme_locale_fr_002_155

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Bienvenue sur le projet AnimAIOS ! Choisissez votre langue :

<div align=center>
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
    <p>
    <h2>Distribution AnimAIOS basée sur <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>, pour ton Desktop Linux / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / Wearable (Concept), cet automne.</h2>
    <p>Livrée avec des logiciels déjà optimisés pour ton CPU grâce aux dépôts <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> et <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>.</p>
<img width="1200" height="1311" alt="anima-logo-fr-v7 4" src="https://github.com/user-attachments/assets/85a8ea15-b959-4798-a15d-8e0c9122632c" />  
</div>

## 🌙 La Vision

- **Moteur de Compagnon AIRI :** Ta compagne — AIRI. Vient avec son sous-système complet pré-configuré. Philosophie open source : t'offrir la meilleure expérience en utilisant uniquement des fournisseurs d'IA communautaire gratuits.
- **Système de Fallback Dynamique :** Fallback dynamique intégré directement dans AIRI pour basculer sans problème entre plusieurs fournisseurs d'IA gratuits. Les fournisseurs sans clé sont prêts dès le départ. Chemin BYOK toujours disponible pour ajouter tes propres fournisseurs à clé quand tu veux plus de puissance.
- **Intégration Système :** Branchée à fond sur ton système, des notifications jusqu'au contrôle complet de Linux via le terminal en mode Agentic
- **Conscience du Contexte :** Ta compagne observe ce qui se passe sur ton bureau pour réagir et interagir de façon proactive, et peut même prendre le contrôle total du desktop en mode Agentic
- **Layouts Modulaires :** Widgets GTK4, arrière-plans générés à la volée via le module artistique, et compositions de fenêtres créées dynamiquement par les personnages
<!--
## 🖥️ Développement

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Prérequis

- pnpm
- Node.js (appli Electron)
- Rust (appli Tauri)

### 🖱️ Démarrage Express

L'appli desktop recommandée reste actuellement la version Electron dans `apps/stage-tamagotchi/`, pendant que le portage Tauri avance activement dans `apps/stage-tauri/`.

🍎🐧🪟 Application desktop Electron :

```shell
pnpm i
pnpm dev:tamagotchi
```

🍎🐧 Application desktop Tauri :

> [!IMPORTANT]
> 🚧 En cours de dev

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` vérifie le scaffold Tauri local, la toolchain Rust, le CLI `cargo-tauri`, puis lance `cargo check`. Installe d'abord le CLI Tauri si nécessaire :

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Pourquoi Tauri

Tauri nous permet de garder le renderer Vue 3 et toute l'expérience AIRI, tout en remplaçant le process principal Electron par un backend Rust beaucoup plus léger. Résultat : moins de RAM au repos, des binaires natifs plus petits, une meilleure intégration avec Linux et une voie beaucoup plus clean pour sortir AIRI en appli mobile native.

Cette migration ouvre aussi la voie aux builds AIRI natifs sur Android et iOS dans les prochains mois.

### ⌨️ Build Linux (en cours)

```shell
cd apps/stage-tamagotchi
./build.sh           # Génère le paquet .deb dans dist/
```

_(Un PKGBUILD optionnel est disponible dans `apps/stage-tamagotchi` pour reconditionner le `.deb` en `.zst` pour Arch/Manjaro/CachyOS/EndeavorOS)._
-->

## ✌🏻 Remerciements
- le projet original [`moeru-ai/airi`](https://github.com/moeru-ai/airi)
  - et son incroyable fork orienté desktop ! [`dasilva333/airi`](https://github.com/dasilva333/airi)
- toutes les personnes qui sont passées par cette page :з
- la commu est incroyable <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20membres&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Nombre de membres Discord"></a>
## 🚙 Roadmap

- [x] **Cerveau**
  - [x] _Artistry :_ Pipelines natifs de génération d'images (Replicate, ComfyUI)
  - [ ] _Proactivité :_ Définir les déclencheurs des interactions autonomes du compagnon (heartbeats)
  - [ ] _Mémoire multi-niveaux :_ built-in AIRI memory system
    - [ ] _Mémoire isolée par personnage_ compatible avec les témoins (plusieurs personnages sur le même écran)
- [x] **Oreilles**
  - [x] Reconnaissance vocale côté client & détection de parole
- [x] **Bouche**
  - [x] Fournisseurs vocaux compatibles OpenAI avec découverte automatique des voix
- [x] **Corps**
  - [x] Support VRM
    - [ ] Contrôle des expressions par LLM, clignement automatique et suivi du regard
    - [ ] Émotions et animations idle pilotées par LLM
  - [x] Support Live2D
    - [ ] Contrôle des expressions par LLM
- [x] **Scène Desktop**
  - [ ] Plusieurs personnages partageant le même écran (KISS : 1 fenêtre par personnage)
  - [ ] Gestion des scènes/arrière-plans par personnage
- [ ] **AnimAIOS (WIP)**
  - [x] Intégration de la zone de notification et capture d'écran
  - [ ] Générer des fenêtres GTK4 natives au lieu de widgets web
  - [ ] Intégration poussée de [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux)
    - [ ] Envoyer un snapshot récent du contexte à chaque heartbeat d'AIRI
- [ ] **Divers**
  - [ ] Ajouter des MCP/skills via des prompts en langage naturel
  - [ ] Support Wayland natif via les flags Ozone

## 🤖 Fournisseurs d'API

- [x] Fournisseurs LLM supportés : tout ce que [xsai](https://github.com/moeru-ai/xsai) prend en charge
- [ ] Fournisseurs TTS supportés : TBD
- [ ] Fournisseurs d'Embeddings supportés : TBD
- [ ] Système de fallback dynamique intégré dans AIRI pour basculer sans problème entre plusieurs fournisseurs d'IA gratuits. Philosophie open source : la meilleure expérience via les fournisseurs d'IA communautaires gratuits. Fournisseurs sans clé pré-configurés. Chemin BYOK toujours disponible. 🚀

##### 🪆🐻‍❄️ readme_locale_ru_810

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Добро пожаловать в проект AnimAIOS! Выберите язык:

<div align=center>
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
  <sub>
    <h2>Дистрибутив AnimAIOS на базе <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>, залетает на твой Linux Desktop / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / Wearable (Concept) уже этой осенью.</h2>
    <h3>В комплекте софт, заранее затюненный под твой CPU через <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> репозитории и <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>, обеспечивая вирус-фри Arch опыт.</h3>
</sub>
<img width="1205" height="1305" alt="anima-logo-ru-v11 1" src="https://github.com/user-attachments/assets/9d730026-1681-4b13-b356-34653d32560d" />
</div>

## 🌙 Видение

- **Движок компаньона AIRI:** Твоя компаньонка — AIRI. Поставляется с полной подсистемой, предварительно настроенной. Философия открытого исходного кода: лучший опыт через бесплатных AI-провайдеров сообщества.
- **Динамическая система фоллбэка:** Динамический фоллбэк, встроенный непосредственно в AIRI для бесшовного переключения между несколькими бесплатными AI-провайдерами. Провайдеры без ключа настроены из коробки. BYOK-путь всегда доступен — принеси своих ключевых провайдеров, когда захочешь больше.
- **Глубокая интеграция с системой:** Полностью цепляется за систему — от простых штук типа уведомлений до полного управления Linux через терминал в Agentic Mode
- **Контекстная осознанность:** Компаньонка наблюдает за активностью рабочего стола, чтобы отвечать и взаимодействовать проактивно, а в Agentic Mode может взять полный контроль над десктопом
- **Модульные сцены:** GTK4-виджеты, интерактивно генерируемые фоны через artistry-модуль и динамически собираемые раскладки окон самими персонажами
<!--
## 🖥️ Разработка

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Требования

- pnpm
- Node.js (Electron app)
- Rust (Tauri app)

### 🖱️ Быстрый старт

Сейчас рекомендуемое desktop-приложение всё ещё Electron-версия в `apps/stage-tamagotchi/`, а порт на Tauri активно пилится в `apps/stage-tauri/`.

🍎🐧🪟 Electron desktop app:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Tauri desktop app:

> [!IMPORTANT]
> 🚧 В разработке

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` проверяет локальный Tauri scaffold, Rust toolchain, `cargo-tauri` CLI и запускает `cargo check`. Если надо — сначала ставим Tauri CLI:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Почему Tauri

Tauri позволяет оставить Vue 3 renderer и AIRI companion experience, заменив Electron main process на более лёгкий Rust backend. Итог: меньше RAM в простое, меньше нативные бандлы, лучше интеграция с Linux desktop и более чистый путь к релизу AIRI как нативного мобильного приложения.

Эта же миграция — наш путь к нативным Android и iOS сборкам AIRI в ближайшие месяцы.

### ⌨️ Сборка под Linux (в разработке)

```shell
cd apps/stage-tamagotchi
./build.sh           # Собирает .deb пакет в dist/
```

_(Опциональный PKGBUILD лежит в `apps/stage-tamagotchi` и позволяет перепаковать `.deb` в `.zst` для Arch/Manjaro/CachyOS/EndeavorOS)._
-->

## ✌🏻 Благодарности
* оригинальному проекту [`moeru-ai/airi`](https://github.com/moeru-ai/airi)

  * и его мощному desktop-форку! [`dasilva333/airi`](https://github.com/dasilva333/airi)
* всем, кто заглянул сюда :з
* топовому комьюнити <a href="https://discord.gg/TgQ3Cu2F7A"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2" alt="Discord member count"></a>

## 🚙 Дорожная карта

* [x] **Мозг**

  * [x] *Artistry:* Нативные пайплайны генерации изображений (Replicate, ComfyUI)
  * [ ] *Проактивность:* Настройка триггеров для автономных взаимодействий компаньона (heartbeats)
  * [ ] *Многоуровневая память:* built-in AIRI memory system

    * [ ] *Память на уровне персонажа* с поддержкой witness-системы (несколько персонажей шарят один экран)
* [x] **Уши**

  * [x] Распознавание речи и детект разговора на стороне клиента
* [x] **Рот**

  * [x] Совместимые с OpenAI voice-провайдеры с поиском голосов
* [x] **Тело**

  * [x] Поддержка VRM

    * [ ] Управление выражениями через LLM, auto-blink и auto-look-at
    * [ ] LLM-эмоции и idle-loop анимации
  * [x] Поддержка Live2D

    * [ ] Управление выражениями через LLM
* [x] **Desktop Stage**

  * [ ] Несколько персонажей на одном экране (KISS: одно окно на персонажа)
  * [ ] Управление сценами/фонами для каждого персонажа
* [ ] **AnimAIOS (WIP)**

  * [x] System tray и интеграция screen capture
  * [ ] Генерация нативных GTK4 окон вместо web widgets
  * [ ] Глубокая интеграция с [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux)

    * [ ] Отправка свежего snapshot контекста с каждым AIRI heartbeat
  * [ ] AIRI chatbox превращается в системный терминал с распознаванием естественного языка (как Warp terminal)
* [ ] **Разное**

  * [ ] Добавление mcp/skills через natural language prompts
  * [ ] Нативный Wayland Support через Ozone platform flags

## 🤖 API Провайдеры

* [x] Поддерживаемые LLM-провайдеры: всё, что поддерживает [xsai](https://github.com/moeru-ai/xsai)
* [ ] Поддерживаемые TTS-провайдеры: TBD
* [ ] Поддерживаемые Embedding-провайдеры: TBD
- [ ] Динамическая система фоллбэка, встроенная в AIRI для бесшовного переключения между несколькими бесплатными AI-провайдерами. Философия открытого кода: лучший опыт через бесплатных AI-провайдеров сообщества. Провайдеры без ключа настроены из коробки. BYOK всегда доступен. 🚀

##### 🌙🕌 readme_locale_ar_fa_tr_015_145

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ أهلاً بك في مشروع AnimAIOS! اختر لغتك:

<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="README en Português / Español">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="README en Français">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="README بالعربية">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
<sub>
    <h2><b>AnimAIOS</b> مبنية على <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>، لجهاز Linux المكتبي / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / الأجهزة القابلة للارتداء.</h2>
    <h2>توزيعۀ <b>AnimAIOS</b> ساخته شده بر پایه‌ی <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> برای دسکتاپ لینوکس، DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS)، CyberDeck (Raspberry Pi) و دستگاه‌های پوشیدنی.</h2>
    <h2><b>AnimAIOS</b>, <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> tabanlı, yapay zeka destekli yeni nesil masaüstü işletim sistemi.</h2>
    <p>تأتي مع برامج محسّنة مسبقاً لمعالجك باستخدام مستودعات <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> و <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>، لتجربة Arch خالية من الفيروسات.</p>
    <p>با نرم‌افزارهایی که برای CPU شما بهینه شده‌اند، با استفاده از مخازن <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> و <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>، برای تجربه‌ی Arch بدون ویروس.</p>
    <p>CPU'n için optimize edilmiş yazılımlar <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> ve <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a> depoları ile geliyor, virüsüz Arch deneyimi sunuyor.</p>
</sub>

<img width="1254" height="1254" alt="anima-logo-ar-fa-tr-v2 1" src="https://github.com/user-attachments/assets/bae8d9ba-a9be-407d-8143-e5eb4859a885" />  
</div>

---

## 🌙 الرؤية | چشم‌انداز | Vizyon

- **محرك رفيق AIRI | موتور همراه AIRI | AIRI Yoldaş Motoru:**
    * **AR:** رفيقتك — AIRI. تأتي مع النظام الفرعي الكامل المُعدّ مسبقاً. فلسفة المصدر المفتوح: نقدم لك أفضل تجربة بالكامل عبر مزودي الذكاء الاصطناعي المجتمعيين المجانيين.
    * **FA:** همراه تو — AIRI. با زیرسیستم کامل خود از پیش پیکربندی شده عرضه می‌شود. فلسفه متن‌باز: ارائه بهترین تجربه به طور کامل از طریق ارائه‌دهندگان هوش مصنوعی اجتماعی رایگان.
    * **TR:** Yoldaşın — AIRI. Alt sistemiyle tamamen önceden yapılandırılmış olarak gelir. Açık kaynak felsefesi: tamamen ücretsiz topluluk AI sağlayıcıları üzerinden en iyi deneyimi sunuyoruz.

- **نظام الفولباك الديناميكي | سیستم فولبک دینامیک | Dinamik Fallback Sistemi:**
    * **AR:** فولباك ديناميكي مدمج مباشرة في AIRI للتبديل السلس بين عدة مزودي ذكاء اصطناعي مجانيين. مزودو الخدمة بدون مفاتيح جاهزون من البداية. مسار BYOK متاح بسهولة لإضافة مزودي خدمة بمفاتيح خاصة متى أردت المزيد.
    * **FA:** سیستم فولبک دینامیک مستقیماً در AIRI تعبیه شده برای سوئیچ کردن روان بین چندین ارائه‌دهنده هوش مصنوعی رایگان. ارائه‌دهندگان بدون کلید از ابتدا آماده‌اند. مسیر BYOK برای افزودن ارائه‌دهندگان کلیددار شخصی شما همیشه در دسترس است.
    * **TR:** AIRI'ye doğrudan entegre edilmiş dinamik fallback sistemi, birden fazla ücretsiz AI sağlayıcısı arasında sorunsuz geçiş için. Anahtarsız sağlayıcılar kutudan çıktığı gibi hazır. İstediğinizde kendi anahtarlı sağlayıcılarınızı eklemek için BYOK yolu her zaman mevcut.
**نظام التكامل الكامل | سیستم یکپارچه‌سازی کامل | Tam Sistem Entegrasyonu:**
    * **AR:** تكامل عميق مع النظام بأكمله، من الإشعارات الأساسية إلى التحكم الكامل في Linux عبر الطرفية في وضع Agentic Mode.
    * **FA:** یکپارچه‌سازی عمیق با کل سیستم، از اعلان‌های پایه تا کنترل کامل لینوکس از طریق ترمینال در حالت Agentic Mode.
    * **TR:** Bildirimlerden Linux'e Agentic Mode'da terminal yoluyla tam kontrole kadar tüm sistemle derin entegrasyon.
**وعي السياق | آگاهی زمینه | Bağlam Farkındalığı:**
    * **AR:** الرفيق يراقب نشاط سطح المكتب للاستجابة والتفاعل الاستباقي، ويمكنه في وضع Agentic Mode التحكم الكامل في سطح المكتب.
    * **FA:** رفیق فعالیت دسکتاپ را برای پاسخ‌دهی و تعامل پیشگیرانه نظارت می‌کند و می‌تواند در حالت Agentic Mode کنترل کامل دسکتاپ را بگیرد.
    * **TR:** Yoldaş masaüstü aktivitesini izleyerek proaktif yanıt ve etkileşim sağlar; Agentic Modda masaüstünü tamamen kontrol edebilir.
**تصميمات المرحلة المعيارية | طراحی‌های صحنه ماژولار | Modüler Sahne Düzenleri:**
    * **AR:** عناصر GTK4، خلفيات توليدية تفاعلية عبر وحدة الفن، وتخطيطات نوافذ مكونة ديناميكياً بواسطة الشخصيات.
    * **FA:** ویجت‌های GTK4، پس‌زمینه‌های تعاملی مولد شده از طریق ماژول هنری، و چیدمان پنجره‌های ساخته شده پویا توسط شخصیت‌ها.
    * **TR:** GTK4 widget'ları, artistry modülü üzerinden interaktif üretilen arka planlar ve karakterler tarafından dinamik oluşturulan pencere düzenleri.


<!--
## 🖥️ التطوير | توسعه | Geliştirme

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ المتطلبات | پیش‌نیازها | Gereksinimler

*   pnpm
*   Node.js (تطبيق Electron / اپ Electron / Electron uygulaması)
*   Rust (تطبيق Tauri / اپ Tauri / Tauri uygulaması)

---

### 🖱️ البداية السريعة | شروع سریع | Hızlı Başlangıç

*   **AR:** الإصدار المكتبي الموصى به حالياً هو نسخة Electron داخل `apps/stage-tamagotchi/` بينما يتم تطوير نسخة Tauri الأصلية داخل `apps/stage-tauri/`.
*   **FA:** نسخه پیشنهادی فعلی دسکتاپ همچنان نسخه Electron در مسیر `apps/stage-tamagotchi/` است، در حالی که نسخه‌ی Tauri در مسیر `apps/stage-tauri/` در حال ساخت است.
*   **TR:** Şu anda önerilen masaüstü uygulaması `apps/stage-tamagotchi/` içindeki Electron sürümüdür. Tauri portu ise aktif olarak `apps/stage-tauri/` içinde geliştirilmektedir.

#### 🍎🐧🪟 تطبيق Electron / اجرای Electron / Electron masaüstü uygulaması:

```shell
pnpm i
pnpm dev:tamagotchi
```

#### 🍎🐧 تطبيق Tauri / اجرای Tauri / Tauri masaüstü uygulaması:

> [!IMPORTANT]
> *   **AR:** 🚧 تحت البناء حالياً
> *   **FA:** 🚧 در حال ساخت و توسعه
> *   **TR:** 🚧 Yapım aşamasında

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

*   **AR:** يقوم `./init.sh` بفحص إعداد Tauri المحلي، أدوات Rust، وواجهة `cargo-tauri` ثم يشغل `cargo check`. إذا لم تكن مثبتة:
*   **FA:** فایل `./init.sh` بررسی تنظیمات محلی Tauri، ابزارهای Rust و ابزار CLI `cargo-tauri` را انجام می‌دهد و سپس `cargo check` را اجرا می‌کند. در صورت عدم نصب:
*   **TR:** `./init.sh` yerel Tauri kurulumunu, Rust araç zincirini, `cargo-tauri` CLI aracını kontrol eder ve `cargo check` çalıştırır. Eğer kurulu değilse:

```shell
cargo install tauri-cli --version '^2.0'
```

---

### ❔ لماذا Tauri؟ | چرا Tauri؟ | Neden Tauri?

*   **AR:** Tauri يسمح لنا بالحفاظ على تجربة Vue 3 ورفيقة AIRI مع استبدال محرك Electron الرئيسي بخلفية Rust أخف.
*   **FA:** Tauri اجازه می‌دهد تجربه Vue 3 و AIRI حفظ شود، اما به جای Electron از بک‌اند سبک Rust استفاده کنیم.
*   **TR:** Tauri sayesinde Vue 3 arayüzünü ve AIRI deneyimini korurken Electron ana sürecini daha hafif Rust backend ile değiştirebiliyoruz.

#### النتيجة / نتیجه / Sonuç:

*   **AR:** استهلاك ذاكرة أقل 🚀 | حزم أصغر | تكامل أفضل مع سطح مكتب Linux | طريق أنظف لتحويل AIRI إلى تطبيق أصلي للجوال
*   **FA:** مصرف رم کمتر 🚀 | حجم کمتر برنامه | هماهنگی بهتر با لینوکس | مسیر بهتر برای انتشار نسخه موبایل
*   **TR:** Daha düşük RAM kullanımı 🚀 | Daha küçük uygulama boyutu | Daha iyi Linux entegrasyonu | Native mobil uygulamalar için daha temiz yol

*   **AR:** وهذه الهجرة هي طريقنا لبناء نسخ Android و iOS الأصلية قريباً.
*   **FA:** این مهاجرت، مسیر ما برای ساخت نسخه‌های بومی (Native) اندروید و iOS در آینده نزدیک است.
*   **TR:** Bu geçiş aynı zamanda Android ve iOS için native AIRI sürümlerinin temelidir.

-->

## ✌🏻 الشكر والتقدير | تشکرها | Teşekkürler
*   **AR:** المشروع الأصلي: [`moeru-ai/airi`](https://github.com/moeru-ai/airi) والنسخة المكتبية الرهيبة: [`dasilva333/airi`](https://github.com/dasilva333/airi)
*   **FA:** پروژه اصلی: [`moeru-ai/airi`](https://github.com/moeru-ai/airi) و فورک فوق‌العاده دسکتاپ: [`dasilva333/airi`](https://github.com/dasilva333/airi)
*   **TR:** Orijinal proje: [`moeru-ai/airi`](https://github.com/moeru-ai/airi) ve harika masaüstü odaklı fork: [`dasilva333/airi`](https://github.com/dasilva333/airi)

*   **AR:** لكل شخص وصل لهذه الصفحة :3
*   **FA:** همه‌ی کسایی که این صفحه رو باز کردن :3
*   **TR:** Bu sayfayı ziyaret eden herkese :3

*   **AR:** مجتمعنا الرهيب:
*   **FA:** کامیونیتی خفن ما:
*   **TR:** Muhteşem topluluğumuz:

<a href="https://discord.gg/TgQ3Cu2F7A">
<img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Finvites%2FTgQ3Cu2F7A%3Fwith_counts%3Dtrue&query=%24.approximate_member_count&suffix=%20members&logo=discord&logoColor=white&label=%20&color=7389D8&labelColor=6A7EC2">
</a>
---

## 🚙 خارطة الطريق | نقشه راه | Yol Haritası

*   **[x] 🧠 العقل / مغز / Beyin**
    *   **AR:** [x] *الفن:* أنظمة توليد الصور الأصلية (Replicate, ComfyUI)
    *   **FA:** [x] *هنر:* سیستم‌های تولید تصویر بومی (Replicate, ComfyUI)
    *   **TR:** [x] *Artistry:* Yerel AI görsel üretim sistemleri (Replicate, ComfyUI)
    *   **AR:** [ ] *الاستباقية:* تعريف محفزات تفاعل الرفيقة الذكية (heartbeats)
    *   **FA:** [ ] *پیش‌دستی:* تعریف محرک‌های تعاملی همراه هوشمند (heartbeats)
    *   **TR:** [ ] *Proaktiflik:* Otonom AI etkileşimleri için tetikleyiciler (heartbeats)
    *   **AR:** [ ] *ذاكرة متعددة المستويات:* built-in AIRI memory system
    *   **FA:** [ ] *حافظه چندسطحی:* built-in AIRI memory system
    *   **TR:** [ ] *Çok katmanlı hafıza:* built-in AIRI memory system
      *   **AR:** [ ] *ذاكرة خاصة لكل شخصية مع دعم witness:* ذاكرة شخصية مع دعم نظام الشهود (عدة شخصيات تشارك الشاشة)
      *   **FA:** [ ] *حافظه اختصاصی برای هر کاراکتر با پشتیبانی witness:* حافظه شخصی با پشتیبانی سیستم شاهد (چندین شخصیت در یک صفحه)
      *   **TR:** [ ] *Her karakter için özel hafıza, witness desteğiyle:* Her karakter için özel hafıza, witness sistemi desteğiyle (birden fazla karakter ekran paylaşır)

*   **[x] 👂 الأذن / گوش / Kulak**
    *   **AR:** [x] التعرف على الصوت وكشف الكلام من الجهاز.
    *   **FA:** [x] تشخیص صدا و گفتار روی دستگاه.
    *   **TR:** [x] Cihaz içi ses tanıma ve konuşma tespiti.

*   **[x] 👄 الفم / دهان / Ağız (Mouth)**
    *   **AR:** [x] مزودات صوت متوافقة مع OpenAI مع اكتشاف الأصوات.
    *   **FA:** [x] ارائه‌دهندگان صوتی سازگار با OpenAI با کشف صداها.
    *   **TR:** [x] OpenAI uyumlu ses sağlayıcıları, ses keşfi ile.

*   **[x] 🤖 الجسد / بدن / Beden**
    *   **AR:** [x] دعم VRM
      *   **AR:** [ ] *تحكم تعابير مدعوم بالـ LLM:* التحكم بالتعبيرات، الرمش التلقائي، والنظر التلقائي
      *   **FA:** [ ] *کنترل حالات چهره با LLM:* کنترل تعابیر، بلک خودکار، و نگاه خودکار
      *   **TR:** [ ] *LLM destekli mimik kontrolü:* ifade kontrolü, otomatik göz kırpma, otomatik bakış
      *   **AR:** [ ] *مشاعر وحركات تلقائية مدعومة بالـ LLM:* المشاعر والحلقات الخاملة
      *   **FA:** [ ] *انیمیشن‌های خودکار احساسات و حرکات با LLM:* احساسات و حلقه‌های idle
      *   **TR:** [ ] *LLM destekli duygu ve idle animasyonları:* duygular ve idle döngüleri
    *   **AR:** [x] دعم Live2D
      *   **AR:** [ ] *تحكم تعابير مدعوم بالـ LLM لـ Live2D*
      *   **FA:** [ ] *کنترل حالات چهره با LLM برای Live2D*
      *   **TR:** [ ] *Live2D için LLM destekli ifade kontrolü*

*   **[x] 🖥️ مرحلة سطح المكتب / صحنه دسکتاپ / Masaüstü Sahnesi**
    *   **AR:** [ ] عدة شخصيات على نفس الشاشة (KISS: نافذة واحدة لكل شخصية)
    *   **FA:** [ ] نمایش چند شخصیت روی یک صفحه (KISS: یک پنجره برای هر شخصیت)
    *   **TR:** [ ] Aynı ekranda birden fazla karakter (KISS: 1 pencere per karakter)
    *   **AR:** [ ] إدارة المشاهد والخلفيات لكل شخصية
    *   **FA:** [ ] مدیریت صحنه و بک‌گراند برای هر شخصیت
    *   **TR:** [ ] Karakter bazlı sahne/arka plan yönetimi

*   **[ ] ⚡ AnimAIOS (قيد التطوير / در حال توسعه / Yapım Aşamasında)**
    *   **AR:** [x] تكامل شريط النظام والتقاط الشاشة
    *   **FA:** [x] ادغام با System Tray و Screen Capture
    *   **TR:** [x] Sistem tepsisi ve ekran yakalama entegrasyonu
    *   **AR:** [ ] إنشاء نوافذ GTK4 أصلية بدلاً من ويب ويدجتس
    *   **FA:** [x] ساخت پنجره‌های بومی GTK4 به جای ویجت‌های وب
    *   **TR:** [x] Native GTK4 pencereleri oluşturma, web widget'ların yerine
    *   **AR:** [ ] تكامل [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) العميق
      *   **AR:** [ ] إرسال لقطة سياق حديثة مع كل نبضة قلب AIRI
      *   **FA:** [ ] ارسال اسنپ‌شات محتوای اخیر با هر ضربه قلب AIRI
      *   **TR:** [ ] Her AIRI heartbeat'inde güncel context snapshot'i gönderme
    *   **AR:** [ ] صندوق دردشة AIRI يصبح طرفية ذكية بلغة طبيعية (مشابه Warp)
    *   **FA:** [ ] باکس چت AIRI تبدیل می‌شود به یک ترمینال هوشمند با زبان طبیعی (شبیه Warp)
    *   **TR:** [ ] AIRI sohbet kutusu, doğal dil termineline dönüşür (Warp benzeri)

*   **[ ] 📦 متفرقات / متفرقه / Diğer (Misc)**
    *   **AR:** [ ] إضافة mcp/skills عبر مطالب باللغة الطبيعية
    *   **FA:** [ ] اضافه کردن mcp/skills از طریق پرامپت‌های زبان طبیعی
    *   **TR:** [ ] Doğal dil prompt'ları ile mcp/skills ekleme
    *   **AR:** [ ] دعم Wayland أصلي باستخدام أعلام منصة Ozone
    *   **FA:** [ ] پشتیبانی بومی Wayland با استفاده از فلگ‌های پلتفرم Ozone
    *   **TR:** [ ] Ozone platform flag'ları ile native Wayland desteği

---

## 🤖 مزودات API | ارائه‌دهنده‌های API | API Sağlayıcıları

*   **[x] AR:** مزودات LLM المدعومة: كل ما يدعمه [xsai](https://github.com/moeru-ai/xsai).
*   **[x] FA:** ارائه‌دهندگان LLM پشتیبانی شده: همه چیزی که [xsai](https://github.com/moeru-ai/xsai) پشتیبانی می‌کند.
*   **[x] TR:** Desteklenen LLM sağlayıcıları: [xsai](https://github.com/moeru-ai/xsai)'nin desteklediği her şey.

*   **[ ] AR:** مزودات TTS المدعومة: TBD
*   **[ ] FA:** ارائه‌دهندگان TTS پشتیبانی شده: TBD
*   **[ ] TR:** Desteklenen TTS sağlayıcıları: TBD

*   **[ ] AR:** مزودات Embedding المدعومة: TBD
*   **[ ] FA:** ارائه‌دهندگان Embedding پشتیبانی شده: TBD
*   **[ ] TR:** Desteklenen Embedding sağlayıcıları: TBD

*   **[ ] AR:** نظام فولباك ديناميكي مدمج في AIRI للتبديل السلس بين عدة مزودي ذكاء اصطناعي مجانيين. فلسفة المصدر المفتوح: أفضل تجربة عبر مزودي الذكاء الاصطناعي المجتمعيين المجانيين. مزودو الخدمة بدون مفاتيح جاهزون من البداية. مسار BYOK متاح بسهولة. 🚀
*   **[ ] FA:** سیستم فولبک دینامیک تعبیه شده در AIRI برای سوئیچ کردن روان بین چندین ارائه‌دهنده هوش مصنوعی رایگان. فلسفه متن‌باز: بهترین تجربه از طریق ارائه‌دهندگان هوش مصنوعی اجتماعی رایگان. ارائه‌دهندگان بدون کلید از ابتدا آماده‌اند. مسیر BYOK همیشه در دسترس است. 🚀
*   **[ ] TR:** AIRI'ye gömülü dinamik fallback sistemi, birden fazla ücretsiz AI sağlayıcısı arasında sorunsuz geçiş için. Açık kaynak felsefesi: ücretsiz topluluk AI sağlayıcıları üzerinden en iyi deneyim. Anahtarsız sağlayıcılar kutudan çıktığı gibi hazır. BYOK yolu her zaman mevcut. 🚀
 
##### ⚙️🎩 readme_locale_de_155

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Willkommen beim AnimAIOS Projekt! Wähle deine Sprache:

<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="Português README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="Français README">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="Arabic README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
<sub>
    <h2><b>AnimAIOS</b> ist eine KI-native Distribution auf Basis von <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>. Dein persönlicher KI-Begleiter für Linux Desktop, DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS), CyberDeck (Raspberry Pi)s und Wearable (Concept)s.</h2>
    <h3>Mit voroptimierter Software für deine CPU durch <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> und <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>, für ein virenfreies Arch-Erlebnis.</h3>
</sub>
<img width="1122" height="1402" alt="anima-logo-de-v5 4" src="https://github.com/user-attachments/assets/0bdbfbf5-4269-4e05-8a97-c1be29b4cfed" />
</div>

## 🌙 Die Vision

- **AIRI Companion Engine:** Dein Companion — AIRI. Wird mit ihrem vollständigen Subsystem vorinstalliert. Open-Source-Philosophie: Dir das beste Erlebnis bieten, vollständig durch kostenlose KI-Community-Provider.

- **Dynamisches Fallback-System:** Fallback-System direkt in AIRI integriert für nahtloses Wechseln zwischen mehreren kostenlosen KI-Providern. Keyless-Provider sind sofort einsatzbereit. BYOK-Pfad immer verfügbar — bring deine eigenen Keyed Provider, wenn du mehr Leistung willst.

- **Tiefe Systemintegration:**

  Von einfachen Benachrichtigungen bis zur vollständigen Linux-Steuerung über Terminal im Agentic Mode.

- **Kontextbewusstsein:**

  Deine Begleiterin versteht deine Desktop-Aktivität, reagiert proaktiv und kann bei Bedarf komplette Kontrolle übernehmen.

- **Modulare Welten:**

  GTK4 Widgets, KI-generierte Hintergründe und dynamische Layouts, die sich an deine Charaktere anpassen.

<!--
## 🖥️ Entwicklung

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Voraussetzungen

- pnpm
- Node.js (Electron App)
- Rust (Tauri App)


### 🖱️ Schnellstart

Die aktuell empfohlene Desktop-App ist weiterhin die Electron-Version:

```

apps/stage-tamagotchi/

```

Die Tauri-Version wird aktiv entwickelt:

```

apps/stage-tauri/

````


🍎🐧🪟 Electron Desktop App:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Tauri Desktop App:

> [!IMPORTANT]
> 🚧 Noch im Aufbau

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` prüft dein lokales Tauri Setup, Rust Toolchain, `cargo-tauri` CLI und führt anschließend `cargo check` aus.

Falls nötig:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Warum Tauri?

Tauri ermöglicht es uns, die Vue 3 Oberfläche und AIRI Companion Experience zu behalten und gleichzeitig Electron durch ein schlankeres Rust Backend zu ersetzen.

Das bedeutet:

* Weniger RAM-Verbrauch 🚀
* Kleinere native Builds
* Bessere Linux-Integration
* Sauberer Weg zu mobilen Native Apps

-->

## ✌🏻 Danksagungen
* Das originale Projekt:

[`moeru-ai/airi`](https://github.com/moeru-ai/airi)

* Der fantastische Desktop-Fork:

[`dasilva333/airi`](https://github.com/dasilva333/airi)

* Jeder, der diese Seite besucht :3

* Unsere unglaubliche Community:

<a href="https://discord.gg/TgQ3Cu2F7A">
<img src="https://img.shields.io/badge/Discord-Community%20beitreten-5865F2">
</a>

## 🚙 Roadmap

* [x] **Gehirn 🧠**

  * [x] *Artistry:* Native KI-Bildgenerierung (Replicate, ComfyUI)
  * [ ] *Proaktivität:* Autonome Companion-Interaktionen
  * [ ] *Mehrstufiges Gedächtnis:* built-in AIRI memory system
      ↳ [ ] Per-character memory scoping that works with witnesses (multiple-character sharing the screen)
* [x] **Ohren 👂**

  * [x] Lokale Spracherkennung und Sprecherkennung

* [x] **Mund 🗣️**

  * [x] OpenAI-kompatible Sprachprovider mit Spracherkennung

* [x] **Körper 🤖**

  * [x] VRM Support
  * [ ] LLM-gesteuerte Ausdrücke, auto-blink und auto-look-at
  * [ ] Emotionen und Idle-Loops
  * [x] Live2D Support
      ↳ [ ] LLM-gesteuerte Ausdrücke

* [x] **Desktop Bühne 🖥️**

  * [ ] Mehrere Charaktere auf einem Bildschirm (KISS 1 Fenster pro Charakter)
  * [ ] Szenen- und Hintergrundverwaltung

* [ ] **AnimAIOS ⚡**

  * [x] System Tray & Screen Capture Integration
  * [ ] Native GTK4 Fenster statt Web-Widgets generieren
  * [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) Integration
      ↳ [ ] Send recent context snapshot with each AIRI heartbeat
  * [ ] AIRI Chatbox als natürlicher KI-Terminal

- [ ] Misc
  - [ ] Add mcp/skills via natural language prompts
  - [ ] Native Wayland Support using Ozone platform flags

## 🤖 API Provider

* [x] Unterstützte LLM Provider:
  Alles, was xsai unterstützt

* [ ] TTS Provider: TBD

* [ ] Embedding Provider: TBD

- [ ] Dynamisches Fallback-System direkt in AIRI integriert für nahtloses Wechseln zwischen mehreren kostenlosen KI-Providern. Open-Source-Philosophie: Das beste Erlebnis durch kostenlose KI-Community-Provider. Keyless-Provider sofort einsatzbereit. BYOK-Pfad immer verfügbar.
**Code rein.**
**Companion an.**
**Zukunft gebaut.** 🚀

##### ⚡🐺 readme_locale_pl_151

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ Witaj w projekcie AnimAIOS! Wybierz swój język:

<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="Português README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="Français README">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="Arabic README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
<sub>
    <h2><b>AnimAIOS</b> — dystrybucja nowej generacji oparta na <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a>. Twój osobisty towarzysz AI dla Linux Desktop, DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS), CyberDeck (Raspberry Pi)ów i urządzeń przyszłości.</h2>
    <h3>Oprogramowanie zoptymalizowane pod Twój CPU dzięki repozytoriom <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> i <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a>, zapewniając doświadczenie Arch bez wirusów.</h3>
</sub>
<img width="1206" height="1305" alt="anima-logo-pl-v8 1" src="https://github.com/user-attachments/assets/81f62662-90fc-4818-9080-0f90a8f6d6ae" />
</div>

## 🌙 Wizja

- **Silnik Kompaniona AIRI:** Twój towarzysz — AIRI. Dostarczana z pełnym podsystemem wstępnie skonfigurowanym. Filozofia open source: zapewniamy najlepsze doświadczenie w pełni za pośrednictwem bezpłatnych dostawców AI społecznościowych.

- **Dynamiczny System Fallback:** System fallbacku zintegrowany bezpośrednio w AIRI do płynnego przełączania między wieloma darmowymi dostawcami AI. Dostawcy bez klucza skonfigurowani są od razu. Ścieżka BYOK zawsze dostępna — wprowadź własnych dostawców z kluczem, gdy chcesz więcej mocy.

- **Pełna integracja z systemem:**

  Od zwykłych powiadomień aż po pełną kontrolę Linuxa przez terminal w trybie Agentic Mode.

- **Świadomość kontekstu:**

  Twój towarzysz rozumie aktywność na pulpicie, reaguje proaktywnie i może przejąć kontrolę, gdy tego potrzebujesz.

- **Modularne światy:**

  Widgety GTK4, generowane przez AI tła oraz dynamiczne układy dopasowane do charakteru postaci.

<!--
## 🖥️ Rozwój

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Wymagania

- pnpm
- Node.js (aplikacja Electron)
- Rust (aplikacja Tauri)


### 🖱️ Szybki start

Aktualnie zalecana aplikacja desktopowa:

```

apps/stage-tamagotchi/

```

bazuje na Electron.

Wersja Tauri jest aktywnie rozwijana:

```

apps/stage-tauri/

````


🍎🐧🪟 Aplikacja Electron:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Aplikacja Tauri:

> [!IMPORTANT]
> 🚧 W trakcie budowy

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` sprawdza lokalny setup Tauri, toolchain Rust, CLI `cargo-tauri` oraz wykonuje `cargo check`.

Jeśli potrzeba:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Dlaczego Tauri?

Tauri pozwala zachować doświadczenie Vue 3 oraz AIRI Companion, jednocześnie zastępując ciężki proces Electron lekkim backendem Rust.

Efekt:

* Mniejsze zużycie RAM 🚀
* Lżejsze paczki aplikacji
* Lepsza integracja z Linuxem
* Prostsza droga do aplikacji mobilnych Native

Ta migracja otwiera drogę do przyszłych wersji AIRI dla Androida i iOS.

-->

## ✌🏻 Podziękowania

* Oryginalny projekt:

[`moeru-ai/airi`](https://github.com/moeru-ai/airi)

* Niesamowity fork desktopowy:

[`dasilva333/airi`](https://github.com/dasilva333/airi)

* Każdemu, kto odwiedził tę stronę :3

* Naszej świetnej społeczności:

<a href="https://discord.gg/TgQ3Cu2F7A">
<img src="https://img.shields.io/badge/Discord-Dołącz%20do%20nas-5865F2">
</a>

## 🚙 Roadmap

* [x] **Mózg 🧠**

  * [x] *Artistry:* natywne pipeline'y generowania obrazów AI (Replicate, ComfyUI)
  * [ ] *Proaktywność:* autonomiczne interakcje companionów

  * [ ] *Pamięć wielopoziomowa:* built-in AIRI memory system
      ↳ [ ] Pamięć na poziomie postaci z obsługą witness-ów (wielu postaci na jednym ekranie)

* [x] **Usi 👂**
  * [x] Rozpoznawanie mowy po stronie klienta i wykrywanie rozmowy

* [x] **Usta 🗣️**
  * [x] Dostawcy głosu kompatybilni z OpenAI z odkrywaniem głosów

* [x] **Ciało 🤖**

  * [x] Obsługa VRM
    ↳ [ ] Sterowanie ekspresją przez LLM, auto-blink i auto-look-at
    ↳ [ ] Emocje i animacje idle
  * [x] Obsługa Live2D
      ↳ [ ] Sterowanie ekspresją przez LLM

* [x] **Scena Desktop 🖥️**

  * [ ] Wiele postaci na jednym ekranie (KISS 1 okno na postać)
  * [ ] Zarządzanie scenami i tłami

* [ ] **AnimAIOS ⚡**

  * [x] Integracja System Tray i przechwytywania ekranu
  * [ ] Generuj natywne okna GTK4 zamiast widgetów web
  * [ ] Integracja [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux)
      ↳ [ ] Wysyłanie aktualnego snapshotu kontekstu przy każdym AIRI heartbeat
  * [ ] AIRI Chat jako terminal sterowany naturalnym językiem

* [ ] **Inne**
  * [ ] Dodawanie mcp/skills przez prompty w języku naturalnym
  * [ ] Natywne wsparcie Wayland przy użyciu flag platformy Ozone

## 🤖 Dostawcy API

* [x] Obsługiwani dostawcy LLM:
  wszystko, co wspiera xsai

* [ ] Dostawcy TTS: TBD

* [ ] Dostawcy Embedding: TBD

- [ ] Dynamiczny system fallbacku zintegrowany w AIRI do płynnego przełączania między wieloma darmowymi dostawcami AI. Filozofia open source: najlepsze doświadczenie przez bezpłatnych dostawców AI społecznościowych. Dostawcy bez klucza skonfigurowani od razu. Ścieżka BYOK zawsze dostępna.

**Pisz kod.**
**Kompanion włączony.**
**Przyszłość zbudowana.** 🚀

##### 🌌🐆 readme_locale_kk_143

╭─[7n1m4@n3t]─[~/github] <br>
╰─➜ AnimAIOS жобасына қош келдің! Тіліңді таңда:

<div align="center">
<a href="https://github.com/7n1m4#-readme_locale_en_021">
  <img src="https://img.shields.io/badge/read%20me-English%20-1e3a8a" alt="English README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_ja_030">
  <img src="https://img.shields.io/badge/リードミー-日本語%20-db2777" alt="Japanese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ko_030">
  <img src="https://img.shields.io/badge/리드미-한국어%20-a020f0" alt="한국어 README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_zh_030">
  <img src="https://img.shields.io/badge/读我-中文%20-dc2626" alt="Chinese README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_es_pt_039_419">
  <img src="https://img.shields.io/badge/leia%20me-Español%20%2F%20Português%20-16a34a" alt="Português README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_fr_002_155">
  <img src="https://img.shields.io/badge/lisez%20moi-Français%20-B59410" alt="Français README">
</a>
<a href="https://github.com/7n1m4#%E2%80%8D%EF%B8%8F-readme_locale_ru_810">
  <img src="https://img.shields.io/badge/прочитай%20меня-Русский%20-71706E" alt="Русский README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_ar_fa_tr_015_145">
  <img src="https://img.shields.io/badge/%D8%A7%D9%82%D8%B1%D8%A3%D9%86%D9%8A%20%2F%20%D8%A8%D8%AE%D9%88%D9%86%D8%B4%20%2F%20Oku%20Beni-%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9%20%2F%20%D9%81%D8%A7%D8%B1%D8%B3%DB%8C%20%2F%20T%C3%BCrk%C3%A7e-8b5cf6" alt="Arabic README">
</a>
<a href="https://github.com/7n1m4#%EF%B8%8F-readme_locale_de_155">
  <img src="https://img.shields.io/badge/lesen%20-%20Deutsch%20-2b2b2b" alt="Deutsches README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_pl_151">
  <img src="https://img.shields.io/badge/czytaj%20mnie-Polski%20-DC143C" alt="Polski README">
</a>
<a href="https://github.com/7n1m4#-readme_locale_kk_143">
  <img src="https://img.shields.io/badge/оқы-Қазақша%20-00A86B" alt="Қазақша README">
</a>
<sub>
    <h2><b>AnimAIOS</b> — <a href="https://endeavouros.com/" target="_blank">EndeavourOS</a> негізіндегі жаңа буын AI операциялық ортасы. Linux Desktop / DroidDesk (Termux:X11) · DroidDeck (Linux/Proton) · Steam Deck (SteamOS) / CyberDeck (Raspberry Pi) / Wearable (Concept) құрылғыларында өзіңнің AI серігіңді іске қос.</h2>
    <h3>CPU-ға арнайы оңтайландырылған бағдарламалар <a href="https://packages.cachyos.org/" target="_blank">CachyOS</a> және <a href="https://aur.chaotic.cx/" target="_blank">Chaotic-AUR</a> арқылы келеді, вируссыз Arch тәжірибесін қамтамасыз етеді.</h3>
</sub>
<img width="1200" height="1311" alt="anima-logo-143-v5 2" src="https://github.com/user-attachments/assets/4e60c020-dbdb-4bac-b493-a8fee2a3a076" />
</div>

## 🌙 Идея

- **AIRI серік қозғалтқышы:** Серігіңіз — AIRI. Толық ішкі жүйемен алдын ала орнатылған. Ашық код философиясы: тегін қоғамдастық AI провайдерлері арқылы ең жақсы тәжірибе ұсыну.

- **Динамикалық фоллбэк жүйесі:** AIRI-ге тікелей ендірілген динамикалық фоллбэк жүйесі, бірнеше тегін AI провайдерлері арасында тегсіз ауысу үшін. Кілтсіз провайдерлер дайын күйде. BYOK жолы әрқашан қолжетімді — күші көбірек қажет болғанда өз кілтті провайдерлеріізді әкеліңіз.

- **Жүйемен толық байланыс:**

  Қарапайым хабарламалардан бастап Linux жүйесін терминал арқылы толық басқаруға дейін Agentic Mode мүмкіндігі.

- **Контексті түсіну:**

  AI серігі жұмыс барысыңды байқайды, жағдайды түсінеді және қажет кезде әрекетті өзі бастайды.

- **Модульдік әлем:**

  GTK4 виджеттері, AI арқылы жасалған фондар және кейіптерге бейімделетін динамикалық интерфейстер.

<!--
## 🖥️ Даму

<a href="https://github.com/7n1m4/actions/workflows/ci.yml">
  <img src="https://github.com/7n1m4/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://animaios.github.io/anima">
  <img src="https://img.shields.io/badge/docs-animaios.github.io/anima-blue" alt="Docs">
</a>

### ☕ Қажетті құралдар

- pnpm
- Node.js (Electron қолданбасы)
- Rust (Tauri қолданбасы)


### 🖱️ Жылдам бастау

Қазіргі ұсынылатын desktop нұсқасы:

```

apps/stage-tamagotchi/

```

ішіндегі Electron версиясы.

Tauri нұсқасы белсенді түрде жасалуда:

```

apps/stage-tauri/

````


🍎🐧🪟 Electron Desktop:

```shell
pnpm i
pnpm dev:tamagotchi
````

🍎🐧 Tauri Desktop:

> [!IMPORTANT]
> 🚧 Құрылу үстінде

```shell
pnpm i
cd apps/stage-tauri
./init.sh
cargo tauri dev
```

`./init.sh` жергілікті Tauri ортасын, Rust toolchain және `cargo-tauri` CLI тексереді.

Қажет болса:

```shell
cargo install tauri-cli --version '^2.0'
```

### ❔ Неге Tauri?

Tauri бізге Vue 3 интерфейсін және AIRI тәжірибесін сақтап, Electron орнына жеңіл Rust backend қолдануға мүмкіндік береді.

Нәтижесі:

* Аз RAM қолдану 🚀
* Кішірек native жинақтар
* Linux-пен жақсы интеграция
* Mobile native нұсқаларға таза жол

Бұл бағыт AIRI-дің Android және iOS нұсқаларына апарады.

-->

## ✌🏻 Алғыс

* Бастапқы жоба:

[`moeru-ai/airi`](https://github.com/moeru-ai/airi)

* Керемет desktop fork:

[`dasilva333/airi`](https://github.com/dasilva333/airi)

* Осы параққа келген әр адамға :3

* Біздің мықты қауымдастық:

<a href="https://discord.gg/TgQ3Cu2F7A">
<img src="https://img.shields.io/badge/Discord-Қауымдастыққа%20қосыл-5865F2">
</a>

## 🚙 Жол картасы

* [x] **Ми 🧠**

  * [x] *Artistry:* AI сурет генерациясы (Replicate, ComfyUI)
  * [ ] *Проактивтілік:* автономды AI әрекеттері
  * [ ] *Көп деңгейлі жады:* built-in AIRI memory system
      ↳ [ ] Атаулы жады персонаж деңгейінде witness-пен жұмыс істейді (бір экранда бірнеше кейіпкер)
* [x] **Құлақ 👂**

  * [x] Құрылғы ішіндегі дауыс тану

* [x] **Ауыз 🗣️**

  * [x] OpenAI үйлесімді дауыс жүйелері дыңдау анықтауымен

* [x] **Дене 🤖**

  * [x] VRM қолдауы
  * [ ] LLM арқылы көз қыпару және қарау басқару
  * [ ] LLM арқылы эмоциялар және idle-анимациялар
  * [x] Live2D қолдауы
      ↳ [ ] LLM арқылы көз қыпару басқару

* [x] **Desktop сахна 🖥️**

  * [ ] Бір экрандағы бірнеше кейіпкер (KISS 1 терезе = 1 кейіпкер)
  * [ ] Сахна және фон басқару

* [ ] **AnimAIOS ⚡**

  * [x] System Tray және Screen Capture
  * [ ] Web-Widget-дердің орнына нативті GTK4 терезелерін генерациялау
  * [ ] [agent-sh/computer-use-linux](https://github.com/agent-sh/computer-use-linux) интеграциясы
      ↳ [ ] Әрбір AIRI heartbeat-те жаңа контекст snapshot жіберу
  * [ ] AIRI Chat-ті AI терминалға айналдыру

* [ ] **Арнайы**

  * [ ] MCP/skills қосу натурал тіл арқылы
  * [ ] Ozone платформа флагтарымен нативті Wayland қолдау

## 🤖 API провайдерлері

* [x] Қолдайтын LLM провайдерлері:
  xsai қолдайтын барлық жүйелер

* [ ] TTS провайдерлері: кейін

* [ ] Embedding провайдерлері: кейін

- [ ] AIRI-ге тікелей ендірілген динамикалық фоллбэк жүйесі, бірнеше тегін AI провайдерлері арасында тегсіз ауысу үшін. Ашық код философиясы: тегін қоғамдастық AI провайдерлері арқылы ең жақсы тәжірибе. Кілтсіз провайдерлер дайын күйде. BYOK жолы әрқашан қолжетімді.

**Код жаз.**
**Серік қосулы.**
**Болашақ құрылды.** 🚀

---

<a href="https://ipfs.orbitor.dev/ipfs/bafybeic2pxdpgdfc43bkvpbt3jtjushebfszp4yvjn3lwqb264hvogr5me">
  <img src="https://api.visitorbadge.io/api/visitors?path=https%3A%2F%2Fgithub.com%2Fvi70x3%2Fairi&label=%F0%9F%92%93%20my%20little%20clicks%20counter&countColor=%23263759&style=flat" alt=":3" />
</a>

##### readme_codebase
