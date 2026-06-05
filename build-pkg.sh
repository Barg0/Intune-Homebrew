#!/bin/bash

# =============================================================================
# build-pkg.sh — Brew-Install PKG Builder for Microsoft Intune (macOS)
# =============================================================================
#
# WHAT THIS DOES
#   For every app listed in APP_LIST, builds a tiny "no-payload" .pkg whose
#   ONLY job is to run, on the managed Mac, at install time, as root:
#
#       brew install --cask <app>      (or:  brew install <formula>)
#
#   The device downloads the newest version from Homebrew. The pkg is a ~10 KB
#   wrapper — Homebrew does all the work and, crucially, TRACKS the install,
#   so your scheduled update-brew-apps.sh can later run `brew upgrade --greedy`
#   to keep every app current. Brew stays the single source of truth.
#
# WHY THE OLD build_pkg.sh FAILED FOR TEAMVIEWER (pkg/dmg casks)
#   Homebrew refuses to run as root, so the postinstall drops to a normal user
#   and runs brew as them. For .app casks brew just copies the bundle — fine.
#   But for PKG/DMG casks brew re-elevates *internally* with:
#
#       /usr/bin/sudo -u root -E LOGNAME=u USER=u USERNAME=u -- /usr/sbin/installer ...
#
#   In Intune's non-interactive context there is no TTY, no SUDO_ASKPASS and no
#   cached credential, so that inner sudo blocks waiting for a password and the
#   install dies. The old "touch /var/db/sudo/ts/<user>" trick does NOT work on
#   modern macOS sudo, and brew 4.x resets the sudo timestamp anyway.
#
# THE FIX (verified against current Homebrew source, June 2026)
#   Before the cask install, drop a temporary, tightly-scoped sudoers rule that
#   lets the brew-owning user run ONLY /usr/sbin/installer with NOPASSWD — and,
#   because brew prepends LOGNAME/USER/USERNAME env assignments, it MUST carry
#   the SETENV tag:
#
#       <brewOwner> ALL=(root) NOPASSWD: SETENV: /usr/sbin/installer
#
#   The drop-in is created, validated with `visudo -cf`, used, then deleted
#   (via a trap) — so the elevation exists only for the duration of one install.
#   Formulae need none of this (they install into brew's own prefix).
#
# PREREQUISITES ON THE MANAGED MAC (deploy these via Intune FIRST)
#   1. Xcode Command Line Tools   (install-xcodeclt.sh)
#   2. Homebrew                    (your Homebrew prerequisite pkg/script)
#   Each generated app pkg should use check-brew.sh as its PRE-INSTALL script
#   so the install simply retries on the next check-in until brew is present.
#
# USAGE (run on your admin Mac, which has brew + Xcode CLT)
#   chmod +x build-pkg.sh
#   ./build-pkg.sh                 # build ALL apps in APP_LIST
#   ./build-pkg.sh teamviewer      # build a single app only
#
# OUTPUT
#   ./apps/<token>/
#       <AppName>.pkg              ← upload to Intune
#       icon.png                   ← from the IntuneBrew Logos repo (if found)
#       info.json                  ← metadata + the exact Intune settings to use
#       scripts/postinstall        ← the install script (for manual debugging)
#   ./logs/YYYY-MM-DD.log          ← build log for this run
#
# HOW TO ADD THE PKG IN INTUNE  (see info.json for per-app specifics)
#   Apps ▸ macOS ▸ Add ▸ "macOS app (PKG)"   (the UNMANAGED type — it allows
#                                              payload-free / unsigned / script
#                                              packages; the managed LOB-PKG
#                                              type does NOT and would loop.)
#   Pre-install script  : contents of check-brew.sh
#   Detection           : the REAL app's bundle id (from info.json) + Ignore
#                         app version = Yes      ← prevents the reinstall loop
#   Install scope       : Device (System)
# =============================================================================


# =============================================================================
# ---------------------------[ APP LIST ]-------------------------------------
# Add Homebrew cask tokens (GUI apps) or formula tokens (CLI) — the type is
# auto-detected. Use the exact token from:
#   Casks:    https://formulae.brew.sh/cask/
#   Formulae: https://formulae.brew.sh/formula/
# =============================================================================
APP_LIST=(
    "firefox"
    "google-chrome"
    "visual-studio-code"
    "gimp"
    "alacritty"
    "cursor"
    "teamviewer"
    "powershell"
)

# ---------------------------[ Build Configuration ]--------------------------
# Reverse-DNS prefix for the generated pkg identifiers (NOT the app's bundle id).
ORG_ID="de.saveitfirst.intunebrew"

# When the app is already brew-installed on a device and the pkg runs again,
# should the postinstall also run `brew upgrade --greedy` for that app?
#   false → just confirm it's installed and exit (recommended: let your
#           scheduled update-brew-apps.sh own all upgrades).
#   true  → opportunistically upgrade on every (re)install.
UPGRADE_ON_REINSTALL=false

# If the app installs to /Applications but brew fails to finalize tracking
# (after a reconcile attempt), should the postinstall FAIL (exit 1) so Intune
# retries until brew tracks it?
#   true  → (recommended) keep retrying until brew-tracked, so update-brew-apps
#           can manage it. Company Portal shows "failed" until a retry succeeds.
#   false → report success once the app is present, even if not brew-tracked.
REQUIRE_BREW_TRACKING=true

# Hard ceiling (seconds) for a single brew install on the device, so a stuck
# install can never hang the Intune deployment indefinitely.
INSTALL_TIMEOUT=480

# Rebuild even if apps/<token>/<App>.pkg already exists.
FORCE_REBUILD=true

# IntuneBrew logo repository (icons + metadata fallback).
IB_RAW="https://raw.githubusercontent.com/ugurkocde/IntuneBrew/main"
# =============================================================================


# ---------------------------[ Script Start Timestamp ]-----------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]----------------------------------
SCRIPT_NAME="build-pkg"
LOG_FILE_NAME="$(date '+%Y-%m-%d').log"

# ---------------------------[ Logging Setup ]--------------------------------
LOG=true
LOG_DEBUG=false    # set true for verbose DEBUG logging
LOG_GET=true       # enable/disable all [Get] logs
LOG_RUN=true       # enable/disable all [Run] logs
ENABLE_LOG_FILE=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/apps"
STAGING_ROOT="$SCRIPT_DIR/staging"
LOG_FILE_DIRECTORY="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_FILE_DIRECTORY/$LOG_FILE_NAME"

mkdir -p "$OUTPUT_DIR" "$LOG_FILE_DIRECTORY" "$STAGING_ROOT"

FAILED_APPS=()
BUILT_APPS=()

# ---------------------------[ Logging Function ]-----------------------------
# Faithful macOS/bash port of the PowerShell Write-Log helper:
#   timestamp [  TAG     ] message   — coloured to terminal, plain to logfile.
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
        "Start")   COLOR="\033[0;36m"  ;;   # Cyan
        "Get")     COLOR="\033[0;34m"  ;;   # Blue
        "Run")     COLOR="\033[0;35m"  ;;   # Magenta
        "Info")    COLOR="\033[0;33m"  ;;   # Yellow
        "Success") COLOR="\033[0;32m"  ;;   # Green
        "Error")   COLOR="\033[0;31m"  ;;   # Red
        "Debug")   COLOR="\033[0;33m"  ;;   # DarkYellow
        "End")     COLOR="\033[0;36m"  ;;   # Cyan
        *)         COLOR="\033[1;37m"  ;;   # White
    esac

    printf "%s " "$TIMESTAMP"
    printf "${COLOR_WHITE}[ ${COLOR_RESET}"
    printf "${COLOR}%s${COLOR_RESET}" "$RAW_TAG_PADDED"
    printf "${COLOR_WHITE} ]${COLOR_RESET} "
    printf "%s\n" "$MESSAGE"
}

# ---------------------------[ Exit Function ]--------------------------------
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

# ---------------------------[ Script Start ]---------------------------------
write_log "==================== Start ====================" "Start"
write_log "$(hostname) | $(whoami) | $SCRIPT_NAME" "Info"
write_log "Log file: $LOG_FILE" "Info"
write_log "Output:   $OUTPUT_DIR" "Info"

# ---------------------------[ Preflight ]------------------------------------
write_log "Running preflight checks..." "Get"

if [ "$(id -u)" -eq 0 ]; then
    write_log "Do NOT run with sudo — brew refuses to run as root." "Error"
    complete_script 1
fi
if ! command -v pkgbuild &>/dev/null; then
    write_log "pkgbuild not found. Run: xcode-select --install" "Error"
    complete_script 1
fi
if ! command -v brew &>/dev/null; then
    write_log "Homebrew not found — needed to look up cask/formula metadata." "Error"
    complete_script 1
fi
if ! command -v python3 &>/dev/null; then
    write_log "python3 not found (used to parse brew JSON at build time)." "Error"
    complete_script 1
fi

write_log "All preflight checks passed." "Success"

# ---------------------------[ Single-app override ]--------------------------
if [ -n "$1" ]; then
    APP_LIST=("$1")
    write_log "Single-app mode: building '$1' only." "Info"
fi
write_log "Apps to build: ${#APP_LIST[@]}" "Info"

# ---------------------------[ Metadata Extractor (python) ]------------------
# Reads cask/formula JSON on stdin, prints TAB-separated fields.
#   cask    -> version, display, desc, homepage, url, appName, appPath, bundleId
#   formula -> version, display, desc, homepage, url
EXTRACTOR_PY="$STAGING_ROOT/_extract_meta.py"
cat > "$EXTRACTOR_PY" << 'PY_EOF'
import sys, json

mode = sys.argv[1] if len(sys.argv) > 1 else "cask"

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

def field(*vals):
    print("\t".join("" if v is None else str(v).replace("\t", " ").replace("\n", " ") for v in vals))

def basename(p):
    return str(p).rstrip("/").split("/")[-1]

if mode == "cask":
    casks = data.get("casks") or []
    if not casks:
        sys.exit(2)
    c = casks[0]

    version  = c.get("version") or ""
    names    = c.get("name") or []
    display  = names[0] if names else ""
    desc     = c.get("desc") or ""
    homepage = c.get("homepage") or ""
    url      = c.get("url") or ""

    artifacts = c.get("artifacts") or []

    # --- Real installed .app: prefer the 'app' artifact (with optional target) ---
    app_name = ""
    app_path = ""
    for art in artifacts:
        if not isinstance(art, dict) or not art.get("app"):
            continue
        src = None
        tgt = None
        for e in art["app"]:
            if isinstance(e, str):
                src = e
            elif isinstance(e, dict) and e.get("target"):
                tgt = e["target"]
        if tgt:
            app_path = tgt
            app_name = basename(tgt)
        elif src:
            app_name = basename(src)
            app_path = "/Applications/" + app_name
        if app_name:
            break

    # --- pkg-only casks (teamviewer, zoom, teams...) have NO 'app' artifact:
    #     recover the bundle name from uninstall/zap delete/trash paths. ---
    if not app_name:
        cands = []
        for art in artifacts:
            if not isinstance(art, dict):
                continue
            for key in ("uninstall", "zap"):
                for entry in (art.get(key) or []):
                    if not isinstance(entry, dict):
                        continue
                    for fld in ("delete", "trash"):
                        vals = entry.get(fld) or []
                        if isinstance(vals, str):
                            vals = [vals]
                        for v in vals:
                            v = str(v)
                            if v.endswith(".app") and "/Applications/" in v:
                                cands.append(v)
        if cands:
            app_path = cands[0]
            app_name = basename(cands[0])

    # --- Bundle id: quit / bundle_id, then pkgutil (skip wildcards) ---
    bundle_id = ""
    for art in artifacts:
        if not isinstance(art, dict):
            continue
        for key in ("uninstall", "zap"):
            for entry in (art.get(key) or []):
                if not isinstance(entry, dict):
                    continue
                for f in ("quit", "bundle_id"):
                    val = entry.get(f)
                    if val:
                        bundle_id = val[0] if isinstance(val, list) else val
                        break
                if bundle_id:
                    break
            if bundle_id:
                break
        if bundle_id:
            break
    if not bundle_id:
        for art in artifacts:
            if not isinstance(art, dict):
                continue
            for key in ("uninstall", "zap"):
                for entry in (art.get(key) or []):
                    if not isinstance(entry, dict):
                        continue
                    val = entry.get("pkgutil")
                    if val:
                        v = val[0] if isinstance(val, list) else val
                        if "*" not in str(v):
                            bundle_id = v
                            break
                if bundle_id:
                    break
            if bundle_id:
                break

    field(version, display, desc, homepage, url, app_name, app_path, bundle_id)

else:
    formulae = data.get("formulae") or []
    if not formulae:
        sys.exit(2)
    f = formulae[0]
    version  = (f.get("versions") or {}).get("stable") or ""
    display  = f.get("full_name") or f.get("name") or ""
    desc     = f.get("desc") or ""
    homepage = f.get("homepage") or ""
    url      = ((f.get("urls") or {}).get("stable") or {}).get("url") or ""
    field(version, display, desc, homepage, url)
PY_EOF


# =============================================================================
# ---------------------------[ BUILD FUNCTION ]-------------------------------
# =============================================================================
build_one() {
    local TOKEN="$1"
    local STAGING_DIR="$STAGING_ROOT/$TOKEN"
    local SCRIPTS_DIR="$STAGING_DIR/scripts"

    write_log "------------------------------------------------------------" "Info"
    write_log "[$TOKEN] Starting build..." "Start"

    # ---------------------------[ Detect cask vs formula ]-------------------
    write_log "[$TOKEN] Detecting type (cask or formula)..." "Get"

    local INSTALL_KIND="" CASK_JSON="" FORMULA_JSON=""
    CASK_JSON=$(brew info --cask "$TOKEN" --json=v2 2>/dev/null)
    if [ -n "$CASK_JSON" ] && echo "$CASK_JSON" | grep -q '"token"'; then
        INSTALL_KIND="cask"
    else
        FORMULA_JSON=$(brew info --formula "$TOKEN" --json=v2 2>/dev/null)
        if [ -n "$FORMULA_JSON" ] && echo "$FORMULA_JSON" | grep -q '"name"'; then
            INSTALL_KIND="formula"
        else
            write_log "[$TOKEN] Not found as cask or formula — skipping." "Error"
            return 1
        fi
    fi
    write_log "[$TOKEN] Type: $INSTALL_KIND" "Get"

    # ---------------------------[ Extract metadata ]------------------------
    local VERSION DISPLAY DESC HOMEPAGE URL APP_NAME APP_PATH BUNDLE_ID
    if [ "$INSTALL_KIND" = "cask" ]; then
        IFS=$'\t' read -r VERSION DISPLAY DESC HOMEPAGE URL APP_NAME APP_PATH BUNDLE_ID \
            < <(printf '%s' "$CASK_JSON" | python3 "$EXTRACTOR_PY" cask)
    else
        IFS=$'\t' read -r VERSION DISPLAY DESC HOMEPAGE URL \
            < <(printf '%s' "$FORMULA_JSON" | python3 "$EXTRACTOR_PY" formula)
        APP_NAME=""; APP_PATH="/opt/homebrew/bin/$TOKEN"; BUNDLE_ID=""
    fi

    [ -z "$DISPLAY" ] && DISPLAY="$TOKEN"
    [ -z "$VERSION" ] && VERSION="1.0"

    # App-bundle fallbacks for casks that exposed neither an app artifact nor a
    # recoverable .app path (rare; keeps a sane Intune detection target).
    if [ "$INSTALL_KIND" = "cask" ]; then
        [ -z "$APP_NAME" ] && APP_NAME="${DISPLAY}.app"
        [ -z "$APP_PATH" ] && APP_PATH="/Applications/$APP_NAME"
    fi

    # ---------------------------[ Bundle id fallbacks ]----------------------
    # Tier: brew (above) → IntuneBrew Apps JSON → synthetic.
    if [ "$INSTALL_KIND" = "cask" ] && [ -z "$BUNDLE_ID" ]; then
        local IB_NAME IB_JSON
        IB_NAME=$(echo "$TOKEN" | tr '-' '_')
        IB_JSON=$(curl -fsSL "$IB_RAW/Apps/${IB_NAME}.json" 2>/dev/null)
        if [ -n "$IB_JSON" ]; then
            BUNDLE_ID=$(printf '%s' "$IB_JSON" | python3 -c \
                "import sys,json; print((json.load(sys.stdin).get('bundleId') or ''))" 2>/dev/null)
            [ -n "$BUNDLE_ID" ] && write_log "[$TOKEN] Bundle id from IntuneBrew." "Debug"
        fi
    fi
    if [ "$INSTALL_KIND" = "cask" ] && [ -z "$BUNDLE_ID" ]; then
        BUNDLE_ID="com.intune.brew.$TOKEN"
        write_log "[$TOKEN] Bundle id not found — using synthetic $BUNDLE_ID (set the real one in Intune)." "Info"
    fi

    local APP_OUTPUT_DIR="$OUTPUT_DIR/$TOKEN"
    local PKG_NAME="${DISPLAY// /_}.pkg"
    mkdir -p "$APP_OUTPUT_DIR"

    write_log "[$TOKEN] Name:      $DISPLAY $VERSION" "Get"
    write_log "[$TOKEN] Type:      $INSTALL_KIND" "Get"
    [ "$INSTALL_KIND" = "cask" ] && write_log "[$TOKEN] App:       $APP_NAME" "Get"
    write_log "[$TOKEN] Detects:   $APP_PATH" "Get"
    write_log "[$TOKEN] Bundle id: ${BUNDLE_ID:-<none / formula>}" "Get"
    write_log "[$TOKEN] Output:    $APP_OUTPUT_DIR" "Get"

    if [ "$INSTALL_KIND" = "formula" ]; then
        write_log "[$TOKEN] WARNING: '$TOKEN' is a CLI formula (no .app bundle)." "Error"
        write_log "[$TOKEN] Intune detects macOS apps by bundle id, so this pkg can't report 'installed'" "Error"
        write_log "[$TOKEN] and would loop. Deploy CLI tools via an Intune SHELL-SCRIPT policy instead." "Error"
    fi

    if [ "$FORCE_REBUILD" != true ] && [ -f "$APP_OUTPUT_DIR/$PKG_NAME" ]; then
        write_log "[$TOKEN] PKG already exists — skipping (set FORCE_REBUILD=true to rebuild)." "Info"
        BUILT_APPS+=("  ⚠️  apps/$TOKEN/$PKG_NAME (skipped — already exists)")
        return 0
    fi

    # ---------------------------[ Clean staging ]----------------------------
    write_log "[$TOKEN] Preparing staging directory..." "Run"
    rm -rf "$STAGING_DIR" 2>/dev/null
    mkdir -p "$SCRIPTS_DIR"

    # ---------------------------[ Write postinstall ]-----------------------
    write_log "[$TOKEN] Writing postinstall script..." "Run"

    # The postinstall = a small generated CONFIG HEADER (build-time values as
    # shell variables) + a STATIC BODY (quoted heredoc, so no escaping games).
    {
        echo '#!/bin/bash'
        echo '# Generated by build-pkg.sh — installs/keeps an app via Homebrew at Intune install time.'
        echo "CASK_TOKEN=$(printf '%q' "$TOKEN")"
        echo "INSTALL_KIND=$(printf '%q' "$INSTALL_KIND")"
        echo "APP_NAME=$(printf '%q' "$DISPLAY")"
        echo "APP_BUNDLE_PATH=$(printf '%q' "$APP_PATH")"
        echo "BUNDLE_ID=$(printf '%q' "$BUNDLE_ID")"
        echo "UPGRADE_ON_REINSTALL=$(printf '%q' "$UPGRADE_ON_REINSTALL")"
        echo "REQUIRE_BREW_TRACKING=$(printf '%q' "$REQUIRE_BREW_TRACKING")"
        echo "INSTALL_TIMEOUT=$(printf '%q' "$INSTALL_TIMEOUT")"
        cat << 'POSTINSTALL_BODY'

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="Install_${APP_NAME// /_}"
LOG_FILE_NAME="$(date '+%Y-%m-%d')-install.log"

# ---------------------------[ Logging Setup ]---------------------------
LOG=true
LOG_DEBUG=true
LOG_GET=true
LOG_RUN=true
ENABLE_LOG_FILE=true
LOG_FILE_DIRECTORY="/Library/Logs/IntuneLogs/Apps/${APP_NAME}"
LOG_FILE="$LOG_FILE_DIRECTORY/$LOG_FILE_NAME"
[ -d "$LOG_FILE_DIRECTORY" ] || mkdir -p "$LOG_FILE_DIRECTORY"

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
        $(( DURATION_S / 3600 )) $(( (DURATION_S % 3600) / 60 )) \
        $(( DURATION_S % 60 )) "$DURATION_MS")
    write_log "Runtime $DURATION_FORMATTED" "Info"
    write_log "Exit $EXIT_CODE" "Info"
    write_log "==================== End ====================" "End"
    exit "$EXIT_CODE"
}

# ---------------------------[ sudoers helpers (cask only) ]---------------------------
# brew elevates the cask PKG install internally with:
#   /usr/bin/sudo -u root -E LOGNAME=.. USER=.. USERNAME=.. -- /usr/sbin/installer ...
# The leading env assignments require the SETENV tag, hence the exact rule below.
SUDOERS_FILE="/etc/sudoers.d/intune-brew-${CASK_TOKEN}"

remove_sudoers() { rm -f "$SUDOERS_FILE" 2>/dev/null; }

setup_sudoers() {
    # $1 = the user brew runs as (must own the brew prefix)
    local owner="$1"
    local tmp
    tmp=$(mktemp) || return 1
    printf '%s ALL=(root) NOPASSWD: SETENV: /usr/sbin/installer\n' "$owner" > "$tmp"
    if /usr/sbin/visudo -cf "$tmp" >/dev/null 2>&1; then
        /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
        rm -f "$tmp"
        if /usr/sbin/visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
            return 0
        fi
        rm -f "$SUDOERS_FILE"
        return 1
    fi
    rm -f "$tmp"
    return 1
}

# Always clean up the temporary sudoers rule, even on unexpected exit or a
# catchable kill (SIGKILL can't be trapped — so we also clear any stale rule
# left by a previously killed run, just below, and setup_sudoers overwrites).
trap remove_sudoers EXIT TERM INT HUP
remove_sudoers   # clear any stale rule a prior killed run may have left behind

# ---------------------------[ Script Start ]---------------------------
write_log "==================== Start ====================" "Start"
write_log "$(hostname) | $APP_NAME | $SCRIPT_NAME" "Info"
write_log "Type: $INSTALL_KIND | Token: $CASK_TOKEN" "Info"
write_log "Running as: $(whoami) (uid $(id -u))" "Debug"

# ---------------------------[ Locate Homebrew + its owner ]---------------------------
write_log "Locating Homebrew and its owning user..." "Get"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW="/opt/homebrew/bin/brew"
else
    BREW="/usr/local/bin/brew"
fi
if [ ! -x "$BREW" ]; then
    write_log "Homebrew not found at $BREW — deploy the Homebrew prerequisite first." "Error"
    complete_script 1
fi
BREW_PREFIX="$(cd "$(dirname "$BREW")/.." && pwd)"

# brew must run as the user that OWNS the prefix (single-user by design),
# which is usually — but not necessarily — the console user.
BREW_OWNER="$(stat -f%Su "$BREW")"
if [ -z "$BREW_OWNER" ] || [ "$BREW_OWNER" = "root" ]; then
    write_log "Homebrew prefix is owned by '$BREW_OWNER' — cannot run brew as that user." "Error"
    complete_script 1
fi
USER_HOME="$(dscl . -read "/Users/$BREW_OWNER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -d "$USER_HOME" ] || USER_HOME="/Users/$BREW_OWNER"
write_log "Architecture: $ARCH | brew: $BREW | owner: $BREW_OWNER" "Get"

# ---------------------------[ Run brew as the owner ]---------------------------
# Drop from root to the prefix owner with a clean, explicit environment.
# The OUTER sudo (root -> owner, setting env) is allowed by root's default
# sudoers rule; the INNER sudo (owner -> root, /usr/sbin/installer) is allowed
# by the temporary SETENV drop-in. We do NOT set HOMEBREW_SUDO_THROUGH_SUDO_USER
# (it would force a much broader NOPASSWD: ALL rule).
brew_as_owner() {
    cd /tmp || return 1
    /usr/bin/sudo -u "$BREW_OWNER" \
        HOME="$USER_HOME" \
        HOMEBREW_NO_AUTO_UPDATE=1 \
        HOMEBREW_NO_ENV_HINTS=1 \
        HOMEBREW_NO_ANALYTICS=1 \
        NONINTERACTIVE=1 \
        SUDO_ASKPASS=/usr/bin/false \
        PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BREW" "$@"
}

# Run a brew command as the owner, captured into INSTALL_OUTPUT and bounded by
# INSTALL_TIMEOUT seconds. This is the safety net for the headless-MDM trap:
# if brew's internal `sudo /usr/sbin/installer` were ever to block on a prompt,
# SUDO_ASKPASS=/usr/bin/false makes it fail fast instead — and even if something
# else stalls, we kill it rather than let Intune hang and kill us mid-receipt.
INSTALL_OUTPUT=""
TIMED_OUT=0
brew_timed() {
    local outfile
    outfile=$(mktemp)
    TIMED_OUT=0
    cd /tmp || true
    /usr/bin/sudo -u "$BREW_OWNER" \
        HOME="$USER_HOME" \
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1 \
        NONINTERACTIVE=1 SUDO_ASKPASS=/usr/bin/false \
        PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BREW" "$@" >"$outfile" 2>&1 </dev/null &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 3; waited=$(( waited + 3 ))
        if [ "$waited" -ge "${INSTALL_TIMEOUT:-480}" ]; then
            kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null
            TIMED_OUT=1; break
        fi
    done
    wait "$pid" 2>/dev/null; local rc=$?
    INSTALL_OUTPUT="$(cat "$outfile" 2>/dev/null)"
    rm -f "$outfile"
    [ "$TIMED_OUT" = 1 ] && return 124
    return $rc
}

BREW_VERSION="$(brew_as_owner --version 2>/dev/null | head -1)"
write_log "Homebrew: ${BREW_VERSION:-unknown}" "Get"

# ---------------------------[ Idempotency check ]---------------------------
write_log "Checking whether $APP_NAME is already brew-installed..." "Get"
KIND_FLAG="--cask"
[ "$INSTALL_KIND" = "formula" ] && KIND_FLAG="--formula"

if brew_as_owner list "$KIND_FLAG" "$CASK_TOKEN" >/dev/null 2>&1; then
    INSTALLED_LINE="$(brew_as_owner list "$KIND_FLAG" --versions "$CASK_TOKEN" 2>/dev/null)"
    write_log "$APP_NAME already installed and brew-tracked: ${INSTALLED_LINE:-$CASK_TOKEN}" "Success"
    if [ "$UPGRADE_ON_REINSTALL" = "true" ]; then
        write_log "UPGRADE_ON_REINSTALL=true — running brew upgrade --greedy..." "Run"
        if [ "$INSTALL_KIND" = "cask" ]; then
            setup_sudoers "$BREW_OWNER" || write_log "Could not stage sudoers rule; cask upgrade may fail." "Error"
        fi
        UP_OUT="$(brew_as_owner upgrade "$KIND_FLAG" "$CASK_TOKEN" --greedy 2>&1)"
        remove_sudoers
        while IFS= read -r LINE; do [ -n "$LINE" ] && write_log "brew | $LINE" "Debug"; done <<< "$UP_OUT"
    fi
    write_log "Nothing to do — update-brew-apps.sh handles ongoing upgrades." "Info"
    complete_script 0
fi

# Take over an app that was installed outside brew (so brew can track + upgrade it).
ADOPT_FLAG=""
if [ "$INSTALL_KIND" = "cask" ] && [ -n "$APP_BUNDLE_PATH" ] && [ -d "$APP_BUNDLE_PATH" ]; then
    write_log "$APP_NAME present at $APP_BUNDLE_PATH but not brew-tracked — will --adopt it." "Info"
    ADOPT_FLAG="--adopt"
fi

write_log "$APP_NAME not brew-tracked — proceeding with install." "Info"

# ---------------------------[ Install via brew ]---------------------------
if [ "$INSTALL_KIND" = "cask" ]; then
    write_log "Staging temporary NOPASSWD sudoers rule for $BREW_OWNER..." "Run"
    if ! setup_sudoers "$BREW_OWNER"; then
        write_log "Failed to stage/validate sudoers rule — pkg/dmg casks cannot install non-interactively." "Error"
        complete_script 1
    fi
    write_log "sudoers rule active: $SUDOERS_FILE" "Debug"

    write_log "Running (≤${INSTALL_TIMEOUT}s): brew install --cask $ADOPT_FLAG $CASK_TOKEN" "Run"
    brew_timed install --cask $ADOPT_FLAG "$CASK_TOKEN"
    INSTALL_EXIT=$?

    remove_sudoers
    trap - EXIT
    write_log "sudoers rule removed." "Debug"
else
    write_log "Running (≤${INSTALL_TIMEOUT}s): brew install $CASK_TOKEN" "Run"
    brew_timed install "$CASK_TOKEN"
    INSTALL_EXIT=$?
fi

while IFS= read -r LINE; do [ -n "$LINE" ] && write_log "brew | $LINE" "Debug"; done <<< "$INSTALL_OUTPUT"

if [ "$INSTALL_EXIT" = "124" ]; then
    write_log "brew install exceeded ${INSTALL_TIMEOUT}s and was terminated (the app may still be on disk)." "Error"
elif [ "$INSTALL_EXIT" -ne 0 ]; then
    write_log "brew install exited $INSTALL_EXIT." "Error"
fi

# ---------------------------[ Verify ]---------------------------
write_log "Verifying installation..." "Get"
if brew_as_owner list "$KIND_FLAG" "$CASK_TOKEN" >/dev/null 2>&1; then
    INSTALLED_LINE="$(brew_as_owner list "$KIND_FLAG" --versions "$CASK_TOKEN" 2>/dev/null)"
    write_log "$APP_NAME verified (brew-tracked): ${INSTALLED_LINE:-$CASK_TOKEN}" "Success"
    complete_script 0
fi

# Cask: the installer placed the app but brew didn't finalize the Caskroom
# receipt (the classic headless interruption). Reconcile once: close any
# instance the pkg launched, then re-run so brew records it.
if [ "$INSTALL_KIND" = "cask" ] && [ -n "$APP_BUNDLE_PATH" ] && [ -d "$APP_BUNDLE_PATH" ]; then
    write_log "$APP_NAME is on disk but brew tracking is not finalized — reconciling once..." "Run"
    /usr/bin/pkill -f "$APP_BUNDLE_PATH" 2>/dev/null || true
    if setup_sudoers "$BREW_OWNER"; then
        brew_timed install --cask --adopt "$CASK_TOKEN"
        while IFS= read -r LINE; do [ -n "$LINE" ] && write_log "brew | $LINE" "Debug"; done <<< "$INSTALL_OUTPUT"
        remove_sudoers
    fi
    if brew_as_owner list --cask "$CASK_TOKEN" >/dev/null 2>&1; then
        INSTALLED_LINE="$(brew_as_owner list --cask --versions "$CASK_TOKEN" 2>/dev/null)"
        write_log "$APP_NAME now brew-tracked after reconcile: ${INSTALLED_LINE:-$CASK_TOKEN}" "Success"
        complete_script 0
    fi
    if [ "$REQUIRE_BREW_TRACKING" = "true" ]; then
        write_log "$APP_NAME installed but NOT brew-tracked. Failing so Intune retries (REQUIRE_BREW_TRACKING=true)." "Error"
        write_log "update-brew-apps.sh can only manage brew-tracked apps. See brew output above." "Info"
        complete_script 1
    fi
    write_log "$APP_NAME installed but NOT brew-tracked. Reporting success (REQUIRE_BREW_TRACKING=false);" "Error"
    write_log "update-brew-apps.sh will NOT manage it until it is brew-tracked." "Info"
    complete_script 0
fi

write_log "$APP_NAME not found after install." "Error"
complete_script 1
POSTINSTALL_BODY
    } > "$SCRIPTS_DIR/postinstall"
    chmod +x "$SCRIPTS_DIR/postinstall"
    write_log "[$TOKEN] Postinstall written." "Debug"

    # ---------------------------[ Build the PKG ]----------------------------
    write_log "[$TOKEN] Building no-payload PKG..." "Run"
    # Strip extended attributes so pkgbuild doesn't embed ._AppleDouble files.
    xattr -rc "$SCRIPTS_DIR" 2>/dev/null || true
    pkgbuild \
        --nopayload \
        --scripts "$SCRIPTS_DIR" \
        --identifier "$ORG_ID.$TOKEN" \
        --version "$VERSION" \
        "$APP_OUTPUT_DIR/$PKG_NAME" >/dev/null 2>&1
    local BUILD_EXIT=$?
    if [ $BUILD_EXIT -ne 0 ]; then
        write_log "[$TOKEN] pkgbuild failed (exit $BUILD_EXIT)." "Error"
        rm -rf "$STAGING_DIR"
        return 1
    fi

    # Keep a copy of the postinstall for manual debugging:
    #   sudo bash apps/<token>/scripts/postinstall
    mkdir -p "$APP_OUTPUT_DIR/scripts"
    cp "$SCRIPTS_DIR/postinstall" "$APP_OUTPUT_DIR/scripts/postinstall"
    chmod +x "$APP_OUTPUT_DIR/scripts/postinstall"
    rm -rf "$STAGING_DIR"

    local PKG_SIZE
    PKG_SIZE=$(du -sh "$APP_OUTPUT_DIR/$PKG_NAME" | awk '{print $1}')
    write_log "[$TOKEN] PKG built: $PKG_NAME ($PKG_SIZE)" "Success"

    # ---------------------------[ Pull icon ]--------------------------------
    write_log "[$TOKEN] Pulling icon from IntuneBrew Logos..." "Run"
    local LOGO_NAME ICON_PATH
    LOGO_NAME="$(echo "$DISPLAY" | tr '[:upper:]' '[:lower:]' | tr ' ' '_').png"
    ICON_PATH="$APP_OUTPUT_DIR/icon.png"
    if curl -fsSL -o "$ICON_PATH" "$IB_RAW/Logos/$LOGO_NAME" 2>/dev/null && [ -s "$ICON_PATH" ]; then
        write_log "[$TOKEN] Icon saved: icon.png" "Success"
    else
        rm -f "$ICON_PATH"
        write_log "[$TOKEN] No IntuneBrew icon for '$LOGO_NAME' — skipping." "Info"
    fi

    # ---------------------------[ Write info.json ]--------------------------
    write_log "[$TOKEN] Writing info.json..." "Run"
    local BUILD_DATE
    BUILD_DATE=$(date "+%Y-%m-%d %H:%M:%S")

    local DETECTION_HINT
    if [ "$INSTALL_KIND" = "cask" ]; then
        DETECTION_HINT="Detection rule = App bundle id '$BUNDLE_ID' (app: $APP_PATH). Set 'Ignore app version' = Yes."
    else
        DETECTION_HINT="Formula (CLI). Intune detects macOS apps by bundle id; a formula has no .app bundle, so use a custom detection or deploy CLI tools via a shell-script policy instead."
    fi

    APP_NAME_JSON="$DISPLAY" \
    TOKEN_JSON="$TOKEN" \
    KIND_JSON="$INSTALL_KIND" \
    VERSION_JSON="$VERSION" \
    BUNDLE_JSON="$BUNDLE_ID" \
    APPNAME_JSON="$APP_NAME" \
    APPPATH_JSON="$APP_PATH" \
    PKG_JSON="$PKG_NAME" \
    HOMEPAGE_JSON="$HOMEPAGE" \
    DESC_JSON="$DESC" \
    URL_JSON="$URL" \
    DATE_JSON="$BUILD_DATE" \
    HINT_JSON="$DETECTION_HINT" \
    python3 - > "$APP_OUTPUT_DIR/info.json" << 'JSON_PY'
import json, os
print(json.dumps({
    "name":        os.environ["APP_NAME_JSON"],
    "token":       os.environ["TOKEN_JSON"],
    "kind":        os.environ["KIND_JSON"],
    "version":     os.environ["VERSION_JSON"],
    "bundleId":    os.environ["BUNDLE_JSON"],
    "appBundle":   os.environ["APPNAME_JSON"],
    "appPath":     os.environ["APPPATH_JSON"],
    "pkg":         os.environ["PKG_JSON"],
    "homepage":    os.environ["HOMEPAGE_JSON"],
    "description": os.environ["DESC_JSON"],
    "downloadUrl": os.environ["URL_JSON"],
    "intune": {
        "appType":          "macOS app (PKG) — UNMANAGED type",
        "displayName":      os.environ["APP_NAME_JSON"],
        "publisher":        os.environ["APP_NAME_JSON"],
        "preInstallScript": "check-brew.sh (blocks until Homebrew is present)",
        "ignoreAppVersion": True,
        "installScope":     "Device (System)",
        "detectionRule":    os.environ["HINT_JSON"],
        "prerequisites":    ["Xcode CLT", "Homebrew"]
    },
    "builtAt":   os.environ["DATE_JSON"],
    "builtBy":   "build-pkg.sh"
}, indent=2))
JSON_PY

    write_log "[$TOKEN] info.json written." "Success"
    BUILT_APPS+=("  ✅  apps/$TOKEN/  [$INSTALL_KIND  ${BUNDLE_ID:-formula}  v$VERSION]")
    return 0
}

# =============================================================================
# ---------------------------[ MAIN LOOP ]------------------------------------
# =============================================================================
write_log "Starting build loop for ${#APP_LIST[@]} app(s)..." "Run"
for TOKEN in "${APP_LIST[@]}"; do
    if ! build_one "$TOKEN"; then
        FAILED_APPS+=("  ❌  $TOKEN")
    fi
done

rm -f "$EXTRACTOR_PY"

# =============================================================================
# ---------------------------[ SUMMARY ]--------------------------------------
# =============================================================================
write_log "------------------------------------------------------------" "Info"
write_log "BUILD SUMMARY" "Info"
write_log "------------------------------------------------------------" "Info"

if [ ${#BUILT_APPS[@]} -gt 0 ]; then
    write_log "Built (${#BUILT_APPS[@]}):" "Success"
    for APP in "${BUILT_APPS[@]}"; do write_log "$APP" "Success"; done
fi
if [ ${#FAILED_APPS[@]} -gt 0 ]; then
    write_log "Failed (${#FAILED_APPS[@]}):" "Error"
    for APP in "${FAILED_APPS[@]}"; do write_log "$APP" "Error"; done
fi

write_log "Output:  $OUTPUT_DIR/<token>/{*.pkg, icon.png, info.json}" "Info"
write_log "Log:     $LOG_FILE" "Info"
write_log "" "Info"
write_log "Per-PKG Intune settings (see each info.json):" "Info"
write_log "  App type           : macOS app (PKG)  — the UNMANAGED type" "Info"
write_log "  Pre-install script : check-brew.sh" "Info"
write_log "  Ignore app version : Yes" "Info"
write_log "  Install scope      : Device (System)" "Info"
write_log "  Detection          : the REAL app's bundle id (NOT the wrapper pkg id)" "Info"
write_log "  Prerequisites      : Xcode CLT + Homebrew deployed first" "Info"

if [ ${#FAILED_APPS[@]} -gt 0 ]; then
    complete_script 1
else
    complete_script 0
fi
