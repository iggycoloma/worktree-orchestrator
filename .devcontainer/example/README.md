# Devcontainer Configuration Example

This directory contains an example devcontainer configuration that works with the dotfiles repository's environment-aware setup strategy.

## Overview

When using devcontainers with named volumes for `.claude` and `.codex` directories, the dotfiles installation automatically switches from **symlink mode** (used on host) to **copy-merge mode** to avoid broken symlinks.

## How It Works

### On Your Host Machine
```bash
~/.claude/settings.json -> ~/.dotfiles/claude-code/settings.json (symlink)
~/.claude/hooks/        -> ~/.dotfiles/claude-code/hooks/      (symlink)
```

### In a Devcontainer
```bash
~/.claude/                    # Named Docker volume (persists across rebuilds)
  ├── settings.json           # Copied from dotfiles, preserved if exists
  ├── hooks/                  # Merged from dotfiles, updated on reinstall
  ├── agents/                 # Merged from dotfiles, updated on reinstall
  ├── commands/               # Merged from dotfiles, updated on reinstall
  └── .dotfiles-version       # Tracks when dotfiles were installed
```

## Setup Instructions

### 1. Copy Configuration to Your Project

Copy `devcontainer.json` to your project's `.devcontainer/` directory:

```bash
mkdir -p .devcontainer
cp ~/.dotfiles/.devcontainer/example/devcontainer.json .devcontainer/
```

### 2. Update the Configuration

Edit `.devcontainer/devcontainer.json`:

- Replace `"repository": "yourusername/.dotfiles"` with your actual dotfiles repo
- Adjust the base image if needed
- Add any project-specific VS Code extensions
- Customize mount points or volume names

### 3. Configure Dotfiles Integration

**Official Method (Recommended)**: Configure in VS Code User Settings:

```json
{
  "dotfiles.repository": "yourusername/.dotfiles",
  "dotfiles.installCommand": "install.sh"
}
```

**Alternative (VS Code-Specific)**: The example `devcontainer.json` includes a `dotfiles` property, which is a VS Code-specific extension not part of the official devcontainer specification. This works in VS Code but may not work with other devcontainer tools. The User Settings method above is more portable.

### 4. Open in Devcontainer

1. Open your project in VS Code
2. Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
3. Select "Dev Containers: Reopen in Container"
4. Wait for container to build and dotfiles to install

## Named Volumes Explained

### Why Named Volumes?

Named volumes persist data across container rebuilds, which is essential for:

- Preserving Claude Code settings and customizations
- Keeping shell history
- Maintaining project-specific overrides

### Volume Naming Convention

The example uses `${localWorkspaceFolderBasename}-claude-volume`, which creates unique volumes per project:

- Project `my-app` → Volume `my-app-claude-volume`
- Project `api-server` → Volume `api-server-claude-volume`

This allows different projects to have different Claude Code configurations.

## Project-Specific Overrides

### Adding Project-Specific Claude Settings

The merge strategy preserves existing files, so you can add project-specific overrides:

1. **After first container build**, modify files in `~/.claude/` inside the container
2. These changes persist in the named volume
3. Dotfiles will NOT overwrite them on subsequent rebuilds

### Example: Project-Specific Settings

Create a project-specific settings.json:

```bash
# Inside the devcontainer
cat > ~/.claude/settings.json <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      "~/.claude/hooks/project-specific-validation.sh"
    ]
  }
}
EOF
```

This file will persist across rebuilds and won't be overwritten by dotfiles.

### Force-Updated Files

Some files are ALWAYS updated from dotfiles:

- `agents/*.md` - Shared agent definitions
- `commands/*.md` - Shared slash commands
- `hooks/*.sh` - Hook scripts (but settings.json controls which are used)

This ensures you get the latest shared tools while preserving customizations.

## Updating Dotfiles in a Running Container

To update your dotfiles in a running container:

```bash
# Inside the devcontainer
cd ~/.dotfiles
git pull
./install.sh
```

The installation will:
- Update force-updated files (agents, commands, hooks)
- Preserve your existing settings.json
- Show what was updated vs. skipped

## Troubleshooting

### Symlinks Appear Broken in Container

If you see broken symlinks in `~/.claude/` inside a container, the dotfiles installation didn't detect the devcontainer environment properly.

**Solution**: Check that `REMOTE_CONTAINERS` or `CODESPACES` environment variables are set. You can manually trigger merge mode by running:

```bash
source ~/.dotfiles/bootstrap/detect.sh
source ~/.dotfiles/bootstrap/merge-configs.sh
setup_claude_merge ~/.dotfiles/claude-code
```

### Settings Not Persisting Across Rebuilds

Make sure the volume mount is configured correctly in `devcontainer.json`:

```json
"mounts": [
  "source=${localWorkspaceFolderBasename}-claude-volume,target=/home/vscode/.claude,type=volume"
]
```

Verify the volume exists:
```bash
docker volume ls | grep claude
```

### Want to Reset Configuration

To reset to fresh dotfiles configuration:

```bash
# Remove the volume
docker volume rm your-project-claude-volume

# Rebuild the container
# Configuration will be freshly copied from dotfiles
```

## Best Practices

1. **Use named volumes** for configuration directories that should persist
2. **Keep base config in dotfiles**, project-specific in the volume
3. **Don't commit** `.devcontainer/devcontainer.json` if it contains personal settings
4. **Use `.gitignore`** for devcontainer files if they're user-specific:
   ```
   .devcontainer/
   ```
5. **Document project requirements** in project README if specific Claude settings are needed

## Alternative Approaches

### Bind Mount Dotfiles (Not Recommended for Volumes)

You could mount dotfiles directly:

```json
"mounts": [
  "source=${localEnv:HOME}/.dotfiles,target=/home/vscode/.dotfiles,type=bind"
]
```

**Pros**: Changes to dotfiles immediately reflected in container
**Cons**: Doesn't work in Codespaces, couples container to host filesystem

### Host Volume Mount for .claude (Not Recommended)

You could mount `.claude` from host:

```json
"mounts": [
  "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind"
]
```

**Pros**: Same config on host and container
**Cons**: Symlinks break, no project isolation, doesn't work in Codespaces

## Additional Resources

- [VS Code Dev Containers Documentation](https://code.visualstudio.com/docs/devcontainers/containers)
- [VS Code Dotfiles Support](https://code.visualstudio.com/docs/devcontainers/tips-and-tricks#_dotfiles)
- [Docker Volumes Documentation](https://docs.docker.com/storage/volumes/)
