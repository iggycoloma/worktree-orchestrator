#!/usr/bin/env bash
# Tests for bin/wt -- worktree operations for the agentic dev environment.
#
# Exercises both layouts against real (temporary) git repositories:
# orchestration mode (bare repo.git + local/ + state/ + wt/) and clone mode
# (sibling <repo>-worktrees/). The ignore-validation security invariant is
# tested first: provisioning must hard-fail on a non-ignored destination.

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WT="$DOTFILES_DIR/bin/wt"

source "$SCRIPT_DIR/test-framework.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$TMP/home"
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global worktree.useRelativePaths true

# Seed remote: a bare repo with one commit on main, a .gitignore that
# ignores .env* so provisioning has legal destinations.
make_remote() {
    local remote="$1"
    git init -q --bare "$remote"
    local seed="$TMP/seed-$$-$RANDOM"
    git clone -q "$remote" "$seed" 2>/dev/null
    printf '.env\n.env.*\n' > "$seed/.gitignore"
    git -C "$seed" add -A
    git -C "$seed" commit -q -m init
    git -C "$seed" push -q origin HEAD
    rm -rf "$seed"
}

# ============================================================
# Test Suite: version floor helper
# ============================================================
test_suite "version_at_least"

vcheck() {
    bash -c "source '$WT' && version_at_least '$1' '$2'" && echo yes || echo no
}
assert_equals "yes" "$(vcheck 0.88.0 0.81.0)" "0.88.0 satisfies the 0.81.0 floor"
assert_equals "yes" "$(vcheck 0.81.0 0.81.0)" "exact floor version satisfies"
assert_equals "no"  "$(vcheck 0.80.9 0.81.0)" "0.80.9 fails the 0.81.0 floor"
assert_equals "no"  "$(vcheck '' 0.81.0)"     "empty version fails the floor"
assert_equals "yes" "$(vcheck 2.55.0 2.48.0)" "git 2.55 satisfies the 2.48 floor"

# ensure_rel_flag degrades on old git instead of passing an unknown flag.
relflag_for() {
    bash -c "
        source '$WT'
        git() { if [[ \"\$1\" == \"--version\" ]]; then echo \"git version $1\"; else command git \"\$@\"; fi; }
        ensure_rel_flag 2>/dev/null
        printf '%s' \"\$WT_REL_FLAG\""
}
assert_equals "--relative-paths" "$(relflag_for 2.48.0)" "git 2.48 gets --relative-paths"
assert_equals "" "$(relflag_for 2.43.0)" "git 2.43 gets no flag instead of an unknown-option failure"
warn=$(bash -c "
    source '$WT'
    git() { if [[ \"\$1\" == \"--version\" ]]; then echo \"git version 2.43.0\"; else command git \"\$@\"; fi; }
    ensure_rel_flag 2>&1 >/dev/null")
assert_contains "$warn" "absolute pointer" "degraded path warns about absolute pointers"

# dotfiles_repo precedence: explicit override, then DOTFILES_DIR, then ~/.dotfiles.
GIT_REL_OK=0
bash -c "source '$WT' && version_at_least \"\$(command git --version | awk '{print \$3}')\" 2.48.0" && GIT_REL_OK=1

# Pointer assertions must hold on new git and degrade with old git.
assert_rel_pointer() {
    local gitfile="$1" label="$2"
    if [[ "$GIT_REL_OK" -eq 1 ]]; then
        assert_contains "$(cat "$gitfile")" "gitdir: ../" "$label"
    else
        assert_file_exists "$gitfile" "$label (absolute-pointer fallback on old git)"
    fi
}

# ============================================================
# Test Suite: slug normalization
# ============================================================
test_suite "slug normalization"

# normalize_slug is internal; observe it through worktree paths in clone mode.
make_remote "$TMP/remote-slug.git"
git clone -q "$TMP/remote-slug.git" "$TMP/slugproj" 2>/dev/null
cd "$TMP/slugproj" || exit 1

dest=$("$WT" add "Feature/CLK-943_Fancy Name" 2>/dev/null)
assert_equals "$TMP/slugproj-worktrees/clk-943_fancy-name" "$dest" \
    "mixed-case path segment normalizes to lowercase leaf slug"
assert_file_exists "$dest/.git" "worktree created at normalized path"

# ============================================================
# Test Suite: clone mode
# ============================================================
test_suite "clone mode"

assert_rel_pointer "$dest/.git" "clone-mode worktree pointer is relative"

cd "$dest" || exit 1
dest2=$("$WT" add second 2>/dev/null)
assert_equals "$TMP/slugproj-worktrees/second" "$dest2" \
    "running from inside a worktree keeps the sibling tree flat"

listing=$("$WT" list 2>/dev/null)
assert_contains "$listing" "slugproj-worktrees/second" "wt list shows created worktrees"

cd "$TMP/slugproj" || exit 1
"$WT" remove second >/dev/null 2>&1
assert_file_not_exists "$TMP/slugproj-worktrees/second/.git" "wt remove deletes a clean worktree"

# ============================================================
# Test Suite: orchestration mode
# ============================================================
test_suite "orchestration mode"

make_remote "$TMP/remote-orch.git"
cd "$TMP" || exit 1
root=$("$WT" init "$TMP/remote-orch.git" "$TMP/proj" 2>/dev/null)
assert_equals "$TMP/proj" "$root" "wt init prints the orchestration root"
assert_dir_exists "$TMP/proj/repo.git" "init creates bare repo.git"
assert_dir_exists "$TMP/proj/local/shared" "init creates local/shared"
assert_dir_exists "$TMP/proj/local/template" "init creates local/template"
assert_dir_exists "$TMP/proj/state" "init creates state/"
assert_dir_exists "$TMP/proj/main" "init creates the main worktree"

# shellcheck disable=SC2012
perms=$(ls -ld "$TMP/proj/local" | cut -c1-10)
assert_equals "drwx------" "$perms" "local/ is chmod 700"

rel=$(git --git-dir="$TMP/proj/repo.git" config worktree.useRelativePaths)
assert_equals "true" "$rel" "init sets worktree.useRelativePaths on repo.git"

cd "$TMP/proj" || exit 1
dest=$("$WT" add issue-123 2>/dev/null)
assert_equals "$TMP/proj/wt/issue-123" "$dest" "orchestration worktrees land in wt/"
assert_rel_pointer "$dest/.git" "orchestration pointer is relative into repo.git"

cd "$TMP/proj/wt/issue-123" || exit 1
nested=$("$WT" add from-inside 2>/dev/null)
assert_equals "$TMP/proj/wt/from-inside" "$nested" \
    "mode detection walks up: add from inside a worktree stays in wt/"

# init against an empty remote (unborn HEAD) fails cleanly and rolls back.
cd "$TMP" || exit 1
git init -q --bare "$TMP/empty.git"
output=$("$WT" init "$TMP/empty.git" "$TMP/proj2" 2>&1)
assert_not_equals 0 $? "init fails on an empty remote"
assert_contains "$output" "rolled back" "failure explains the rollback"
assert_file_not_exists "$TMP/proj2/repo.git/HEAD" "failed init leaves no repo.git"

# After the remote gains a commit, init succeeds in the same directory.
git clone -q "$TMP/empty.git" "$TMP/seed2" 2>/dev/null
git -C "$TMP/seed2" commit -q --allow-empty -m init
git -C "$TMP/seed2" push -q origin HEAD
rm -rf "$TMP/seed2"
root2=$("$WT" init "$TMP/empty.git" "$TMP/proj2" 2>/dev/null)
assert_equals "$TMP/proj2" "$root2" "re-run init succeeds after rollback"

# ============================================================
# Test Suite: provisioning and the ignore-validation invariant
# ============================================================
test_suite "provisioning security invariant"

cd "$TMP/proj" || exit 1
printf 'SANDBOX_KEY=abc\n' > local/shared/.env.shared
printf 'LOCAL_SEED=1\n'    > local/template/.env.local

dest=$("$WT" add provisioned 2>/dev/null)
assert_file_exists "$dest/.env.shared" "shared file provisioned into new worktree"
assert_file_exists "$dest/.env.local" "template file provisioned into new worktree"

printf 'CUSTOMIZED=1\n' > "$dest/.env.local"
printf 'SANDBOX_KEY=xyz\n' > local/shared/.env.shared

# Non-ignored destination must abort the whole add and roll back.
printf 'oops\n' > local/shared/not-ignored.txt
output=$("$WT" add rejected 2>&1)
status=$?
assert_not_equals 0 "$status" "add fails when a local file destination is not gitignored"
assert_contains "$output" "non-ignored" "failure names the offending file"
assert_file_not_exists "$TMP/proj/wt/rejected/.git" "failed add rolls the worktree back"
rm -f local/shared/not-ignored.txt

# ============================================================
# Test Suite: sync and diff-local
# ============================================================
test_suite "sync and diff-local"

cd "$TMP/proj" || exit 1
dest="$TMP/proj/wt/provisioned"

# shared drifted earlier (SANDBOX_KEY=xyz written after provisioning abc)
output=$("$WT" diff-local provisioned 2>&1)
status=$?
assert_not_equals 0 "$status" "diff-local exits nonzero on drift"
assert_contains "$output" "differs" "diff-local reports the drifted file"

"$WT" sync provisioned >/dev/null 2>&1
synced=$(cat "$dest/.env.shared")
assert_equals "SANDBOX_KEY=xyz" "$synced" "sync overwrites shared copies"
customized=$(cat "$dest/.env.local")
assert_equals "CUSTOMIZED=1" "$customized" "sync leaves customized template files alone"

output=$("$WT" diff-local provisioned 2>&1)
assert_equals 0 $? "diff-local passes after sync"

# The stable main/ checkout syncs like any other worktree.
"$WT" sync main >/dev/null 2>&1
assert_equals 0 $? "wt sync main succeeds"
assert_file_exists "$TMP/proj/main/.env.shared" "sync main provisions the stable checkout"
main_path=$("$WT" path main 2>/dev/null)
assert_equals "$TMP/proj/main" "$main_path" "wt path main resolves the stable checkout"

# main is protected from add and remove.
output=$("$WT" add main 2>&1)
assert_not_equals 0 $? "wt add main is refused"
assert_contains "$output" "reserved" "add-main refusal explains why"
output=$("$WT" remove main 2>&1)
assert_not_equals 0 $? "wt remove main is refused"
assert_file_exists "$TMP/proj/main/.git" "main survives the refused remove"

# sync --all refreshes main and every task worktree in one pass.
printf 'SANDBOX_KEY=rotated\n' > local/shared/.env.shared
"$WT" sync --all >/dev/null 2>&1
assert_equals 0 $? "wt sync --all succeeds"
assert_equals "SANDBOX_KEY=rotated" "$(cat "$TMP/proj/main/.env.shared")" \
    "sync --all refreshes main"
assert_equals "SANDBOX_KEY=rotated" "$(cat "$dest/.env.shared")" \
    "sync --all refreshes task worktrees"

# ============================================================
# Test Suite: runtime identity and port registry
# ============================================================
test_suite "runtime identity"

assert_file_exists "$dest/.env.worktree" "add generates .env.worktree"
env_content=$(cat "$dest/.env.worktree")
assert_contains "$env_content" "WORKTREE_SLUG=provisioned" "env has slug"
assert_contains "$env_content" "COMPOSE_PROJECT_NAME=proj-provisioned" "env has compose project name"
port1=$(sed -n 's/^APP_PORT=//p' "$dest/.env.worktree")
assert_contains "$env_content" "APP_PORT=$port1" "worktree gets a port from the registry"

dest2=$("$WT" add second-id 2>/dev/null)
port2=$(sed -n 's/^APP_PORT=//p' "$dest2/.env.worktree")
assert_not_equals "$port1" "$port2" "each worktree gets a distinct port"
dupes=$(awk -F'\t' 'seen[$2]++ { print $2 }' "$TMP/proj/state/ports.tsv")
assert_equals "" "$dupes" "port registry has no duplicate allocations"

"$WT" remove second-id --branch >/dev/null 2>&1
if grep -q "second-id" "$TMP/proj/state/ports.tsv"; then
    released="no"
else
    released="yes"
fi
assert_equals "yes" "$released" "remove releases the allocated port"

# ============================================================
# Test Suite: container command gating
# ============================================================
test_suite "container gating"

# Name resolution precedes any docker/CLI requirement, in every environment.
output=$("$WT" exec nonexistent -- true 2>&1)
assert_not_equals 0 $? "exec fails on an unknown worktree"
assert_contains "$output" "no such worktree" "exec resolves the name before the docker check"

if [[ -f /.dockerenv ]]; then
    output=$("$WT" container-up provisioned 2>&1)
    status=$?
    assert_not_equals 0 "$status" "container-up refuses to run inside a container"
    assert_contains "$output" "host-only" "refusal explains containers never launch containers"
    output=$("$WT" exec provisioned -- true 2>&1)
    assert_not_equals 0 $? "exec refuses to run inside a container"
    # main resolves (would otherwise be "no such worktree") and then hits
    # the host-only gate -- proving container commands accept main.
    output=$("$WT" exec main -- true 2>&1)
    assert_contains "$output" "host-only" "exec resolves main before the host-only refusal"
else
    output=$("$WT" container-up 2>&1)
    assert_not_equals 0 $? "container-up requires a name"
fi

# ============================================================
# Test Suite: remove safety
# ============================================================
test_suite "remove safety"

printf 'work in progress\n' > "$TMP/proj/wt/issue-123/wip.txt"
output=$("$WT" remove issue-123 2>&1)
status=$?
assert_not_equals 0 "$status" "remove refuses a worktree with untracked files"
assert_contains "$output" "untracked" "refusal names the reason"
assert_file_exists "$TMP/proj/wt/issue-123/wip.txt" "refused remove leaves work intact"

rm -f "$TMP/proj/wt/issue-123/wip.txt"
"$WT" remove issue-123 --branch >/dev/null 2>&1
assert_file_not_exists "$TMP/proj/wt/issue-123/.git" "clean worktree removes"
if git --git-dir="$TMP/proj/repo.git" show-ref --verify --quiet refs/heads/issue-123; then
    branch_gone="no"
else
    branch_gone="yes"
fi
assert_equals "yes" "$branch_gone" "--branch also deletes the branch"

# ============================================================
# Test Suite: doctor
# ============================================================
test_suite "doctor"

cd "$TMP/proj" || exit 1
output=$("$WT" doctor 2>&1)
status=$?
assert_equals 0 "$status" "doctor passes on a healthy orchestration dir"
assert_contains "$output" "mode: orchestration" "doctor reports orchestration mode"
assert_contains "$output" "useRelativePaths: true" "doctor confirms relative paths config"

# ============================================================
# Test Suite: post-checkout safety-net hook
# ============================================================
test_suite "post-checkout hook"

HOOK="$DOTFILES_DIR/git/hooks/post-checkout"
export WT_BIN="$WT"
NULL_REF="0000000000000000000000000000000000000000"

# A worktree created OUTSIDE wt (plain git) gets provisioned by the hook.
# No explicit --relative-paths: the global useRelativePaths config covers
# new git, and old git must not fail on an unknown flag here.
git --git-dir="$TMP/proj/repo.git" worktree add -q \
    -b outside "$TMP/proj/wt/outside" main 2>/dev/null
head_ref=$(git -C "$TMP/proj/wt/outside" rev-parse HEAD)
assert_file_not_exists "$TMP/proj/wt/outside/.env.shared" \
    "plain git worktree add does not provision by itself"
(cd "$TMP/proj/wt/outside" && bash "$HOOK" "$NULL_REF" "$head_ref" 1)
assert_equals 0 $? "hook exits 0 on initial checkout"
assert_file_exists "$TMP/proj/wt/outside/.env.shared" \
    "hook provisions local/shared into an externally created worktree"

# Ordinary branch switch (non-null old ref) must be a no-op.
rm -f "$TMP/proj/wt/outside/.env.shared"
(cd "$TMP/proj/wt/outside" && bash "$HOOK" "$head_ref" "$head_ref" 1)
assert_file_not_exists "$TMP/proj/wt/outside/.env.shared" \
    "hook ignores ordinary branch switches"

# File checkout (kind 0) must be a no-op.
(cd "$TMP/proj/wt/outside" && bash "$HOOK" "$NULL_REF" "$head_ref" 0)
assert_file_not_exists "$TMP/proj/wt/outside/.env.shared" \
    "hook ignores file checkouts"

# A non-slug directory name still round-trips: the hook passes the path
# and resolve_worktree accepts absolute paths.
git --git-dir="$TMP/proj/repo.git" worktree add -q \
    -b feature-x "$TMP/proj/wt/Feature_X" main 2>/dev/null
fx_ref=$(git -C "$TMP/proj/wt/Feature_X" rev-parse HEAD)
(cd "$TMP/proj/wt/Feature_X" && bash "$HOOK" "$NULL_REF" "$fx_ref" 1)
assert_file_exists "$TMP/proj/wt/Feature_X/.env.shared" \
    "hook provisions worktrees whose directory name is not a slug"

# Clone-mode worktrees (no orchestration local/) exit silently.
output=$(cd "$TMP/slugproj" && bash "$HOOK" "$NULL_REF" "$head_ref" 1 2>&1)
assert_equals 0 $? "hook exits 0 outside orchestration layout"
assert_equals "" "$output" "hook is silent outside orchestration layout"

unset WT_BIN

# ============================================================
# Test Suite: WorktreeCreate / WorktreeRemove shims
# ============================================================
test_suite "harness shims"

CREATE_SHIM="$DOTFILES_DIR/claude-code/hooks/worktree-create.sh"
REMOVE_SHIM="$DOTFILES_DIR/claude-code/hooks/worktree-remove.sh"
export WT_BIN="$WT"

shim_json() {
    jq -n -c --arg base "$1" --arg suffix "$2" --arg cwd "$3" \
        '{worktree_base_path: $base, worktree_suffix: $suffix, cwd: $cwd}'
}

# Orchestration repo: shim routes through wt, path lands in wt/.
path=$(shim_json "$TMP/proj/.claude/worktrees" "claude-abc" "$TMP/proj" | bash "$CREATE_SHIM" 2>/dev/null)
assert_equals 0 $? "create shim exits 0 via wt"
assert_equals "$TMP/proj/wt/claude-abc" "$path" "shim redirects creation into wt/, not .claude/worktrees"
assert_file_exists "$path/.env.shared" "shim-created worktree is provisioned"

# Reuse: same suffix returns the existing worktree.
path2=$(shim_json "$TMP/proj/.claude/worktrees" "claude-abc" "$TMP/proj" | bash "$CREATE_SHIM" 2>/dev/null)
assert_equals "$path" "$path2" "shim is idempotent for an existing name"

# Security abort: non-ignored local file must abort creation, not degrade.
printf 'oops\n' > "$TMP/proj/local/shared/bad.txt"
shim_json "$TMP/proj/.claude/worktrees" "claude-sec" "$TMP/proj" | bash "$CREATE_SHIM" >/dev/null 2>&1
assert_not_equals 0 $? "create shim aborts on ignore-validation failure"
assert_file_not_exists "$TMP/proj/wt/claude-sec/.git" "aborted creation leaves no worktree"
rm -f "$TMP/proj/local/shared/bad.txt"

# Degrade: wt unavailable falls back to plain git worktree add at the base path.
path=$(shim_json "$TMP/slugproj/.claude/worktrees" "claude-fb" "$TMP/slugproj" | WT_BIN=/nonexistent/wt bash "$CREATE_SHIM" 2>/dev/null)
assert_equals "$TMP/slugproj/.claude/worktrees/claude-fb" "$path" "shim degrades to git worktree add at the suggested base"
assert_rel_pointer "$path/.git" "fallback worktree still gets a relative pointer"

# A leftover branch from an earlier worktree must not abort the fallback.
git -C "$TMP/slugproj" branch worktree-claude-fb2 2>/dev/null
path=$(shim_json "$TMP/slugproj/.claude/worktrees" "claude-fb2" "$TMP/slugproj" | WT_BIN=/nonexistent/wt bash "$CREATE_SHIM" 2>/dev/null)
assert_equals "$TMP/slugproj/.claude/worktrees/claude-fb2" "$path" "fallback uniquifies a colliding branch instead of aborting"

# Remove shim: tears down a clean wt-managed worktree, always exits 0.
printf '%s' "{\"worktree_path\": \"$TMP/proj/wt/claude-abc\"}" | bash "$REMOVE_SHIM" >/dev/null 2>&1
assert_equals 0 $? "remove shim exits 0"
assert_file_not_exists "$TMP/proj/wt/claude-abc/.git" "remove shim removes the worktree"

# Dirty worktree: refused by wt, shim still exits 0 and preserves work.
dirty=$("$WT" add dirty-one 2>/dev/null)
printf 'wip\n' > "$dirty/wip.txt"
printf '%s' "{\"worktree_path\": \"$dirty\"}" | bash "$REMOVE_SHIM" >/dev/null 2>&1
assert_equals 0 $? "remove shim exits 0 even when removal is refused"
assert_file_exists "$dirty/wip.txt" "refused removal preserves uncommitted work"

# dotfiles_repo precedence: explicit override, then DOTFILES_DIR, then ~/.dotfiles.
out=$(DOTFILES_DIR="$TMP/slugproj" bash -c "source '$WT' && dotfiles_repo")
assert_contains "$out" "remote-slug.git" "dotfiles_repo honors DOTFILES_DIR checkouts"
out=$(WT_DOTFILES_REPOSITORY="https://example.com/df.git" DOTFILES_DIR="$TMP/slugproj" \
    bash -c "source '$WT' && dotfiles_repo")
assert_equals "https://example.com/df.git" "$out" "explicit WT_DOTFILES_REPOSITORY wins over DOTFILES_DIR"
out=$(DOTFILES_DIR='' WT_DOTFILES_REPOSITORY='' bash -c "source '$WT' && dotfiles_repo")
assert_equals "" "$out" "no dotfiles checkout yields an empty repo (flag omitted)"

unset WT_BIN

# ============================================================
# Test Suite: lifecycle hooks and env idempotency
# ============================================================
test_suite "lifecycle hooks and env idempotency"

cd "$TMP/proj" || exit 1
mkdir -p local/hooks
# shellcheck disable=SC2016  # $1 is for the hook script, not this shell
printf '#!/usr/bin/env bash\necho "added:$1" >> "%s/state/hooklog"\n' "$TMP/proj" > local/hooks/post-add
# shellcheck disable=SC2016  # $1 is for the hook script, not this shell
printf '#!/usr/bin/env bash\necho "synced:$1" >> "%s/state/hooklog"\n' "$TMP/proj" > local/hooks/post-sync
chmod +x local/hooks/post-add local/hooks/post-sync

dest=$("$WT" add hooked 2>/dev/null)
assert_contains "$(cat state/hooklog 2>/dev/null)" "added:$dest" "post-add hook runs after provisioning"

"$WT" sync hooked >/dev/null 2>&1
assert_contains "$(cat state/hooklog 2>/dev/null)" "synced:$dest" "post-sync hook runs after sync"

# A failing hook warns but never fails the command.
printf '#!/usr/bin/env bash\nexit 1\n' > local/hooks/post-sync
chmod +x local/hooks/post-sync
"$WT" sync hooked >/dev/null 2>&1
assert_equals 0 $? "sync succeeds despite a failing post-sync hook"

# Idempotent env write: unchanged content is not rewritten (a read-only
# file would make a rewrite fail, so success proves the skip).
port_before=$(sed -n 's/^APP_PORT=//p' "$dest/.env.worktree")
chmod 444 "$dest/.env.worktree"
"$WT" sync hooked >/dev/null 2>&1
assert_equals 0 $? "no-change sync does not rewrite .env.worktree"
chmod 600 "$dest/.env.worktree"
port_after=$(sed -n 's/^APP_PORT=//p' "$dest/.env.worktree")
assert_equals "$port_before" "$port_after" "sync preserves the allocated port"

# Content change is picked up on sync.
mkdir -p "$dest/.dev"
printf 'PROJECT_ID=renamed\n' > "$dest/.dev/worktree.conf"
"$WT" sync hooked >/dev/null 2>&1
assert_contains "$(cat "$dest/.env.worktree")" "COMPOSE_PROJECT_NAME=renamed-hooked" \
    "sync regenerates env when project config changes"

# A checkout-controlled conf with a bad port range must warn, not abort.
printf 'PORT_RANGE_START=abc\nPORT_RANGE_END=99xx\n' > "$dest/.dev/worktree.conf"
output=$("$WT" sync hooked 2>&1)
assert_equals 0 $? "garbage PORT_RANGE values do not abort sync"
assert_contains "$output" "invalid PORT_RANGE_START" "bad range is reported"
port_kept=$(sed -n 's/^APP_PORT=//p' "$dest/.env.worktree")
assert_equals "$port_before" "$port_kept" "existing allocation survives a bad range"

# ============================================================
# Summary
# ============================================================
print_test_summary
