@echo off
:: AIRI Tamagotchi - Production Preview Starter
:: Builds packages, builds the app, and starts the packaged production bundle (hutch/electrobun).

echo [1/3] Building packages...
call pnpm run build:packages

echo [2/3] Building Tamagotchi production assets...
call pnpm -F @proj-anima/stage-tamagotchi run build

echo [3/3] Starting Tamagotchi in Preview Mode...
set ELECTRON_RUN_AS_NODE=
call pnpm -F @proj-anima/stage-tamagotchi start
