#!/bin/bash

# =============================================================
# PreInstall_CheckXcodeCLT.sh
#
# PURPOSE:
#   Intune pre-install script for Homebrew.pkg
#   Blocks the PKG install if Xcode CLT is not present.
#   Intune will retry the PKG deployment on next check-in.
#
# PASTE INTO:
#   Intune → Apps → Homebrew.pkg → Program → Pre-install script
# =============================================================

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="check-xcodeclt"
LOG_FILE_NAME="check-xcodeclt.log"

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
write_log "Pre-install check for: Homebrew.pkg" "Info"
write_log "Checking dependency: Xcode Command Line Tools" "Info"

# ---------------------------[ Check Xcode CLT ]---------------------------
write_log "Running xcode-select -p..." "Get"
CLT_PATH=$(xcode-select -p 2>/dev/null)
CLT_EXIT=$?

if [ $CLT_EXIT -ne 0 ] || [ ! -d "$CLT_PATH" ]; then
    write_log "Xcode CLT not found (xcode-select exit: $CLT_EXIT)." "Error"
    write_log "Homebrew.pkg install BLOCKED." "Error"
    write_log "Deploy InstallXcodeCLT.sh first, then retry." "Info"
    complete_script 1
fi

write_log "xcode-select path: $CLT_PATH" "Get"

# Verify compilers are actually present
if [ ! -f "$CLT_PATH/usr/bin/gcc" ] && [ ! -f "/usr/bin/gcc" ]; then
    write_log "Xcode CLT path exists but gcc not found — incomplete install." "Error"
    write_log "Homebrew.pkg install BLOCKED." "Error"
    write_log "Re-run InstallXcodeCLT.sh to repair." "Info"
    complete_script 1
fi

# Get CLT version for the log
CLT_VERSION=$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables \
    2>/dev/null | awk '/version:/ {print $2}')
write_log "Xcode CLT confirmed: ${CLT_VERSION:-unknown version} at $CLT_PATH" "Success"
write_log "Dependency satisfied — Homebrew.pkg install can proceed." "Success"

complete_script 0
