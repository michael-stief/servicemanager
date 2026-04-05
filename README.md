# Service Manager

A macOS menu bar process supervisor. Drop executables into `~/.local/services/` and they run. No launchd plists, no config files.

Pure AppKit, no Xcode project, builds with `swift build`.

![Service Manager](screenshot.png)

## Build & Install

Requires macOS 13+ and Swift 6.0+.

```bash
git clone https://github.com/YOUR_USERNAME/service-manager.git
cd service-manager
swift build -c release
cp .build/release/ServiceManager ServiceManager.app/Contents/MacOS/ServiceManager
cp -r ServiceManager.app /Applications/
open /Applications/ServiceManager.app
```

## Usage

```bash
mkdir -p ~/.local/services
```

**Services** — any executable without a schedule suffix. Starts immediately, restarts on exit with exponential backoff (1s → 30s cap, resets after 60s uptime).

```bash
ln -s /usr/local/bin/some-daemon ~/.local/services/some-daemon
```

**Scheduled tasks** — append a schedule suffix to the filename. Times are anchored to midnight, not app start. Missed jobs are skipped.

| Suffix | Example | Fires at |
|--------|---------|----------|
| `.Xm` | `backup.5m` | :00, :05, :10, ... |
| `.Xh` | `sync.2h` | 00:00, 02:00, 04:00, ... |
| `.Xd` | `cleanup.1d` | Daily at midnight |

**Logs** — stdout + stderr go to `~/.local/log/<name>.log`. The panel tails the last 80 lines. Click the filename to reveal in Finder, click the file size to truncate.

**Menu bar** — left-click opens the panel, right-click to quit. Click a service row to stop/start it, click a task row to force-run it.

The directory is watched via FSEvents — add or remove scripts at runtime, no restart needed. Shutdown sends SIGTERM → SIGQUIT → SIGKILL to process groups.

## License

MIT
