# Clean Acceptance workflow

This launcher creates a disposable game copy outside the tracked repository. It keeps Acceptance saves separate from the development save and records the exact source commit used for each run.

## Rules

- Run it only from a clean Git checkout. It refuses uncommitted or untracked source changes.
- `prepare` creates a timestamped runtime copy under `<checkout>-runtime/generated/` and records the source commit SHA.
- Only the generated copy receives `config/use_custom_user_dir=true` and the `MYRIAL Unwritten Acceptance` save location.
- The tracked `godot/project.godot` and development save are never rewritten by the launcher.
- Run `prepare` again after changing commits. `run` refuses a stale runtime whose SHA differs from the checkout.
- Generated runtimes and logs remain outside the repository and must not be committed.
- Acceptance is an evidence workspace, not a coding workspace. If a gameplay defect appears, stop, collect evidence, and fix it later on a separate coding branch; never patch the generated runtime.
- The generated runtime is disposable, but the development save must never be deleted or overwritten.
- This desktop workflow does not provide iPhone or iPad sandbox isolation; that remains a separate future concern.

## Normal flow

```sh
tools/acceptance/acceptance.sh prepare
tools/acceptance/acceptance.sh show
tools/acceptance/acceptance.sh run
```

`show` prints the source checkout, source SHA, generated runtime, isolated save location, and the two isolation settings for verification.

After testing, collect the evidence and confirm that the source checkout remains clean.

The launcher defaults to `/Applications/Godot.app/Contents/MacOS/Godot`. Advanced users may override `GODOT_BIN`, `ACCEPTANCE_RUNTIME_ROOT`, or `ACCEPTANCE_USER_DIR_NAME` for a single command.

The complete flow is: clean checkout → prepare → show → run → test → collect evidence → confirm the source remains clean.
