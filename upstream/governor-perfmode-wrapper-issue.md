# DRAFT issue for filippor/cyan-skillfish-governor (smu branch)

> **Status: DRAFT, not filed.** Found while re-testing the hub on hardware (Oct 2026).

---

**Title:** `cyan-skillfish-performance-mode` wrapper mode never disables performance mode (`exec` skips the EXIT trap)

**Body:**

### Summary
The README describes wrapper mode as "enable, run command, disable on exit"
(`cyan-skillfish-performance-mode --fixed-frequency 1200 mangohud %command%`), but the clock
stays pinned after the wrapped command exits. Every wrapper path does:

```bash
trap cleanup EXIT INT TERM
exec "$@"
```

`exec` replaces the shell process with the command, so the shell never reaches its own exit
and the `EXIT` trap (`cleanup` → `Enabled false`) never runs. This affects all 5 wrapper sites
(`--on`, `--fixed-frequency`, `--range`, … with a command, and the bare `*)` wrapper case).

### Environment
- Bazzite 44.20260929, kernel 7.2.7-ogc1.1.fc44, BC-250
- `cyan-skillfish-governor-smu-v0.4.14-1.20260619120402457887.update.deps.3.g14080b4.fc44` (COPR)
- Script identical to `smu` HEAD except the shebang line

### Reproduction
```bash
cat > /tmp/inner.sh <<'EOF'
#!/bin/bash
sleep 2; cyan-skillfish-performance-mode --status | head -1; exit ${1:-0}
EOF
chmod +x /tmp/inner.sh
cyan-skillfish-performance-mode --fixed-frequency 1700 -- /tmp/inner.sh 0
cyan-skillfish-performance-mode --status      # expected: b false
```

### Observed
```text
== wrapper, command exits 0
Performance mode enabled with fixed frequency 1700 MHz
  inside: status=b true sclk=1700MHz
  wrapper exit=0  after: b true
== wrapper, command exits 1
  wrapper exit=1  after: b true
== wrapper without --
  after: b true
```
Performance mode stays enabled in all three cases. On this board a pinned clock keeps the GPU
at its pinned frequency even at idle (e.g. 1500 MHz idle: 65 °C / 62 W package vs ~55 °C /
43 W adaptive), so a Steam launch option silently leaves the GPU hot after the game exits.

### Suggested fix
Run the command as a child instead of `exec`-ing it, and propagate its exit status:

```diff
                 trap cleanup EXIT INT TERM
-                exec "$@"
+                "$@"
+                exit $?
```
(applied at all 5 sites). With that change, the same reproduction prints `after: b false`,
and the wrapped command's exit status is preserved (verified on the board with a patched copy
of the script — see "Verification" below).

Optional refinement: `trap cleanup EXIT` plus `trap 'exit 130' INT` / `trap 'exit 143' TERM`
so Ctrl+C runs cleanup once and exits with the conventional status.

### Verification
Patched copy (`sed` replacing each `exec "$@"` with `"$@"` + `exit $?`) vs the installed
script, same board, same inner command:

```text
== patched, command exits 0
  inside: b true
  wrapper exit=0  after: b false
== patched, command exits 3
  inside: b true
  wrapper exit=3  after: b false      <- exit status preserved
== patched, bare form
  inside: b true
  after: b false
== unpatched, exits 0
  inside: b true
  after: b true                       <- still pinned
```
SIGINT to the patched wrapper while the command runs also leaves `b false` afterwards
(exit status 0 in that case, hence the optional trap refinement above).

Happy to send this as a PR if you prefer.
