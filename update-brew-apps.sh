#!/bin/bash

# =============================================================================
# update-brew-apps.sh — Keep brew-deployed apps current (Microsoft Intune)
# =============================================================================
#
# WHAT THIS DOES
#   Deploy this as a Microsoft Intune macOS SHELL-SCRIPT policy on a schedule.
#   It runs as root, drops to the user that owns Homebrew, and keeps every
#   brew-tracked formula and cask current:
#       brew update                       (refresh the package index)
#       brew upgrade --formula            (all CLI tools)
#       brew upgrade --cask               (GUI apps that DON'T self-update)
#       brew cleanup                      (reclaim disk)
#
# WHY NOT  brew upgrade --greedy  BY DEFAULT?
#   Casks marked `auto_updates true` (VS Code, Chrome, TeamViewer, Zoom,
#   Teams, ...) update THEMSELVES. brew only records the version it installed,
#   so once the app self-updates, brew's receipt goes stale and `--greedy`
#   tries to "upgrade" an app that is already current — which fails, e.g.:
#       Error: visual-studio-code: It seems the App source
#       '/tmp/brew_appdir_.../Visual Studio Code.app' is not there.
#   ...on EVERY run, forever. So by default we let self-updaters update
#   themselves (the app stays current either way) and only brew-upgrade the
#   things that actually need it. Set GREEDY_AUTO_UPDATES=true to force them
#   anyway — we then SKIP any cask whose on-disk version is already >= the tap
#   version, which avoids the failure above.
#
# PKG/DMG CASKS
#   Upgrading a pkg-type cask re-runs `sudo /usr/sbin/installer` internally
#   (same as install). We stage the identical temporary, SETENV-tagged NOPASSWD
#   sudoers drop-in around cask upgrades so they succeed non-interactively, then
#   remove it (mirrors build-pkg.sh).
#
# DEPLOY IN INTUNE
#   Devices ▸ macOS ▸ Shell scripts ▸ Add
#     Run script as signed-in user : No   (must run as root)
#     Script frequency             : e.g. every 1 day
#     Max retries                  : 1-3
# =============================================================================


# ---------------------------[ Behaviour Configuration ]----------------------
# Force-upgrade self-updating casks via brew (see header). Default false.
# When true, casks already current on disk are skipped (no spurious failures).
GREEDY_AUTO_UPDATES=false

# Exit 1 (Intune marks the run "failed") if any package fails to upgrade.
# Default false: log the failure clearly but exit 0, so routine scheduled runs
# don't perpetually alarm on transient issues (e.g. an app being open).
FAIL_ON_PACKAGE_ERROR=false
# =============================================================================


# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="update-brew-apps"
LOG_FILE_NAME="$(date '+%Y-%m-%d').log"

# ---------------------------[ Logging Setup ]---------------------------
LOG=true
LOG_DEBUG=false
LOG_GET=true
LOG_RUN=true
ENABLE_LOG_FILE=true
LOG_FILE_DIRECTORY="/Library/Logs/IntuneLogs/Scripts/$SCRIPT_NAME"
LOG_FILE="$LOG_FILE_DIRECTORY/$LOG_FILE_NAME"

if [ "$ENABLE_LOG_FILE" = true ] && [ ! -d "$LOG_FILE_DIRECTORY" ]; then
    mkdir -p "$LOG_FILE_DIRECTORY"
fi

# ---------------------------[ Logging Function ]---------------------------
write_log() {
    local MESSAGE="$1"
    local TAG="${2:-Info}"
    [ "$LOG" = false ] && return
    [ "$TAG" = "Debug" ] && [ "$LOG_DEBUG" = false ] && return
    [ "$TAG" = "Get"   ] && [ "$LOG_GET"   = false ] && return
    [ "$TAG" = "Run"   ] && [ "$LOG_RUN"   = false ] && return
    local TIMESTAMP
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    local VALID_TAGS=("Start" "Get" "Run" "Info" "Success" "Error" "Debug" "End")
    local RAW_TAG="$TAG"
    local IS_VALID=false
    for T in "${VALID_TAGS[@]}"; do [ "$T" = "$RAW_TAG" ] && IS_VALID=true && break; done
    [ "$IS_VALID" = false ] && RAW_TAG="Error"
    local RAW_TAG_PADDED
    RAW_TAG_PADDED=$(printf "%-7s" "$RAW_TAG")
    local LOG_MESSAGE="$TIMESTAMP [  $RAW_TAG_PADDED ] $MESSAGE"
    if [ "$ENABLE_LOG_FILE" = true ]; then
        { echo "$LOG_MESSAGE" >> "$LOG_FILE"; } 2>/dev/null || true
    fi
    local COLOR_RESET="\033[0m"
    local COLOR_WHITE="\033[1;37m"
    local COLOR
    case "$RAW_TAG" in
        "Start")   COLOR="\033[0;36m"  ;;
        "Get")     COLOR="\033[0;34m"  ;;
        "Run")     COLOR="\033[0;35m"  ;;
        "Info")    COLOR="\033[0;33m"  ;;
        "Success") COLOR="\033[0;32m"  ;;
        "Error")   COLOR="\033[0;31m"  ;;
        "Debug")   COLOR="\033[0;33m"  ;;
        "End")     COLOR="\033[0;36m"  ;;
        *)         COLOR="\033[1;37m"  ;;
    esac
    printf "%s " "$TIMESTAMP"
    printf "${COLOR_WHITE}[ ${COLOR_RESET}"
    printf "${COLOR}%s${COLOR_RESET}" "$RAW_TAG_PADDED"
    printf "${COLOR_WHITE} ]${COLOR_RESET} "
    printf "%s\n" "$MESSAGE"
}

# Log a captured multi-line command output, one indented line per row.
log_block() {
    local TAG="$1"; local TEXT="$2"
    while IFS= read -r LINE; do
        [ -n "$LINE" ] && write_log "    | $LINE" "$TAG"
    done <<< "$TEXT"
}

# ---------------------------[ Exit Function ]---------------------------
complete_script() {
    local EXIT_CODE="${1:-0}"
    local SCRIPT_END_TIME
    SCRIPT_END_TIME=$(date +%s%N)
    local DURATION_NS=$(( SCRIPT_END_TIME - SCRIPT_START_TIME ))
    local DURATION_S=$(( DURATION_NS / 1000000000 ))
    local DURATION_MS=$(( (DURATION_NS % 1000000000) / 10000000 ))
    local DURATION_FORMATTED
    DURATION_FORMATTED=$(printf "%02d:%02d:%02d.%02d" \
        $(( DURATION_S / 3600 )) \
        $(( (DURATION_S % 3600) / 60 )) \
        $(( DURATION_S % 60 )) \
        "$DURATION_MS")
    write_log "Runtime $DURATION_FORMATTED" "Info"
    write_log "Exit $EXIT_CODE" "Info"
    write_log "==================== End ====================" "End"
    exit "$EXIT_CODE"
}

# ---------------------------[ Version compare: $1 >= $2 ? ]---------------------------
ver_ge() {
    [ "$1" = "$2" ] && return 0
    local lowest
    lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
    [ "$lowest" = "$2" ]
}

# =============================================================================
# ---------------------------[ Script Start ]---------------------------
# =============================================================================
HOSTNAME=$(hostname)
ERRORS=0
FAILED_PKGS=()

write_log "==================== Start ====================" "Start"
write_log "$HOSTNAME | $(whoami) | $SCRIPT_NAME" "Info"
write_log "Triggered by Intune scheduled run" "Info"
write_log "Running as: $(whoami) (uid $(id -u)) | greedy=$GREEDY_AUTO_UPDATES" "Debug"

# ---------------------------[ Locate Homebrew + owner ]---------------------------
write_log "Locating Homebrew and its owning user..." "Get"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW="/opt/homebrew/bin/brew"
else
    BREW="/usr/local/bin/brew"
fi
if [ ! -x "$BREW" ]; then
    write_log "Homebrew not found at $BREW — nothing to update (deploy Homebrew first)." "Error"
    complete_script 1
fi
BREW_PREFIX="$(cd "$(dirname "$BREW")/.." && pwd)"
BREW_OWNER="$(stat -f%Su "$BREW")"
if [ -z "$BREW_OWNER" ] || [ "$BREW_OWNER" = "root" ]; then
    write_log "Homebrew prefix is owned by '$BREW_OWNER' — cannot run brew as that user." "Error"
    complete_script 1
fi
USER_HOME="$(dscl . -read "/Users/$BREW_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -d "$USER_HOME" ] || USER_HOME="/Users/$BREW_OWNER"
write_log "Architecture: $ARCH | brew: $BREW | owner: $BREW_OWNER" "Get"

# ---------------------------[ Run brew as the owner ]---------------------------
# Works whether the script runs as root (Intune) or already as the owner (manual test).
brew_as_owner() {
    cd /tmp || return 1
    if [ "$(id -un)" = "$BREW_OWNER" ]; then
        HOME="$USER_HOME" \
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 \
        PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BREW" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        /usr/bin/sudo -u "$BREW_OWNER" \
            HOME="$USER_HOME" \
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 \
            PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            "$BREW" "$@"
    else
        write_log "Not running as root or as brew owner '$BREW_OWNER' — cannot run brew." "Error"
        return 97
    fi
}

# ---------------------------[ sudoers helpers (cask upgrades) ]---------------------------
# Same SETENV-tagged rule used by build-pkg.sh, so brew's internal
# 'sudo -u root /usr/sbin/installer' for pkg-casks works non-interactively.
SUDOERS_FILE="/etc/sudoers.d/intune-brew-update"
remove_sudoers() { [ "$(id -u)" -eq 0 ] && rm -f "$SUDOERS_FILE" 2>/dev/null; }
setup_sudoers() {
    [ "$(id -u)" -eq 0 ] || return 0   # only root can/need write sudoers; manual runs auth interactively
    local tmp
    tmp=$(mktemp) || return 1
    printf '%s ALL=(root) NOPASSWD: SETENV: /usr/sbin/installer\n' "$BREW_OWNER" > "$tmp"
    if /usr/sbin/visudo -cf "$tmp" >/dev/null 2>&1; then
        /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
        rm -f "$tmp"
        /usr/sbin/visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1 && return 0
        rm -f "$SUDOERS_FILE"; return 1
    fi
    rm -f "$tmp"; return 1
}
trap remove_sudoers EXIT TERM INT HUP
remove_sudoers   # clear any stale rule a prior killed run may have left behind

# ---------------------------[ Resolve a cask's installed .app path ]---------------------------
# Used by the greedy pass to compare the on-disk version against the tap.
cask_app_path() {
    brew_as_owner info --cask "$1" --json=v2 2>/dev/null | python3 - << 'PY' 2>/dev/null
import sys, json
try:
    c = json.load(sys.stdin)["casks"][0]
except Exception:
    sys.exit(1)
def base(p): return str(p).rstrip("/").split("/")[-1]
arts = c.get("artifacts") or []
for a in arts:
    if isinstance(a, dict) and a.get("app"):
        src=tgt=None
        for e in a["app"]:
            if isinstance(e, str): src = e
            elif isinstance(e, dict) and e.get("target"): tgt = e["target"]
        if tgt: print(tgt); sys.exit(0)
        if src: print("/Applications/" + base(src)); sys.exit(0)
for a in arts:
    if not isinstance(a, dict): continue
    for k in ("uninstall","zap"):
        for entry in (a.get(k) or []):
            if not isinstance(entry, dict): continue
            for fld in ("delete","trash"):
                vals = entry.get(fld) or []
                if isinstance(vals, str): vals=[vals]
                for v in vals:
                    v=str(v)
                    if v.endswith(".app") and "/Applications/" in v:
                        print(v); sys.exit(0)
PY
}

# =============================================================================
# Homebrew
# =============================================================================
BREW_VERSION="$(brew_as_owner --version 2>/dev/null | head -1)"
write_log "Homebrew: ${BREW_VERSION:-unknown}" "Get"

# --- brew update (refresh index) ---
write_log "Updating Homebrew package index..." "Run"
UPDATE_OUTPUT="$(brew_as_owner update 2>&1)"; UPDATE_EXIT=$?
if [ $UPDATE_EXIT -ne 0 ]; then
    write_log "brew update failed (exit $UPDATE_EXIT):" "Error"
    log_block "Error" "$UPDATE_OUTPUT"
    ERRORS=$(( ERRORS + 1 ))
else
    write_log "Package index updated." "Success"
fi

# =============================================================================
# Formulae (CLI tools) — always safe to brew-upgrade
# =============================================================================
OUTDATED_F="$(brew_as_owner outdated --formula 2>/dev/null)"
if [ -z "$OUTDATED_F" ]; then
    write_log "Formulae: all up to date." "Success"
else
    F_COUNT=$(printf '%s\n' "$OUTDATED_F" | grep -c .)
    write_log "Formulae outdated ($F_COUNT):" "Get"
    while IFS= read -r P; do [ -n "$P" ] && write_log "  → $P" "Get"; done <<< "$OUTDATED_F"
    write_log "Running brew upgrade --formula..." "Run"
    F_OUT="$(brew_as_owner upgrade --formula 2>&1)"; F_EXIT=$?
    if [ $F_EXIT -ne 0 ]; then
        write_log "brew upgrade --formula failed (exit $F_EXIT):" "Error"
        log_block "Error" "$F_OUT"
        FAILED_PKGS+=("formulae")
        ERRORS=$(( ERRORS + 1 ))
    else
        log_block "Debug" "$F_OUT"
        write_log "Formulae upgraded." "Success"
    fi
fi

# =============================================================================
# Casks (GUI apps) that do NOT self-update — brew owns their updates
# =============================================================================
OUTDATED_C="$(brew_as_owner outdated --cask 2>/dev/null)"
if [ -z "$OUTDATED_C" ]; then
    write_log "Casks (non-self-updating): all up to date." "Success"
else
    C_COUNT=$(printf '%s\n' "$OUTDATED_C" | grep -c .)
    write_log "Casks outdated ($C_COUNT):" "Get"
    while IFS= read -r P; do [ -n "$P" ] && write_log "  → $P" "Get"; done <<< "$OUTDATED_C"
    write_log "Staging temporary sudoers rule for pkg-cask upgrades..." "Run"
    setup_sudoers || write_log "Could not stage sudoers rule — pkg-type cask upgrades may prompt/fail." "Error"
    write_log "Running brew upgrade --cask..." "Run"
    C_OUT="$(brew_as_owner upgrade --cask 2>&1)"; C_EXIT=$?
    remove_sudoers
    if [ $C_EXIT -ne 0 ]; then
        write_log "brew upgrade --cask failed (exit $C_EXIT):" "Error"
        log_block "Error" "$C_OUT"
        FAILED_PKGS+=("casks")
        ERRORS=$(( ERRORS + 1 ))
    else
        log_block "Debug" "$C_OUT"
        write_log "Casks upgraded." "Success"
    fi
fi

# =============================================================================
# Self-updating casks (auto_updates / :latest)
# =============================================================================
GREEDY_LIST="$(brew_as_owner outdated --cask --greedy 2>/dev/null)"
# Self-updaters = greedy-outdated minus the non-greedy list we already handled.
SELF_UPDATERS=""
while IFS= read -r P; do
    [ -z "$P" ] && continue
    if ! printf '%s\n' "$OUTDATED_C" | grep -qx "$P"; then
        SELF_UPDATERS+="$P"$'\n'
    fi
done <<< "$GREEDY_LIST"
SELF_UPDATERS="$(printf '%s' "$SELF_UPDATERS" | sed '/^$/d')"

if [ "$GREEDY_AUTO_UPDATES" != "true" ]; then
    if [ -n "$SELF_UPDATERS" ]; then
        S_COUNT=$(printf '%s\n' "$SELF_UPDATERS" | grep -c .)
        write_log "Leaving $S_COUNT self-updating cask(s) to the app's own updater (GREEDY_AUTO_UPDATES=false):" "Info"
        while IFS= read -r P; do [ -n "$P" ] && write_log "  · $P" "Info"; done <<< "$SELF_UPDATERS"
    fi
else
    if [ -n "$SELF_UPDATERS" ]; then
        write_log "Greedy pass over self-updating casks (skipping any already current on disk)..." "Run"
        while IFS= read -r TOKEN; do
            [ -z "$TOKEN" ] && continue
            TAP_VER="$(brew_as_owner info --cask "$TOKEN" --json=v2 2>/dev/null \
                | python3 -c "import sys,json; print((json.load(sys.stdin)['casks'][0].get('version') or '').split(',')[0])" 2>/dev/null)"
            APP_PATH="$(cask_app_path "$TOKEN")"
            DISK_VER=""
            [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] && \
                DISK_VER="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
            if [ -n "$DISK_VER" ] && [ -n "$TAP_VER" ] && ver_ge "$DISK_VER" "$TAP_VER"; then
                write_log "  · $TOKEN: on-disk $DISK_VER already >= tap $TAP_VER — self-updated, skipping." "Info"
                continue
            fi
            write_log "  → upgrading $TOKEN (disk='${DISK_VER:-?}' tap='${TAP_VER:-?}')..." "Run"
            setup_sudoers || write_log "    Could not stage sudoers rule for $TOKEN." "Error"
            G_OUT="$(brew_as_owner upgrade --cask "$TOKEN" --greedy 2>&1)"; G_EXIT=$?
            remove_sudoers
            if [ $G_EXIT -ne 0 ]; then
                write_log "  $TOKEN upgrade failed (exit $G_EXIT):" "Error"
                log_block "Error" "$G_OUT"
                FAILED_PKGS+=("$TOKEN")
                ERRORS=$(( ERRORS + 1 ))
            else
                log_block "Debug" "$G_OUT"
                write_log "  $TOKEN upgraded." "Success"
            fi
        done <<< "$SELF_UPDATERS"
    fi
fi

# =============================================================================
# Cleanup
# =============================================================================
write_log "Running brew cleanup..." "Run"
CLEAN_OUT="$(brew_as_owner cleanup 2>&1)"
log_block "Debug" "$CLEAN_OUT"
write_log "Cleanup complete." "Success"

# =============================================================================
# Summary
# =============================================================================
if [ $ERRORS -eq 0 ]; then
    write_log "All sections completed without errors." "Success"
    complete_script 0
fi

write_log "$ERRORS issue(s) this run. Failed: ${FAILED_PKGS[*]}" "Error"
if [ "$FAIL_ON_PACKAGE_ERROR" = "true" ]; then
    complete_script 1
else
    write_log "FAIL_ON_PACKAGE_ERROR=false — reporting success to Intune; see errors above." "Info"
    complete_script 0
fi
