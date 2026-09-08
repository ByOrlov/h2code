# Contributing to H2Code

Thanks for your interest in improving H2Code. Before your first merge, please read the two sections below — the **CLA** is mandatory for every outside contribution.

## 1. Contributor License Agreement (CLA)

H2Code is distributed under the **GPL-2.0-or-later**, but the copyright is held solely by **Oleg Orlov <orelcokolov@gmail.com>** so that the project can be re-licensed (dual-licensed to a commercial product, for example) without having to track down every past contributor. To make that possible, every external contribution must be accompanied by a CLA acceptance.

### What you grant

By submitting a pull request, you agree that:

1. You confirm that you wrote the contribution yourself, or that you have the right to submit it on behalf of its copyright holder.
2. You grant **Oleg Orlov** a perpetual, worldwide, non-exclusive, royalty-free, irrevocable copyright license to reproduce, prepare derivative works of, publicly display, publicly perform, sublicense, distribute, and **relicense** your contribution as part of the H2Code project, including under licenses other than the GPL-2.0-or-later (e.g. a proprietary or commercial license).
3. You retain ownership of your copyright in the contribution; only the rights described above are granted.
4. The contribution is licensed to the public under the GPL-2.0-or-later regardless of any future relicensing of the project.
5. You are not obligated to provide support for your contribution, and you provide it "AS IS" without warranties of any kind.

### How to accept

For contributions you make in the **normal course of development** (bug fixes, features, docs) on a personal basis, you accept the CLA by adding the following line to the description of your **first** pull request:

```
I accept the H2Code Individual CLA (CONTRIBUTING.md, section 1).
```

That one-time acceptance covers all subsequent contributions to the project unless you explicitly withdraw it.

### Corporate / employer contributions

If you are contributing on behalf of your employer, the employer must send a signed **Entity CLA** to <orelcokolov@gmail.com> before the pull request can be merged. The Entity CLA is the same grant as above, but signed by someone with legal authority to bind the company.

### Why a CLA at all?

Without a CLA, every contributor keeps a fragment of copyright, and any future relicensing — even to a more permissive license, even to fix a license incompatibility — would require contacting every contributor who has ever touched the codebase. The CLA keeps the project's licensing flexible for the long term while guaranteeing that the public always has the contribution under GPL-2.0-or-later.

If you are uncomfortable with the CLA, you are still free to fork H2Code under the GPL-2.0-or-later — that right is permanent and does not require any agreement with the maintainer.

## 2. Development setup

### Prerequisites

- **Crystal ≥ 1.14.0** — see <https://crystal-lang.org/install/> for installation.
- A POSIX system (Linux, macOS, BSD). H2Code is not tested on Windows.

### Get started

```bash
git clone https://github.com/<fork>/h2code.git
cd h2code
shards install          # install dependencies
rake build              # build the h2code binary
rake spec               # run the test suite
rake coverage           # run the suite under kcov and report total src/ coverage
rake mock:default       # self-test with the mock provider (no API key needed)
```

The `mock:*` tasks run the TUI against a scripted provider, so you can exercise the agent loop, tools, and rendering without an API key or network access.

### Running against a real provider

H2Code speaks the OpenAI-compatible Chat Completions protocol, so any compatible endpoint works. The minimum configuration:

```bash
export MOONSHOT_API_KEY=YOUR_API_KEY
export MOONSHOT_ENDPOINT=https://api.example.com/v1   # any OpenAI-compatible endpoint
export MOONSHOT_MODEL=your-model-name
./h2code --yolo
```

For local models, point `MOONSHOT_ENDPOINT` at your llama.cpp / Ollama / vLLM server.

### Project layout

| Path | Purpose |
| --- | --- |
| `src/llm/` | Provider abstraction, OpenAI-compatible HTTP client, mock provider, streaming. |
| `src/tools/` | Agent tools (bash, read, write, edit, glob, grep, todo, agent_swarm). |
| `src/tui/` | Terminal UI: rendering, themes, dialogs, streaming. |
| `src/context/` | Context window construction and token budgeting. |
| `src/loop/` | The agent loop: prompt → model → tool calls → repeat. |
| `src/permission/` | Permission policy and prompt layer. |
| `src/session/` | Session persistence and resume. |
| `src/auth/` | API-key and credential handling. |
| `src/config/` | Configuration loading (TOML + env). |
| `spec/` | Test suite. |

## 3. Pull request checklist

- [ ] Branch is up to date with `main`.
- [ ] `rake spec` passes locally.
- [ ] `rake build` produces a clean binary.
- [ ] Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- [ ] If the change is user-facing, update `README.md` accordingly.
- [ ] First-time contributors: paste the CLA acceptance line into the PR description.
