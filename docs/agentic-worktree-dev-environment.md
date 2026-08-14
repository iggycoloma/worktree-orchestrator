# Portable Agentic Development with Git Worktrees, Dev Containers, and Docker Compose

## Status

Original design, adopted with amendments.
The implementation plan is [`planning/2026-08-02-agentic-worktree-system.md`](../planning/2026-08-02-agentic-worktree-system.md); where the two disagree, the plan wins.
The amendments, decided 2026-08-02 (rationale and verification evidence in the plan):

- **Layout: adopted as designed** -- the section 2 orchestration directory (bare `repo.git/` + `local/` + `state/` + `main/` + `wt/`) stands.
  A **clone mode** is added for repositories not yet migrated and for GitHub Codespaces (which mounts a single repository): worktrees go to a sibling directory `<parent>/<repo>-worktrees/<leaf>`, without `local/`/`state/` provisioning.
  Verification status: the devcontainer CLI's `--mount-git-worktree-common-dir` is proven to reconstruct relative worktree structure for nested worktrees; the equivalent spike for this layout's `wt/x -> ../../repo.git/worktrees/x` is specified in the plan and gates per-worktree container support.
- **Relative paths are mandatory:** `worktree.useRelativePaths = true` globally, and `wt add` passes `--relative-paths`.
  Required by the devcontainer CLI's common-dir mounting, and makes worktrees relocatable across the host/container mount boundary.
  Git version floor: 2.48.
- **Hooks (supersedes section 9's `core.hooksPath` advice):** no project ever sets repository-local `core.hooksPath` -- doing so silently disables the globally deployed secret-scanning and commit-message hooks.
  The global `post-checkout` hook delegates to a repo-local `post-checkout.local`, resolved via `--git-common-dir`.
- **`.worktreeinclude` (updates section 3):** now implemented natively by Claude Code, not only by third-party tools.
  Still treated as an optional adapter: it is per-harness, sources from the main checkout rather than a central store, and is not processed when a `WorktreeCreate` hook is configured.
- **Execution model (extends section 8):** the primary mode runs the agent on the host with the container as a pure build/test executor via `devcontainer up`/`exec`; the in-container mode (GitHub Codespaces) remains fully supported.

This document defines a portable development-workspace convention intended to live in a dotfiles repository. It supports:

- ordinary interactive development;
- multiple concurrent coding agents;
- local host-based development;
- VS Code Dev Containers and the Dev Container CLI;
- Docker Compose environments running once per worktree;
- centrally managed, untracked local-development configuration and secrets;
- predictable creation, synchronization, inspection, and removal of worktrees.

The implementation deliberately uses standard Git worktrees plus small shell scripts. It does not depend on a particular coding agent, editor, or third-party worktree manager.

---

## 1. Goals and non-goals

### Goals

1. **One shared Git object database** per project, avoiding a full clone for every task.
2. **One populated working tree per human or agent task**, so concurrent edits and indexes remain isolated.
3. **A stable main checkout** for review, integration, and ordinary development.
4. **Centralized local-development files** outside every Git checkout.
5. **Automatic provisioning of ignored local files** into newly created worktrees.
6. **Independent runtime identity** for every concurrent worktree.
7. **Dev Container compatibility** without requiring a populated checkout at the project container root.
8. **Least-privilege credential exposure**, especially for autonomous coding agents.
9. **Safe, idempotent teardown** that does not silently destroy uncommitted work or persistent data.
10. **Portability through dotfiles**, with project-specific configuration kept small and declarative.

### Non-goals

This convention does not attempt to:

- make production credentials available to agents;
- share mutable build output between worktrees;
- hide the security implications of running autonomous tools;
- replace project-owned `.devcontainer`, Compose, build, test, lint, or formatting configuration;
- automatically merge or publish agent work;
- make Git submodules fully reliable across arbitrary concurrent worktree workflows.

---

## 2. Recommended filesystem layout

Each logical project gets an orchestration directory that is **not itself a Git checkout**:

```text
~/code/example-project/
├── repo.git/                 # bare shared Git repository
├── local/                    # untracked local-development source of truth
│   ├── shared/               # refreshed into existing worktrees
│   └── template/             # copied only when a worktree is created
├── hooks/                    # optional repository-local Git hooks
├── state/                    # worktree registry and allocated runtime values
├── main/                     # stable populated worktree
└── wt/                       # task worktrees
    ├── issue-123/
    ├── agent-auth/
    └── production-debug/
```

The key distinction is:

- `repo.git/` stores shared Git objects, refs, and worktree administration;
- `main/` and every directory under `wt/` are real populated worktrees;
- `local/` stores machine-local files that must never depend on a particular checkout;
- the orchestration directory gives scripts a stable place from which to derive all paths.

### Why use a bare shared repository?

Git worktrees share repository data while retaining separate per-worktree files such as `HEAD` and the index. A bare repository is a clean administrative center because it does not privilege one checkout as the repository itself. The `main/` checkout remains important, but it is simply one worktree rather than the parent of all others.

This avoids nesting agent worktrees inside the main checkout, which can confuse recursive searches, Docker build contexts, file watchers, editor indexing, and scripts that assume the repository does not contain complete copies of itself.

### Why the orchestration root needs an `.ignore`

Every directory under `wt/` is a full checkout, so the file count below the orchestration root grows linearly with worktree count.
Nothing bounds a search descending from here: `.gitignore` only applies inside a repository, and the orchestration directory is deliberately not one.
A tool that walks down from the root therefore enumerates every worktree in full.

This matters beyond wasted time.
A glob is expanded before the command runs, so `cmd wt/*/src/*.ts` reaches `cmd` as the literal path of every match.
Arguments and environment share a per-`execve` budget of roughly 2 MB, which puts a hard ceiling on how many worktrees can exist before ordinary commands start failing with `E2BIG` ("argument list too long").
The ceiling is content-proportional -- budget divided by bytes per checkout -- so it lands somewhere in the single digits to low teens for a substantial repository, and moves whenever the tree grows.

`wt init` writes an `.ignore` at the orchestration root, `wt doctor` reports it missing or stale, and `wt ignore [path]` regenerates one anywhere.

One file per orchestration directory is sufficient, including for a session rooted further up.
Ripgrep reads ignore files at every directory level as it descends, so a search started at a workspace root picks up each project's file on entering that project and prunes `wt/` before walking into it:

```text
~/Projects/
├── example-project/
│   └── .ignore             # wt/ -- prunes this project's worktrees
└── other-project/
    └── .ignore             # likewise, read on descent from ~/Projects
```

Measured on a workspace holding two orchestration directories with three worktrees between them: 105 files visible with no ignore files present, 45 with only the two per-project ones -- exactly the non-worktree content.

A file at the workspace root is therefore optional, and duplicating the per-project patterns there buys nothing.
It earns a place only as a catch-all for what per-project files cannot cover: repositories never initialized by `wt`, whose native `.claude/worktrees/` nothing excludes, and vault machinery such as `.obsidian/`.
Both are constant in size rather than growing with worktree count, so they are hygiene rather than the failure described above.

The file is honored by `rg` and `fd`, and therefore by agent tooling built on them.
It bounds only *descent from above*: ripgrep never filters its own search root or a path named explicitly on the command line, so a search run from inside `wt/feat-1/`, or one targeting it directly, still works normally.
Content outside the generated block is preserved, so hand-written rules survive regeneration.

Shell pathname expansion honors no ignore file at all.
That gap has no configuration-level fix, so it is covered by convention instead -- see the glob rule in `agent-prompts/engineering-conventions.md`.

### Why keep a populated `main/` worktree?

The stable checkout is useful for:

- human review and integration;
- comparing agent branches against a known baseline;
- reading project documentation without entering a task worktree;
- running release or maintenance tasks that should not occur in disposable worktrees;
- recovering when a tool expects to open an ordinary populated repository.

---

## 3. Local-development files

Git does not copy untracked or ignored files into a newly created worktree. This convention therefore treats local-development files as a separate machine-local input.

### Mirrored layout

The contents of `local/shared/` and `local/template/` mirror paths inside a checkout:

```text
local/
├── shared/
│   ├── .env.shared
│   ├── config/
│   │   └── local.yaml
│   └── certs/
│       └── development-ca.pem
└── template/
    ├── .env.local
    └── .envrc.local
```

Provisioning maps them directly into a worktree:

```text
local/shared/.env.shared
    -> wt/agent-auth/.env.shared

local/shared/config/local.yaml
    -> wt/agent-auth/config/local.yaml

local/template/.env.local
    -> wt/agent-auth/.env.local
```

The mirrored structure makes synchronization a normal recursive copy:

```bash
rsync -a local/shared/ worktree/
rsync -a --ignore-existing local/template/ worktree/
```

### `shared/` versus `template/`

Use two classes because not all local files have the same lifecycle.

#### `local/shared/`

Files in `shared/` are centrally maintained and may be refreshed into existing worktrees. Examples:

- sandbox API credentials;
- local TLS certificates;
- shared development endpoints;
- non-secret machine-specific configuration;
- a development-only service-account file.

The synchronization command may overwrite the corresponding worktree copies.

#### `local/template/`

Files in `template/` are initial values that a worktree may customize independently. Examples:

- `.env.local` containing a generated Compose project name;
- a worktree-specific database name;
- a local debugger override;
- an editor setting that differs between tasks.

Template files are copied only when absent.

### Why copy rather than symlink?

Physical copies are the least surprising option across host development and Dev Containers:

- the worktree remains self-contained when mounted into a container;
- a host-absolute symlink does not break because that host path is absent in the container;
- tools that reject or normalize symlinks continue to work;
- each worktree may safely customize template files;
- removing a disposable worktree removes its local copies with it.

The tradeoff is that copied shared files can become stale. The command surface therefore includes explicit `sync` and `diff-local` operations.

### Why not depend on `.worktreeinclude`?

`.worktreeinclude` is a convention implemented by some third-party tools. It is not part of Git itself, and plain `git worktree add` does not process it. A dotfiles-managed wrapper and hook provide deterministic behavior regardless of whether the worktree was created by a human, an editor, Codex, Claude Code, or another agent.

A project may still carry `.worktreeinclude` for compatible tools, but it should be treated as an optional adapter, not the foundation of this design.

---

## 4. Credential policy

Autonomous coding agents increase the importance of deciding what credentials are visible inside each worktree or container.

### Three credential classes

#### Class A: safe to copy into every development worktree

Examples:

- local-only database passwords;
- sandbox API keys with narrow scope;
- development certificates;
- service accounts restricted to disposable development resources;
- read-only credentials for public or non-sensitive test data.

These may live under `local/shared/`, provided every destination is ignored by Git.

#### Class B: forward or mount, do not copy

Examples:

- the host SSH agent;
- Git credential-helper access;
- short-lived cloud SSO sessions;
- Docker credential-helper integration;
- a password-manager or hardware-token mediated session;
- a narrowly scoped GitHub token supplied at runtime.

These are better delegated through the host or container runtime because copies become stale and increase the number of secret-bearing files on disk.

VS Code Dev Containers supports reuse of host Git credentials and copies the host Git configuration into the container. Prefer that mechanism over copying SSH private keys or personal access tokens into each worktree.

#### Class C: never expose by default

Examples:

- production kubeconfig;
- production cloud administrator credentials;
- personal SSH private keys;
- broad organization-owner tokens;
- unrestricted password-manager exports;
- credentials capable of changing billing, identity, or production data.

Agents should not inherit these merely because a human developer can access them on the same workstation.

### Least privilege and task-specific exposure

A worktree should receive only the credentials required to complete its task. It is reasonable to maintain separate local profiles, for example:

```text
local-profiles/
├── default/
├── cloud-readonly/
├── payments-sandbox/
└── no-secrets/
```

The worktree creation command can select a profile:

```bash
wt add agent-docs --profile no-secrets
wt add diagnose-cloud --profile cloud-readonly
```

### Required ignore validation

Before copying any file from `local/`, the provisioning script must verify that its destination is ignored by Git:

```bash
git -C "$worktree" check-ignore -q -- "$relative_path"
```

If any destination is not ignored, provisioning must fail rather than copy the file. This converts “we intended to ignore secrets” into an enforced invariant.

Do not rely only on a global Git ignore file for project secrets. Project-owned `.gitignore` entries make the expected local paths visible and testable to every developer and CI check.

### File permissions

Protect the source of truth:

```bash
chmod 700 "$project_root/local"
find "$project_root/local" -type f -exec chmod 600 {} +
```

Copying logic may preserve restrictive modes or deliberately reset them. Avoid world-readable secret files merely because they are on a single-user workstation.

### Backup and indexing considerations

The `local/` directory may be included in system backup, cloud synchronization, desktop search, antivirus upload, or crash-report collection. Decide deliberately whether that is acceptable. For high-value credentials, use a credential manager or runtime forwarding rather than a persistent file.

---

## 5. Per-worktree runtime identity

A Git branch isolates source changes. It does **not** isolate external runtime resources.

Every concurrent worktree should receive a stable slug used to derive:

- Docker Compose project name;
- database name or schema;
- cache namespace;
- queue or topic prefix;
- test tenant identifier;
- temporary directory;
- debugger session name;
- allocated host ports;
- state and log paths.

Example generated file:

```dotenv
# .env.worktree -- generated, ignored, and unique per worktree
WORKTREE_SLUG=agent-auth
COMPOSE_PROJECT_NAME=example-agent-auth
DATABASE_NAME=example_agent_auth
CACHE_NAMESPACE=agent-auth
APP_PORT=3187
DB_PORT=5187
```

### Slug rules

Normalize once and reuse everywhere:

- lowercase;
- only letters, digits, dashes, and underscores;
- start with a letter or digit;
- limited to a practical length;
- collision checked against active worktrees and state records.

This is compatible with Docker Compose project-name constraints.

### Why stable rather than random identity?

A stable identity makes it possible to:

- reconnect to an existing Dev Container;
- inspect the correct Compose project;
- stop and remove the correct resources;
- keep a stable local database across container rebuilds;
- avoid allocating a new port every time a command runs.

Random values are acceptable only when recorded in project state.

---

## 6. Docker Compose isolation

Docker Compose uses a **project name** to isolate one deployment of a Compose application from another. This is essential when multiple worktrees run the same Compose file concurrently.

### Project name

Set a unique value per worktree through `COMPOSE_PROJECT_NAME` or `docker compose -p`:

```bash
COMPOSE_PROJECT_NAME=example-agent-auth docker compose up -d
```

Avoid a fixed top-level Compose `name:` when the same file must run once per worktree. A fixed name collapses all worktrees back into the same Compose project.

### Avoid globally explicit resource names

This defeats project scoping:

```yaml
volumes:
  database:
    name: example-database
```

Prefer:

```yaml
volumes:
  database:
```

Compose will scope the actual volume name using the project name.

Apply the same rule to networks, containers, and other resources. Avoid `container_name:` unless interoperability with a non-Compose system truly requires it; explicit container names prevent scaling and cause cross-worktree collisions.

### Host ports

Compose project names isolate Docker-side resources, but they cannot make the same host port available twice:

```yaml
ports:
  - "3000:3000"
```

Choose one of two strategies.

#### Strategy A: dynamic host ports

Publish the container port without a fixed host port:

```yaml
ports:
  - target: 3000
    published: 0
```

Then discover the assigned port:

```bash
docker compose port app 3000
```

This is low-maintenance but requires tooling to surface the chosen port to browsers and debuggers.

#### Strategy B: persistent allocation registry

Allocate a unique port when the worktree is created and record it under `state/`:

```text
state/ports.tsv
agent-auth    3187    5187
issue-123     3188    5188
```

This is preferable when editor launch profiles, OAuth callbacks, mobile clients, or external tools need stable endpoints.

Never choose ports with an unrecorded `$RANDOM`; collisions become intermittent and teardown cannot reliably release ownership.

### Persistent data

Decide whether database volumes are:

- **per-worktree and disposable**;
- **per-worktree and retained across container rebuilds**;
- **intentionally shared**.

The safe default is per-worktree. Shared mutable databases make tests order-dependent and allow one agent to invalidate another agent’s assumptions.

The remove command should not delete persistent volumes without an explicit option such as:

```bash
wt remove agent-auth --volumes
```

### Compose profiles and override files

Project-owned Compose profiles or override files can selectively enable expensive development services:

```bash
COMPOSE_PROFILES=debug,observability docker compose up -d
```

Keep the base Compose definition reproducible. Put machine-local values in ignored environment files rather than editing tracked YAML per worktree.

---

## 7. Shared and isolated caches

Parallel worktrees can waste time downloading identical dependencies, but indiscriminate cache sharing causes branch contamination.

### Reasonable shared caches

Share caches whose primary role is immutable or content-addressed downloads:

- pnpm, npm, or Yarn package download stores;
- Cargo registry and Git caches;
- Go module cache;
- Maven or Gradle dependency caches;
- pip or uv download caches;
- compiler toolchain downloads.

### Keep these isolated

Do not share mutable project output by default:

- `node_modules/`;
- `target/`;
- `dist/` or `build/`;
- `.venv/` when native dependencies or editable installs are involved;
- language-server indexes;
- test caches;
- database volumes;
- generated application state.

A shared download cache improves speed. A shared build tree allows one branch to make another branch appear to compile or test successfully when it should not.

### Dev Container volume naming

A cache intended to be global across worktrees may use a deliberate stable volume name:

```json
{
  "mounts": [
    "source=example-pnpm-cache,target=/home/vscode/.local/share/pnpm/store,type=volume"
  ]
}
```

Mutable project state should use the per-worktree identity or remain inside that worktree’s Compose project.

---

## 8. Dev Container support

### Open the worktree, not the orchestration directory

Each worktree contains the project’s tracked `.devcontainer/` directory. Open the specific populated worktree:

```bash
code ~/code/example-project/wt/agent-auth
```

Then reopen that folder in its Dev Container. The orchestration directory does not need to contain source code.

One editor window should normally correspond to one worktree and one Dev Container. This keeps source-control state, terminals, debuggers, ports, and agent context aligned.

### Git metadata caveat

A linked worktree usually contains a `.git` **file** that points to administrative data under the shared repository. If a container mounts only the worktree but not the shared Git metadata, Git inside the container cannot resolve that pointer.

Current Dev Container CLI releases include support for mounting a worktree’s common Git directory. When invoking the CLI directly, use the supported worktree-common-directory option where needed:

```bash
devcontainer up \
  --workspace-folder "$worktree" \
  --mount-git-worktree-common-dir
```

Use a recent Dev Container CLI. Worktree common-directory mounting was added in CLI 0.81.0.

### Default workspace mounting

Prefer the normal Dev Container workspace mount unless the project has a concrete reason to override it. Custom `workspaceMount` settings alter how the workspace is exposed and can require additional care to ensure the shared Git directory is available at the path referenced by the worktree’s `.git` file.

When a custom workspace mount is unavoidable, test all of these inside the container:

```bash
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git status
git worktree list --porcelain
```

Do not declare the setup complete merely because source files are visible.

### Local files inside containers

Because local files are copied into the worktree, they arrive naturally with the workspace bind mount. This avoids host-path-dependent symlinks and project-specific secret mounts in tracked `devcontainer.json`.

For credentials that should not be copied, use host credential forwarding or a runtime mount. Keep personal host paths out of committed `devcontainer.json`; use `${localEnv:...}` indirection or user-level Dev Container configuration when a mount is necessary.

### Lifecycle scripts

Project-owned Dev Container lifecycle scripts should be idempotent:

```json
{
  "onCreateCommand": "./scripts/devcontainer-on-create",
  "postCreateCommand": "./scripts/devcontainer-post-create",
  "postStartCommand": "./scripts/devcontainer-post-start"
}
```

Appropriate responsibilities include:

- dependency installation from lockfiles;
- creating generated local directories;
- checking required ignored configuration;
- starting lightweight supporting services;
- printing useful endpoints.

Do not place irreversible data migrations, secret generation, or unbounded long-running commands in lifecycle hooks.

### Container identity

Ensure the Dev Container and any Compose services derive identity from the worktree-generated environment. Rebuilding one worktree’s container must not replace or attach to another worktree’s container.

---

## 9. Git hooks

Git runs `post-checkout` after `git worktree add` unless `--no-checkout` is used. For worktree creation, the old ref passed to the hook is a null ref.

This makes `post-checkout` useful as a **safety net**, but not as the primary orchestration mechanism.

### Wrapper responsibilities

The `wt add` wrapper should own:

- validating prerequisites;
- choosing branch and path;
- creating the worktree;
- selecting a local credential profile;
- copying shared and template files;
- allocating runtime identity and ports;
- writing state metadata;
- optionally opening the editor or starting the container;
- rolling back if provisioning fails.

### Hook responsibilities

The hook should do only lightweight, idempotent work:

- detect initial worktree creation;
- populate missing local files when possible;
- never overwrite customized template files;
- never start containers;
- never install dependencies;
- never require interactive input;
- exit harmlessly during ordinary `git switch` or `git checkout`.

Complex logic belongs in a normal script that both the wrapper and hook can invoke.

### Shared hook path

A project orchestration directory may configure a repository-local hook directory:

```bash
git --git-dir="$project_root/repo.git" \
  config core.hooksPath "$project_root/hooks"
```

Be aware that `core.hooksPath` is repository configuration shared by the worktrees. Dotfiles scripts should install or update the hook deliberately rather than assuming every repository accepts global hooks.

---

## 10. Command surface

Expose a single command, for example `wt`, from dotfiles:

```text
wt init <url> <project-directory>
wt add <name> [base] [--profile profile]
wt go [name]
wt list [--names]
wt path [name]
wt pull [name]
wt git <name> <git-arguments...>
wt sync [name|--all] [--diff]
wt open <name>
wt container up [name]
wt container exec <name> -- <command...>
wt compose <name> -- <compose arguments...>
wt doctor [name]
wt remove <name> [--branch] [--volumes]
wt prune
```

### Design principles

- Commands must be safe to rerun.
- Machine-readable Git output must be used for scripting.
- Destructive operations must inspect uncommitted and untracked files.
- Persistent volumes require explicit removal.
- Every command should work from outside a populated checkout.
- Paths should be derived through Git, not by assuming undocumented internal layouts.

Use:

```bash
git --git-dir="$git_dir" worktree list --porcelain
```

rather than parsing human-formatted `git worktree list` output.

---

## 11. Reference project configuration

Dotfiles should supply generic machinery. Each project should supply a small machine-local or tracked configuration describing project-specific behavior.

Example machine-local file:

```bash
# ~/code/example-project/project.conf
PROJECT_ID=example
DEFAULT_BRANCH=main
WORKTREE_BRANCH_PREFIX=agent/
PORT_RANGE_START=3100
PORT_RANGE_END=3999
LOCAL_PROFILE=default
DEVCONTAINER_ENABLED=1
COMPOSE_ENABLED=1
```

Optionally, a project may track a safe configuration file such as `.dev/worktree.conf` containing no secrets:

```bash
PROJECT_ID=example
DEFAULT_BRANCH=main
VERIFY_COMMAND='./dev verify'
COMPOSE_FILE='compose.yaml'
```

The local orchestration config can override tracked defaults.

Do not `source` arbitrary repository files from an untrusted checkout without considering command execution. A safer implementation parses a restricted key-value format or requires explicit trust before sourcing shell code.

---

## 12. Reference implementation

The following Bash implementation is intentionally conservative. It requires Bash, Git, and `rsync`.

### `wt` launcher

```bash
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
[[ -n "$command_name" ]] || {
  echo "usage: wt <init|add|list|sync|doctor|remove|prune> ..." >&2
  exit 2
}
shift

case "$command_name" in
  init)   wt_init "$@" ;;
  add)    wt_add "$@" ;;
  list)   wt_list "$@" ;;
  sync)   wt_sync "$@" ;;
  doctor) wt_doctor "$@" ;;
  remove) wt_remove "$@" ;;
  prune)  wt_prune "$@" ;;
  *)
    echo "unknown wt command: $command_name" >&2
    exit 2
    ;;
esac
```

In a real dotfiles repository, place functions in a library file and have the launcher source only trusted dotfiles-owned code.

### Initialize a project

```bash
wt_init() {
  local remote_url="${1:?usage: wt init REMOTE_URL PROJECT_DIR}"
  local project_root="${2:?usage: wt init REMOTE_URL PROJECT_DIR}"

  mkdir -p "$project_root"/{local/shared,local/template,hooks,state,wt}

  git clone --bare "$remote_url" "$project_root/repo.git"

  local default_branch
  default_branch="$(
    git --git-dir="$project_root/repo.git" symbolic-ref \
      --short refs/remotes/origin/HEAD 2>/dev/null || true
  )"
  default_branch="${default_branch#origin/}"
  default_branch="${default_branch:-main}"

  git --git-dir="$project_root/repo.git" worktree add \
    "$project_root/main" "$default_branch"

  git --git-dir="$project_root/repo.git" config \
    core.hooksPath "$project_root/hooks"

  chmod 700 "$project_root/local"

  printf 'Initialized %s\nDefault branch: %s\n' \
    "$project_root" "$default_branch"
}
```

Remote default-branch discovery varies between bare-clone configurations. Production code should fall back to inspecting remote refs and should print a clear error when the intended base is ambiguous.

### Normalize names

```bash
normalize_slug() {
  local input="${1:?}"

  printf '%s' "$input" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c1-48
}
```

Reject an empty result and collision-check it before use.

### Validate local file destinations

```bash
validate_local_tree() {
  local source_dir="${1:?}"
  local worktree="${2:?}"
  local source relative

  [[ -d "$source_dir" ]] || return 0

  while IFS= read -r -d '' source; do
    relative="${source#"$source_dir"/}"

    if ! git -C "$worktree" check-ignore -q -- "$relative"; then
      printf 'Refusing to provision non-ignored local file: %s\n' \
        "$relative" >&2
      return 1
    fi
  done < <(find "$source_dir" -type f -print0)
}
```

This check should cover both `shared/` and `template/` before either tree is copied.

### Copy local files

```bash
provision_local_files() {
  local project_root="${1:?}"
  local worktree="${2:?}"

  local shared="$project_root/local/shared"
  local template="$project_root/local/template"

  validate_local_tree "$shared" "$worktree"
  validate_local_tree "$template" "$worktree"

  if [[ -d "$shared" ]]; then
    rsync -a --exclude='.DS_Store' "$shared/" "$worktree/"
  fi

  if [[ -d "$template" ]]; then
    rsync -a --ignore-existing --exclude='.DS_Store' \
      "$template/" "$worktree/"
  fi
}
```

Do not use `--delete` during normal synchronization. It can remove worktree-specific ignored state that is not present in the central local tree.

### Allocate a port

A simple lock-protected allocator can scan a configured range and record ownership:

```bash
allocate_port() {
  local project_root="${1:?}"
  local slug="${2:?}"
  local range_start="${3:-3100}"
  local range_end="${4:-3999}"
  local registry="$project_root/state/ports.tsv"
  local lock="$project_root/state/ports.lock"

  mkdir -p "$project_root/state"
  touch "$registry"

  # Requires flock. On platforms without it, use mkdir as an atomic lock.
  exec 9>"$lock"
  flock 9

  local port
  for ((port = range_start; port <= range_end; port++)); do
    if ! awk -v p="$port" '$2 == p { found=1 } END { exit found ? 0 : 1 }' \
      "$registry"; then
      printf '%s\t%s\n' "$slug" "$port" >> "$registry"
      printf '%s\n' "$port"
      return 0
    fi
  done

  echo "no available port in range $range_start-$range_end" >&2
  return 1
}
```

A production implementation should also test whether an unregistered process already owns the port.

### Generate worktree runtime state

```bash
write_worktree_env() {
  local project_root="${1:?}"
  local worktree="${2:?}"
  local project_id="${3:?}"
  local slug="${4:?}"
  local app_port="${5:?}"

  cat > "$worktree/.env.worktree" <<EOF_ENV
# Generated by wt. Do not commit.
WORKTREE_SLUG=$slug
COMPOSE_PROJECT_NAME=$project_id-$slug
DATABASE_NAME=${project_id}_${slug//-/_}
CACHE_NAMESPACE=$slug
APP_PORT=$app_port
EOF_ENV

  chmod 600 "$worktree/.env.worktree"
}
```

Ensure `.env.worktree` is explicitly ignored by the project.

### Create a worktree transactionally

```bash
wt_add() {
  local name="${1:?usage: wt add NAME [BASE]}"
  local base="${2:-main}"

  local project_root="${WT_PROJECT_ROOT:?set WT_PROJECT_ROOT}"
  local git_dir="$project_root/repo.git"
  local slug
  slug="$(normalize_slug "$name")"
  [[ -n "$slug" ]] || {
    echo "name produced an empty slug" >&2
    return 1
  }

  local worktree="$project_root/wt/$slug"
  local branch="agent/$slug"
  local created=0

  cleanup_failed_add() {
    local status=$?
    if (( status != 0 && created == 1 )); then
      git --git-dir="$git_dir" worktree remove --force "$worktree" \
        >/dev/null 2>&1 || true
      git --git-dir="$git_dir" branch -D "$branch" \
        >/dev/null 2>&1 || true
    fi
    return "$status"
  }
  trap cleanup_failed_add RETURN

  [[ ! -e "$worktree" ]] || {
    echo "worktree path already exists: $worktree" >&2
    return 1
  }

  git --git-dir="$git_dir" worktree add \
    -b "$branch" "$worktree" "$base"
  created=1

  provision_local_files "$project_root" "$worktree"

  local app_port
  app_port="$(allocate_port "$project_root" "$slug" 3100 3999)"
  write_worktree_env "$project_root" "$worktree" \
    "example" "$slug" "$app_port"

  cat > "$project_root/state/$slug.env" <<EOF_STATE
WORKTREE=$worktree
BRANCH=$branch
BASE=$base
APP_PORT=$app_port
EOF_STATE

  printf 'Created worktree: %s\nBranch: %s\nPort: %s\n' \
    "$worktree" "$branch" "$app_port"
}
```

Adapt the trap mechanism for the Bash versions supported by the dotfiles. An `EXIT` trap in a subshell is often simpler and more portable than a function `RETURN` trap.

### Synchronize local files

```bash
wt_sync_one() {
  local project_root="${1:?}"
  local worktree="${2:?}"

  provision_local_files "$project_root" "$worktree"
}
```

The shared tree is overwritten; template files are preserved once present.

### Safety-net `post-checkout` hook

```bash
#!/usr/bin/env bash
set -euo pipefail

old_ref="${1:-}"
new_ref="${2:-}"
checkout_kind="${3:-}"

# Initial checkout from clone or worktree add has a null old ref.
[[ "$old_ref" =~ ^0+$ ]] || exit 0
[[ "$checkout_kind" == 1 ]] || exit 0

worktree="$(git rev-parse --show-toplevel)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
project_root="$(dirname "$common_dir")"

helper="$HOME/.dotfiles/bin/wt-sync-local"
[[ -x "$helper" ]] || exit 0
[[ -d "$project_root/local" ]] || exit 0

# Safety-net behavior should not overwrite worktree-specific files.
"$helper" --initial "$worktree" || {
  echo "warning: local worktree provisioning failed" >&2
  exit 0
}
```

The hook warns rather than making ordinary Git use unusable. The explicit `wt add` command remains responsible for strict transactional setup.

### Worktree health checks

`wt doctor` should verify at least:

```text
- repo.git exists and is bare
- main worktree exists
- worktree registry has no stale entries
- every local/shared and local/template file maps to an ignored destination
- worktree .git pointers resolve
- git status works from the host
- git status works inside the Dev Container, when enabled
- generated Compose project names are unique and valid
- allocated ports are unique and not unexpectedly occupied
- required local files exist
- copied shared files match their source
- Docker and Dev Container CLI versions meet project requirements
```

### Remove safely

Before removal, check:

```bash
git -C "$worktree" diff --quiet
git -C "$worktree" diff --cached --quiet
test -z "$(git -C "$worktree" ls-files --others --exclude-standard)"
```

Then:

1. stop the worktree’s Compose project;
2. remove containers and networks;
3. retain volumes unless `--volumes` is explicitly supplied;
4. call `git worktree remove`, not `rm -rf`;
5. optionally delete the branch only after checking merge or publication state;
6. release allocated ports;
7. remove worktree state records;
8. run `git worktree prune`.

Example Compose teardown:

```bash
COMPOSE_PROJECT_NAME="$compose_project" docker compose down
```

Destructive variant:

```bash
COMPOSE_PROJECT_NAME="$compose_project" docker compose down --volumes
```

---

## 13. Project repository requirements

For this convention to work well, each project repository should track:

```text
.devcontainer/
.env.example
.gitignore
AGENTS.md or equivalent agent instructions
compose.yaml, when applicable
scripts or a ./dev command for canonical project operations
```

### Recommended `.gitignore` entries

```gitignore
# Worktree-local development configuration
.env
.env.local
.env.shared
.env.worktree
.envrc.local
config/local.yaml
certs/development-*

# Project-local mutable output
node_modules/
dist/
build/
.pytest_cache/
```

Use paths appropriate to the project. Do not blindly ignore broad credential directories if doing so would conceal accidental placement of production credentials.

### Canonical project command

Give humans and agents one verification command:

```bash
./dev verify
```

It should run the project’s meaningful pre-handoff checks, such as:

- formatting verification;
- linting;
- static type checking;
- focused or full tests;
- generated-file consistency;
- migration validation.

Agents should not need to reverse-engineer the expected workflow from package files.

### Agent instructions

Track an `AGENTS.md` or similar file describing:

- architecture boundaries;
- commands for build, test, lint, and formatting;
- generated files;
- directories agents must not modify;
- migration and data-safety rules;
- available development credentials and their scope;
- whether agents may commit, push, or open pull requests;
- handoff expectations.

---

## 14. Host, editor, and agent boundaries

### One task, one worktree, one editor window

This prevents accidental edits in the wrong branch and keeps debugger state aligned with the correct runtime environment.

### One agent, one worktree

Do not allow two autonomous agents to modify the same working tree concurrently. Git isolates branches, but it cannot reconcile simultaneous filesystem edits, dependency installation, generated files, or editor operations in one checkout.

### Git publication policy

A useful default is:

- agent may edit and create local commits;
- human reviews commits and diff;
- human pushes or opens the pull request.

Grant push capability only when the workflow benefits from it and the credential is narrowly scoped.

### Docker daemon exposure

Access to a host Docker socket is effectively broad control over the host’s containers and often its filesystem. Treat an agent with Docker socket access as highly privileged. Prefer isolated Docker environments or purpose-built sandboxes for untrusted tasks.

### Workspace trust

A repository can contain executable lifecycle scripts, hooks, task definitions, and build files. Do not automatically expose credentials to an untrusted repository merely because it was cloned beneath the expected project root.

---

## 15. Platform considerations

### Linux

The reference Bash and `rsync` workflow is straightforward. Use `flock` for state-file locking where available.

### macOS

The system Bash is old, and BSD utilities differ from GNU variants. Either:

- write to Bash 3.2-compatible syntax and avoid GNU-only flags;
- install a modern Bash and GNU tools through a package manager;
- implement locking with atomic `mkdir` rather than relying on `flock`.

### Windows

Prefer WSL2 for this exact Unix-oriented layout. Keep the repository and worktrees inside the WSL filesystem for better filesystem and container performance, and invoke VS Code through the WSL integration.

If the repository lives on a Windows filesystem while containers run through WSL or Docker Desktop, test path resolution, file permissions, line endings, symlinks, file watching, and worktree `.git` pointers carefully.

---

## 16. Failure modes and diagnostics

### Git works on the host but not inside the Dev Container

Likely cause: the worktree’s `.git` file points to shared metadata that is not mounted inside the container.

Check:

```bash
cat .git
git rev-parse --git-common-dir
```

Use a recent Dev Container CLI and enable worktree common-directory mounting. Re-evaluate custom `workspaceMount` settings.

### Two worktrees manipulate the same containers

Likely cause: identical Compose project names, fixed `container_name`, or explicit global volume/network names.

Check:

```bash
docker compose config
echo "$COMPOSE_PROJECT_NAME"
```

### Second worktree cannot start because a port is already allocated

Likely cause: fixed host port publishing.

Use dynamic host ports or the central allocation registry.

### Agent sees credentials it does not need

Likely cause: a monolithic `local/` profile or broad host credential forwarding.

Split credential profiles and default to `no-secrets` or development-only scope.

### Shared `.env` changes are not reflected

Copied files are snapshots. Run:

```bash
wt sync <name>
```

Provide `wt diff-local` to show drift before overwriting.

### Worktree was deleted with `rm -rf`

Run:

```bash
git --git-dir=repo.git worktree prune
```

Use `git worktree remove` in the future. If paths were moved, use `git worktree repair` as appropriate.

### Branch cannot be checked out

Git normally prevents the same branch from being checked out in more than one worktree. Create a separate branch per task rather than forcing the same branch into multiple worktrees.

### Submodule problems

Git documents limitations around multiple worktrees and submodules. Test the exact repository workflow before standardizing it. Repositories heavily dependent on submodules may need separate clones or stricter submodule procedures.

---

## 17. Security checklist

Before enabling this workflow on a development machine:

- [ ] `local/` has restrictive filesystem permissions.
- [ ] Every copied destination is explicitly ignored by the project.
- [ ] Provisioning fails when an intended secret path is not ignored.
- [ ] Production credentials are absent from default profiles.
- [ ] Git private keys are not copied into worktrees.
- [ ] Cloud and Kubernetes access is development-only or read-only where possible.
- [ ] Agent push access is intentional and scoped.
- [ ] Docker socket access is treated as privileged.
- [ ] Worktree removal does not automatically delete persistent volumes.
- [ ] Local secret files are excluded from inappropriate cloud synchronization or backups.
- [ ] Dev Container lifecycle scripts are trusted before credentials are exposed.
- [ ] `wt doctor` can identify stale or divergent local copies.

---

## 18. Operational checklist

### Creating a task

```bash
wt add issue-123 origin/main --profile default
wt open issue-123
```

### Running the environment

```bash
wt container-up issue-123
wt compose issue-123 -- up -d
```

### Refreshing shared local configuration

```bash
wt diff-local issue-123
wt sync issue-123
```

### Reviewing

```bash
git -C ~/code/example-project/wt/issue-123 status
git -C ~/code/example-project/wt/issue-123 log --oneline origin/main..HEAD
```

### Removing

```bash
wt remove issue-123
```

Remove associated database volumes only after making that decision explicitly:

```bash
wt remove issue-123 --volumes --branch
```

---

## 19. Decision summary

| Decision | Reason |
|---|---|
| Bare `repo.git` plus sibling worktrees | Clean separation between shared Git administration and populated task checkouts |
| Stable `main/` worktree | Review, integration, documentation, and ordinary development baseline |
| `local/` outside all worktrees | One machine-local source of truth that cannot be committed accidentally from a checkout |
| Mirrored `local/` paths | Makes provisioning a predictable recursive copy |
| `shared/` and `template/` split | Distinguishes centrally refreshed files from per-worktree customizable files |
| Copy rather than symlink | Works naturally through Dev Container workspace mounts and avoids host-path coupling |
| Ignore validation before copy | Enforces secret safety instead of depending on convention |
| Wrapper as primary interface | Enables transactional creation, runtime allocation, state recording, and rollback |
| `post-checkout` only as safety net | Git invokes it for more than worktree creation, so it must remain lightweight and idempotent |
| Unique Compose project name | Isolates containers, networks, and normally named volumes per worktree |
| No fixed container/resource names | Prevents collisions that bypass Compose project scoping |
| Port registry or dynamic ports | Host ports are not isolated by Compose project names |
| Per-worktree databases and cache namespaces | Prevents concurrent tasks from corrupting or observing each other’s mutable state |
| Shared download caches only | Gains speed without sharing stale build output |
| Copy low-risk development secrets; forward high-value credentials | Balances usability, freshness, and least privilege |
| Open each worktree directly in its Dev Container | The task worktree is the project root; the orchestration directory need not contain source |
| Recent Dev Container CLI with worktree common-dir mounting | Linked worktree Git metadata lives outside the worktree directory |
| Explicit cleanup command | Protects uncommitted work, volumes, ports, branches, and Git administration |
| Canonical `./dev verify` | Gives humans and agents the same definition of a complete change |

---

## 20. Authoritative references

- Git worktree documentation: <https://git-scm.com/docs/git-worktree>
- Git hooks documentation, including `post-checkout`: <https://git-scm.com/docs/githooks>
- Git repository layout and `.git` files: <https://git-scm.com/docs/gitrepository-layout>
- VS Code worktree support: <https://code.visualstudio.com/docs/sourcecontrol/branches-worktrees>
- Dev Container default workspace mounts: <https://code.visualstudio.com/remote/advancedcontainers/change-default-source-mount>
- Dev Container Git credential sharing: <https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials>
- Dev Container CLI changelog: <https://github.com/devcontainers/cli/blob/main/CHANGELOG.md>
- Docker Compose project names: <https://docs.docker.com/compose/how-tos/project-name/>
- Docker Compose networking: <https://docs.docker.com/compose/how-tos/networking/>
- Docker Compose volumes: <https://docs.docker.com/reference/compose-file/volumes/>
- Docker Compose environment-variable behavior: <https://docs.docker.com/compose/how-tos/environment-variables/>

---

## 21. Recommended dotfiles packaging

A practical dotfiles tree:

```text
~/.dotfiles/
├── bin/
│   └── wt
├── lib/
│   └── wt/
│       ├── common.sh
│       ├── init.sh
│       ├── add.sh
│       ├── local-files.sh
│       ├── ports.sh
│       ├── compose.sh
│       ├── devcontainer.sh
│       ├── doctor.sh
│       └── remove.sh
├── templates/
│   └── worktree-project/
│       ├── hooks/post-checkout
│       └── project.conf.example
└── docs/
    └── agentic-worktree-dev-environment.md
```

Keep generic implementation in dotfiles and project policy in each project. The dotfiles tooling should never silently weaken a repository’s ignore rules, credential scope, or cleanup protections merely to make worktree creation succeed.
