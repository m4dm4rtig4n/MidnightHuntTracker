# MidnightHuntTracker

Track your **Prey Hunt** progression in the Midnight expansion with a clear, always-visible UI.

## The Problem

The default hunt tracker is a tiny crystal icon that's hard to read at a glance. You can't tell how far along you are — just that the crystal is "kind of filling up."

## The Solution

MidnightHuntTracker gives you a **big percentage display** with a color-coded progress bar that tracks your hunt across all 4 phases:

🔵 **Cold** (0-40%) → 🟡 **Warm** (40-55%) → 🟠 **Hot** (55-95%) → 🔴 **Imminent** (100% — prey spawned!)

## Features

- **Estimated % display** — large, readable at a glance
- **Weighted activity tracking** — expeditions count more than rares, just like in-game
- **Auto-calibration** — gets more accurate with every completed hunt
- **Sound alerts** — audio + raid warning notification on phase changes
- **Movable & scalable** UI frame
- **Slash commands** — `/mht` or `/traque` for diagnostics, calibration data, and more

## How It Works

The WoW API only exposes 4 discrete phases (Cold/Warm/Hot/Imminent) — not a real percentage. This addon estimates sub-phase progress by tracking aura stack changes from your activities, weighting them by impact. The more hunts you complete, the better the estimate gets.

## Commands

- `/mht` — Help
- `/mht show` / `hide` — Toggle display
- `/mht lock` — Lock/unlock frame position
- `/mht scale 0.5-3` — Resize
- `/mht sound` — Toggle sound alerts
- `/mht cal` — View calibration data
- `/mht test` — Run a simulation

## Requirements

- WoW Midnight (12.0+)
- Level 90 with access to the Prey Hunt system
