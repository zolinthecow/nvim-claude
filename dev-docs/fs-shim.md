# FS Shim (blocking pre-flight) for Agent-Agnostic File Edits

This is a macOS (`dyld` interpose) dynamic library that **blocks right before** a file
change lands (write/truncate/rename/unlink), lets a sidecar **ack** after taking a
baseline (e.g., `git add && git commit`), then allows the operation to proceed.
After the operation succeeds, the shim emits a **post** event so UIs can refresh diffs.

- **Goal:** be agent-agnostic (Codex, Claude Code, shell tools) and editor-agnostic.
- **Does NOT ship file content.** Only paths + op type.
- **Process tree coverage:** inject the agent; children inherit `DYLD_INSERT_LIBRARIES`.

## What is intercepted

Pre (blocking) and Post (non-blocking) signals:

| Operation                    | Pre (blocking)          | Post (non-blocking)       |
|-----------------------------|--------------------------|---------------------------|
| First `write/pwrite/writev` | `pre_modify(path)`       | `post_modify(path)` on `close` if dirty |
| `ftruncate` / `truncate`    | `pre_truncate(path)`     | `post_modify(path)`       |
| `rename` (incl. `$UNIX2003`)| `pre_rename(new_path)`   | `post_modify(new_path)`   |
| `unlink` (incl. `$NOCANCEL`)| `pre_delete(path)`       | `post_delete(path)`       |

> Atomic save (temp → rename over final) is handled by **pre‑gating `rename(new_path)`**,
> so the baseline captures the **destination**’s previous state before the swap.

### Not (yet) hooked
- `open/openat` with `O_TRUNC` (add a tiny C shim if you want to pre‑gate on open).
- `renameat/renameatx_np/unlinkat` (easy to add if needed).
- `mmap` write flows (rare for agent workflows; could add `msync/munmap` if necessary).

## Transport

- JSON‑RPC 2.0 over a local stream (Unix domain socket or TCP).
- **Pre** calls are requests: shim sends with `id=1` (per‑thread stream), sidecar replies:
  ```json
  {"jsonrpc":"2.0","id":1,"result":{"allow":true}}
  ```

## Building the shim

- Run `./shim/build.sh` from the repo root.
  - Produces `target/universal/release/libnvimclaude_shim.dylib` (arm64 + arm64e slices).
  - Requires stable Rust for `aarch64-apple-darwin` and nightly (with `-Z build-std`) for `arm64e-apple-darwin`.
  - The script codesigns the output with an ad-hoc identity so `DYLD_INSERT_LIBRARIES` can load it.

## Manual testing with the Python sidecar

1. Build the shim (see above).
2. Start the JSON-RPC sidecar in one terminal:
   ```bash
   NVIM_CLAUDE_SHIM_SOCK=/tmp/fs_shim.sock \
     python shim/fs_shim_sidecar.py \
     --log /tmp/fs-shim-log.jsonl
   ```
   - `--deny-method pre_delete` (repeatable) can be used to simulate a rejected operation.
3. In another terminal, launch any tool with the shim injected:
   ```bash
   export DYLD_INSERT_LIBRARIES="$PWD/shim/target/universal/release/libnvimclaude_shim.dylib"
   export NVIM_CLAUDE_SHIM_SOCK=/tmp/fs_shim.sock
   export NVIM_CLAUDE_SHIM_DEBUG=1      # optional: emit shim/* debug notifications
   export FS_SHIM_FAIL_CLOSED=1         # optional: block filesystem ops if the sidecar rejects

   python - <<'PY'
   from pathlib import Path
   path = Path('/tmp/fs-shim-demo.txt')
   path.write_text('hello from shim!\\n', encoding='utf-8')
   with path.open('a', encoding='utf-8') as fh:
       fh.write('mutated\\n')
   path.unlink()
   PY
   ```
4. Watch the sidecar stdout or `/tmp/fs-shim-log.jsonl` for `pre_modify`, `post_modify`, `pre_delete`, etc. to confirm events arrive in order.

Because the shim hooks `rename`, `unlink`, `write*`, and `truncate`, you can repeat step 3 with editors, `cat > file`, `rm`, or any other tool while the sidecar logs each operation. Set `FS_SHIM_FAIL_CLOSED=1` plus `--deny-method …` to verify that blocked `pre_*` calls stop the underlying filesystem change.
