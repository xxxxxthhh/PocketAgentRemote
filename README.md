# PocketAgentRemote

Turn the IINE L1162 mini controller into a pocket remote for Codex and Claude Code on macOS.

Full design: `iine-l1162-codex-claude-macos-implementation-spec-v0.1.md`.

**Current state: Phase 0 complete (2026-09-15).** The probe has characterised all three platform modes
(T / C / H) and answered the spec's ten hardware questions from measurement. No gesture engine, no
adapters, no menu-bar app yet.

## Layout

```text
docs/phase0-summary.md    start here — conclusions, implementation constraints, spec corrections
docs/hardware-probe.md    raw findings, per-question evidence, evidence-log index
scripts/make-app.sh       wraps the probe in an ad-hoc signed .app bundle
Sources/AgentProbe/       the probe itself (GameController first, IOHIDManager fallback)
```

## Build and run

```bash
swift build
./.build/debug/agentprobe list            # identity snapshot (read-only, safe while typing)
./.build/debug/agentprobe watch --log logs/probe.jsonl

./scripts/make-app.sh release             # bundled app for Bluetooth discovery / TCC grants
```

See `docs/hardware-probe.md` for the capture procedure, log tags and permissions.

## Constraints carried over from the spec

- Native macOS Swift, GameController first, IOHIDManager fallback, CGEvent for output.
- Semantic action layer between physical inputs and tool adapters — no direct key hardcoding.
- Explicit Generic / Codex / Claude profiles; macros disabled by default.
- No kernel extension, no network, no arbitrary shell execution, no one-tap permission bypass.
