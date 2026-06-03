#!/bin/bash

# =============================================================
# PreInstall_CheckBrew.sh
#
# PURPOSE:
#   Intune pre-install script for all app PKGs (Firefox, Chrome etc.)
#   Blocks the PKG install if Homebrew is not present.
#   Intune will retry the PKG deployment on next check-in.
#
# PASTE INTO:
#   Intune → Apps → <AppName>.pkg → Program → Pre-install script
# =============================================================

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="check-brew"
LOG_FILE_NAME="check-brew.log"

# ---------------------------[ Logging Setup ]---------------------------
LOG=true
LOG_DEBUG=false
LOG_GET=true
LOG_RUN=true
ENABLE_LOG_FILE=true
LOG_FILE_DIRECTORY="/Library/Logs/IntuneLogs/PreInstall"
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
HOSTNAME=$(hostname)
write_log "==================== Start ====================" "Start"
write_log "$HOSTNAME | $SCRIPT_NAME" "Info"
write_log "Pre-install check for: App PKG (brew cask)" "Info"
write_log "Checking dependency: Homebrew" "Info"

# ---------------------------[ Detect Architecture ]---------------------------
write_log "Detecting architecture..." "Get"
ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
    BREW_PATH="/opt/homebrew/bin/brew"
else
    BREW_PATH="/usr/local/bin/brew"
fi

write_log "Architecture: $ARCH | Expected brew path: $BREW_PATH" "Get"

# ---------------------------[ Check Homebrew ]---------------------------
write_log "Checking if Homebrew is installed at $BREW_PATH..." "Get"

if [ ! -f "$BREW_PATH" ]; then
    write_log "Homebrew binary not found at $BREW_PATH." "Error"
    write_log "App PKG install BLOCKED." "Error"
    write_log "Deploy Homebrew.pkg first, then retry." "Info"
    complete_script 1
fi

# Verify brew is actually executable and functional
BREW_VERSION=$(su - "$(stat -f '%Su' /dev/console)" \
    -c "$BREW_PATH --version" 2>/dev/null | head -1)

if [ -z "$BREW_VERSION" ]; then
    write_log "Homebrew found at $BREW_PATH but not functional." "Error"
    write_log "App PKG install BLOCKED." "Error"
    write_log "Check Homebrew installation or ownership issues." "Info"
    complete_script 1
fi

write_log "Homebrew confirmed: $BREW_VERSION" "Success"
write_log "Dependency satisfied — App PKG install can proceed." "Success"

complete_script 0
