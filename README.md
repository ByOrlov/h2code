# H2Code — Vibe-code even on a potato

**English** · [Русский](./README.ru.md) · [Español](./README.es.md) · [中文](./README.zh.md) · [日本語](./README.ja.md) · [Português](./README.pt.md) · [हिन्दी](./README.hi.md) · [فارسی](./README.fa.md) · [Українська](./README.uk.md) · [Беларуская](./README.be.md)

[![CI](https://github.com/ByOrlov/H2Code/actions/workflows/ci.yml/badge.svg?style=flat-square)](https://github.com/ByOrlov/H2Code/actions/workflows/ci.yml)
[![Release](https://github.com/ByOrlov/H2Code/actions/workflows/release.yml/badge.svg?style=flat-square)](https://github.com/ByOrlov/H2Code/actions/workflows/release.yml)
[![Tag](https://img.shields.io/github/v/release/ByOrlov/H2Code?display_name=tag&sort=semver&style=flat-square)](https://github.com/ByOrlov/H2Code/releases/latest)
[![License](https://img.shields.io/github/license/ByOrlov/H2Code?style=flat-square)](./LICENSE)
[![Crystal](https://img.shields.io/badge/crystal-1.21-000000?logo=crystal&style=flat-square)](https://crystal-lang.org)
[![RAM](https://img.shields.io/badge/RAM-%7E3%20MB%20per%20agent-brightgreen?style=flat-square)](#memory-sorted)
[![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey?style=flat-square)](#h2code--vibe-code-even-on-a-potato)
[![Repo size](https://img.shields.io/github/repo-size/ByOrlov/H2Code?style=flat-square&label=repo)](https://github.com/ByOrlov/H2Code)
[![Static binary](https://img.shields.io/badge/binary-static-blue?style=flat-square)](#h2code--vibe-code-even-on-a-potato)

> **~3 MB of RAM per agent at idle. One static binary. Zero runtime. GPL forever.**
> A lighter-than-air AI agent by Orlov — Hydrogen-light: **H** for the lightest element, **Code** for what you ship.

Linux & MacOS

```sh
curl -fsSL https://raw.githubusercontent.com/ByOrlov/H2Code/master/install.sh | bash
```

Windows

```powershell
irm https://raw.githubusercontent.com/ByOrlov/H2Code/master/install.ps1 | iex 
```

**Crystal 1.14 · GPL-2.0-or-later · Native Binary · No Runtime**

---

### Memory, sorted

From featherweight to heavyweight.

| # | Agent       | Lang       | Idle RAM         | License             | Source |
|---|-------------|------------|------------------|---------------------|--------|
| 1 | **H2Code**   | **Crystal**| **~3 MB**        | **GPL-2.0-or-later**| [1]    |
| 2 | grok-build  | Rust       | ~20 MB           | Apache-2.0          | [3]    |
| 3 | Codex CLI   | Rust       | ~30 MB           | Apache-2.0          | [2]    |
| 4 | Goose       | Rust + TS  | ~50–100 MB (est) | Apache-2.0          | [4]    |
| 5 | Claude Code | TS / Node  | ~120 MB (grows)  | proprietary         | [7]    |
| 6 | Aider       | Python     | ~150–250 MB(est) | Apache-2.0          | [6]    |
| 7 | kimi-code   | TS / Node  | ~250 MB+         | MIT                 | [5]    |
| 8 | opencode    | TS / Bun   | ~400 MB          | MIT                 | [8]    |

**The gap.** H2Code sits ~7× under the nearest Rust agent (grok-build), ~40× under the lightest Node agent (Claude Code), ~80× under kimi-code, and **~130× under opencode.** The Node family spans an enormous range — from ~120 MB up to ~400 MB — because each one ships a V8 runtime per process and grows with use. The Rust agents (Codex, grok-build, Goose) are native and lean; H2Code keeps pace with them on RAM and beats them on readability and license (see [Why Crystal?](#why-crystal)).

> Aider (est. ~150–250 MB) and kimi-code (~250 MB+) sit on the border of the same weight class — their relative order is within the margin.


---

## Origin Story

I opened the system monitor and was horrified. Two opencode instances were eating **1 GB of RAM**. Five kimi-code chats were doing the same — because each dragged a full Node.js runtime along for the ride.

I remembered 2007. My mother bought me **512 MB of RAM** so I could play *S.T.A.L.K.E.R.: Shadow of Chernobyl* — a full 3D game that ran on a machine with 1 GB of RAM. And now, in 2026, we can't run two chats on 1 GB. What? **The world has gone mad.**

Worse — these "chats" are hard to call **real software**. They're software prototypes with features bolted on. Real software cannot be this horrifying on performance. And the scariest part: they are **eternal prototypes**. Eternal temporary solutions, shipped as finished products.

Then other developers reach for Rust to build agents. Rust is a language where you fight the compiler instead of building things — the opposite extreme. And the punchline: the Rust competitors sit at **~10× H2Code's memory while idle**.

So I took Moonshot-AI's TypeScript agent as a baseline and rewrote its logic in Crystal, with help from Kimi 2.6 and GLM 5. First results: **~3 MB idle** versus kimi-code's ~200 MB. The core loop already worked. Peak consumption did climb afterward — up to ~130 MB — which is horrifying for a chat-notepad, but still less than kimi-code at idle.

**That gap is what H2Code exists to close.**

---

## Why it exists

Spin up five coding agents in parallel. Watch your RAM. Every agent that ships a Node.js runtime pays for it — per process, forever. Each H2Code process sits around **3 MB resident** while it waits for the next prompt — not 120, not 250, not 400 MB. Your editor keeps its memory budget. Your laptop stays cool. The OS stops swapping. You can finally run a swarm of agents on the machine you already own.

> The Rust agents — Codex, grok-build, Goose — are native and lean too. Against them H2Code's edge isn't RAM, it's **readability and license**. See [The Landscape](#the-landscape) below.

---

## Why Crystal?

We looked hard at Rust, Go, and TypeScript. Each forced a trade-off we did not want to live with. Crystal is the first language that let us keep all three wins at once.

- 🦀 **As safe as Rust, with syntax a human can read.** Static typing, nil-safety, union types, generics, and a macro system — but the code reads like Ruby and runs like C. No borrow checker turning every refactor into a research problem. The two most-hyped native agents — OpenAI's **Codex** and xAI's **grok-build** — are both written in Rust, and their source proves the cost: fast and safe, but adding a tool means fighting lifetimes for a week. Crystal's tool layer is one file you read in an afternoon.
- 🐹 **As light as Go, without the boilerplate.** CSP-style fibers and channels, sub-second compiles, single static binaries — but no `if err != nil` on every other line. You write the feature, not the ceremony.
- 🟦 **As capable as TypeScript, without a Node.js runtime per process.** Crystal compiles ahead-of-time to a native LLVM binary. There is no V8 heap, no JIT warmup, no event loop duplicated inside every agent. Less memory copying, fewer system freezes, millisecond cold starts.

**One language. Three wins. Zero runtime.**

---

## Build from source

If you prefer to build H2Code yourself, you need Crystal ≥ 1.14 and ripgrep (`rg`):

```sh
# Install Crystal ≥ 1.14 — https://crystal-lang.org/install/
brew install crystal          # macOS
# sudo pacman -S crystal      # Arch
# see docs for Debian/Ubuntu/Windows

# Install ripgrep (required by the Grep and Glob tools)
brew install ripgrep          # macOS
# sudo apt-get install ripgrep  # Debian/Ubuntu
# sudo pacman -S ripgrep        # Arch

# Build
git clone https://github.com/ByOrlov/H2Code
cd H2Code
shards install
rake build            # → ./h2code (release flags)

# Or build + install in one go — same as the installers (deps, install dir, PATH)
rake install

# Smoke-test your credentials
./h2code --hi

# Headless — one-shot prompt, streams to stdout
./h2code -p "explain this repo's entry point"

# Interactive TUI
./h2code
```

---

### Freedom

Memory is half the story. The other half: who owns the code, where you're allowed to run it, and where your prompts actually go.

| Agent       | License             | Country-blocked | Forced router   | BYO endpoint |
|-------------|---------------------|-----------------|-----------------|--------------|
| Claude Code | proprietary         | yes             | yes (Anthropic) | no           |
| Codex CLI   | Apache-2.0          | yes             | yes (OpenAI)    | no           |
| grok-build  | Apache-2.0          | partial         | xAI default     | partial      |
| Goose       | Apache-2.0          | no              | no              | yes          |
| Aider       | Apache-2.0          | no              | no              | yes          |
| opencode    | MIT                 | no              | no              | yes          |
| kimi-code   | MIT                 | no              | Moonshot        | yes          |
| **H2Code**   | **GPL-2.0-or-later**| **no**          | **no**          | **yes**      |


## License

H2Code is released under the **GPL-2.0-or-later**.

Copyright © 2026 **Oleg Orlov** <orelcokolov@gmail.com> · byorlov.com.
All rights reserved. See [LICENSE](./LICENSE) for the full text.

> **Why GPL-2.0, not MIT?** opencode and kimi-code are both MIT — anyone can absorb them into a closed-source product and never give back. H2Code is copyleft: every derivative must ship its source under the same terms. The community always has a free, usable version that cannot be re-closed.
>
> **Dual licensing.** The copyright is held solely by the author so the project can additionally offer a separate commercial license to parties that need to avoid GPL copyleft (e.g. embedding H2Code inside a closed-source product). To keep that option viable, outside contributions require a CLA that grants the author a license to relicense. See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Contributing

PRs welcome — please sign the CLA so the project can keep both the GPL and the commercial license viable. See [CONTRIBUTING.md](./CONTRIBUTING.md).
