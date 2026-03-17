# APK Lifecycle Manager

Configuration-driven APK lifecycle manager for Synology NAS. Organizes, archives, and purges Android APK backups from a JSON config. Normalizes `.apk+` partial files common in Android backup tools. Designed for any workflow mirroring a device APK directory to a NAS homes folder. Zero dependencies, pure bash.

## How It Works

```
Device (Android)
    │
    │  CX File Explorer backs up APKs to device storage
    │  Autosync mirrors device storage to NAS
    ▼
/volume1/homes/DEVICENAME/backups/apps/    ← watch_dir
    │
    │  APK Lifecycle Manager runs on schedule
    │
    ├── Step 0: Normalize .apk+ → .apk
    ├── Step 1: Organize into subfolders by app
    ├── Step 2: Archive files older than archive_after_days
    └── Step 3: Delete from archive older than delete_after_days
    ▼
/volume1/Software/Android/                 ← archive_dir
    ├── Spotify AB - Spotify/
    ├── Google LLC - Voice/
    └── ...
```

## Requirements

- Synology NAS running DSM 6 or later
- Bash (stock Synology shell)
- No additional packages required

## Installation

1. Copy `APK-Lifecycle-Manager.sh` and `config.json` to your NAS:
   ```
   /volume1/Scripts/APK-Lifecycle-Manager/
   ├── APK-Lifecycle-Manager.sh
   └── config.json
   ```

2. Copy `config.json.example` to `config.json` and edit it:
   ```bash
   cp config.json.example config.json
   nano config.json
   ```

3. Make the script executable:
   ```bash
   chmod +x /volume1/Scripts/APK-Lifecycle-Manager/APK-Lifecycle-Manager.sh
   ```

4. Fix line endings if copied from Windows:
   ```bash
   sed -i 's/\r//' /volume1/Scripts/APK-Lifecycle-Manager/APK-Lifecycle-Manager.sh
   sed -i 's/\r//' /volume1/Scripts/APK-Lifecycle-Manager/config.json
   ```

5. Test manually:
   ```bash
   /bin/bash /volume1/Scripts/APK-Lifecycle-Manager/APK-Lifecycle-Manager.sh
   ```

6. Schedule via Synology Task Scheduler or crontab:
   ```bash
   # Run every 5 minutes (recommended for testing, change to daily for production)
   echo '*/5 * * * * root /bin/bash /volume1/Scripts/APK-Lifecycle-Manager/APK-Lifecycle-Manager.sh' | sudo tee -a /etc/crontab
   sudo synocrond restart
   ```

## Configuration

Edit `config.json` to define your paths and apps. See `config.json.example` for a full example.

### Paths

```json
"paths": {
  "watch_dir": "/volume1/homes/DEVICENAME/backups/apps",
  "archive_dir": "/volume1/Software/Android"
}
```

- `watch_dir` — where your device APKs are mirrored to on the NAS
- `archive_dir` — where old APKs are archived to for long-term storage

### Global Defaults

```json
"global_defaults": {
  "archive_after_days": 60,
  "archive_action": "move",
  "delete_after_days": 365
}
```

- `archive_after_days` — days before an APK in watch_dir is moved to archive
- `archive_action` — `move` or `delete`
- `delete_after_days` — days before an APK in archive_dir is permanently deleted

### Apps

Each app entry defines how a specific APK is handled:

```json
{
  "id": 1,
  "manufacturer": "Spotify AB",
  "display_name": "Spotify",
  "folder": "Spotify AB - Spotify",
  "package_prefix": "Spotify",
  "category": "Music",
  "archive_after_days": 60,
  "archive_action": "move",
  "delete_after_days": 365,
  "notes": ""
}
```

- `id` — sequential integer, last id = total app count
- `folder` — subfolder name created in both watch_dir and archive_dir
- `package_prefix` — filename prefix used to match APKs (case-insensitive)
- Per-app `archive_after_days`, `archive_action`, and `delete_after_days` override global defaults

### Prefix Ordering

If multiple apps share a common prefix (e.g. `Google`, `Google Wallet`, `Google Play services`), place the more specific entries **before** the generic one in the apps array. The script processes entries top to bottom and a file can only be matched once.

## The .apk+ Problem

Some Android backup tools write a `.apk+` file alongside the completed `.apk` during transfer. This script normalizes all `.apk+` files to `.apk` before any other processing. If a `.apk` with the same name already exists, it is overwritten.

## File Lifecycle

```
Day 0        APK appears in watch_dir
Day 0-60     APK sits in watch_dir/FOLDER/
Day 60       APK moved to archive_dir/FOLDER/
Day 60-365   APK sits in archive_dir/FOLDER/
Day 365      APK permanently deleted
```

All thresholds are configurable globally or per app.

## Logs

The script writes a log to:
```
/volume1/Scripts/APK-Lifecycle-Manager/apk-lifecycle.log
```

Each run appends to the log. Rotate as needed.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.
