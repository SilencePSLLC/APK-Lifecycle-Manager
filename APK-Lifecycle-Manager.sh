#!/bin/bash
# =============================================================================
# APK-Lifecycle-Manager.sh
# https://github.com/SilencePSLLC/APK-Lifecycle-Manager
#
# Reads config.json, scans watch_dir, organizes APKs into subfolders,
# archives old APKs to archive_dir, and deletes from archive after
# delete_after_days.
#
# Rules:
#   - Only APKs matching a config entry are touched
#   - Files not in config are left completely alone
#   - Archive path mirrors folder structure: archive_dir/folder/file.apk
#   - .apk+ partial files are normalized to .apk before all other steps
#
# Setup:
#   1. Copy config.json.example to config.json and edit paths and apps
#   2. chmod +x APK-Lifecycle-Manager.sh
#   3. sed -i 's/\r//' APK-Lifecycle-Manager.sh config.json
#   4. Schedule via Task Scheduler or crontab
#
# License: GNU General Public License v3.0
# =============================================================================

set -euo pipefail

# ── Script directory — config.json and log live here ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
LOG_FILE="$SCRIPT_DIR/apk-lifecycle.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: Config not found: $CONFIG_FILE"
    log "       Copy config.json.example to config.json and edit it."
    exit 1
fi

# ── Pure bash JSON helpers ────────────────────────────────────────────────────
get_json_value() {
    grep -o "\"${2}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" \
        | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

get_json_number() {
    grep -o "\"${2}\"[[:space:]]*:[[:space:]]*[0-9]*" "$1" \
        | head -1 | grep -o '[0-9]*$'
}

# ── Read global config ────────────────────────────────────────────────────────
WATCH_DIR=$(get_json_value "$CONFIG_FILE" "watch_dir")
ARCHIVE_DIR=$(get_json_value "$CONFIG_FILE" "archive_dir")
GLOBAL_ARCHIVE_DAYS=$(get_json_number "$CONFIG_FILE" "archive_after_days")
GLOBAL_ACTION=$(get_json_value "$CONFIG_FILE" "archive_action")
GLOBAL_DELETE_DAYS=$(get_json_number "$CONFIG_FILE" "delete_after_days")

log "═══════════════════════════════════════════════════"
log "APK Lifecycle Manager started"
log "  Watch dir:     $WATCH_DIR"
log "  Archive dir:   $ARCHIVE_DIR"
log "  Archive after: ${GLOBAL_ARCHIVE_DAYS} days"
log "  Delete after:  ${GLOBAL_DELETE_DAYS} days (from archive)"

if [[ ! -d "$WATCH_DIR" ]]; then
    log "ERROR: Watch directory not found: $WATCH_DIR"; exit 1
fi
if [[ ! -d "$ARCHIVE_DIR" ]]; then
    log "ERROR: Archive directory not found: $ARCHIVE_DIR"; exit 1
fi

# ── Parse app entries ─────────────────────────────────────────────────────────
APP_FOLDERS=()
APP_PREFIXES=()
APP_DAYS=()
APP_ACTIONS=()
APP_DELETE_DAYS=()

parse_apps() {
    local in_apps=0 in_object=0
    local cur_folder="" cur_prefix="" cur_days="" cur_action="" cur_delete=""

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" == '"apps"'* ]] && in_apps=1 && continue
        [[ $in_apps -eq 0 ]] && continue
        [[ "$line" == ']'* ]] && break
        [[ "$line" == '{'* ]] && in_object=1 && continue

        if [[ $in_object -eq 1 ]]; then
            if [[ "$line" =~ ^\"folder\"[[:space:]]*:[[:space:]]*\"(.*)\"[,]?$ ]]; then
                cur_folder="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^\"package_prefix\"[[:space:]]*:[[:space:]]*\"(.*)\"[,]?$ ]]; then
                cur_prefix="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^\"archive_after_days\"[[:space:]]*:[[:space:]]*([0-9]+)[,]?$ ]]; then
                cur_days="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^\"archive_action\"[[:space:]]*:[[:space:]]*\"(.*)\"[,]?$ ]]; then
                cur_action="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^\"delete_after_days\"[[:space:]]*:[[:space:]]*([0-9]+)[,]?$ ]]; then
                cur_delete="${BASH_REMATCH[1]}"
            fi

            if [[ "$line" == '}'* ]]; then
                APP_FOLDERS+=("$cur_folder")
                APP_PREFIXES+=("$cur_prefix")
                APP_DAYS+=("${cur_days:-$GLOBAL_ARCHIVE_DAYS}")
                APP_ACTIONS+=("${cur_action:-$GLOBAL_ACTION}")
                APP_DELETE_DAYS+=("${cur_delete:-$GLOBAL_DELETE_DAYS}")
                cur_folder="" cur_prefix="" cur_days="" cur_action="" cur_delete=""
                in_object=0
            fi
        fi
    done < "$CONFIG_FILE"
}

# ── Step 0: Normalize .apk+ → .apk ───────────────────────────────────────────
# Some Android backup tools write .apk+ alongside completed .apk files during
# transfer. This step renames all .apk+ files to .apk before any other
# processing. If a .apk with the same name already exists it is overwritten.
normalize_extensions() {
    local renamed=0
    log "── Normalizing .apk+ extensions ─────────────────────────"

    while IFS= read -r apkplus; do
        [[ -e "$apkplus" ]] || continue
        local target="${apkplus%+}"
        mv -f "$apkplus" "$target"
        log "  Renamed: $(basename "$apkplus") -> $(basename "$target")"
        (( renamed++ )) || true
    done < <(find "$WATCH_DIR" -type f -name "*.apk+")

    [[ $renamed -eq 0 ]] && log "  No .apk+ files found." || log "  Renamed: $renamed file(s)"
}

# ── Step 1: Organize APKs into subfolders ─────────────────────────────────────
# Only moves root-level files matching a configured prefix into subfolders.
# Files not matching any config entry are left untouched.
organize_apks() {
    local moved=0
    log "── Organizing APKs ──────────────────────────────────────"

    for (( i=0; i<${#APP_FOLDERS[@]}; i++ )); do
        local folder="${APP_FOLDERS[$i]}"
        local prefix="${APP_PREFIXES[$i]}"
        [[ -z "$prefix" ]] && continue

        while IFS= read -r apk; do
            [[ -e "$apk" ]] || continue
            local target="$WATCH_DIR/$folder"
            mkdir -p "$target"
            local filename; filename="$(basename "$apk")"
            [[ "$(dirname "$apk")" == "$target" ]] && continue
            mv -n "$apk" "$target/$filename"
            log "  Organized: $filename -> $folder/"
            (( moved++ )) || true
        done < <(find "$WATCH_DIR" -maxdepth 1 -type f -iname "${prefix}*.apk")
    done

    log "  Organized: $moved APKs"
}

# ── Step 2: Archive old APKs from watch_dir ───────────────────────────────────
# Moves APKs older than archive_after_days from configured subfolders in
# watch_dir to the matching subfolder in archive_dir.
archive_old_apks() {
    local archived=0
    local now; now=$(date +%s)
    log "── Archiving old APKs ───────────────────────────────────"

    for (( i=0; i<${#APP_FOLDERS[@]}; i++ )); do
        local folder="${APP_FOLDERS[$i]}"
        local archive_days="${APP_DAYS[$i]}"
        local action="${APP_ACTIONS[$i]}"
        local archive_cutoff=$(( now - archive_days * 86400 ))
        local source_folder="$WATCH_DIR/$folder"
        [[ -d "$source_folder" ]] || continue

        while IFS= read -r apk; do
            [[ -e "$apk" ]] || continue
            local mod_time
            mod_time=$(stat -c '%Y' "$apk" 2>/dev/null || stat -f '%m' "$apk" 2>/dev/null)
            [[ -z "$mod_time" ]] && continue
            (( mod_time < archive_cutoff )) || continue

            local age_days=$(( (now - mod_time) / 86400 ))
            local filename; filename="$(basename "$apk")"
            local archive_target="$ARCHIVE_DIR/$folder"
            mkdir -p "$archive_target"

            if [[ "$action" == "move" ]]; then
                mv -f "$apk" "$archive_target/$filename"
                log "  Archived (${age_days}d): $filename -> $folder/"
            elif [[ "$action" == "delete" ]]; then
                rm -f "$apk"
                log "  Deleted from watch (${age_days}d): $filename"
            fi
            (( archived++ )) || true
        done < <(find "$source_folder" -maxdepth 1 -type f -iname "*.apk")
    done

    log "  Archived: $archived APKs"
}

# ── Step 3: Delete old APKs from archive_dir ─────────────────────────────────
# Permanently deletes APKs older than delete_after_days from configured
# subfolders in archive_dir.
delete_old_from_archive() {
    local deleted=0
    local now; now=$(date +%s)
    log "── Deleting old APKs from archive ───────────────────────"

    for (( i=0; i<${#APP_FOLDERS[@]}; i++ )); do
        local folder="${APP_FOLDERS[$i]}"
        local delete_days="${APP_DELETE_DAYS[$i]}"
        [[ -z "$delete_days" ]] && continue
        local delete_cutoff=$(( now - delete_days * 86400 ))
        local archive_folder="$ARCHIVE_DIR/$folder"
        [[ -d "$archive_folder" ]] || continue

        while IFS= read -r apk; do
            [[ -e "$apk" ]] || continue
            local mod_time
            mod_time=$(stat -c '%Y' "$apk" 2>/dev/null || stat -f '%m' "$apk" 2>/dev/null)
            [[ -z "$mod_time" ]] && continue
            (( mod_time < delete_cutoff )) || continue

            local age_days=$(( (now - mod_time) / 86400 ))
            local filename; filename="$(basename "$apk")"
            rm -f "$apk"
            log "  Deleted from archive (${age_days}d): $folder/$filename"
            (( deleted++ )) || true
        done < <(find "$archive_folder" -maxdepth 1 -type f -iname "*.apk")
    done

    log "  Deleted from archive: $deleted APKs"
}

# ── Summary ───────────────────────────────────────────────────────────────────
summarize() {
    local watch_count archive_count
    watch_count=$(find "$WATCH_DIR" -type f -iname "*.apk" 2>/dev/null | wc -l)
    archive_count=$(find "$ARCHIVE_DIR" -type f -iname "*.apk" 2>/dev/null | wc -l)
    log "── Summary ──────────────────────────────────────────────"
    log "  Watch dir APKs:   $watch_count"
    log "  Archive dir APKs: $archive_count"
    log "═══════════════════════════════════════════════════"
}

# ── Entry point ───────────────────────────────────────────────────────────────
parse_apps
log "  Loaded ${#APP_FOLDERS[@]} app(s) from config."
normalize_extensions    # Step 0 — must run before all other steps
organize_apks           # Step 1
archive_old_apks        # Step 2
delete_old_from_archive # Step 3
summarize
log "APK Lifecycle Manager finished"
