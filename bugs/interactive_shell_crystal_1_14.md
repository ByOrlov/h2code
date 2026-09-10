# InteractiveShell broken under Crystal 1.14 (project targets 1.21)

## Summary

Commit 42e8a11 (`feat(tools): add InteractiveShell tool`) fails to build and,
once the compile error is patched around, its sessions die instantly when
compiled with Crystal 1.14. The project pins **Crystal 1.21.0**
(`shard.yml` line 7, `.github/workflows/ci.yml`), where the tool builds and
passes all specs. **Crystal 1.14 does not support the APIs and semantics this
tool relies on.**

## Symptoms (Crystal 1.14 only)

1. **Compile error** — `Process::Status#exit_signal?` does not exist:

   ```
   In src/tools/interactive_shell.cr:96:61
    96 | "[process terminated by signal #{status.exit_signal?}]"
   Error: undefined method 'exit_signal?' for Process::Status
   Did you mean: 'exit_signal'?
   ```

   `exit_signal?` was added to the stdlib after 1.14; 1.14 only has
   `exit_signal`.

2. **Runtime: session exits immediately with code 0** — after replacing
   `exit_signal?` with `exit_signal` to get past (1), `spec/tools/interactive_shell_spec.cr`
   still fails: `start` of `cat` reports
   `banner: "[process exited with code 0]"` and the following `write` fails
   with `stdin … is no longer writable`. Interactive programs (REPLs, `cat`,
   debuggers) see EOF on stdin the moment the session starts.

## Root cause

Crystal 1.14's `Process#wait` (`/usr/lib/crystal/lib/process.cr:372`) closes
the stdin pipe **before** waiting:

```crystal
def wait : Process::Status
  close_io @input # only closed when a pipe was created but not managed by copy_io
  ...
end
```

`ShellSession#watch_exit` spawns a fiber that calls `@process.wait`
immediately after the process is created, so the parent's write end of the
stdin pipe is closed at once → the child reads EOF and exits. This makes
`Process#wait` incompatible with a persistent-writable-stdin session on 1.14.

In Crystal 1.21 the `close_io @input` line is gone from `wait` (pipes are
closed only in the `ensure` after the child actually exits) and
`Process::Status#exit_signal?` exists — both problems disappear.

Minimal repro of the `wait` behavior (any Crystal version):

```crystal
b = Process.new("/bin/bash", ["-c", "cat"],
  input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
  error: Process::Redirect::Pipe)
spawn { b.wait }                          # on 1.14 this closes stdin instantly
sleep 300.milliseconds
b.input.write("x\n".to_slice)             # IO::Error: Closed stream on 1.14
```

## Resolution

**Crystal 1.14 is not supported for building h2code.** Use the pinned
toolchain 1.21.0:

```bash
/home/oleg/crystal/crystal-1.21.0-1/bin/crystal spec spec/tools/interactive_shell_spec.cr
# → 5 examples, 0 failures
```

The default `/usr/bin/crystal` on this machine is 1.14 and predates the
project's minimum — that is what surfaced the failure (the pre-commit hook
runs `rake spec` with whatever `crystal` is first in `PATH`). No source change
is required; `src/tools/interactive_shell.cr` is correct for 1.21 as written.

## Status

Verified 2026-09-10: full `spec/tools/interactive_shell_spec.cr` passes on
Crystal 1.21.0 (5 examples, 0 failures), including the python3 REPL
integration test. Fails on 1.14 as described above — by design, 1.14 is
unsupported.
