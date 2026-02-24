# RAIOT Multi-Project Git Layout

This directory is a **superproject** that tracks each child project as a Git submodule.

## Included submodules

- `Mecha-UI`
- `Richard-admin`
- `Richard-ai-server`
- `Richard-backend`
- `Richard-esp32`
- `Richard-mqtt-gateway`

## Daily workflow

1. Enter a child project and commit there first:

```powershell
cd Richard-backend
git add .
git commit -m "feat: ..."
```

2. Return to this root and update the submodule pointer:

```powershell
cd ..
git add Richard-backend
git commit -m "chore: bump Richard-backend"
```

3. Pull all submodules after cloning:

```powershell
git submodule update --init --recursive
```

## Important note

Current submodule URLs are local paths (for local setup).
If you publish these projects to remote Git hosts, update URLs:

```powershell
git submodule set-url Richard-backend <your-remote-url>
git add .gitmodules
git commit -m "chore: update submodule remotes"
```
