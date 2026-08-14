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

# Regression: truncation used to run AFTER the trailing-punctuation trim, so a
# name longer than the budget produced a slug ending in a bare '-'.
long_name="CLK-1287-add-support-for-import-broker-from-the-marketplace"
dest_long=$("$WT" add "$long_name" 2>/dev/null)
# The expected slug ends in a word character, which is the regression: the
# old ordering yielded 'clk-1287-add-support-for-import-broker-from-the-'.
assert_equals "$TMP/slugproj-worktrees/clk-1287-add-support-for-import-broker" "$dest_long" \
    "over-budget name truncates at a word boundary with no trailing dash"

# The branch keeps the full name; only the directory is budgeted.
branch=$(git -C "$dest_long" symbolic-ref --short HEAD 2>/dev/null)
assert_equals "$long_name" "$branch" "truncating the slug does not truncate the branch"

# A name with no separator has no word boundary to retreat to, so a hard cut
# is the only option -- but it must still respect the budget.
solid=$(printf 'a%.0s' $(seq 1 60))
dest_solid=$("$WT" add "$solid" 2>/dev/null)
solid_slug=$(basename "$dest_solid")
assert_equals 40 "${#solid_slug}" "separator-free name is hard-cut to the budget"

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
# Test Suite: go, --names, and name resolution
# ============================================================
test_suite "go and name resolution"

names=$("$WT" list --names 2>/dev/null)
assert_contains "$names" "clk-1287-add-support-for-import-broker" \
    "list --names prints bare directory names"
case "$names" in
    */*) assert_equals "bare" "paths" "list --names prints no paths" ;;
    *)   assert_equals "bare" "bare" "list --names prints no paths" ;;
esac

# go resolves the full name through the same mapping add used...
dest_go=$("$WT" go "$long_name" 2>/dev/null)
assert_equals "$TMP/slugproj-worktrees/clk-1287-add-support-for-import-broker" "$dest_go" \
    "wt go resolves the full over-budget name"

# ...and an unambiguous prefix, which is what makes a truncated slug typeable.
dest_go=$("$WT" go clk-1287 2>/dev/null)
assert_equals "$TMP/slugproj-worktrees/clk-1287-add-support-for-import-broker" "$dest_go" \
    "wt go resolves an unambiguous prefix"

dest_go=$("$WT" go 2>/dev/null)
assert_equals "$TMP/slugproj" "$dest_go" "bare wt go returns the repo root in clone mode"

output=$("$WT" go nope 2>&1)
status=$?
assert_equals 1 "$status" "wt go on an unknown name fails"
assert_contains "$output" "no such worktree" "wt go on an unknown name explains why"

# A worktree created before the slug budget shrank keeps its longer directory
# name; resolution must fall back to git's registry so it is never orphaned.
legacy="clk-9999-a-very-long-legacy-name-from-the-olden"
git worktree add -q "$TMP/slugproj-worktrees/$legacy" -b legacy 2>/dev/null
assert_equals "$TMP/slugproj-worktrees/$legacy" "$("$WT" path clk-9999 2>/dev/null)" \
    "a legacy over-budget slug still resolves by prefix"
assert_equals "$TMP/slugproj-worktrees/$legacy" \
    "$("$WT" path "CLK-9999-a-very-long-legacy-name-from-the-olden-days" 2>/dev/null)" \
    "a legacy slug still resolves from the name that created it"
"$WT" remove clk-9999 >/dev/null 2>&1
assert_file_not_exists "$TMP/slugproj-worktrees/$legacy/.git" \
    "wt remove works on a legacy over-budget slug"

# An ambiguous prefix must name the candidates rather than guess.
"$WT" add clk-5555-alpha >/dev/null 2>&1
"$WT" add clk-5555-beta >/dev/null 2>&1
output=$("$WT" go clk-5555 2>&1)
status=$?
assert_equals 1 "$status" "an ambiguous prefix fails"
assert_contains "$output" "matches 2 worktrees" "an ambiguous prefix reports the count"
assert_contains "$output" "clk-5555-beta" "an ambiguous prefix lists the candidates"
"$WT" remove clk-5555-alpha >/dev/null 2>&1
"$WT" remove clk-5555-beta >/dev/null 2>&1

# ============================================================
# Test Suite: argument and help handling
# ============================================================
test_suite "argument and help handling"

# Regression: `wt add --help` used to slugify the flag ('--help' -> 'help')
# and create a worktree instead of printing help.
output=$("$WT" add --help 2>&1)
status=$?
assert_equals 0 "$status" "wt add --help exits 0"
assert_contains "$output" "Usage: wt add <name> [base]" "wt add --help prints add's usage"
assert_file_not_exists "$TMP/slugproj-worktrees/help/.git" "wt add --help creates no worktree"

# Help is answered before any layout detection, so it works anywhere.
cd "$TMP" || exit 1
"$WT" add --help >/dev/null 2>&1
assert_equals 0 $? "wt add --help works outside a repository"
cd "$TMP/slugproj" || exit 1

output=$("$WT" --help 2>&1)
assert_equals 0 $? "wt --help exits 0"
assert_contains "$output" "container up|exec" "wt --help lists every command"
assert_contains "$output" "'wt <command> --help'" "wt --help points at per-command help"

output=$("$WT" help sync 2>&1)
assert_equals 0 $? "wt help <command> exits 0"
assert_contains "$output" "Usage: wt sync [name|--all] [--diff]" "wt help sync prints sync's usage"

# A bare invocation is a usage error: stderr, exit 2.
"$WT" >/dev/null 2>&1
assert_equals 2 $? "bare wt exits 2"
assert_equals "" "$("$WT" 2>/dev/null)" "bare wt writes usage to stderr, not stdout"

# Stray flags are rejected rather than becoming worktree names.
output=$("$WT" add -x 2>&1)
assert_not_equals 0 $? "wt add -x fails"
assert_contains "$output" "unknown option: -x" "wt add -x names the offending flag"
assert_file_not_exists "$TMP/slugproj-worktrees/x/.git" "wt add -x creates no worktree"

output=$("$WT" add one two three 2>&1)
assert_not_equals 0 $? "wt add rejects extra positional arguments"
assert_contains "$output" "usage: wt add <name> [base]" "arity error shows the synopsis"

output=$("$WT" sync -x 2>&1)
assert_not_equals 0 $? "wt sync -x fails"
assert_contains "$output" "unknown option: -x" "wt sync -x names the offending flag"

output=$("$WT" bogus 2>&1)
assert_not_equals 0 $? "unknown command fails"
assert_contains "$output" "unknown command: bogus" "unknown command is named"

# Everything after '--' belongs to the container command, help flags included.
output=$("$WT" container exec nosuch -- tool --help 2>&1)
assert_not_contains "$output" "Usage: wt container" "container exec passes --help after -- to the command"
assert_contains "$output" "no such worktree" "container exec resolves the worktree instead of printing help"

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

refspec=$(git --git-dir="$TMP/proj/repo.git" config remote.origin.fetch)
assert_equals '+refs/heads/*:refs/remotes/origin/*' "$refspec" \
    "init sets a fetch refspec (bare clones have none)"
origin_head=$(git --git-dir="$TMP/proj/repo.git" symbolic-ref --short refs/remotes/origin/HEAD)
assert_equals "origin/main" "$origin_head" "init points origin/HEAD at the default branch"

# Plain `git fetch origin` must actually move origin/* -- the whole point
# of the refspec. Advance the remote out-of-band, fetch, compare.
git clone -q "$TMP/remote-orch.git" "$TMP/seed-fetch" 2>/dev/null
git -C "$TMP/seed-fetch" commit -q --allow-empty -m advance
git -C "$TMP/seed-fetch" push -q origin HEAD
remote_tip=$(git --git-dir="$TMP/remote-orch.git" rev-parse HEAD)
rm -rf "$TMP/seed-fetch"
git -C "$TMP/proj/main" fetch -q origin
fetched_tip=$(git --git-dir="$TMP/proj/repo.git" rev-parse refs/remotes/origin/main)
assert_equals "$remote_tip" "$fetched_tip" \
    "plain 'git fetch origin' updates origin/main in an init'd layout"

cd "$TMP/proj" || exit 1
dest=$("$WT" add issue-123 2>/dev/null)
assert_equals "$TMP/proj/wt/issue-123" "$dest" "orchestration worktrees land in wt/"
assert_rel_pointer "$dest/.git" "orchestration pointer is relative into repo.git"

cd "$TMP/proj/wt/issue-123" || exit 1
nested=$("$WT" add from-inside 2>/dev/null)
assert_equals "$TMP/proj/wt/from-inside" "$nested" \
    "mode detection walks up: add from inside a worktree stays in wt/"

# In orchestration mode a bare `go` targets the stable checkout, not the root,
# and `main` stays resolvable as a name rather than matching a wt/ prefix.
assert_equals "$TMP/proj/main" "$("$WT" go 2>/dev/null)" \
    "bare wt go returns main/ in orchestration mode"
assert_equals "$TMP/proj/main" "$("$WT" go main 2>/dev/null)" \
    "wt go main resolves the stable checkout"
assert_equals "$TMP/proj/wt/issue-123" "$("$WT" go issue 2>/dev/null)" \
    "wt go resolves a prefix in orchestration mode"

# main/ must stay un-removable, including via the resolver's prefix path.
output=$("$WT" remove main 2>&1)
assert_not_equals 0 $? "wt remove main fails"
assert_contains "$output" "refusing to remove the stable main" \
    "wt remove main explains the refusal"
assert_dir_exists "$TMP/proj/main" "refused removal leaves main/ intact"

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
# Test Suite: sync and sync --diff
# ============================================================
test_suite "sync and sync --diff"

cd "$TMP/proj" || exit 1
dest="$TMP/proj/wt/provisioned"

# shared drifted earlier (SANDBOX_KEY=xyz written after provisioning abc)
output=$("$WT" sync --diff provisioned 2>&1)
status=$?
assert_not_equals 0 "$status" "sync --diff exits nonzero on drift"
assert_contains "$output" "differs" "sync --diff reports the drifted file"

"$WT" sync provisioned >/dev/null 2>&1
synced=$(cat "$dest/.env.shared")
assert_equals "SANDBOX_KEY=xyz" "$synced" "sync overwrites shared copies"
customized=$(cat "$dest/.env.local")
assert_equals "CUSTOMIZED=1" "$customized" "sync leaves customized template files alone"

output=$("$WT" sync --diff provisioned 2>&1)
assert_equals 0 $? "sync --diff passes after sync"

# --diff never writes: the drifted copy must survive the preview untouched.
printf 'SANDBOX_KEY=preview\n' > local/shared/.env.shared
"$WT" sync --diff provisioned >/dev/null 2>&1
assert_equals "SANDBOX_KEY=xyz" "$(cat "$dest/.env.shared")" \
    "sync --diff leaves the worktree copy untouched"

# --diff --all prefixes each line with the tree it belongs to.
output=$("$WT" sync --diff --all 2>&1)
assert_not_equals 0 $? "sync --diff --all exits nonzero on drift"
assert_contains "$output" $'provisioned\tdiffers' "sync --diff --all attributes drift per tree"
printf 'SANDBOX_KEY=xyz\n' > local/shared/.env.shared

# The stable main/ checkout syncs like any other worktree -- and is the
# default when no name is given.
"$WT" sync >/dev/null 2>&1
assert_equals 0 $? "wt sync with no name succeeds"
assert_file_exists "$TMP/proj/main/.env.shared" "bare sync provisions the stable checkout"
main_path=$("$WT" path main 2>/dev/null)
assert_equals "$TMP/proj/main" "$main_path" "wt path main resolves the stable checkout"
assert_equals "$TMP/proj/main" "$("$WT" path 2>/dev/null)" \
    "wt path with no name defaults to the stable checkout"

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

# The noun group rejects unknown subcommands before doing anything else.
output=$("$WT" container 2>&1)
assert_not_equals 0 $? "bare wt container is a usage error"
assert_contains "$output" "usage: wt container" "bare container prints the synopsis"
output=$("$WT" container bogus 2>&1)
assert_not_equals 0 $? "unknown container subcommand fails"

# exec's -- separator is mandatory: without it the container command's
# flags would leak into wt's own parsing.
output=$("$WT" container exec provisioned true 2>&1)
assert_not_equals 0 $? "container exec without -- is a usage error"
assert_contains "$output" "usage: wt container" "missing -- prints the synopsis"

# Name resolution precedes any docker/CLI requirement, in every environment.
output=$("$WT" container exec nonexistent -- true 2>&1)
assert_not_equals 0 $? "container exec fails on an unknown worktree"
assert_contains "$output" "no such worktree" "container exec resolves the name before the docker check"

if [[ -f /.dockerenv ]]; then
    output=$("$WT" container up provisioned 2>&1)
    status=$?
    assert_not_equals 0 "$status" "container up refuses to run inside a container"
    assert_contains "$output" "host-only" "refusal explains containers never launch containers"
    output=$("$WT" container exec provisioned -- true 2>&1)
    assert_not_equals 0 $? "container exec refuses to run inside a container"
    # No name: up defaults to main, which resolves (would otherwise be
    # "no such worktree") and then hits the host-only gate.
    output=$("$WT" container up 2>&1)
    assert_contains "$output" "host-only" "container up with no name resolves main before the host-only refusal"
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
assert_contains "$output" "remote.origin.fetch: configured" "doctor confirms the fetch refspec"

# A pre-fix layout (bare clone, no refspec) must fail doctor with the repair command.
git --git-dir="$TMP/proj/repo.git" config --unset-all remote.origin.fetch
output=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "doctor fails when origin has no fetch refspec"
assert_contains "$output" "no fetch refspec" "doctor names the missing refspec"
assert_contains "$output" "config remote.origin.fetch" "doctor prints the repair command"
git --git-dir="$TMP/proj/repo.git" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

# ============================================================
# Test Suite: ignore generation
# ============================================================
test_suite "ignore"

# init must leave a bounded .ignore behind: an orchestration dir is not a
# repository, so nothing else stops a search descending into every worktree.
assert_file_exists "$TMP/proj/.ignore" "init writes .ignore at the orchestration root"
assert_contains "$(cat "$TMP/proj/.ignore")" "wt/" ".ignore excludes the worktree dir"
output=$(cd "$TMP/proj" && "$WT" doctor 2>&1)
assert_contains "$output" ".ignore: current" "doctor accepts the generated .ignore"

# Detection is by layout, not by a fixed list: a workspace above several
# orchestration dirs gets a pattern per project.
IGN="$TMP/ws"
mkdir -p "$IGN/a/repo.git" "$IGN/a/wt/one" "$IGN/b/repo.git" "$IGN/b/wt/two" "$IGN/solo-worktrees/x"
output=$("$WT" ignore --print "$IGN")
assert_contains "$output" "a/wt/" "ignore detects the first orchestration dir"
assert_contains "$output" "b/wt/" "ignore detects the second orchestration dir"
assert_contains "$output" "solo-worktrees/" "ignore detects a clone-mode sibling tree"
assert_contains "$output" '**/.claude/worktrees/' "ignore always covers native Claude Code worktrees"
assert_file_not_exists "$IGN/.ignore" "--print writes nothing to disk"

# A dir with repo.git but no wt/ is not a worktree host and must not match.
mkdir -p "$IGN/bare-only/repo.git"
output=$("$WT" ignore --print "$IGN")
assert_not_contains "$output" "bare-only/" "ignore skips a bare repo with no wt/ dir"

# Regeneration is idempotent and preserves hand-written rules outside the block.
printf '# handwritten\nscratch/\n' > "$IGN/.ignore"
"$WT" ignore "$IGN" >/dev/null 2>&1
"$WT" ignore "$IGN" >/dev/null 2>&1
assert_contains "$(cat "$IGN/.ignore")" "scratch/" "regeneration preserves user rules"
assert_equals 1 "$(grep -c 'wt ignore >>>' "$IGN/.ignore")" "regeneration leaves exactly one managed block"

# Vault machinery is emitted only where a vault exists.
assert_not_contains "$("$WT" ignore --print "$IGN")" ".obsidian/" "no vault patterns without a vault"
mkdir -p "$IGN/vault/.obsidian"
assert_contains "$("$WT" ignore --print "$IGN")" ".obsidian/" "vault machinery emitted when a vault is present"

output=$("$WT" ignore "$TMP/does-not-exist" 2>&1)
assert_not_equals 0 $? "ignore rejects a missing directory"
assert_contains "$output" "not a directory" "ignore names the missing directory"

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
# Test Suite: pull and git pass-through
# ============================================================
test_suite "pull and git pass-through"

make_remote "$TMP/remote-pull.git"
"$WT" init "$TMP/remote-pull.git" "$TMP/pullproj" >/dev/null 2>&1
cd "$TMP/pullproj" || exit 1

# Advance the remote out-of-band so the layout is stale.
advance_remote() {
    local remote="$1" msg="$2" branch="${3:-}"
    git clone -q "$remote" "$TMP/seed-adv" 2>/dev/null
    if [[ -n "$branch" ]]; then git -C "$TMP/seed-adv" checkout -q -B "$branch" "origin/$branch"; fi
    git -C "$TMP/seed-adv" commit -q --allow-empty -m "$msg"
    git -C "$TMP/seed-adv" push -q origin HEAD
    rm -rf "$TMP/seed-adv"
}

# wt git: verbatim pass-through into the named worktree.
out=$("$WT" git main rev-parse --abbrev-ref HEAD)
assert_equals "main" "$out" "wt git runs in the named worktree"
out=$("$WT" git main log --oneline -1)
assert_contains "$out" "init" "wt git passes flags through verbatim"
"$WT" git main rev-parse --verify --quiet refs/heads/nope >/dev/null 2>&1
assert_not_equals 0 $? "wt git propagates git's exit code"
output=$("$WT" git nope status 2>&1)
assert_not_equals 0 $? "wt git fails on an unknown worktree"
assert_contains "$output" "no such worktree" "wt git names the missing worktree"
output=$("$WT" git --help)
assert_equals 0 $? "wt git --help is wt's help, not a worktree lookup"
assert_contains "$output" "verbatim" "wt git help documents the pass-through"
output=$("$WT" git 2>&1)
assert_not_equals 0 $? "wt git without a name is a usage error"

# wt pull with no name fast-forwards main/ from anywhere in the layout.
advance_remote "$TMP/remote-pull.git" advance-1
remote_tip=$(git --git-dir="$TMP/remote-pull.git" rev-parse HEAD)
feature=$("$WT" add pull-feature 2>/dev/null)
cd "$feature" || exit 1
"$WT" pull >/dev/null 2>&1
assert_equals 0 $? "wt pull succeeds from inside a feature worktree"
assert_equals "$remote_tip" "$(git -C "$TMP/pullproj/main" rev-parse HEAD)" \
    "wt pull default target is main/, fast-forwarded to the remote tip"
cd "$TMP/pullproj" || exit 1

# add pre-fetch: the feature branched AFTER the remote advanced must start
# at the true remote head even though nothing fetched explicitly.
assert_equals "$remote_tip" "$(git -C "$feature" rev-parse HEAD)" \
    "wt add fetches first: new branch starts at the true remote head"

# Dirty main/ is refused.
printf 'dirty\n' >> "$TMP/pullproj/main/.gitignore"
output=$("$WT" pull 2>&1)
assert_not_equals 0 $? "wt pull refuses a dirty main/"
assert_contains "$output" "unstaged changes" "pull names the dirtiness"
git -C "$TMP/pullproj/main" checkout -q -- .gitignore

# A diverged main/ is an error, never an implicit merge.
git -C "$TMP/pullproj/main" commit -q --allow-empty -m local-divergence
advance_remote "$TMP/remote-pull.git" advance-2
output=$("$WT" pull 2>&1)
assert_not_equals 0 $? "wt pull refuses to merge a diverged main/"
assert_contains "$output" "fast-forward" "divergence error names the ff-only policy"
git -C "$TMP/pullproj/main" reset -q --hard origin/main
"$WT" pull >/dev/null 2>&1
assert_equals 0 $? "wt pull recovers once main/ is back on the remote line"

# A branch that was never pushed cannot pull.
output=$("$WT" pull pull-feature 2>&1)
assert_not_equals 0 $? "wt pull fails on a never-pushed branch"
assert_contains "$output" "never pushed" "pull explains the missing origin branch"

# A pushed branch fast-forwards to its own origin ref.
git -C "$feature" push -q origin pull-feature
advance_remote "$TMP/remote-pull.git" feature-advance pull-feature
feature_tip=$(git --git-dir="$TMP/remote-pull.git" rev-parse refs/heads/pull-feature)
"$WT" pull pull-feature >/dev/null 2>&1
assert_equals 0 $? "wt pull works on a named, pushed worktree"
assert_equals "$feature_tip" "$(git -C "$feature" rev-parse HEAD)" \
    "named pull fast-forwards to origin/<branch>"

# ============================================================
# Test Suite: bash completion
# ============================================================
test_suite "bash completion"

# Drive _wt exactly as readline would: set COMP_WORDS/COMP_CWORD, collect
# COMPREPLY. The wt() shim points completion's `wt list --names` at the
# pullproj layout built above.
complete_wt() {
    bash -c '
        wt() { "'"$WT"'" "$@"; }
        cd "'"$TMP"'/pullproj" || exit 1
        source "'"$DOTFILES_DIR"'/shell/completions/wt.bash"
        COMP_WORDS=("$@"); COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 )); COMPREPLY=()
        _wt
        printf "%s\n" "${COMPREPLY[@]}"
    ' -- "$@"
}

out=$(complete_wt wt "")
assert_contains "$out" "pull" "top-level completion offers pull"
assert_contains "$out" "git" "top-level completion offers git"
assert_contains "$out" "container" "top-level completion offers container"
assert_not_contains "$out" "diff-local" "top-level completion drops the absorbed diff-local"

out=$(complete_wt wt container "")
assert_equals "up exec" "${out//$'\n'/ }" "wt container completes its two subcommands"
out=$(complete_wt wt container up "")
assert_contains "$out" "main" "wt container up completes worktree names"

out=$(complete_wt wt sync "")
assert_contains "$out" "--diff" "wt sync offers --diff"
assert_contains "$out" "--all" "wt sync offers --all"
assert_contains "$out" "main" "wt sync offers worktree names"

out=$(complete_wt wt remove main "")
assert_equals "--branch" "$out" "wt remove past the name offers only the flag"

out=$(complete_wt wt pull "")
assert_contains "$out" "main" "wt pull completes main"
assert_contains "$out" "pull-feature" "wt pull completes worktree names"

out=$(complete_wt wt git "")
assert_contains "$out" "main" "wt git completes worktree names at the name position"

# Past the name, without git's own completion loaded, _wt must stay silent
# and exit cleanly rather than offering worktree names to git.
out=$(complete_wt wt git main "")
status=$?
assert_equals 0 "$status" "wt git past the name exits cleanly without git completion"
assert_equals "" "$out" "wt git past the name offers no wt candidates"

# ============================================================
# Test Suite: zsh completion registration
# ============================================================
test_suite "zsh completion registration"

# Registration is a separate failure from the completion's own logic: a healthy
# _wt that compinit never scans leaves `wt <TAB>` on zsh's _files fallback,
# which looks like cwd names. Every link in that chain is checked here, because
# each one has its own way of breaking while the other tests stay green.

# Link one: .zshrc must put the completions dir on fpath BEFORE compinit.
# completions.zsh also sets fpath, but completion.sh sources it after compinit.
zshrc_fpath_line=$(grep -n 'fpath=(' "$DOTFILES_DIR/shell/.zshrc" | head -1 | cut -d: -f1)
zshrc_compinit_line=$(grep -n '^[[:space:]]*compinit' "$DOTFILES_DIR/shell/.zshrc" | head -1 | cut -d: -f1)
assert_not_equals "" "$zshrc_fpath_line" ".zshrc adds the completions dir to fpath itself"
[[ -n "$zshrc_fpath_line" && -n "$zshrc_compinit_line" && \
    "$zshrc_fpath_line" -lt "$zshrc_compinit_line" ]] && ordered=yes || ordered=no
assert_equals "yes" "$ordered" ".zshrc sets fpath before compinit runs"

# Link two: .zshrc scans the dir the installer writes to. The two compute their
# paths independently, so drift in either leaves every other check here passing
# while the completion is dead. Evaluate both expressions instead of comparing
# their text, under set and unset ZDOTDIR to cover the fallback branch too.
expand_expr() {
    if [[ -n "$2" ]]; then
        env -i HOME="$1" ZDOTDIR="$2" bash -c "printf '%s' $3"
    else
        env -i HOME="$1" bash -c "printf '%s' $3"
    fi
}

zshrc_dir_expr=$(grep -m1 '^_comp_dir=' "$DOTFILES_DIR/shell/.zshrc" | cut -d= -f2-)
zshrc_dump_expr=$(grep -m1 '^_comp_dump=' "$DOTFILES_DIR/shell/.zshrc" | cut -d= -f2-)
inst_dir_expr=$(grep -m1 'zsh_dir="' "$DOTFILES_DIR/bootstrap/completions.sh" | sed 's/.*zsh_dir=//')
inst_dump_expr=$(grep -m1 'comp_dump="' "$DOTFILES_DIR/bootstrap/completions.sh" | sed 's/.*comp_dump=//')
assert_not_equals "" "$zshrc_dir_expr" ".zshrc names the completions dir in _comp_dir"
assert_not_equals "" "$inst_dir_expr" "completions.sh names the completions dir in zsh_dir"
assert_not_equals "" "$zshrc_dump_expr" ".zshrc names the dump in _comp_dump"
assert_not_equals "" "$inst_dump_expr" "completions.sh names the dump in comp_dump"

for zdotdir in "" "/probe/zdot"; do
    if [[ -z "$zdotdir" ]]; then label="ZDOTDIR unset"; else label="ZDOTDIR=$zdotdir"; fi
    assert_equals \
        "$(expand_expr /probe/home "$zdotdir" "$inst_dir_expr")/completions" \
        "$(expand_expr /probe/home "$zdotdir" "$zshrc_dir_expr")" \
        ".zshrc and completions.sh agree on the completions dir ($label)"
    assert_equals \
        "$(expand_expr /probe/home "$zdotdir" "$inst_dump_expr")" \
        "$(expand_expr /probe/home "$zdotdir" "$zshrc_dump_expr")" \
        ".zshrc and completions.sh agree on the dump path ($label)"
done

# Link three: a cached dump must not outlive a change to the completions dir.
# `compinit -C` replays the dump without rescanning fpath, so without this the
# fpath entry above does nothing until the daily rebuild -- the installer can
# write _wt and `wt <TAB>` stays broken for a day. Run the real condition text
# rather than a copy, so a rewrite of it cannot pass by staying plausible.
comp_cond=$(grep -m1 '^if \[\[.*_comp_dump' "$DOTFILES_DIR/shell/.zshrc")
assert_not_equals "" "$comp_cond" ".zshrc guards compinit with a rebuild condition"

if command -v zsh >/dev/null 2>&1 && [[ -n "$comp_cond" ]]; then
    # Both dumps are written now, so they stay inside the 24h window and only
    # the dir comparison can decide. The dirs get fixed timestamps rather than
    # creation order: mtime granularity is coarse enough on some filesystems
    # for two consecutive creations to tie. -t CCYYMMDDhhmm is the one touch
    # format GNU, BSD, and busybox all accept.
    mkdir -p "$TMP/cached_dir" "$TMP/stale_dir"
    echo dump > "$TMP/cached_dump"
    echo dump > "$TMP/stale_dump"
    touch -t 202001010000 "$TMP/cached_dir"
    touch -t 203001010000 "$TMP/stale_dir"

    for case_name in cached stale; do
        {
            printf '%s\n' 'setopt EXTENDED_GLOB'
            printf '_comp_dir=%s\n' "$TMP/${case_name}_dir"
            printf '_comp_dump=%s\n' "$TMP/${case_name}_dump"
            printf '%s\n' "$comp_cond" '    print rebuild' 'else' '    print cached' 'fi'
        } > "$TMP/cond_$case_name.zsh"
    done

    assert_equals "cached" "$(zsh -f "$TMP/cond_cached.zsh" 2>/dev/null)" \
        "a fresh dump newer than the completions dir uses the cached path"
    assert_equals "rebuild" "$(zsh -f "$TMP/cond_stale.zsh" 2>/dev/null)" \
        "a completions dir newer than the dump forces a full compinit"
else
    echo "  (zsh not installed -- skipping dump-staleness check)"
fi

# The installer closes the same gap from its side, for shells whose .zshrc
# predates the check and for coarse-mtime filesystems.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
assert_contains "$(cat "$DOTFILES_DIR/bootstrap/completions.sh")" 'rm -f "$comp_dump"' \
    "completions.sh drops the dump after installing completions"

# Link four: carapace ships a colliding `wt` spec (Windows Terminal) and
# mass-registers every spec after our compdef, so the exclusion is what keeps
# the binding. It must live in exports.sh -- completion.sh is too late, it runs
# `carapace _carapace <shell>` itself.
assert_contains "$(cat "$DOTFILES_DIR/shell/exports.sh")" "CARAPACE_EXCLUDES" \
    "exports.sh sets CARAPACE_EXCLUDES"
carapace_in_completion=$(grep -c 'CARAPACE_EXCLUDES' "$DOTFILES_DIR/shell/completion.sh" || true)
assert_equals "0" "$carapace_in_completion" \
    "CARAPACE_EXCLUDES is not set in completion.sh, which runs after carapace init"

# The subshell-local HOME and CARAPACE_EXCLUDES are the point of these two
# checks -- exports.sh must be probed against a controlled environment, and the
# result must not leak back into the suite.
# shellcheck disable=SC2030
carapace_excludes=$(
    export HOME="$TMP/carapace_home"
    source "$DOTFILES_DIR/shell/exports.sh" 2>/dev/null
    printf '%s' "$CARAPACE_EXCLUDES"
)
assert_contains ",$carapace_excludes," ",wt," "sourcing exports.sh excludes the wt spec"

# Pre-existing exclusions are a deliberate user or devcontainer choice; assign
# instead of append and they silently come back.
# shellcheck disable=SC2031
carapace_excludes_kept=$(
    export HOME="$TMP/carapace_home"
    export CARAPACE_EXCLUDES="docker,kubectl"
    source "$DOTFILES_DIR/shell/exports.sh" 2>/dev/null
    source "$DOTFILES_DIR/shell/exports.sh" 2>/dev/null
    printf '%s' "$CARAPACE_EXCLUDES"
)
assert_equals "docker,kubectl,wt" "$carapace_excludes_kept" \
    "exports.sh appends wt to existing excludes and stays idempotent"

# Link five: with the dir on fpath, compinit must actually bind wt to _wt --
# guards the #compdef tag and the filename in shell/completions/_wt.
if command -v zsh >/dev/null 2>&1; then
    comps_wt=$(zsh -f -c "
        mkdir -p '$TMP/zfpath'
        ln -sf '$DOTFILES_DIR/shell/completions/_wt' '$TMP/zfpath/_wt'
        fpath=('$TMP/zfpath' \$fpath)
        autoload -Uz compinit
        compinit -u -d '$TMP/zcompdump'
        print -r -- \${_comps[wt]}
    " 2>/dev/null)
    assert_equals "_wt" "$comps_wt" "compinit binds wt to _wt when the dir is on fpath"
else
    echo "  (zsh not installed -- skipping compinit binding check)"
fi

# ============================================================
# Summary
# ============================================================
print_test_summary
