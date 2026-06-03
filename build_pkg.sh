#!/bin/bash

# =============================================================
# build_pkg.sh — Lightweight Brew-Install PKG Builder for Intune
#
# HOW IT WORKS:
#   Builds a tiny no-payload PKG per app. The PKG contains only
#   a postinstall script that runs `brew install` on the target
#   Mac at install time. Auto-detects casks vs formulae.
#   The device does all the downloading — PKG is ~10KB wrapper.
#
#   Updates are handled by UpdateAllApps.sh on its schedule.
#   Brew must already be installed (via Homebrew.pkg).
#
# USAGE:
#   chmod +x build_pkg.sh
#   ./build_pkg.sh              ← builds ALL apps in APP_LIST
#   ./build_pkg.sh powershell   ← builds a single app only
#
# OUTPUT:
#   ./apps/<name>/
#       <AppName>.pkg           ← upload to Intune
#       icon.png                ← pulled from IntuneBrew Logos repo
#       info.json               ← app metadata for reference
#   ./logs/YYYY-MM-DD.log       ← build log for this run
# =============================================================

# =============================================================
# ---------------------------[ APP LIST ]---------------------------
# Add casks AND formulae here — the script auto-detects the type.
# Casks:    https://formulae.brew.sh/cask/     (GUI apps)
# Formulae: https://formulae.brew.sh/formula/  (CLI tools)
# =============================================================
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
# =============================================================

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="build_pkg"
LOG_FILE_NAME="$(date '+%Y-%m-%d').log"

# ---------------------------[ Logging Setup ]---------------------------
LOG=true
LOG_DEBUG=false    # Set to true for verbose DEBUG logging
LOG_GET=true       # enable/disable all [Get] logs
LOG_RUN=true       # enable/disable all [Run] logs
ENABLE_LOG_FILE=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/apps"
LOG_FILE_DIRECTORY="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_FILE_DIRECTORY/$LOG_FILE_NAME"

mkdir -p "$OUTPUT_DIR" "$LOG_FILE_DIRECTORY"

FAILED_APPS=()
BUILT_APPS=()

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
    RAW_TAG_PADDED=$(printf "%-7s" "$RAW_TAG")

    local LOG_MESSAGE="$TIMESTAMP [  $RAW_TAG_PADDED ] $MESSAGE"

    if [ "$ENABLE_LOG_FILE" = true ]; then
        echo "$LOG_MESSAGE" >> "$LOG_FILE" 2>/dev/null || true
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

# ---------------------------[ Script Start ]---------------------------
write_log "==================== Start ====================" "Start"
write_log "$(hostname) | $(whoami) | $SCRIPT_NAME" "Info"
write_log "Log file: $LOG_FILE" "Info"
write_log "Output:   $OUTPUT_DIR" "Info"

# ---------------------------[ Preflight ]---------------------------
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
    write_log "Homebrew not found — needed to look up cask metadata." "Error"
    complete_script 1
fi
if ! command -v python3 &>/dev/null; then
    write_log "python3 not found." "Error"
    complete_script 1
fi

write_log "All preflight checks passed." "Success"

# ---------------------------[ Single app override ]---------------------------
if [ -n "$1" ]; then
    APP_LIST=("$1")
    write_log "Single-app mode: building '$1' only." "Info"
fi

write_log "Apps to build: ${#APP_LIST[@]}" "Info"

# =============================================================
# ---------------------------[ BUILD FUNCTION ]---------------------------
# =============================================================
build_pkg() {
    local CASK_NAME="$1"
    local STAGING_DIR="$SCRIPT_DIR/staging/$CASK_NAME"
    local SCRIPTS_DIR="$STAGING_DIR/scripts"

    write_log "------------------------------------------------------------" "Info"
    write_log "[$CASK_NAME] Starting build..." "Start"

    # ---------------------------[ Auto-detect: cask or formula ]---------------------------
    write_log "[$CASK_NAME] Detecting type (cask or formula)..." "Get"

    local BREW_TYPE=""
    local CASK_JSON=""
    local FORMULA_JSON=""

    # Try cask first
    CASK_JSON=$(brew info --cask "$CASK_NAME" --json=v2 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$CASK_JSON" ]; then
        BREW_TYPE="cask"
        write_log "[$CASK_NAME] Type: cask" "Get"
    else
        # Fall back to formula
        FORMULA_JSON=$(brew info --formula "$CASK_NAME" --json=v2 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$FORMULA_JSON" ]; then
            BREW_TYPE="formula"
            write_log "[$CASK_NAME] Type: formula" "Get"
        else
            write_log "[$CASK_NAME] Not found as cask or formula — skipping." "Error"
            return 1
        fi
    fi

    # App display name (Title Case)
    local APP_NAME
    APP_NAME=$(echo "$CASK_NAME" | sed 's/-/ /g' \
        | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')

    local APP_BUNDLE=""
    local CASK_VERSION=""
    local DETECTION_PATH=""
    local INSTALL_CMD=""

    if [ "$BREW_TYPE" = "cask" ]; then
        # --- Cask: installs a .app to /Applications ---
        APP_BUNDLE=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks:
    for artifact in casks[0].get('artifacts', []):
        if isinstance(artifact, dict) and 'app' in artifact:
            val = artifact['app']
            item = val[0] if isinstance(val, list) else val
            if isinstance(item, dict):
                item = item.get('target') or list(item.values())[0]
            print(str(item))
            break
" 2>/dev/null)
        [ -z "$APP_BUNDLE" ] && APP_BUNDLE="${APP_NAME// /}.app"

        CASK_VERSION=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks: print(casks[0].get('version','1.0'))
" 2>/dev/null)

        DETECTION_PATH="/Applications/$APP_BUNDLE"
        INSTALL_CMD="--cask $CASK_NAME"

    else
        # --- Formula: installs a binary to /opt/homebrew/bin (arm64) ---
        CASK_VERSION=$(echo "$FORMULA_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
formulae = data.get('formulae', [])
if formulae:
    versions = formulae[0].get('versions', {})
    print(versions.get('stable', '1.0'))
" 2>/dev/null)

        # Binary path — arm64 uses /opt/homebrew/bin, Intel uses /usr/local/bin
        # We use a runtime check in the postinstall (ARCH detection)
        APP_BUNDLE="$CASK_NAME"
        DETECTION_PATH="/opt/homebrew/bin/$CASK_NAME"
        INSTALL_CMD="$CASK_NAME"
    fi

    CASK_VERSION="${CASK_VERSION:-1.0}"

    # Bundle ID — three-tier lookup:
    #   Tier 1: IntuneBrew Apps JSON (most reliable, pre-validated)
    #   Tier 2: brew cask JSON quit/bundle_id/pkgutil fields
    #   Tier 3: Extract from zap trash/launchctl paths (e.g. Chrome)
    local BUNDLE_ID=""
    local IB_APP_NAME
    IB_APP_NAME=$(echo "$CASK_NAME" | tr '-' '_')

    # Tier 1 — IntuneBrew Apps JSON
    local IB_JSON
    IB_JSON=$(curl -fsSL         "https://raw.githubusercontent.com/ugurkocde/IntuneBrew/main/Apps/${IB_APP_NAME}.json"         2>/dev/null)
    if [ -n "$IB_JSON" ]; then
        BUNDLE_ID=$(echo "$IB_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('bundleId', ''))
" 2>/dev/null)
        [ -n "$BUNDLE_ID" ] && write_log "[$CASK_NAME] Bundle ID (IntuneBrew): $BUNDLE_ID" "Debug"
    fi

    # Tier 2 — brew cask JSON quit/bundle_id/pkgutil
    if [ -z "$BUNDLE_ID" ]; then
        BUNDLE_ID=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if not casks: sys.exit(1)
cask = casks[0]
for artifact in cask.get('artifacts', []):
    if not isinstance(artifact, dict): continue
    for key in ('uninstall', 'zap'):
        for entry in artifact.get(key, []):
            if not isinstance(entry, dict): continue
            for field in ('quit', 'bundle_id'):
                val = entry.get(field)
                if val:
                    print(val[0] if isinstance(val, list) else val)
                    sys.exit(0)
            val = entry.get('pkgutil')
            if val:
                v = val[0] if isinstance(val, list) else val
                if '*' not in str(v):
                    print(v)
                    sys.exit(0)
" 2>/dev/null)
        [ -n "$BUNDLE_ID" ] && write_log "[$CASK_NAME] Bundle ID (brew quit/pkgutil): $BUNDLE_ID" "Debug"
    fi

    # Tier 3 — extract from zap trash/launchctl paths (e.g. com.google.Chrome from trash paths)
    if [ -z "$BUNDLE_ID" ]; then
        BUNDLE_ID=$(echo "$CASK_JSON" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
casks = data.get('casks', [])
if not casks: sys.exit(1)
cask = casks[0]
candidates = []
for artifact in cask.get('artifacts', []):
    if not isinstance(artifact, dict): continue
    for key in ('uninstall', 'zap'):
        for entry in artifact.get(key, []):
            if not isinstance(entry, dict): continue
            # Check launchctl — often has bundle ID pattern
            for lc in (entry.get('launchctl') or []):
                m = re.match(r'([a-zA-Z]{2,}\.[a-zA-Z0-9]+\.[a-zA-Z0-9]+)', str(lc))
                if m: candidates.append(m.group(1))
            # Check trash paths — extract bundle ID patterns
            for t in (entry.get('trash') or []):
                t = str(t).replace('~/Library/', '').replace('/Library/', '')
                m = re.search(r'([a-zA-Z]{2,}\.[a-zA-Z0-9]+\.[a-zA-Z0-9A-Z]+)(?:\.|\/|\*|\$)', t)
                if m:
                    bid = m.group(1)
                    # Filter out generic/system paths
                    if not any(x in bid for x in ['apple', 'Apple', 'LSShared', 'WebKit']):
                        candidates.append(bid)
# Return most common candidate
if candidates:
    from collections import Counter
    print(Counter(candidates).most_common(1)[0][0])
" 2>/dev/null)
        [ -n "$BUNDLE_ID" ] && write_log "[$CASK_NAME] Bundle ID (zap paths): $BUNDLE_ID" "Debug"
    fi

    [ -z "$BUNDLE_ID" ] && BUNDLE_ID="com.intune.brew.$CASK_NAME"

    local PKG_NAME="${APP_NAME// /_}.pkg"
    local APP_PATH="$DETECTION_PATH"

    # App output folder: ./apps/<name>/
    local APP_OUTPUT_DIR="$OUTPUT_DIR/$CASK_NAME"
    mkdir -p "$APP_OUTPUT_DIR"

    write_log "[$CASK_NAME] App name:  $APP_NAME $CASK_VERSION" "Get"
    write_log "[$CASK_NAME] Type:      $BREW_TYPE" "Get"
    write_log "[$CASK_NAME] Bundle:    $APP_BUNDLE" "Get"
    write_log "[$CASK_NAME] Bundle ID: $BUNDLE_ID" "Get"
    write_log "[$CASK_NAME] Detects:   $APP_PATH" "Get"
    write_log "[$CASK_NAME] Output:    $APP_OUTPUT_DIR" "Get"

    # Skip if already built
    if [ -f "$APP_OUTPUT_DIR/$PKG_NAME" ]; then
        write_log "[$CASK_NAME] PKG already exists — skipping. Delete folder to rebuild." "Info"
        BUILT_APPS+=("  ⚠️  apps/$CASK_NAME/$PKG_NAME (skipped — already exists)")
        return 0
    fi

    # ---------------------------[ Clean staging ]---------------------------
    write_log "[$CASK_NAME] Preparing staging directory..." "Run"
    if [ -d "$STAGING_DIR" ]; then
        sudo rm -rf "$STAGING_DIR" 2>/dev/null || rm -rf "$STAGING_DIR"
    fi
    mkdir -p "$SCRIPTS_DIR"

    # ---------------------------[ Write postinstall script ]---------------------------
    write_log "[$CASK_NAME] Writing postinstall script..." "Run"

    cat > "$SCRIPTS_DIR/postinstall" << POSTINSTALL_EOF
#!/bin/bash

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=\$(date +%s%N)

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
LOG_FILE="\$LOG_FILE_DIRECTORY/\$LOG_FILE_NAME"

if [ ! -d "\$LOG_FILE_DIRECTORY" ]; then
    mkdir -p "\$LOG_FILE_DIRECTORY"
fi

# ---------------------------[ Logging Function ]---------------------------
write_log() {
    local MESSAGE="\$1"
    local TAG="\${2:-Info}"
    [ "\$LOG" = false ] && return
    [ "\$TAG" = "Debug" ] && [ "\$LOG_DEBUG" = false ] && return
    [ "\$TAG" = "Get"   ] && [ "\$LOG_GET"   = false ] && return
    [ "\$TAG" = "Run"   ] && [ "\$LOG_RUN"   = false ] && return
    local TIMESTAMP
    TIMESTAMP=\$(date "+%Y-%m-%d %H:%M:%S")
    local VALID_TAGS=("Start" "Get" "Run" "Info" "Success" "Error" "Debug" "End")
    local RAW_TAG="\$TAG"
    local IS_VALID=false
    for T in "\${VALID_TAGS[@]}"; do [ "\$T" = "\$RAW_TAG" ] && IS_VALID=true && break; done
    [ "\$IS_VALID" = false ] && RAW_TAG="Error"
    RAW_TAG_PADDED=\$(printf "%-7s" "\$RAW_TAG")
    local LOG_MESSAGE="\$TIMESTAMP [  \$RAW_TAG_PADDED ] \$MESSAGE"
    if [ "\$ENABLE_LOG_FILE" = true ]; then
        echo "\$LOG_MESSAGE" >> "\$LOG_FILE" 2>/dev/null || true
    fi
    local COLOR_RESET="\033[0m"
    local COLOR_WHITE="\033[1;37m"
    local COLOR
    case "\$RAW_TAG" in
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
    printf "%s " "\$TIMESTAMP"
    printf "\${COLOR_WHITE}[ \${COLOR_RESET}"
    printf "\${COLOR}%s\${COLOR_RESET}" "\$RAW_TAG_PADDED"
    printf "\${COLOR_WHITE} ]\${COLOR_RESET} "
    printf "%s\n" "\$MESSAGE"
}

# ---------------------------[ Exit Function ]---------------------------
complete_script() {
    local EXIT_CODE="\${1:-0}"
    local SCRIPT_END_TIME
    SCRIPT_END_TIME=\$(date +%s%N)
    local DURATION_NS=\$(( SCRIPT_END_TIME - SCRIPT_START_TIME ))
    local DURATION_S=\$(( DURATION_NS / 1000000000 ))
    local DURATION_MS=\$(( (DURATION_NS % 1000000000) / 10000000 ))
    local DURATION_FORMATTED
    DURATION_FORMATTED=\$(printf "%02d:%02d:%02d.%02d" \
        \$(( DURATION_S / 3600 )) \$(( (DURATION_S % 3600) / 60 )) \
        \$(( DURATION_S % 60 )) "\$DURATION_MS")
    write_log "Runtime \$DURATION_FORMATTED" "Info"
    write_log "Exit \$EXIT_CODE" "Info"
    write_log "==================== End ====================" "End"
    exit "\$EXIT_CODE"
}

# ---------------------------[ Script Start ]---------------------------
HOSTNAME=\$(hostname)
write_log "==================== Start ====================" "Start"
write_log "\$HOSTNAME | ${APP_NAME} | \$SCRIPT_NAME" "Info"
write_log "Type: ${BREW_TYPE} | Package: ${CASK_NAME}" "Info"

# ---------------------------[ Get logged-in user ]---------------------------
write_log "Detecting logged-in user..." "Get"
CURRENT_USER=\$(stat -f '%Su' /dev/console 2>/dev/null)
write_log "Logged-in user: \$CURRENT_USER" "Get"

if [ -z "\$CURRENT_USER" ] || [ "\$CURRENT_USER" = "root" ]; then
    write_log "No valid user logged in — cannot install cask." "Error"
    complete_script 1
fi

USER_HOME=\$(dscl . -read /Users/"\$CURRENT_USER" NFSHomeDirectory 2>/dev/null | awk '{print \$2}')
write_log "Home directory: \$USER_HOME" "Get"

# ---------------------------[ Detect brew path ]---------------------------
write_log "Detecting architecture and brew path..." "Get"
ARCH=\$(uname -m)
if [ "\$ARCH" = "arm64" ]; then
    BREW_PATH="/opt/homebrew/bin/brew"
    BREW_PATH_DIR="/opt/homebrew/bin"
else
    BREW_PATH="/usr/local/bin/brew"
    BREW_PATH_DIR="/usr/local/bin"
fi
write_log "Architecture: \$ARCH | Brew path: \$BREW_PATH" "Get"

if [ ! -f "\$BREW_PATH" ]; then
    write_log "Homebrew not found at \$BREW_PATH — deploy InstallHomebrew PKG first." "Error"
    complete_script 1
fi

BREW_VERSION=\$(su - "\$CURRENT_USER" -c "\$BREW_PATH --version" 2>/dev/null | head -1)
write_log "Homebrew found: \$BREW_VERSION" "Get"

# ---------------------------[ Idempotency check ]---------------------------
write_log "Checking if ${APP_NAME} is already installed..." "Get"

BREW_TYPE="${BREW_TYPE}"
INSTALL_CMD="${INSTALL_CMD}"

if [ "\$BREW_TYPE" = "cask" ]; then
    APP_DEST="/Applications/${APP_BUNDLE}"
    if [ -d "\$APP_DEST" ]; then
        INSTALLED_VER=\$(defaults read "\$APP_DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
        write_log "${APP_NAME} already installed (\$INSTALLED_VER) — nothing to do." "Success"
        complete_script 0
    fi
    USER_UID=\$(id -u "\$CURRENT_USER")
    if launchctl asuser "\$USER_UID" sudo -u "\$CURRENT_USER" \
        /usr/bin/env PATH="\$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin" \
        "\$BREW_PATH" list --cask '${CASK_NAME}' &>/dev/null; then
        write_log "${APP_NAME} already managed by Homebrew — nothing to do." "Success"
        complete_script 0
    fi
else
    FORMULA_BIN="\$BREW_PATH_DIR/${CASK_NAME}"
    if [ -f "\$FORMULA_BIN" ]; then
        write_log "${APP_NAME} binary already exists at \$FORMULA_BIN — nothing to do." "Success"
        complete_script 0
    fi
    if launchctl asuser "\$USER_UID" sudo -u "\$CURRENT_USER" \
        /usr/bin/env PATH="\$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin" \
        "\$BREW_PATH" list --formula '${CASK_NAME}' &>/dev/null; then
        write_log "${APP_NAME} already managed by Homebrew — nothing to do." "Success"
        complete_script 0
    fi
fi

write_log "${APP_NAME} not found. Proceeding with installation." "Info"

# ---------------------------[ Install via brew ]---------------------------
write_log "Running: brew install \$INSTALL_CMD" "Run"

if [ "\$BREW_TYPE" = "cask" ]; then
    # THE CORRECT PATTERN (scriptingosx.com — the definitive Mac admin reference):
    #
    # We run as root via Intune PKG postinstall. We cannot call brew as root
    # (brew explicitly aborts). We must run brew as the user. But brew's internal
    # sudo calls (sudo cp, sudo installer) fail for standard LAPS users.
    #
    # The solution: launchctl asuser $uid sudo -u $user brew install
    #
    # - launchctl asuser: places the process in the user's login session
    # - sudo -u $user: runs as the user (no password needed — we're already root)
    # - brew's internal sudo calls: satisfied because the parent is root context
    #
    # This is the standard Mac admin pattern for running user commands from root.
    # No sudoers file, no dscl group changes, no hacks.

    USER_UID=\$(id -u "\$CURRENT_USER")
    write_log "User UID: \$USER_UID" "Debug"

    INSTALL_OUTPUT=\$(launchctl asuser "\$USER_UID" sudo -u "\$CURRENT_USER" \
        /usr/bin/env \
        HOME="\$USER_HOME" \
        PATH="\$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOMEBREW_NO_AUTO_UPDATE=1 \
        "\$BREW_PATH" install --cask ${CASK_NAME} 2>&1)
    INSTALL_EXIT=\$?

    while IFS= read -r LINE; do
        [ -n "\$LINE" ] && write_log "brew | \$LINE" "Debug"
    done <<< "\$INSTALL_OUTPUT"

    if [ \$INSTALL_EXIT -ne 0 ]; then
        write_log "brew install --cask ${CASK_NAME} failed (exit \$INSTALL_EXIT)." "Error"
        complete_script 1
    fi

    write_log "Cask installed and registered in Caskroom — brew upgrade will manage updates." "Run"

else
    # Formula — no /Applications copy needed, brew installs binary directly
    USER_UID=\$(id -u "\$CURRENT_USER")
    INSTALL_OUTPUT=\$(launchctl asuser "\$USER_UID" sudo -u "\$CURRENT_USER" \
        /usr/bin/env \
        HOME="\$USER_HOME" \
        PATH="\$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOMEBREW_NO_AUTO_UPDATE=1 \
        "\$BREW_PATH" install ${CASK_NAME} 2>&1)
    INSTALL_EXIT=\$?

    while IFS= read -r LINE; do
        [ -n "\$LINE" ] && write_log "brew | \$LINE" "Debug"
    done <<< "\$INSTALL_OUTPUT"

    if [ \$INSTALL_EXIT -ne 0 ]; then
        write_log "brew install ${CASK_NAME} failed (exit \$INSTALL_EXIT)." "Error"
        complete_script 1
    fi
fi

write_log "Installation completed." "Run"

# ---------------------------[ Verify ]---------------------------
write_log "Verifying installation..." "Get"
if [ "\$BREW_TYPE" = "cask" ]; then
    APP_DEST="/Applications/${APP_BUNDLE}"
    # Also check staged bundle name in case it differs
    if [ ! -d "\$APP_DEST" ]; then
        APP_DEST=\$(find /Applications -maxdepth 1 -name "*.app" -newer /tmp -type d 2>/dev/null | head -1)
    fi
    if [ -d "\$APP_DEST" ]; then
        INSTALLED_VER=\$(defaults read "\$APP_DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
        write_log "${APP_NAME} \$INSTALLED_VER verified at \$APP_DEST" "Success"
        complete_script 0
    else
        write_log "${APP_NAME} not found in /Applications after install." "Error"
        complete_script 1
    fi
else
    FORMULA_BIN="\$BREW_PATH_DIR/${CASK_NAME}"
    if [ -f "\$FORMULA_BIN" ]; then
        BIN_VERSION=\$(su -l "\$CURRENT_USER" -c "
            export PATH=\"\$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin\"
            \"\$FORMULA_BIN\" --version 2>/dev/null | head -1
        " 2>/dev/null || echo "unknown")
        write_log "${APP_NAME} \$BIN_VERSION verified at \$FORMULA_BIN" "Success"
        complete_script 0
    else
        write_log "${APP_NAME} binary not found at \$FORMULA_BIN after install." "Error"
        complete_script 1
    fi
fi
POSTINSTALL_EOF

    chmod +x "$SCRIPTS_DIR/postinstall"
    write_log "[$CASK_NAME] Postinstall script written." "Debug"

    # ---------------------------[ Build PKG ]---------------------------
    write_log "[$CASK_NAME] Building no-payload PKG..." "Run"

    pkgbuild \
        --nopayload \
        --scripts "$SCRIPTS_DIR" \
        --identifier "$BUNDLE_ID" \
        --version "$CASK_VERSION" \
        "$APP_OUTPUT_DIR/$PKG_NAME" >/dev/null 2>&1

    local BUILD_EXIT=$?

    if [ $BUILD_EXIT -ne 0 ]; then
        write_log "[$CASK_NAME] pkgbuild failed (exit $BUILD_EXIT)." "Error"
        rm -rf "$STAGING_DIR"
        return 1
    fi

    # ---------------------------[ Save scripts for manual debugging ]---------------------------
    # Scripts are saved to apps/<name>/scripts/ so you can run them manually:
    #   sudo bash ~/Downloads/files/apps/firefox/scripts/postinstall
    local SCRIPTS_OUTPUT_DIR="$APP_OUTPUT_DIR/scripts"
    mkdir -p "$SCRIPTS_OUTPUT_DIR"
    cp "$SCRIPTS_DIR/postinstall" "$SCRIPTS_OUTPUT_DIR/postinstall"
    chmod +x "$SCRIPTS_OUTPUT_DIR/postinstall"
    write_log "[$CASK_NAME] Scripts saved to: apps/$CASK_NAME/scripts/" "Debug"

    rm -rf "$STAGING_DIR"

    local PKG_SIZE
    PKG_SIZE=$(du -sh "$APP_OUTPUT_DIR/$PKG_NAME" | awk '{print $1}')
    write_log "[$CASK_NAME] PKG built: $PKG_NAME ($PKG_SIZE)" "Success"

    # ---------------------------[ Pull icon from IntuneBrew Logos ]---------------------------
    # IntuneBrew stores logos at:
    # https://raw.githubusercontent.com/ugurkocde/IntuneBrew/main/Logos/<app_name>.png
    # Filename convention: app name lowercased, spaces → underscores
    write_log "[$CASK_NAME] Pulling icon from IntuneBrew Logos..." "Run"

    local LOGO_NAME
    LOGO_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_').png
    local LOGO_URL="https://raw.githubusercontent.com/ugurkocde/IntuneBrew/main/Logos/$LOGO_NAME"
    local ICON_PATH="$APP_OUTPUT_DIR/icon.png"

    curl -fsSL -o "$ICON_PATH" "$LOGO_URL" 2>/dev/null
    if [ $? -eq 0 ] && [ -f "$ICON_PATH" ] && [ -s "$ICON_PATH" ]; then
        write_log "[$CASK_NAME] Icon saved: icon.png (from IntuneBrew)" "Success"
    else
        rm -f "$ICON_PATH"
        write_log "[$CASK_NAME] Icon not in IntuneBrew — trying cask homepage favicon..." "Info"

        # Fallback: try formulae.brew.sh which has app icons
        local BREW_ICON_URL="https://formulae.brew.sh/api/cask/$CASK_NAME.json"
        local HOMEPAGE
        HOMEPAGE=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks: print(casks[0].get('homepage', ''))
" 2>/dev/null)

        if [ -n "$HOMEPAGE" ]; then
            # Extract domain for favicon
            local DOMAIN
            DOMAIN=$(echo "$HOMEPAGE" | python3 -c "
import sys
from urllib.parse import urlparse
print(urlparse(sys.stdin.read().strip()).netloc)
" 2>/dev/null)
            local FAVICON_URL="https://www.google.com/s2/favicons?domain=$DOMAIN&sz=128"
            curl -fsSL -o "$ICON_PATH" "$FAVICON_URL" 2>/dev/null
            if [ $? -eq 0 ] && [ -s "$ICON_PATH" ]; then
                write_log "[$CASK_NAME] Icon saved: icon.png (favicon fallback)" "Info"
            else
                rm -f "$ICON_PATH"
                write_log "[$CASK_NAME] No icon available — skipping." "Info"
            fi
        fi
    fi

    # ---------------------------[ Write info.json ]---------------------------
    write_log "[$CASK_NAME] Writing info.json..." "Run"

    local HOMEPAGE
    HOMEPAGE=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks: print(casks[0].get('homepage', ''))
" 2>/dev/null)

    local DESCRIPTION
    DESCRIPTION=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks: print(casks[0].get('desc', ''))
" 2>/dev/null)

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(echo "$CASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
casks = data.get('casks', [])
if casks: print(casks[0].get('url', ''))
" 2>/dev/null)

    local BUILD_DATE
    BUILD_DATE=$(date "+%Y-%m-%d %H:%M:%S")

    cat > "$APP_OUTPUT_DIR/info.json" << INFO_EOF
{
  "name": "$APP_NAME",
  "cask": "$CASK_NAME",
  "version": "$CASK_VERSION",
  "bundleId": "$BUNDLE_ID",
  "appBundle": "$APP_BUNDLE",
  "appPath": "$APP_PATH",
  "pkg": "$PKG_NAME",
  "homepage": "$HOMEPAGE",
  "description": "$DESCRIPTION",
  "downloadUrl": "$DOWNLOAD_URL",
  "intune": {
    "displayName": "$APP_NAME",
    "publisher": "$APP_NAME",
    "bundleId": "$BUNDLE_ID",
    "version": "$CASK_VERSION",
    "ignoreAppVersion": true,
    "installScope": "device",
    "detectionRule": {
      "type": "file",
      "path": "/Applications",
      "fileOrFolder": "$APP_BUNDLE",
      "detection": "exists"
    }
  },
  "builtAt": "$BUILD_DATE",
  "builtBy": "build_pkg.sh",
  "logoSource": "IntuneBrew (https://github.com/ugurkocde/IntuneBrew)"
}
INFO_EOF

    write_log "[$CASK_NAME] info.json written." "Success"
    write_log "[$CASK_NAME] Output folder: apps/$CASK_NAME/" "Debug"
    write_log "[$CASK_NAME]   ├── $PKG_NAME ($PKG_SIZE)" "Debug"
    [ -f "$ICON_PATH" ] && write_log "[$CASK_NAME]   ├── icon.png" "Debug"
    write_log "[$CASK_NAME]   └── info.json" "Debug"

    BUILT_APPS+=("  ✅  apps/$CASK_NAME/  [${BUNDLE_ID}  v${CASK_VERSION}  →  $APP_PATH]")
    return 0
}

# =============================================================
# ---------------------------[ MAIN LOOP ]---------------------------
# =============================================================
write_log "Starting build loop for ${#CASK_LIST[@]} app(s)..." "Run"

for CASK in "${APP_LIST[@]}"; do
    if ! build_pkg "$CASK"; then
        FAILED_APPS+=("  ❌  $CASK")
    fi
done

# =============================================================
# ---------------------------[ SUMMARY ]---------------------------
# =============================================================
write_log "------------------------------------------------------------" "Info"
write_log "BUILD SUMMARY" "Info"
write_log "------------------------------------------------------------" "Info"

if [ ${#BUILT_APPS[@]} -gt 0 ]; then
    write_log "Built (${#BUILT_APPS[@]}):" "Success"
    for APP in "${BUILT_APPS[@]}"; do
        write_log "$APP" "Success"
    done
fi

if [ ${#FAILED_APPS[@]} -gt 0 ]; then
    write_log "Failed (${#FAILED_APPS[@]}):" "Error"
    for APP in "${FAILED_APPS[@]}"; do
        write_log "$APP" "Error"
    done
fi

write_log "Output:  $OUTPUT_DIR/<cask>/{pkg, icon.png, info.json}" "Info"
write_log "Log:     $LOG_FILE" "Info"
write_log "" "Info"
write_log "Intune settings per PKG:" "Info"
write_log "  App type          : Line-of-business app (PKG)" "Info"
write_log "  Ignore app version: Yes" "Info"
write_log "  Install scope     : Device" "Info"
write_log "  Detection rule    : File exists → /Applications/<App>.app" "Info"
write_log "  Prerequisite      : InstallHomebrew PKG (deploy first)" "Info"

# Exit with failure if any apps failed to build
if [ ${#FAILED_APPS[@]} -gt 0 ]; then
    complete_script 1
else
    complete_script 0
fi