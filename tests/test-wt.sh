#!/usr/bin/env bash
# Tests for bin/wt -- worktree operations for the agentic dev environment.
#
# Exercises both layouts against real (temporary) git repositories:
# orchestration mode (bare repo.git + local/ + state/ + wt/) and clone mode
# (sibling <repo>-worktrees/). The ignore-validation security invariant is
# tested first: provisioning must hard-fail on a non-ignored destination.

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WT="$ROOT/bin/wt"

source "$SCRIPT_DIR/test-framework.sh"

TMP="$(mktemp -d)"
# git reports worktree paths with symlinks resolved (docs/wt-maintenance.md),
# and on macOS mktemp returns /var/... which is a symlink to /private/var/...,
# so unresolved expectations would never match wt's output. Resolve once here.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_NOSYSTEM=1
# The host shell may export these (a dotfiles setup does); dotfiles_repo
# reads both, so a leaked value flips its precedence tests.
unset WT_DOTFILES_REPOSITORY DOTFILES_DIR
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$TMP/home"
# An exported XDG dir would keep pointing at the real home: install.sh and
# fish both resolve their data dir through it before falling back to HOME.
unset XDG_DATA_HOME XDG_CONFIG_HOME
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
assert_contains "$output" "Usage: wt add <name|pr:N> [base]" "wt add --help prints add's usage"
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
assert_contains "$output" "usage: wt add <name|pr:N> [base]" "arity error shows the synopsis"

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

# A branch that exists on the remote before init: the bare clone copies it
# into refs/heads/* with no upstream, exercising add's attach path below.
git clone -q "$TMP/remote-orch.git" "$TMP/seed-inherited" 2>/dev/null
git -C "$TMP/seed-inherited" switch -q -c inherited
git -C "$TMP/seed-inherited" commit -q --allow-empty -m "feat: inherited"
git -C "$TMP/seed-inherited" push -q origin inherited
rm -rf "$TMP/seed-inherited"

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

# Bare clones configure no upstream for any branch, which would make a plain
# `git pull` in main/ fail with "no tracking information".
main_merge=$(git --git-dir="$TMP/proj/repo.git" config --get branch.main.merge)
assert_equals "refs/heads/main" "$main_merge" \
    "init sets an upstream for the default branch (bare clones have none)"

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

# Attaching to a branch the bare clone brought along must adopt
# origin/<branch>, for the same "no tracking information" reason as main/.
"$WT" add inherited >/dev/null 2>&1
inherited_merge=$(git --git-dir="$TMP/proj/repo.git" config --get branch.inherited.merge)
assert_equals "refs/heads/inherited" "$inherited_merge" \
    "attaching to a clone-inherited branch adopts origin/<branch> as upstream"
"$WT" remove inherited >/dev/null 2>&1

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
# Test Suite: cwd-sensitive defaults
# ============================================================
test_suite "cwd-sensitive defaults"

cd "$dest" || exit 1

# go and path are the deliberate exceptions: from inside a worktree their
# bare form still answers "where is the stable checkout".
assert_equals "$TMP/proj/main" "$("$WT" path 2>/dev/null)" \
    "path keeps meaning the stable checkout from inside a worktree"
assert_equals "$TMP/proj/main" "$("$WT" go 2>/dev/null)" \
    "go keeps meaning the stable checkout from inside a worktree"

# sync acts on a tree, so it defaults the other way. Clearing the file from
# both trees is what makes the assertion two-sided: the one you are in comes
# back, the one you are not in does not.
rm -f "$dest/.env.shared" "$TMP/proj/main/.env.shared"
"$WT" sync >/dev/null 2>&1
assert_equals 0 $? "bare sync from inside a worktree succeeds"
assert_file_exists "$dest/.env.shared" "bare sync provisions the worktree you are standing in"
assert_file_not_exists "$TMP/proj/main/.env.shared" \
    "bare sync from inside a worktree leaves main alone"

# --config resolves against the target and fails before the docker check, so
# the path in the error names whichever worktree was chosen.
output=$("$WT" container exec --config nope.json -- true 2>&1)
assert_not_contains "$output" "usage: wt container" \
    "container exec no longer needs a name: -- already separates the arguments"
assert_contains "$output" "$dest/nope.json" \
    "container exec with no name resolves the worktree you are standing in"

mkdir -p "$dest/nested/deeper"
cd "$dest/nested/deeper" || exit 1
output=$("$WT" container exec --config nope.json -- true 2>&1)
assert_contains "$output" "$dest/nope.json" "a subdirectory resolves to the same worktree"
rm -rf "$dest/nested"

# Outside every worktree there is nothing to infer, so the stable checkout
# stands in -- the orchestration root, local/ and state/ all count as outside.
cd "$TMP/proj" || exit 1
output=$("$WT" container exec --config nope.json -- true 2>&1)
assert_contains "$output" "$TMP/proj/main/nope.json" \
    "outside every worktree, container exec falls back to the stable checkout"
output=$("$WT" container up --config nope.json 2>&1)
assert_contains "$output" "$TMP/proj/main/nope.json" "container up shares the same default"
cd "$TMP/proj/local" || exit 1
output=$("$WT" container exec --config nope.json -- true 2>&1)
assert_contains "$output" "$TMP/proj/main/nope.json" "local/ counts as outside every worktree"

cd "$TMP/proj" || exit 1
"$WT" sync main >/dev/null 2>&1
assert_file_exists "$TMP/proj/main/.env.shared" "a named sync restores the stable checkout"

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

# --config parses before any docker/CLI requirement: a missing value is a
# usage error, an unknown flag names itself, and a missing file dies with
# the resolved path.
output=$("$WT" container up provisioned --config 2>&1)
assert_not_equals 0 $? "container up --config without a value is a usage error"
assert_contains "$output" "usage: wt container" "missing --config value prints the synopsis"
output=$("$WT" container up provisioned --bogus 2>&1)
assert_not_equals 0 $? "container up rejects unknown options"
assert_contains "$output" "unknown option" "unknown container option names itself"
output=$("$WT" container up provisioned --config .devcontainer/nope/devcontainer.json 2>&1)
assert_not_equals 0 $? "container up fails on a missing config file"
assert_contains "$output" "no such devcontainer config" "missing config is reported before the docker check"
output=$("$WT" container exec provisioned --config .devcontainer/nope/devcontainer.json -- true 2>&1)
assert_not_equals 0 $? "container exec fails on a missing config file"
assert_contains "$output" "no such devcontainer config" "exec validates --config like up"
output=$("$WT" container exec provisioned --config -- true 2>&1)
assert_not_equals 0 $? "container exec --config without a value is a usage error"
assert_contains "$output" "usage: wt container" "exec missing --config value prints the synopsis"

# A relative --config resolves against the worktree, not the cwd: the file
# exists only under the worktree, so getting past config validation (to the
# docker/CLI gate) proves the resolution base.
mkdir -p "$TMP/proj/wt/provisioned/.devcontainer/ci"
printf '{}' > "$TMP/proj/wt/provisioned/.devcontainer/ci/devcontainer.json"
output=$("$WT" container up provisioned --config .devcontainer/ci/devcontainer.json 2>&1)
assert_not_contains "$output" "no such devcontainer config" "relative --config resolves against the worktree"

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
# Test Suite: dotfiles repository resolution (container up)
# ============================================================
test_suite "dotfiles repository resolution"

# dotfiles_repo precedence: explicit override, then DOTFILES_DIR, then ~/.dotfiles.
out=$(DOTFILES_DIR="$TMP/slugproj" bash -c "source '$WT' && dotfiles_repo")
assert_contains "$out" "remote-slug.git" "dotfiles_repo honors DOTFILES_DIR checkouts"
out=$(WT_DOTFILES_REPOSITORY="https://example.com/df.git" DOTFILES_DIR="$TMP/slugproj" \
    bash -c "source '$WT' && dotfiles_repo")
assert_equals "https://example.com/df.git" "$out" "explicit WT_DOTFILES_REPOSITORY wins over DOTFILES_DIR"
out=$(DOTFILES_DIR='' WT_DOTFILES_REPOSITORY='' bash -c "source '$WT' && dotfiles_repo")
assert_equals "" "$out" "no dotfiles checkout yields an empty repo (flag omitted)"

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

# A failing post-* hook keeps the worktree -- setup is retryable -- but the
# failure must reach the exit status, or an agent proceeds against a tree it
# believes is configured.
printf '#!/usr/bin/env bash\nexit 1\n' > local/hooks/post-sync
chmod +x local/hooks/post-sync
"$WT" sync hooked >/dev/null 2>&1
assert_equals 1 $? "failing post-sync hook fails the command"
assert_file_exists "$dest/.env.worktree" "failing post-sync hook still leaves the worktree provisioned"
rm -f local/hooks/post-sync

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
printf 'PROJECT_ID=renamed\n' > "$dest/.worktree.conf"
"$WT" sync hooked >/dev/null 2>&1
assert_contains "$(cat "$dest/.env.worktree")" "COMPOSE_PROJECT_NAME=renamed-hooked" \
    "sync regenerates env when project config changes"

# A checkout-controlled conf with a bad port range must warn, not abort.
printf 'PORT_RANGE_START=abc\nPORT_RANGE_END=99xx\n' > "$dest/.worktree.conf"
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

# wt pull with no name targets the worktree it is run from. pull-feature was
# never pushed, so there is nothing to fast-forward it to -- and main/ has to
# be left exactly where it was, which is the whole point of the change.
advance_remote "$TMP/remote-pull.git" advance-1
remote_tip=$(git --git-dir="$TMP/remote-pull.git" rev-parse HEAD)
feature=$("$WT" add pull-feature 2>/dev/null)
main_before=$(git -C "$TMP/pullproj/main" rev-parse HEAD)
cd "$feature" || exit 1
output=$("$WT" pull 2>&1)
assert_not_equals 0 $? "bare pull targets the worktree it is run from, not main"
assert_contains "$output" "no origin/pull-feature" \
    "pull names the branch it found no counterpart for"
assert_equals "$main_before" "$(git -C "$TMP/pullproj/main" rev-parse HEAD)" \
    "bare pull from inside a worktree leaves main/ untouched"

# A named target still wins regardless of where it is run from.
"$WT" pull main >/dev/null 2>&1
assert_equals 0 $? "wt pull main succeeds from inside another worktree"
assert_equals "$remote_tip" "$(git -C "$TMP/pullproj/main" rev-parse HEAD)" \
    "a named target is honoured regardless of cwd"
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

# --all fetches once and sweeps every registered worktree. A branch with no
# origin counterpart is the normal state of a task worktree, so it is counted
# and skipped -- failing on it would make the sweep useless on any real
# layout, where most trees have never been pushed.
advance_remote "$TMP/remote-pull.git" advance-3
output=$("$WT" pull --all 2>&1)
assert_equals 0 $? "pull --all succeeds when a worktree has no origin branch"
assert_contains "$output" "no origin/pull-feature" "pull --all names the skipped branch"
assert_contains "$output" "1 with no origin branch" "pull --all counts what it skipped"
assert_equals "$(git --git-dir="$TMP/remote-pull.git" rev-parse HEAD)" \
    "$(git -C "$TMP/pullproj/main" rev-parse HEAD)" "pull --all fast-forwards main"

# A dirty tree is a real refusal and must fail the command, but only after
# the rest of the sweep has run.
printf 'dirty\n' >> "$TMP/pullproj/main/.gitignore"
output=$("$WT" pull --all 2>&1)
assert_not_equals 0 $? "pull --all fails when a worktree refuses"
assert_contains "$output" "unstaged changes" "pull --all names the refusing tree"
assert_contains "$output" "could not be fast-forwarded" "pull --all summarises the failure"
git -C "$TMP/pullproj/main" checkout -q -- .gitignore

output=$("$WT" pull --all pull-feature 2>&1)
assert_not_equals 0 $? "pull --all with a name is a usage error"
output=$("$WT" pull --bogus 2>&1)
assert_not_equals 0 $? "pull rejects an unknown option"
assert_contains "$output" "unknown option" "pull names the offending flag"

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
        source "'"$ROOT"'/completions/wt.bash"
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
assert_contains "$out" "--config" "wt container up offers --config at the name position"
out=$(complete_wt wt container up main "")
assert_equals "--config" "$out" "wt container up past the name offers only --config"
out=$(complete_wt wt container exec main -- tool "")
assert_equals "" "$out" "container completion stays silent past --"

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

# With the dir on fpath, compinit must actually bind wt to _wt --
# guards the #compdef tag and the filename in completions/_wt.
if command -v zsh >/dev/null 2>&1; then
    comps_wt=$(zsh -f -c "
        mkdir -p '$TMP/zfpath'
        ln -sf '$ROOT/completions/_wt' '$TMP/zfpath/_wt'
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
# Test Suite: shell-init
# ============================================================
test_suite "shell-init"

"$WT" shell-init >/dev/null 2>&1
assert_not_equals 0 $? "shell-init without a shell is a usage error"
output=$("$WT" shell-init tcsh 2>&1)
assert_not_equals 0 $? "shell-init rejects a shell it has no integration for"
assert_contains "$output" "unsupported shell" "shell-init names the unsupported shell"

# The function resolves the executable through PATH ('command wt'), so the
# checkout's bin/ goes first. Each probe prints what the interactive user
# would observe: the cwd after the call, or the passed-through output.
shell_init_probe() {
    local shell="$1" body="$2" load
    # shellcheck disable=SC2016  # the expansions are for the probed shell, not this one
    case "$shell" in
        fish) load='wt shell-init fish | source' ;;
        *)    load='eval "$(wt shell-init '"$shell"')"' ;;
    esac
    PATH="$ROOT/bin:$PATH" "$shell" "${@:3}" -c '
        cd "'"$TMP"'/pullproj" || exit 1
        '"$load"'
        '"$body"'
    ' 2>/dev/null
}

shell_init_suite() {
    # shellcheck disable=SC2016  # expanded by the probed shell, not this one
    local shell="$1" last_status='$?'; shift
    # shellcheck disable=SC2016
    [[ "$shell" != "fish" ]] || last_status='$status'
    assert_equals "$feature" "$(shell_init_probe "$shell" 'wt go pull-feature; pwd -P' "$@")" \
        "$shell: wt go changes into the worktree"
    assert_equals "$feature" "$(shell_init_probe "$shell" 'wt go pull-f; pwd -P' "$@")" \
        "$shell: wt go resolves a prefix"
    assert_equals "$TMP/pullproj" "$(shell_init_probe "$shell" 'wt go no-such-tree; pwd -P' "$@")" \
        "$shell: a failed lookup leaves the cwd alone"
    assert_equals "1" "$(shell_init_probe "$shell" "wt go no-such-tree; echo $last_status" "$@")" \
        "$shell: a failed lookup keeps the executable's exit status"
    output=$(shell_init_probe "$shell" 'wt go --help; pwd -P' "$@")
    assert_contains "$output" "Usage: wt go" "$shell: wt go --help passes the help text through"
    assert_contains "$output" "$TMP/pullproj" "$shell: wt go --help does not change directory"
    assert_contains "$(shell_init_probe "$shell" 'wt list --names' "$@")" "pull-feature" \
        "$shell: other commands pass straight through"
    assert_contains "$(shell_init_probe "$shell" 'wt doctor 2>&1' "$@")" "shell integration: loaded" \
        "$shell: doctor sees the function's marker"
}

shell_init_suite bash --noprofile --norc
assert_contains "$(shell_init_probe bash 'complete -p wt' --noprofile --norc)" "_wt" \
    "bash: shell-init registers completion"

if command -v zsh >/dev/null 2>&1; then
    shell_init_suite zsh -f
    # shellcheck disable=SC2016  # the expansions are for zsh, not this shell
    comps_wt=$(shell_init_probe zsh '
        autoload -Uz compinit
        compinit -u -d "'"$TMP"'/zcompdump-before"
        print -r -- ${_comps[wt]}' -f)
    assert_equals "_wt" "$comps_wt" "zsh: shell-init before compinit gets wt bound through fpath"
    comps_wt=$(PATH="$ROOT/bin:$PATH" zsh -f -c '
        autoload -Uz compinit
        compinit -u -d "'"$TMP"'/zcompdump-after"
        eval "$(wt shell-init zsh)"
        print -r -- ${_comps[wt]}' 2>/dev/null)
    assert_equals "_wt" "$comps_wt" "zsh: shell-init after compinit binds wt directly"
else
    echo "  (zsh not installed -- skipping zsh shell-init checks)"
fi

if command -v fish >/dev/null 2>&1; then
    shell_init_suite fish
    assert_contains "$(shell_init_probe fish 'complete -C"wt go pull-f"')" "pull-feature" \
        "fish: shell-init registers completion"
    assert_contains "$(shell_init_probe fish 'complete -C"wt shell-init "')" "fish" \
        "fish: completion offers the shell-init shells"
else
    echo "  (fish not installed -- skipping fish shell-init checks)"
fi

# Without the function, go still prints only the path on stdout, and the
# hint stays off stderr unless stdout is a terminal -- cd "$(wt go x)" in a
# script must not start talking.
output=$(cd "$TMP/pullproj" && "$WT" go pull-feature 2>&1)
assert_equals "$feature" "$output" "go through a pipe prints the path and nothing else"
assert_contains "$(cd "$TMP/pullproj" && "$WT" doctor 2>&1)" "shell integration not loaded" \
    "doctor notes a missing shell function"
(cd "$TMP/pullproj" && "$WT" doctor >/dev/null 2>&1)
assert_equals 0 $? "a missing shell function never fails doctor"

# A pty is the only way to give go a terminal on stdout; util-linux script
# provides one, and BSD script takes different arguments. script runs its
# command through $SHELL, so the shell under test is set inside the pty.
if script --version 2>/dev/null | grep -q util-linux; then
    hint_probe() {
        (cd "$TMP/pullproj" && SHELL=/bin/sh \
            script -qec "SHELL='$1' WT_SHELL_INTEGRATION='$2' '$WT' go pull-feature" /dev/null 2>&1)
    }
    output=$(hint_probe /bin/zsh "")
    assert_contains "$output" "$feature" "go at a terminal still prints the path"
    # shellcheck disable=SC2016  # the literal line the user is told to paste
    assert_contains "$output" 'eval "$(wt shell-init zsh)"' "go at a terminal names the zsh line to add"
    assert_contains "$(hint_probe /usr/bin/fish "")" "wt shell-init fish | source" \
        "go at a terminal names the fish line to add"
    assert_contains "$(hint_probe /bin/tcsh "")" "shell-init --help" \
        "go at a terminal points an unsupported shell at the help"
    assert_not_contains "$(hint_probe /bin/zsh 1)" "shell-init" \
        "go called by the shell function stays quiet"
else
    echo "  (util-linux script not available -- skipping terminal hint checks)"
fi

# ============================================================
# Test Suite: install.sh
# ============================================================
test_suite "install.sh"

install_probe() {
    SHELL="$1" PREFIX="$2" bash "$ROOT/install.sh" 2>&1
}

output=$(install_probe /bin/zsh "$TMP/prefix")
assert_equals 0 $? "install.sh succeeds into an empty PREFIX"
# shellcheck disable=SC2016  # the literal line the user is told to paste
assert_contains "$output" 'eval "$(wt shell-init zsh)"' "install.sh prints the zsh line"
assert_symlink "$TMP/prefix/share/fish/vendor_functions.d/wt.fish" "$ROOT/functions/wt.fish" \
    "install.sh links the fish function"
assert_symlink "$TMP/prefix/share/fish/vendor_completions.d/wt.fish" "$ROOT/completions/wt.fish" \
    "install.sh links the fish completion"
# shellcheck disable=SC2016  # the literal line the user is told to paste
assert_contains "$(install_probe /bin/bash "$TMP/prefix")" 'eval "$(wt shell-init bash)"' \
    "install.sh prints the bash line"
assert_contains "$(install_probe /usr/bin/fish "$TMP/prefix")" "wt shell-init fish | source" \
    "install.sh prints the fish line when PREFIX is outside fish's data dir"
output=$(install_probe /usr/bin/fish "$HOME/.local")
assert_contains "$output" "on its own" "install.sh tells a default-PREFIX fish user nothing is left to do"
assert_not_contains "$output" "bashrc" "install.sh never points a fish user at ~/.bashrc"
assert_not_contains "$(install_probe /bin/tcsh "$TMP/prefix")" "bashrc" \
    "install.sh never points an unsupported shell at ~/.bashrc"

# The vendor dirs are on fish's default search paths, so a default-PREFIX
# install needs no config.fish line at all.
if command -v fish >/dev/null 2>&1; then
    output=$(PATH="$HOME/.local/bin:$PATH" fish -c '
        cd "'"$TMP"'/pullproj"; or exit 1
        wt go pull-feature
        pwd -P
        complete -C"wt shell-init "' 2>/dev/null)
    assert_contains "$output" "$feature" "fish autoloads the function from the vendor dir"
    assert_contains "$output" "zsh" "fish autoloads the completion from the vendor dir"
else
    echo "  (fish not installed -- skipping fish vendor dir checks)"
fi

# ============================================================
# Test Suite: version and rename-aware output
# ============================================================
test_suite "version and rename-aware output"

assert_contains "$("$WT" version)" "wt " "version prints the name and number"
assert_contains "$("$WT" version --json)" '"version"' "version --json carries a version field"
assert_contains "$("$WT" version --json)" '"path"' "version --json names the resolved executable"
assert_contains "$("$WT" --version)" "wt " "--version is accepted as a flag"

# A renamed copy must not tell the user to run a command they do not have.
cp "$WT" "$TMP/wtx"
assert_contains "$("$TMP/wtx" --help)" "Usage: wtx" "a renamed executable names itself in usage"
assert_contains "$("$TMP/wtx" nope 2>&1)" "see 'wtx --help'" "a renamed executable names itself in errors"
# argv0 reaches sed as a replacement string, so it must not be able to inject.
assert_contains "$(WT_NAME='a/b' "$WT" --help)" "Usage: wt" "an unsafe WT_NAME falls back to wt"

# ============================================================
# Test Suite: port blocks
# ============================================================
test_suite "port blocks"

# wt carries `set -e`, which sourcing imports; without set +e the probe shell
# dies on the first non-zero return instead of reporting it.
pcheck() { bash -c "source '$WT'; set +e; $1"; }

# Port 1 is privileged and nothing in the test environment listens there.
assert_equals "1" "$(pcheck 'port_in_use 1 >/dev/null 2>&1; echo $?')" \
    "port_in_use reports a port nothing listens on as free"
# block_free must treat both registry shapes as occupied: the two-column rows
# written before ranges existed, and the current three-column ones.
printf 'old\t3100\nnew\t3200\t3209\n' > "$TMP/ports.tsv"
assert_equals "1" "$(pcheck "block_free 3100 5 '$TMP/ports.tsv' >/dev/null 2>&1; echo \$?")" \
    "a legacy single-port row still blocks its block"
assert_equals "1" "$(pcheck "block_free 3205 5 '$TMP/ports.tsv' >/dev/null 2>&1; echo \$?")" \
    "an overlapping range blocks"
assert_equals "0" "$(pcheck "block_free 3400 5 '$TMP/ports.tsv' >/dev/null 2>&1; echo \$?")" \
    "a free block is free"

# ============================================================
# Test Suite: link provisioning, cache sharing, JSON, hooks
# ============================================================
test_suite "provisioning modes and structured output"

make_remote "$TMP/r2.git"
# Seed a project whose .gitignore legalises the provisioning destinations and
# whose tracked conf asks for a cache path and a small port block.
seed="$TMP/seed2"
git clone -q "$TMP/r2.git" "$seed" 2>/dev/null
printf '.env\n.env.*\nnode_modules/\nshared.txt\nlinked.txt\n' > "$seed/.gitignore"
printf 'CACHE_PATHS=node_modules\nPORT_BLOCK_SIZE=4\n' > "$seed/.worktree.conf"
git -C "$seed" add -A && git -C "$seed" commit -q -m conf && git -C "$seed" push -q origin HEAD
rm -rf "$seed"

"$WT" init "$TMP/r2.git" "$TMP/p2" >/dev/null 2>&1
cd "$TMP/p2" || exit 1
printf 'shared\n' > local/shared/shared.txt
printf 'linked\n' > local/link/linked.txt
mkdir -p main/node_modules && printf 'cached\n' > main/node_modules/pkg.txt

out=$("$WT" add feat --json 2>/dev/null)
d="$TMP/p2/wt/feat"
assert_contains "$out" '"port_start"' "add --json reports the allocated port block"
assert_contains "$out" '"branch":"feat"' "add --json reports the branch"
assert_file_exists "$d/shared.txt" "local/shared is copied"
assert_is_symlink "$d/linked.txt" "local/link is symlinked, not copied"
assert_file_exists "$d/node_modules/pkg.txt" "a declared cache path is shared into the worktree"
assert_not_symlink "$d/node_modules" "cache sharing copies by default rather than linking"
assert_contains "$(cat "$d/.env.worktree")" "WORKTREE_PORT_END" "the env carries the port block bounds"

# PORT_BLOCK_SIZE=4, so the first block allocated runs 3100-3103 rather than
# handing out a single port.
assert_contains "$(cat state/ports.tsv)" "3100	3103" "the block size from the tracked conf is honoured"

# sync applies the same cache sharing as add, so a worktree that predates the
# conf -- or one whose cache was deleted -- is brought up to date in place
# rather than being recreated.
rm -rf "$d/node_modules"
"$WT" sync feat >/dev/null 2>&1
assert_equals 0 $? "wt sync feat succeeds"
assert_file_exists "$d/node_modules/pkg.txt" "sync fills a cache path the worktree is missing"

# Fill-only: a cache the worktree has since built for itself is left alone,
# which is what makes running sync repeatedly safe.
printf 'built-here\n' > "$d/node_modules/pkg.txt"
"$WT" sync feat >/dev/null 2>&1
assert_equals "built-here" "$(cat "$d/node_modules/pkg.txt")" \
    "sync never replaces a cache the worktree already has"

rm -rf "$d/node_modules"
"$WT" sync --all >/dev/null 2>&1
assert_equals 0 $? "wt sync --all succeeds"
assert_file_exists "$d/node_modules/pkg.txt" "sync --all shares caches into every worktree"
assert_not_symlink "$d/node_modules" "sync honours CACHE_MODE=copy just as add does"

assert_contains "$("$WT" list --json 2>/dev/null)" '"worktrees"' "list --json emits a worktrees array"
assert_not_contains "$("$WT" list --names 2>/dev/null)" "repo.git" \
    "the bare repo is never reported as a worktree"
assert_contains "$("$WT" doctor --json 2>/dev/null)" '"checks"' "doctor --json emits its checks"

# A cache path the project does not ignore is refused, exactly like local/.
# The conf is tracked, so the change has to reach origin before a new worktree
# checks it out.
printf 'CACHE_PATHS=notignored\n' > main/.worktree.conf
git -C main add -A >/dev/null 2>&1
git -C main commit -q -m "chore: point cache at a non-ignored path" >/dev/null 2>&1
git -C main push -q origin HEAD >/dev/null 2>&1
mkdir -p main/notignored && printf 'x\n' > main/notignored/f
out=$("$WT" add cache-bad 2>&1)
assert_contains "$out" "refusing to share non-ignored cache path" \
    "a non-ignored cache path is refused"
assert_file_not_exists "$TMP/p2/wt/cache-bad" "a refused cache path rolls the worktree back"

# Restore the conf: it is tracked, so leaving it pointing at a non-ignored
# path would make every later `add` in this fixture fail the same way.
printf 'CACHE_PATHS=node_modules\nPORT_BLOCK_SIZE=4\n' > main/.worktree.conf
rm -rf main/notignored
git -C main add -A >/dev/null 2>&1
git -C main commit -q -m "chore: restore cache conf" >/dev/null 2>&1
git -C main push -q origin HEAD >/dev/null 2>&1

# pre-* hooks gate the operation; post-* hooks report failure without
# destroying the worktree.
mkdir -p local/hooks
printf '#!/usr/bin/env bash\nexit 1\n' > local/hooks/pre-add
chmod +x local/hooks/pre-add
"$WT" add blocked >/dev/null 2>&1
assert_equals 1 $? "a failing pre-add hook fails the command"
assert_file_not_exists "$TMP/p2/wt/blocked" "a failing pre-add hook creates no worktree"
rm -f local/hooks/pre-add

# pr:/mr: argument handling that needs no forge round-trip.
assert_contains "$("$WT" add pr:abc 2>&1)" "not a request number" \
    "a non-numeric request is rejected before any forge call"
assert_contains "$(WT_FORGE=bitbucket "$WT" add pr:1 2>&1)" "WT_FORGE must be" \
    "an unknown WT_FORGE is rejected"

# ============================================================
# Test Suite: post-pull, post-remove, async hooks
# ============================================================
test_suite "post-pull, post-remove, async hooks"

printf '#!/usr/bin/env bash\necho pulled >> "%s/state/pulllog"\n' "$TMP/p2" > local/hooks/post-pull
chmod +x local/hooks/post-pull
"$WT" pull main >/dev/null 2>&1
assert_contains "$(cat state/pulllog 2>/dev/null)" "pulled" "post-pull runs after a fast-forward"
rm -f local/hooks/post-pull

# The async form detaches and logs. A blocking hook writes to the caller's
# stderr and never creates a log file, so the file's existence is what proves
# the async path was taken.
printf '#!/usr/bin/env bash\nsleep 1\necho async-done\n' > local/hooks/post-add.async
chmod +x local/hooks/post-add.async
"$WT" add asyncwt >/dev/null 2>&1
assert_equals 0 $? "an async hook does not fail the command"
logf="$TMP/p2/state/hooks/asyncwt-post-add.log"
tries=0
while [[ ! -s "$logf" && $tries -lt 60 ]]; do sleep 0.2; tries=$((tries + 1)); done
assert_contains "$(cat "$logf" 2>/dev/null)" "async-done" \
    "the async hook's output is captured under state/hooks"
rm -f local/hooks/post-add.async

printf '#!/usr/bin/env bash\nexit 0\n' > local/hooks/pre-add.async
chmod +x local/hooks/pre-add.async
assert_contains "$("$WT" add asyncpre 2>&1)" "pre-* hooks cannot run asynchronously" \
    "an async pre-hook is refused, because a gate that does not block is not a gate"
rm -f local/hooks/pre-add.async

# post-remove fires from the root, after teardown, with the worktree gone.
# shellcheck disable=SC2016  # $1 and $(basename) are for the hook script, not this shell
printf '#!/usr/bin/env bash\nprintf "removed:%%s\\n" "$(basename "$1")" >> "%s/state/removelog"\n' \
    "$TMP/p2" > local/hooks/post-remove
chmod +x local/hooks/post-remove
"$WT" remove feat >/dev/null 2>&1
assert_equals 0 $? "remove succeeds with a post-remove hook"
assert_contains "$(cat state/removelog 2>/dev/null)" "removed:feat" \
    "post-remove runs after the worktree is gone"
assert_file_not_exists "$TMP/p2/wt/feat" "post-remove does not resurrect the worktree"
rm -f local/hooks/post-remove

cd "$TMP" || exit 1

# ============================================================
# Test Suite: escaping, port probing, symlink resolution
# ============================================================
test_suite "escaping, port probing, symlink resolution"

# A path or a branch name may legally contain either of these, and an
# unescaped one terminates the JSON string early -- every --json consumer
# then sees malformed output rather than an error.
esc_bs="$(bash -c "source '$WT'; json_escape 'a\\b'")"
assert_equals 'a\\b' "$esc_bs" "json_escape doubles a backslash"
esc_q="$(bash -c "source '$WT'; json_escape 'say \"hi\"'")"
assert_equals 'say \"hi\"' "$esc_q" "json_escape escapes a double quote"

# The other C0 bytes are equally illegal raw inside a JSON string and have no
# short escape, so they have to go out as \u00XX. A path may legally hold one.
esc_ctl="$(bash -c "source '$WT'; json_escape \$'a\x08b'")"
assert_equals 'a\u0008b' "$esc_ctl" "json_escape encodes a control byte as an escaped code point"
if command -v jq >/dev/null 2>&1; then
    printf '{"p":"%s"}' "$esc_ctl" | jq -e . >/dev/null 2>&1
    assert_equals 0 $? "a control byte survives as parseable JSON"
fi

if command -v jq >/dev/null 2>&1; then
    # End to end: git permits a double quote in a branch name.
    cd "$TMP/p2" || exit 1
    "$WT" add 'quote"branch' >/dev/null 2>&1
    "$WT" list --json 2>/dev/null | jq -e . >/dev/null 2>&1
    assert_equals 0 $? "list --json stays parseable when a branch name contains a quote"

    # The deployed executable is a symlink, so the resolved path is the case
    # that matters and the one version must report.
    ln -sf "$WT" "$TMP/wt-link"
    wt_expected="$(cd -P "$(dirname "$WT")" && pwd)/$(basename "$WT")"
    assert_equals "$wt_expected" "$("$TMP/wt-link" version --json 2>/dev/null | jq -r .path)" \
        "version resolves a symlinked executable back to the real file"
    cd "$TMP" || exit 1
else
    echo "  (jq not installed -- skipping the --json parseability and symlink checks)"
fi

# port_in_use's free branch is covered by the port-block suite; this is the
# branch the probe exists for. Binding a socket needs a helper that is not on
# every platform CI covers, so it skips rather than fails when absent.
probe_port=39871
listener_pid=""
if command -v perl >/dev/null 2>&1; then
    # A deep backlog, because nothing ever accepts: every probe leaves its
    # connection queued, and a backlog of 1 would refuse the second one.
    perl -MIO::Socket::INET -e '
        my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ARGV[0],
                                      Listen => 128, ReuseAddr => 1) or exit 1;
        sleep 30;
    ' "$probe_port" &
    listener_pid=$!
elif command -v socat >/dev/null 2>&1; then
    socat TCP-LISTEN:"$probe_port",bind=127.0.0.1,reuseaddr,fork /dev/null &
    listener_pid=$!
fi

if [[ -n "$listener_pid" ]]; then
    tries=0
    until bash -c "source '$WT'; port_in_use $probe_port" 2>/dev/null || [[ $tries -ge 50 ]]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if bash -c "source '$WT'; port_in_use $probe_port" 2>/dev/null; then
        assert_equals "0" "$(bash -c "source '$WT'; set +e; port_in_use $probe_port; echo \$?")" \
            "port_in_use detects a real listener"
        printf 'other\t1\t2\n' > "$TMP/probe.tsv"
        assert_equals "1" "$(bash -c "source '$WT'; set +e; block_free $probe_port 2 '$TMP/probe.tsv' >/dev/null 2>&1; echo \$?")" \
            "block_free rejects a block containing a listening port"
    else
        echo "  (could not bind $probe_port -- skipping the real-listener probe check)"
    fi
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
else
    echo "  (no perl or socat -- skipping the real-listener probe check)"
fi

# Portable complement: stubbing the probe covers block_free's rejection path
# even where nothing can bind a socket.
printf 'other\t1\t2\n' > "$TMP/probe.tsv"
assert_equals "1" \
    "$(bash -c "source '$WT'; set +e; port_in_use() { [[ \$1 == 3402 ]]; }; block_free 3400 5 '$TMP/probe.tsv' >/dev/null 2>&1; echo \$?")" \
    "block_free rejects a block whose middle port is busy"

# ============================================================
# Test Suite: prune
# ============================================================
test_suite "prune"

cd "$TMP/p2" || exit 1
"$WT" add prunable >/dev/null 2>&1
assert_contains "$("$WT" list --names 2>/dev/null)" "prunable" "the worktree is registered before pruning"

# Deleting the directory outside git leaves the administrative entry behind,
# which is the only thing prune exists to clear.
rm -rf "$TMP/p2/wt/prunable"
assert_contains "$("$WT" list --names 2>/dev/null)" "prunable" \
    "a directory deleted outside git stays registered"

"$WT" prune >/dev/null 2>&1
assert_equals 0 $? "prune succeeds"
assert_not_contains "$("$WT" list --names 2>/dev/null)" "prunable" \
    "prune clears the stale administrative entry"

# prune is git's cleanup, not wt's: it knows nothing about the port registry,
# so a worktree deleted outside `remove` keeps its block. Pinned so the day
# that changes is a deliberate decision rather than a surprise.
assert_contains "$(cat "$TMP/p2/state/ports.tsv")" "prunable" \
    "prune leaves the port block allocated, because only remove releases it"

# ...which is what doctor is for: nothing else compares the registry against
# the worktrees that actually exist, so the pool would erode silently.
out=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "doctor fails while a port reservation is orphaned"
assert_contains "$out" "orphaned port reservation: prunable" \
    "doctor names the orphaned reservation"
assert_contains "$out" "ports.tsv" "doctor points at the registry to fix"

if command -v jq >/dev/null 2>&1; then
    assert_contains "$("$WT" doctor --json 2>/dev/null | jq -r '.checks[].detail')" \
        "orphaned port reservation" "doctor --json carries the orphan finding too"
fi

# Releasing it by hand clears the finding, which proves the check tracks the
# registry rather than reporting unconditionally.
grep -v '^prunable' "$TMP/p2/state/ports.tsv" > "$TMP/p2/state/ports.tsv.tmp"
mv "$TMP/p2/state/ports.tsv.tmp" "$TMP/p2/state/ports.tsv"
assert_contains "$("$WT" doctor 2>&1)" "no orphaned reservations" \
    "doctor reports a clean registry once the block is released"

out=$("$WT" prune extra 2>&1)
assert_not_equals 0 $? "prune rejects an argument"
assert_contains "$out" "usage:" "prune's arity error shows the synopsis"

cd "$TMP" || exit 1

# ============================================================
# Test Suite: request refs, rollback safety, pre-sync under --all
# ============================================================
test_suite "request refs, rollback safety, pre-sync under --all"

cd "$TMP/p2" || exit 1

# A request opened from a fork has no refs/heads/<branch> on origin at all,
# only the forge's request ref. Simulated exactly: the commit is published as
# refs/pull/1/head and under no branch name anywhere.
git -C main commit -q --allow-empty -m "feat: the revision under review"
fork_sha="$(git -C main rev-parse HEAD)"
git -C main push -q origin "HEAD:refs/pull/1/head"
git -C main reset --hard -q HEAD~1

# The origin here is a local path, which no hostname heuristic recognises.
# Installed CLIs are a property of the machine, not the repository, so an
# unrecognised host must demand configuration rather than guess from them.
out=$("$WT" add pr:1 2>&1)
assert_not_equals 0 $? "an unrecognised origin host fails rather than guessing the forge"
assert_contains "$out" "WT_FORGE" "the failure names the configuration that resolves it"

WT_FORGE=github "$WT" add pr:1 >/dev/null 2>&1
assert_equals 0 $? "a request whose branch exists only as a fork ref still resolves"
assert_dir_exists "$TMP/p2/wt/pr-1" "the request worktree is created under a pr-N name"
assert_equals "$fork_sha" "$(git -C "$TMP/p2/wt/pr-1" rev-parse HEAD 2>/dev/null)" \
    "the worktree is pinned to the request head, not to the default branch"
assert_equals "" "$(git --git-dir="$TMP/p2/repo.git" config --get branch.pr-1.merge)" \
    "a request branch gets no upstream (origin has no refs/heads/pr-N to pull)"

# Re-adding a request whose head has moved must not silently reuse the branch
# left behind by an earlier remove: that checks out the revision the request
# used to be, which is the opposite of the guarantee.
git -C main commit -q --allow-empty -m "feat: a newer revision under review"
fork_sha2="$(git -C main rev-parse HEAD)"
git -C main push -q -f origin "HEAD:refs/pull/1/head"
git -C main reset --hard -q HEAD~1
"$WT" remove pr-1 >/dev/null 2>&1   # deliberately without --branch
out=$(WT_FORGE=github "$WT" add pr:1 2>&1)
assert_not_equals 0 $? "re-adding a moved request refuses the stale local branch"
assert_contains "$out" "is now at" "the refusal names both revisions"
assert_contains "$out" "branch -D pr-1" "the refusal prints the command that clears it"

# Once the stale branch is gone the new revision checks out.
git --git-dir="$TMP/p2/repo.git" branch -D pr-1 >/dev/null 2>&1
WT_FORGE=github "$WT" add pr:1 >/dev/null 2>&1
assert_equals "$fork_sha2" "$(git -C "$TMP/p2/wt/pr-1" rev-parse HEAD 2>/dev/null)" \
    "the recreated worktree is at the updated request head"

# [base] cannot mean anything for a request: silently honouring it would
# produce a tree that is not the revision under review.
out=$(WT_FORGE=github "$WT" add pr:1 main 2>&1)
assert_not_equals 0 $? "a request plus an explicit base is refused"
assert_contains "$out" "cannot be combined" "the refusal explains why base is meaningless here"

# Rollback must not delete a branch this invocation did not create. Otherwise
# a bad provisioning path destroys unpushed commits on an existing branch.
git --git-dir="$TMP/p2/repo.git" branch keepme main 2>/dev/null
printf 'x\n' > local/shared/notignored.txt
"$WT" add keepme >/dev/null 2>&1
assert_not_equals 0 $? "add fails when a provisioned file is not gitignored"
assert_file_not_exists "$TMP/p2/wt/keepme" "the half-made worktree is rolled back"
git --git-dir="$TMP/p2/repo.git" show-ref --verify --quiet refs/heads/keepme
assert_equals 0 $? "rollback preserves a branch that already existed"

# The mirror image: a branch this invocation did create is still cleaned up,
# so the guard did not simply disable rollback.
"$WT" add brandnew >/dev/null 2>&1
git --git-dir="$TMP/p2/repo.git" show-ref --verify --quiet refs/heads/brandnew
assert_not_equals 0 $? "rollback still deletes a branch it created itself"
rm -f local/shared/notignored.txt

# pre-sync gates `sync <name>`; it must gate `sync --all` too, or the more
# expansive command is the unguarded one.
mkdir -p local/hooks
printf '#!/usr/bin/env bash\nexit 1\n' > local/hooks/pre-sync
chmod +x local/hooks/pre-sync
out=$("$WT" sync --all 2>&1)
assert_not_equals 0 $? "a failing pre-sync fails sync --all"
assert_contains "$out" "pre-sync hook failed" "sync --all reports which gate refused"
assert_contains "$out" "failed validation" "sync --all still reports an aggregate count"
rm -f local/hooks/pre-sync

cd "$TMP" || exit 1

# ============================================================
# Test Suite: port lock lifecycle
# ============================================================
test_suite "port lock lifecycle"

cd "$TMP/p2" || exit 1
lockpath="$TMP/p2/state/ports.lock"

# The lock is a kernel flock, so the file's continued existence means
# nothing: held or free is the only distinction, and the kernel frees it
# when the holder dies -- any death, including kill -9.
lock_is_free() {
    (flock -n 9) 9>>"$1" 2>/dev/null
}

"$WT" add lockcheck >/dev/null 2>&1
assert_equals "0" "$(lock_is_free "$lockpath"; echo $?)" "a normal run leaves the lock free"

bash -c "source '$WT'; acquire_ports_lock '$lockpath' >/dev/null 2>&1; exit 1" >/dev/null 2>&1
assert_equals "0" "$(lock_is_free "$lockpath"; echo $?)" "a run that exits non-zero leaves the lock free"

# The case no userspace cleanup can cover, and the reason the lock is an
# flock rather than a symlink protocol: SIGKILL runs no handler.
bash -c "source '$WT'; acquire_ports_lock '$lockpath' >/dev/null 2>&1; kill -9 \$\$" >/dev/null 2>&1
assert_equals "0" "$(lock_is_free "$lockpath"; echo $?)" "a run killed with SIGKILL leaves the lock free"

# With no signal traps installed, default disposition terminates the process:
# the command must not carry on mutating state after the caller stops it.
bash -c "source '$WT'; acquire_ports_lock '$lockpath' >/dev/null 2>&1; kill -TERM \$\$; echo SURVIVED" \
    > "$TMP/sigterm.out" 2>&1
sig_status=$?
assert_equals 143 "$sig_status" "SIGTERM yields a signal-derived exit status, not success"
assert_not_contains "$(cat "$TMP/sigterm.out" 2>/dev/null)" "SURVIVED" \
    "the process stops at the signal instead of continuing"
assert_equals "0" "$(lock_is_free "$lockpath"; echo $?)" "a run killed with SIGTERM leaves the lock free"

# Contention. The holder must outlive the acquirer's wait window (flock -w 5),
# or the second acquirer simply waits it out and the refusal is never
# exercised.
# exec, not a plain sleep: modern bash replaces itself with the trailing
# command anyway, but bash 3.2 forks it, and then kill hits the shell while
# the orphaned sleep keeps lock fd 9 open for the full 30 seconds.
bash -c "source '$WT'; acquire_ports_lock '$lockpath' >/dev/null 2>&1; exec sleep 30" &
lock_holder=$!
tries=0
while lock_is_free "$lockpath" && [[ $tries -lt 40 ]]; do sleep 0.05; tries=$((tries + 1)); done

out=$("$WT" doctor 2>&1)
assert_contains "$out" "locked by a running process" "doctor distinguishes live contention"

# Releasing the port block is part of remove's contract, so a remove that
# cannot lock the registry must refuse before destroying anything, and a
# direct release failure must be nonzero and loud rather than a silent
# success that strands the reservation.
out=$("$WT" remove lockcheck 2>&1)
assert_not_equals 0 $? "remove fails when the registry cannot be locked"
assert_contains "$out" "worktree left in place" "the refusal says nothing was removed"
assert_dir_exists "$TMP/p2/wt/lockcheck" "the worktree survives a refused remove"
assert_contains "$(cat state/ports.tsv)" "lockcheck" "the reservation survives a refused remove"

rp_out="$(bash -c "source '$WT'; set +e; release_port '$TMP/p2' lockcheck 2>&1; echo status=\$?")"
assert_contains "$rp_out" "status=1" "release_port propagates a lock failure as nonzero"
assert_contains "$rp_out" "not released" "release_port names the reservation it left behind"

kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
assert_equals "0" "$(lock_is_free "$lockpath"; echo $?)" "the holder's death frees the lock"

out=$("$WT" remove lockcheck 2>&1)
assert_equals 0 $? "remove succeeds once the lock is free"
assert_not_contains "$(cat state/ports.tsv)" "lockcheck" "remove releases the reservation"

# A free block that is not aligned to PORT_RANGE_START must still be found:
# unrelated listeners do not land on wt's block boundaries.
printf 'a\t3100\t3104\nb\t3115\t3119\n' > "$TMP/unaligned.tsv"
assert_equals "0" "$(bash -c "source '$WT'; set +e; block_free 3105 10 '$TMP/unaligned.tsv' >/dev/null 2>&1; echo \$?")" \
    "an unaligned free range is recognised as free"

# A symlink at the lock path is a leftover from the pre-flock scheme; opening
# it would create a stray file named after its owner token, so it is refused
# by name rather than followed.
ln -sfn "999999:never_ran" "$lockpath"
out=$("$WT" add legacyblocked 2>&1)
assert_not_equals 0 $? "a legacy symlink at the lock path fails the command"
assert_contains "$out" "older" "the failure attributes the symlink to the old scheme"
out=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "doctor fails on a legacy symlink lock"
assert_contains "$out" "symlink" "doctor names the legacy symlink"
rm -f "$lockpath"

# Anything else at the lock path that is not a regular file cannot be locked
# and must be reported rather than timed out against.
mkdir -p "$lockpath"
out=$("$WT" add lockdirblocked 2>&1)
assert_not_equals 0 $? "a non-file at the lock path fails the command"
assert_contains "$out" "not a regular file" "the failure names the obstruction"
out=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "doctor fails on a non-file lock path"
assert_contains "$out" "not a regular file" "doctor names the obstruction too"
rmdir "$lockpath"

# ============================================================
# Test Suite: provisioning failure propagation
# ============================================================
test_suite "provisioning failure propagation"

# errexit is disabled inside a function evaluated as a condition, and every
# caller runs these under `if ! ...`, so an unchecked copy failure would fall
# through to `return 0` and report a partial worktree as good.
shimdir="$TMP/shim"
mkdir -p "$shimdir"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shimdir/rsync"
chmod +x "$shimdir/rsync"

printf 'shared\n' > local/shared/shared.txt
# shellcheck disable=SC2031  # the shimmed PATH is deliberate and scoped to this one call
out=$(PATH="$shimdir:$PATH" "$WT" add copyfails 2>&1)
assert_not_equals 0 $? "a failing copy fails add"
assert_file_not_exists "$TMP/p2/wt/copyfails" "a failing copy rolls the worktree back"
assert_not_contains "$(cat state/ports.tsv)" "copyfails" \
    "a rolled-back worktree leaves no port reservation behind"
rm -f "$shimdir/rsync"

# Rollback releases the block directly, which is what keeps a failure between
# allocation and the env write from stranding one.
printf 'stranded\t3900\t3909\n' >> state/ports.tsv
bash -c "source '$WT'; set +e; WT_MODE=orchestration WT_ROOT='$TMP/p2' WT_GIT_DIR='$TMP/p2/repo.git' \
    rollback_add '$TMP/p2/wt/stranded' stranded 0" >/dev/null 2>&1
assert_not_contains "$(cat state/ports.tsv)" "stranded" \
    "rollback releases the slug's port reservation"

cd "$TMP" || exit 1

# ============================================================
# Test Suite: convert
# ============================================================
test_suite "convert"

make_remote "$TMP/convremote.git"
git clone -q "$TMP/convremote.git" "$TMP/convproj" 2>/dev/null
cd "$TMP/convproj" || exit 1

# Local state that must survive the conversion: an ignored env file, a
# wholly-untracked directory, a local-only branch, a stash, and a
# clone-mode worktree in the sibling dir.
printf 'SECRET=1\n' > .env
mkdir -p notes
printf 'todo\n' > notes/todo.txt
git branch local-only
printf '# stash me\n' >> .gitignore
git stash -q
"$WT" add feature >/dev/null 2>&1

output=$("$WT" convert --dry-run 2>&1)
assert_equals 0 $? "convert --dry-run exits 0"
assert_contains "$output" "dry run" "dry-run says nothing changed"
assert_contains "$output" "feature" "dry-run names the worktree it would adopt"
assert_dir_exists "$TMP/convproj/.git" "dry-run leaves .git in place"
assert_command_fails "dry-run creates no repo.git" test -e "$TMP/convproj/repo.git"

# Refusals: dirty tree, non-default branch, detached HEAD.
printf '# dirty\n' >> .gitignore
output=$("$WT" convert 2>&1)
assert_equals 1 $? "convert refuses unstaged changes"
assert_contains "$output" "unstaged changes" "dirty refusal names the reason"
git checkout -q -- .gitignore

git checkout -q -b sidework 2>/dev/null
output=$("$WT" convert 2>&1)
assert_equals 1 $? "convert refuses a non-default checked-out branch"
assert_contains "$output" "check out 'main' first" "branch refusal names the fix"
git checkout -q main
git branch -q -D sidework

git checkout -q --detach
output=$("$WT" convert 2>&1)
assert_equals 1 $? "convert refuses a detached HEAD"
assert_contains "$output" "detached HEAD" "detached refusal names the reason"
git checkout -q main

root_out=$("$WT" convert 2>"$TMP/convert.log")
status=$?
assert_equals 0 "$status" "convert succeeds on a clean clone"
assert_equals "$TMP/convproj" "$root_out" "convert prints the orchestration root"
assert_equals "true" "$(git --git-dir="$TMP/convproj/repo.git" rev-parse --is-bare-repository 2>/dev/null)" \
    "repo.git is the clone's git dir, now bare"
assert_file_exists "$TMP/convproj/main/.gitignore" "tracked files are checked out in main/"
assert_equals "SECRET=1" "$(cat "$TMP/convproj/main/.env" 2>/dev/null)" "ignored .env moved into main/"
assert_file_exists "$TMP/convproj/main/notes/todo.txt" "untracked directory moved into main/"
assert_command_succeeds "local-only branch survives (object db moved, not re-cloned)" \
    git --git-dir="$TMP/convproj/repo.git" show-ref --verify --quiet refs/heads/local-only
assert_command_succeeds "stash survives the conversion" \
    git --git-dir="$TMP/convproj/repo.git" rev-parse --verify refs/stash
assert_dir_exists "$TMP/convproj/wt/feature" "sibling worktree adopted under wt/"
assert_command_succeeds "adopted worktree pointer is repaired" \
    git -C "$TMP/convproj/wt/feature" rev-parse --git-dir
assert_command_fails "emptied sibling worktree dir is removed" test -e "$TMP/convproj-worktrees"
assert_command_fails "staging dir is cleaned up" test -e "$TMP/convproj/.wt-convert-stage"
assert_file_exists "$TMP/convproj/.ignore" "convert writes the root .ignore"
assert_file_exists "$TMP/convproj/wt/feature/.env.worktree" "adopted worktree gets runtime identity"
assert_contains "$(cat "$TMP/convproj/state/ports.tsv" 2>/dev/null)" "feature" \
    "adopted worktree holds a port reservation"
assert_contains "$(cat "$TMP/convert.log")" "moved from" "convert warns that the checkout path changed"

# The converted layout must be indistinguishable from an init-created one.
output=$("$WT" doctor 2>&1)
assert_equals 0 $? "doctor passes on a converted dir"
assert_contains "$output" "mode: orchestration" "converted dir detects as orchestration mode"

dest=$("$WT" add postconv 2>/dev/null)
assert_equals "$TMP/convproj/wt/postconv" "$dest" "add provisions into the converted layout"
"$WT" remove postconv >/dev/null 2>&1

output=$("$WT" convert 2>&1)
assert_equals 1 $? "convert refuses an orchestration dir"
assert_contains "$output" "already an orchestration dir" "re-convert refusal names the reason"

cd "$TMP" || exit 1

# ============================================================
# Test Suite: doctor provisioning checks
# ============================================================
test_suite "doctor provisioning checks"

# A dedicated fixture: these tests deliberately break the conf, the hooks and
# the ignore rules one at a time, and none of that should reach the other
# suites' projects.
make_remote "$TMP/r3.git"
"$WT" init "$TMP/r3.git" "$TMP/p3" >/dev/null 2>&1
cd "$TMP/p3" || exit 1

output=$("$WT" doctor 2>&1)
assert_equals 0 $? "doctor passes on a fresh orchestration dir"
assert_contains "$output" "provisioning: hooks, conf and ignore coverage check out" \
    "doctor reports the provisioning group when it is clean"

# run_hook silently skips a hook that is not executable, which is the whole
# reason this is worth a check.
mkdir -p local/hooks
printf '#!/usr/bin/env bash\nexit 0\n' > local/hooks/post-add
output=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "a non-executable hook fails doctor"
assert_contains "$output" "not executable" "doctor names the non-executable hook"
assert_contains "$output" "chmod +x" "doctor names the fix for it"
chmod +x local/hooks/post-add
"$WT" doctor >/dev/null 2>&1
assert_equals 0 $? "an executable hook passes"

printf '#!/usr/bin/env bash\nexit 0\n' > local/hooks/post-create
chmod +x local/hooks/post-create
assert_contains "$("$WT" doctor 2>&1)" "matches no hook stage" \
    "a hook named for no real stage is reported"
rm -f local/hooks/post-create

# The silent conf failures: read_conf substitutes its default and says
# nothing, so a value that was set and a value that was read differ.
printf 'CACHE_PATHS=node_modules, .venv\n' > main/.worktree.conf
assert_contains "$("$WT" doctor 2>&1)" "CACHE_PATHS is set but no value is read from it" \
    "a space in a conf list is reported rather than silently dropped"

printf '  CACHE_PATHS=node_modules\n' > main/.worktree.conf
assert_contains "$("$WT" doctor 2>&1)" "CACHE_PATHS is set but no value is read from it" \
    "an indented conf key is reported"

printf 'CACHE_PATHS =node_modules\n' > main/.worktree.conf
assert_contains "$("$WT" doctor 2>&1)" "CACHE_PATHS is set but no value is read from it" \
    "a space before the conf separator is reported"

printf 'CACHE_PATHS=\n' > main/.worktree.conf
assert_not_contains "$("$WT" doctor 2>&1)" "CACHE_PATHS is set but" \
    "a deliberately emptied key is a choice, not a finding"

printf 'CACHE_MODE=symlink\n' > main/.worktree.conf
assert_contains "$("$WT" doctor 2>&1)" "CACHE_MODE=symlink is not a mode" \
    "an unrecognised CACHE_MODE is reported instead of quietly meaning copy"

printf 'CACHE_MODE=copy\nCACHE_MODE=link\n' > main/.worktree.conf
assert_contains "$("$WT" doctor 2>&1)" "CACHE_MODE is set 2 times" \
    "a duplicated key notes that the first one wins"

# Ignore coverage: the same rule add and sync enforce, asked ahead of time.
printf 'CACHE_PATHS=node_modules\n' > main/.worktree.conf
mkdir -p main/node_modules
output=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "an unignored cache path fails doctor"
assert_contains "$output" "CACHE_PATHS names 'node_modules/'" \
    "an unignored cache path is reported before add fails on it"

printf 'node_modules/\n' >> main/.gitignore
assert_not_contains "$("$WT" doctor 2>&1)" "CACHE_PATHS names" \
    "ignoring the cache path clears the finding"

# CACHE_MODE=link leaves a symlink at the destination, and git refuses a
# trailing-slash pathspec through a symlink ("beyond a symbolic link"), so a
# probe shaped for a not-yet-existing directory read every shared cache as
# unignored -- on exactly the worktrees where sharing had worked. A dir-only
# pattern ("node_modules/") never matches a symlink, so the ignore rule here
# is the bare name. The conf is tracked, so it has to reach origin before
# add checks it out.
printf '.env\n.env.*\nnode_modules\n' > main/.gitignore
printf 'CACHE_PATHS=node_modules\nCACHE_MODE=link\n' > main/.worktree.conf
git -C main add -A >/dev/null 2>&1
git -C main commit -q -m "chore: link caches" >/dev/null 2>&1
git -C main push -q origin HEAD >/dev/null 2>&1
"$WT" add linked >/dev/null 2>&1
assert_is_symlink "$TMP/p3/wt/linked/node_modules" "add links the cache under CACHE_MODE=link"
output=$("$WT" doctor 2>&1)
assert_equals 0 $? "a linked cache path passes doctor"
assert_not_contains "$output" "CACHE_PATHS names" \
    "a symlinked cache destination is not reported as unignored"

# The bare probe still has to ask git the real question: drop the rule on
# the task branch and the linked cache is a finding again, named as the
# path git would be asked to ignore.
printf '.env\n.env.*\n' > "$TMP/p3/wt/linked/.gitignore"
output=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "an unignored symlinked cache path fails doctor"
assert_contains "$output" "linked: CACHE_PATHS names 'node_modules'" \
    "a symlinked cache destination the branch stopped ignoring is reported"
git -C "$TMP/p3/wt/linked" checkout -q -- .gitignore
"$WT" remove linked >/dev/null 2>&1

printf 'secret\n' > local/shared/notignored.txt
output=$("$WT" doctor 2>&1)
assert_contains "$output" "local/ provisions 'notignored.txt'" \
    "an unignored local/ destination is reported"
rm -f local/shared/notignored.txt

# An absent cache path is normal on a checkout nobody has built yet, so it
# is a note and must not fail the run.
printf 'CACHE_PATHS=node_modules,dist\n' > main/.worktree.conf
printf 'dist/\n' >> main/.gitignore
output=$("$WT" doctor 2>&1)
assert_equals 0 $? "a cache path absent from the stable checkout does not fail doctor"
assert_contains "$output" "is absent from" "an absent cache path is reported as a note"

# write_worktree_env returns success when .env.worktree is not ignored, so
# nothing but doctor ever reports the worktree that got no port block.
printf 'node_modules/\ndist/\n' > main/.gitignore
output=$("$WT" doctor 2>&1)
assert_not_equals 0 $? "an unignored .env.worktree fails doctor"
assert_contains "$output" "no runtime identity and no port block" \
    "doctor explains what the missing ignore rule costs"

cd "$TMP" || exit 1

# ============================================================
# Summary
# ============================================================
print_test_summary
