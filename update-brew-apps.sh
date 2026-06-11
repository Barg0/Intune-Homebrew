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
#   Upgrading a pkg-type cask first UNINSTALLS the old version (launchctl,
#   pkgutil --forget, rm of receipt-listed files — all via internal sudo) and
#   then re-runs `sudo /usr/sbin/installer`. We stage a temporary, SETENV-tagged
#   NOPASSWD sudoers drop-in covering exactly those binaries around each cask
#   upgrade so it succeeds non-interactively, then remove it (extends the
#   installer-only rule used by build-pkg.sh, which only needs fresh installs).
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
GREEDY_AUTO_UPDATES=true

# Exit 1 (Intune marks the run "failed") if any package fails to upgrade.
# Default false: log the failure clearly but exit 0, so routine scheduled runs
# don't perpetually alarm on transient issues (e.g. an app being open).
FAIL_ON_PACKAGE_ERROR=false

# Defer the greedy brew-upgrade of an .app-bundle cask when that app is
# currently OPEN on the device (replacing an in-use bundle is disruptive and
# can fail with "It seems the App source ... is not there"; the cask is simply
# retried on the next scheduled run). pkg-type casks (e.g. TeamViewer) are
# never deferred — their background daemons would otherwise defer them forever.
# Set false to always upgrade regardless of whether the app is running.
SKIP_RUNNING_APPS=false
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
    # NONINTERACTIVE + SUDO_ASKPASS=/usr/bin/false (same as build-pkg.sh): any
    # internal sudo NOT covered by the temporary sudoers rule fails fast
    # instead of stalling on a password prompt in the headless Intune context.
    if [ "$(id -un)" = "$BREW_OWNER" ]; then
        HOME="$USER_HOME" \
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 \
        NONINTERACTIVE=1 \
        PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BREW" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        /usr/bin/sudo -u "$BREW_OWNER" \
            HOME="$USER_HOME" \
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 \
            NONINTERACTIVE=1 SUDO_ASKPASS=/usr/bin/false \
            PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            "$BREW" "$@"
    else
        write_log "Not running as root or as brew owner '$BREW_OWNER' — cannot run brew." "Error"
        return 97
    fi
}

# ---------------------------[ sudoers helpers (cask upgrades) ]---------------------------
# Same SETENV-tagged pattern as build-pkg.sh, but broader: a cask UPGRADE first
# UNINSTALLS the old version, and brew internally elevates more than just
# /usr/sbin/installer for that, e.g.:
#   sudo launchctl remove <service>                     (launchd services)
#   sudo -E -- /usr/bin/xargs -0 -- /bin/rm --          (pkgutil file lists)
#   sudo pkgutil --forget <id>                          (package receipts)
# Without these, pkg-casks like TeamViewer fail mid-upgrade with
# "sudo: a terminal is required to read the password".
# The rule is staged immediately before each upgrade and removed right after.
SUDOERS_FILE="/etc/sudoers.d/intune-brew-update"
remove_sudoers() { [ "$(id -u)" -eq 0 ] && rm -f "$SUDOERS_FILE" 2>/dev/null; }
setup_sudoers() {
    [ "$(id -u)" -eq 0 ] || return 0   # only root can/need write sudoers; manual runs auth interactively
    local tmp
    tmp=$(mktemp) || return 1
    printf '%s ALL=(root) NOPASSWD: SETENV: /usr/sbin/installer, /bin/launchctl, /usr/sbin/pkgutil, /usr/bin/xargs, /bin/rm, /usr/bin/pkill\n' "$BREW_OWNER" > "$tmp"
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
# Prints "<kind> <path>" where kind is:
#   app — the cask installs a plain .app bundle (brew moves it itself)
#   pkg — pkg/dmg-installer cask; the .app path was recovered from
#         uninstall/zap stanzas (the macOS installer manages it)
# NOTE: the JSON is passed via an env var (like build-pkg.sh does) — piping it
# to `python3 - << 'PY'` does NOT work, the heredoc clobbers the piped stdin.
cask_app_path() {
    local json
    json="$(brew_as_owner info --cask "$1" --json=v2 2>/dev/null)"
    [ -n "$json" ] || return 1
    CASK_JSON="$json" python3 - << 'PY' 2>/dev/null
import os, sys, json
try:
    c = json.loads(os.environ.get("CASK_JSON", ""))["casks"][0]
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
        if tgt: print("app " + str(tgt)); sys.exit(0)
        if src: print("app /Applications/" + base(src)); sys.exit(0)
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
                        print("pkg " + v); sys.exit(0)
PY
}

# ---------------------------[ Heal poisoned cask configs ]---------------------------
# Older install wrappers ran `brew install --cask --appdir=<mktemp dir>` and
# brew PERSISTS that explicit appdir in Caskroom/<token>/.metadata/config.json
# forever. Every later upgrade then looks for the app in the long-gone temp
# dir and fails with:
#   Error: <token>: It seems the App source '/tmp/brew_appdir_.../<App>.app' is not there.
# Drop any recorded explicit appdir that points into a temp location or no
# longer exists, so brew falls back to the default /Applications. A legitimate
# custom appdir (existing, non-temp) is left untouched.
heal_cask_configs() {
    local caskroom="$BREW_PREFIX/Caskroom"
    [ -d "$caskroom" ] || return 0
    local cfg token fixed
    for cfg in "$caskroom"/*/.metadata/config.json; do
        [ -f "$cfg" ] || continue
        token="$(basename "$(dirname "$(dirname "$cfg")")")"
        fixed=$(CFG="$cfg" python3 - << 'PY' 2>/dev/null
import json, os, sys
p = os.environ["CFG"]
try:
    with open(p) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
explicit = data.get("explicit") or {}
appdir = explicit.get("appdir")
if not appdir:
    sys.exit(0)
is_tmp = appdir.startswith(("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"))
if not is_tmp and os.path.isdir(appdir):
    sys.exit(0)
del explicit["appdir"]
with open(p, "w") as f:
    json.dump(data, f)
print(appdir)
PY
)
        [ -n "$fixed" ] && write_log "  · $token: dropped stale explicit appdir '$fixed' from cask config." "Info"
    done
    return 0
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

# --- repair cask configs poisoned by old install wrappers (stale --appdir) ---
heal_cask_configs

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
            APP_INFO="$(cask_app_path "$TOKEN")"
            APP_KIND="${APP_INFO%% *}"
            APP_PATH="${APP_INFO#* }"
            DISK_VER=""
            [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] && \
                DISK_VER="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
            if [ -n "$DISK_VER" ] && [ -n "$TAP_VER" ] && ver_ge "$DISK_VER" "$TAP_VER"; then
                write_log "  · $TOKEN: on-disk $DISK_VER already >= tap $TAP_VER — self-updated, skipping." "Info"
                continue
            fi
            # Optionally defer upgrades of OPEN .app-bundle casks (see
            # SKIP_RUNNING_APPS in the configuration block at the top).
            # Match on the bundle path only — Electron apps rewrite their
            # helper process command lines, so deeper paths don't reliably match.
            if [ "$SKIP_RUNNING_APPS" = "true" ] && [ "$APP_KIND" = "app" ] && [ -n "$APP_PATH" ] && /usr/bin/pgrep -qf "$APP_PATH" 2>/dev/null; then
                write_log "  · $TOKEN: app is currently running (disk='${DISK_VER:-?}' tap='${TAP_VER:-?}') — deferring to next run." "Info"
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
