#!/bin/bash

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
    RAW_TAG_PADDED=$(printf "%-7s" "$RAW_TAG")
    local LOG_MESSAGE="$TIMESTAMP [  $RAW_TAG_PADDED ] $MESSAGE"
    if [ "$ENABLE_LOG_FILE" = true ]; then
        echo "$LOG_MESSAGE" >> "$LOG_FILE" 2>/dev/null || true
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
        $(( DURATION_S / 3600 )) \
        $(( (DURATION_S % 3600) / 60 )) \
        $(( DURATION_S % 60 )) \
        "$DURATION_MS")
    write_log "Runtime $DURATION_FORMATTED" "Info"
    write_log "Exit $EXIT_CODE" "Info"
    write_log "==================== End ====================" "End"
    exit "$EXIT_CODE"
}

# =============================================================
# ---------------------------[ Script Start ]---------------------------
# =============================================================
CURRENT_USER=$(echo "show State:/Users/ConsoleUser" | scutil \
    | awk '/Name :/ && ! /loginwindow/ { print $3 }')
HOSTNAME=$(hostname)
ERRORS=0

write_log "==================== Start ====================" "Start"
write_log "$HOSTNAME | $CURRENT_USER | $SCRIPT_NAME" "Info"
write_log "Triggered by Intune scheduled run" "Info"
write_log "Running as: $(whoami) (UID: $(id -u))" "Debug"

# ---------------------------[ Validate User ]---------------------------
write_log "Detecting logged-in user via scutil..." "Get"

if [ -z "$CURRENT_USER" ]; then
    write_log "No valid user logged in — will retry on next scheduled run." "Info"
    complete_script 0
fi

if ! /usr/bin/dscl . -read "/Users/${CURRENT_USER}" &>/dev/null; then
    write_log "User $CURRENT_USER not found in dscl — aborting." "Error"
    complete_script 1
fi

write_log "Logged-in user: $CURRENT_USER" "Get"
USER_HOME=$(dscl . -read "/Users/${CURRENT_USER}" NFSHomeDirectory | awk '{print $2}')
write_log "Home directory: $USER_HOME" "Get"

# ---------------------------[ Detect Architecture ]---------------------------
write_log "Detecting architecture..." "Get"
ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
    BREW_PATH="/opt/homebrew/bin/brew"
    BREW_PATH_DIR="/opt/homebrew/bin"
else
    BREW_PATH="/usr/local/bin/brew"
    BREW_PATH_DIR="/usr/local/bin"
fi

write_log "Architecture: $ARCH | Brew path: $BREW_PATH" "Get"

# ---------------------------[ Helper: run as user ]---------------------------
# Consistent with PKG postinstall scripts — su -l with explicit PATH
run_as_user() {
    su -l "$CURRENT_USER" -c "
        export HOME=\"$USER_HOME\"
        export PATH=\"$BREW_PATH_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"
        export HOMEBREW_NO_AUTO_UPDATE=1
        $1
    " 2>&1
}

# =============================================================
# Homebrew Updates
# =============================================================

if [ ! -f "$BREW_PATH" ]; then
    write_log "Homebrew not found at $BREW_PATH — skipping." "Error"
    write_log "Ensure Homebrew.pkg has been deployed first." "Info"
    ERRORS=$(( ERRORS + 1 ))
else
    BREW_VERSION=$(run_as_user "$BREW_PATH --version" | head -1)
    write_log "Homebrew: $BREW_VERSION" "Get"

    # --- brew update (refresh index) ---
    write_log "Updating Homebrew package index..." "Run"
    UPDATE_OUTPUT=$(run_as_user "$BREW_PATH update")
    UPDATE_EXIT=$?
    while IFS= read -r LINE; do
        [ -n "$LINE" ] && write_log "brew update | $LINE" "Debug"
    done <<< "$UPDATE_OUTPUT"

    if [ $UPDATE_EXIT -ne 0 ]; then
        write_log "brew update failed (exit $UPDATE_EXIT)." "Error"
        ERRORS=$(( ERRORS + 1 ))
    else
        write_log "Package index updated." "Success"
    fi

    # --- Check what's outdated before upgrading ---
    write_log "Checking for outdated packages..." "Get"
    OUTDATED=$(run_as_user "$BREW_PATH outdated --greedy")

    if [ -z "$OUTDATED" ]; then
        write_log "All packages are up to date." "Success"
    else
        OUTDATED_COUNT=$(echo "$OUTDATED" | grep -c . || true)
        write_log "Found $OUTDATED_COUNT outdated package(s):" "Get"
        while IFS= read -r PKG; do
            [ -n "$PKG" ] && write_log "  → $PKG" "Get"
        done <<< "$OUTDATED"

        # --- brew upgrade --greedy handles formulae + casks in one command ---
        write_log "Running brew upgrade --greedy..." "Run"
        UPGRADE_OUTPUT=$(run_as_user "$BREW_PATH upgrade --greedy")
        UPGRADE_EXIT=$?
        while IFS= read -r LINE; do
            [ -n "$LINE" ] && write_log "brew upgrade | $LINE" "Debug"
        done <<< "$UPGRADE_OUTPUT"

        if [ $UPGRADE_EXIT -ne 0 ]; then
            write_log "brew upgrade finished with warnings (exit $UPGRADE_EXIT)." "Error"
            ERRORS=$(( ERRORS + 1 ))
        else
            write_log "All packages upgraded successfully." "Success"
        fi
    fi

    # --- brew cleanup ---
    write_log "Running brew cleanup..." "Run"
    CLEANUP_OUTPUT=$(run_as_user "$BREW_PATH cleanup")
    while IFS= read -r LINE; do
        [ -n "$LINE" ] && write_log "brew cleanup | $LINE" "Debug"
    done <<< "$CLEANUP_OUTPUT"
    write_log "Cleanup complete." "Success"
fi

# =============================================================
# Summary
# =============================================================

if [ $ERRORS -eq 0 ]; then
    write_log "All sections completed without errors." "Success"
    complete_script 0
else
    write_log "$ERRORS section(s) completed with warnings — check debug logs above." "Error"
    complete_script 1
fi
