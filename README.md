# RAIOT Multi-Project Git Layout

This directory is a **superproject** that tracks each child project as a Git submodule.

## Included submodules

- `Mecha-UI`
- `Richard-admin`
- `Richard-ai-server`
- `Richard-backend`
- `Richard-esp32`
- `Richard-mqtt-gateway`

## Environment setup

- See `docs/environment-setup.md` for local setup (MySQL, Redis, Node.js, Python, JDK/Maven, and one-command startup).
- For the current Windows Docker Desktop demo, use [`docs/local-docker.md`](docs/local-docker.md) and `Start-Local.ps1`. The older `start-all.ps1` targets the original native installation and changes device configuration; it is not the new container launcher.

## Local App and Hermes demo (2026-10-07)

The checkout is at `D:\workspace\personal\RAIOT`. The seven upstream submodules are present. The following local repositories extend the demo:

- `Richard-demo-app`: Flutter Android task creation, history, approval, cancellation and the human-control session entry.
- `Richard-im`: durable SQLite Run/event API and a separate Windows Hermes worker.
- `Richard-agent-runtime`: checkout of `RichardLirh/hermes-demo`, with cancellation and versioned approval integration.
- `Richard-admin`: retains the existing account/device UI and adds a read-only task monitor at `/local-runs.html`.

New local repositories have not yet been published or registered as remote submodules. Their source is kept in this checkout; cloning RAIOT elsewhere will not include them until that publication step is completed.

The independent local API can run before Docker is available:

```powershell
.\scripts\Start-TaskApi.ps1
```

Docker Desktop and WSL are installed. The first Windows restart was completed on 2026-10-08, and all seven local containers passed health checks. Open Docker Desktop and wait for its engine, then run:

```powershell
.\Start-Local.ps1 -ValidateOnly
.\Start-Local.ps1
```

The default stack contains MySQL, Redis, Java backend, task API and Admin. The `voice` profile adds AI and MQTT services after model assets and provider settings are prepared. The Windows cloud worker is deliberately separate; it uses the existing protected model/cloud credentials and creates ACS resources only for submitted tasks.

Access tokens and local database passwords are generated into ignored `.local/` and `.env.local`. Never add those files or an APK containing a local owner token to the public repository.

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

Existing submodule URLs point to `RichardLirh` repositories on GitHub. If a child repository moves, update its URL:

```powershell
git submodule set-url Richard-backend <your-remote-url>
git add .gitmodules
git commit -m "chore: update submodule remotes"
```
