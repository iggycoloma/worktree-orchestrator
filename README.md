# worktree-orchestrator

`wt` -- git worktree orchestration for parallel, agent-driven development.
One task, one worktree, one branch: each unit of work gets an isolated checkout,
with optional dev container lifecycle, per-worktree port allocation,
and provisioning of untracked local files into every new worktree.

It is a single Bash script (3.2 compatible, macOS `/bin/bash` included) with no hard dependencies beyond git.

## Layouts

`wt` auto-detects one of two layouts:

- **Orchestration mode** -- a directory created by `wt init`:
  bare `repo.git/` + `local/` (untracked files to provision) + `state/` (port registry) + `main/` (stable checkout) + `wt/<slug>` (one dir per worktree).
  Worktrees get `local/shared` files copied in, a generated `.env.worktree` with a reserved port block,
  and per-worktree dev container support.
- **Clone mode** -- any ordinary clone:
  worktrees go to a sibling directory `<parent>/<repo>-worktrees/<leaf>`, without provisioning.
  No setup required; `wt add` just works.
  `wt convert` upgrades a clone to an orchestration dir in place, preserving branches, stashes, untracked files, and existing worktrees.

## Install

Requirements: bash 3.2+, git, and rsync.
Git 2.48+ is recommended (relative worktree pointers; older versions degrade with a warning).
Orchestration mode also needs flock for the port registry -- Linux has it via util-linux, macOS needs `brew install flock`.
Optional: docker plus the devcontainer CLI for `wt container`, jq for consuming `--json` output, zsh for zsh completions.

```bash
curl -fsSL https://raw.githubusercontent.com/iggycoloma/worktree-orchestrator/main/install.sh | bash
```

This clones the repo to `~/.local/share/worktree-orchestrator` and symlinks `wt` and the completions under `~/.local/bin` and `~/.local/share`
(override with the `WT_ORCH_DIR`, `WT_ORCH_REPO`, and `PREFIX` environment variables).
Re-running it fast-forwards the clone, so it doubles as the update command.
From an existing checkout, `./install.sh` (or `make install`) installs from that checkout instead of cloning a second copy.
Make sure `$PREFIX/bin` is on your `PATH`.
`make uninstall` removes the symlinks.

Then add one line to your shell's startup file (the installer prints the one for your shell):

```bash
eval "$(wt shell-init zsh)"     # ~/.zshrc
eval "$(wt shell-init bash)"    # ~/.bashrc
```

That line does two things.
It defines the `wt` shell function that lets `wt go` and `wt add` change directory --
a child process cannot change its parent shell's directory, so without the function `wt go` only prints the path.
It also registers tab completion, so `wt go clk<Tab>` expands to the worktree name.
In zsh the line works on either side of `compinit`: before it, the completion dir goes on `fpath` for `compinit` to scan; after it, the completion is bound directly.
If nothing in your `~/.zshrc` runs `compinit` yet (no framework such as Oh My Zsh), add `autoload -Uz compinit && compinit` too.

To check a zsh session: `type wt` should report a shell function, and `print ${_comps[wt]}` should print `_wt`.

Completion alone also works without the line:
bash picks it up where the bash-completion package scans `$PREFIX/share/bash-completion/completions`,
and zsh finds it when `~/.local/share/zsh/site-functions` is on `fpath` before `compinit` runs.

## Commands

```text
init <url> <dir>            create an orchestration dir (bare clone + local/ state/ main/ wt/)
convert [--dry-run]         convert the enclosing clone into an orchestration dir, in place
add <name|pr:N> [base]      create a worktree (+ provision local files in orchestration mode)
go [name]                   cd into a worktree (no name: the stable checkout)
list [--names|--json]       list worktrees for the current project
path [name]                 print the worktree's path (default: main)
pull [name|--all]           fetch origin and fast-forward a worktree to origin/<branch> (default: the one you are in)
git <name> <git-args...>    run git in the named worktree (verbatim pass-through)
sync [name|--all] [--diff]  refresh local/ files and shared caches into a worktree (default: the one you are in); --diff previews drift
container up|exec ...       manage the worktree's dev container (host only)
remove <name> [--branch]    remove a worktree + its containers (refuses dirty)
prune                       clean up stale worktree administrative entries
ignore [--print] [path]     write a workspace .ignore so searches skip worktrees (default: .)
doctor [--json]             check layout, git version, pointers, tooling, and provisioning config
shell-init <bash|zsh>       print shell integration: the cd wrapper for go/add, and completion
version [--json]            print the version and where this executable came from
```

Commands that act on a worktree -- `pull`, `sync`, `container up`, `container exec` -- default to the worktree you are standing in, and to the stable checkout when you are outside every worktree.
`go` and `path` deliberately keep meaning the stable checkout, since answering "where is main" from inside a worktree is what the bare form is for.
`add`, `remove` and `git` always need a name.

Run `wt <command> --help` for detail on one command.
Paths go to stdout and logging to stderr, so command substitution is safe: `cd "$(wt add feature-x)"`.

## Quickstart

Clone mode, in any existing repository:

```bash
cd ~/code/myrepo
cd "$(wt add clk-123-fix-login)"   # worktree + branch, path printed
# ...work, commit, push...
wt remove clk-123-fix-login        # refuses if the tree is dirty
```

Orchestration mode, for a project that wants provisioning and containers:

```bash
wt init git@github.com:yourorg/app.git ~/work/app
cd ~/work/app                      # drop untracked local files into local/shared
wt add clk-456
wt container up clk-456
wt container exec clk-456 -- npm test
```

`wt doctor` checks the layout, git version, worktree pointers, and tooling, and names the fix for what it finds.
It also checks that provisioning will do what the project declared: hooks that are executable and named for a real stage,
`.dev/worktree.conf` values that actually parse, and the gitignore rules `local/`, `CACHE_PATHS` and `.env.worktree` depend on.
Those failures are otherwise silent -- an unparsed `CACHE_PATHS` disables cache sharing without a word, and an unignored `.env.worktree` leaves a worktree with no port block while `add` still reports success.
`wt ignore` writes a workspace `.ignore` so searches rooted above the worktrees do not descend into every checkout.

A reference devcontainer template lives in [`examples/devcontainer/`](examples/devcontainer/).

## Development

```bash
make test   # bash tests/test-wt.sh -- full suite against temporary repositories
make lint   # shellcheck over the script, tests, and bash completion
```

CI runs both on Linux and macOS, including the suite under macOS `/bin/bash` 3.2.

## Design

The design doc is [`docs/agentic-worktree-dev-environment.md`](docs/agentic-worktree-dev-environment.md);
the implementation plan it defers to is [`docs/planning/2026-08-02-agentic-worktree-system.md`](docs/planning/2026-08-02-agentic-worktree-system.md).
