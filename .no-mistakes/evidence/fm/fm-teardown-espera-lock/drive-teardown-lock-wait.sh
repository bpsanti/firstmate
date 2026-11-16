#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh against disposable FM_HOME fixtures while a
# separate process holds the shared Treehouse project lock.
# usage: drive-teardown-lock-wait.sh <firstmate-root> <hold-secs> <wait-env|unset> <label>
set -u
FMR=$1 HOLD=$2 WAITENV=$3 LABEL=$4
TESTS={run-worktree}/tests
. "$TESTS/lib.sh"
ROOT=$FMR
TMP_ROOT=$(fm_test_tmproot drive-lock-wait)
dir="$TMP_ROOT/c"; id=lock-case
mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/project" "$dir/pool/1"
git init -q "$dir/project"
: > "$dir/runtime.log"
for t in tmux treehouse; do
  printf '#!/usr/bin/env bash\nprintf "%s" >> "${FM_RUNTIME_LOG:?}"; printf " <%%s>" "$@" >> "${FM_RUNTIME_LOG:?}"; printf "\\n" >> "${FM_RUNTIME_LOG:?}"\n' "$t" > "$dir/fakebin/$t"
  chmod +x "$dir/fakebin/$t"
done
git -C "$dir/project" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm f
git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
ln -s pool/1/project "$dir/worktree"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
: > "$dir/worktree/sentinel"
fm_write_meta "$dir/home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
  "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
lock=$(FM_HOME="$dir/home" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/project")
FM_HOME="$dir/home" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; sleep "$5"; fm_lock_release "$2"; : > "$4"; exec sleep 60' _ \
  "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/held" "$dir/released" "$HOLD" &
holder=$!
for _ in $(seq 100); do [ -e "$dir/held" ] && break; sleep 0.1; done
echo "=== $LABEL ==="
echo "firstmate root: $ROOT"
echo "spawn stand-in holds project lock for ${HOLD}s (pid $holder); FM_TEARDOWN_TREEHOUSE_LOCK_WAIT_SECS=${WAITENV}"
start=$SECONDS
envargs=(); [ "$WAITENV" = unset ] || envargs=(FM_TEARDOWN_TREEHOUSE_LOCK_WAIT_SECS="$WAITENV")
env -u FM_TEARDOWN_TREEHOUSE_LOCK_WAIT_SECS "${envargs[@]}" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
  "$ROOT/bin/fm-teardown.sh" "$id" --force > "$dir/out" 2>&1
rc=$?
el=$((SECONDS-start))
rel=$(stat -f %m "$dir/released" 2>/dev/null || echo none); fin=$(date +%s)
echo "teardown exit=$rc elapsed=${el}s"
echo "holder released lock at epoch $rel; teardown finished at epoch $fin; teardown started at epoch $((fin-el))"
echo "--- teardown output ---"; sed 's/^/  /' "$dir/out" | tail -8
echo "--- state after ---"
echo "lock released by holder before teardown finished: $([ -e "$dir/released" ] && echo yes || echo no)"
echo "task meta present: $([ -e "$dir/home/state/$id.meta" ] && echo yes || echo no)"
echo "worktree sentinel present: $([ -e "$dir/worktree/sentinel" ] && echo yes || echo no)"
echo "runtime calls:"; sed 's/^/  /' "$dir/runtime.log"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
echo
