#!/bin/bash

# ---------------------------[ Script Start Timestamp ]---------------------------
SCRIPT_START_TIME=$(date +%s%N)

# ---------------------------[ Script Name ]---------------------------
SCRIPT_NAME="install-xcodeclt"
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
HOSTNAME=$(hostname)
CURRENT_USER=$(echo "show State:/Users/ConsoleUser" | scutil \
    | awk '/Name :/ && ! /loginwindow/ { print $3 }')

write_log "==================== Start ====================" "Start"
write_log "$HOSTNAME | $CURRENT_USER | $SCRIPT_NAME" "Info"
write_log "Triggered by Intune scheduled run" "Info"
write_log "Running as: $(whoami) (UID: $(id -u))" "Debug"

# ---------------------------[ Idempotency Check ]---------------------------
write_log "Checking if Xcode CLT is already installed..." "Get"

CLT_PATH=$(xcode-select -p 2>/dev/null)
CLT_EXIT=$?

if [ $CLT_EXIT -eq 0 ] && [ -d "$CLT_PATH" ]; then
    # Also verify the actual compilers are present — xcode-select -p can
    # return a path even when CLT is only partially installed
    if [ -f "$CLT_PATH/usr/bin/gcc" ] || [ -f "/usr/bin/gcc" ]; then
        CLT_VERSION=$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables \
            2>/dev/null | awk '/version:/ {print $2}')
        write_log "Xcode CLT already installed: ${CLT_VERSION:-unknown version} at $CLT_PATH" "Success"
        write_log "Nothing to do — exiting cleanly." "Info"
        complete_script 0
    fi
fi

write_log "Xcode CLT not found. Proceeding with installation." "Info"

# ---------------------------[ Trigger softwareupdate ]---------------------------
# The headless approach: create the trigger file that tells softwareupdate
# to include Command Line Tools in its list, then install via softwareupdate.
# This avoids any GUI dialog (xcode-select --install shows a popup).

write_log "Creating CLT install trigger file..." "Run"
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

write_log "Querying softwareupdate for CLT package..." "Get"
CLT_PACKAGE=$(softwareupdate -l 2>/dev/null \
    | grep -B1 "Command Line Tools" \
    | awk -F"*" '/\*/ {print $2}' \
    | sed -e 's/^ *//' -e 's/[()]//g' \
    | sort -V \
    | tail -n1)

write_log "Available CLT package: ${CLT_PACKAGE:-none found}" "Get"

if [ -z "$CLT_PACKAGE" ]; then
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    write_log "No CLT package found via softwareupdate." "Error"
    write_log "This can happen if:" "Info"
    write_log "  1. The device is not connected to the internet" "Info"
    write_log "  2. softwareupdate is managed by another MDM policy" "Info"
    write_log "  3. CLT is already installing in the background" "Info"
    write_log "Intune will retry on next scheduled run." "Info"
    complete_script 1
fi

# ---------------------------[ Install CLT ]---------------------------
write_log "Installing: $CLT_PACKAGE" "Run"
write_log "This may take several minutes..." "Info"

softwareupdate -i "$CLT_PACKAGE" --verbose 2>&1 | while IFS= read -r LINE; do
    [ -n "$LINE" ] && write_log "$LINE" "Debug"
done

SW_EXIT=${PIPESTATUS[0]}
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

if [ $SW_EXIT -ne 0 ]; then
    write_log "softwareupdate exited with code $SW_EXIT." "Error"
    complete_script 1
fi

# ---------------------------[ Verify ]---------------------------
write_log "Verifying Xcode CLT installation..." "Get"

# Wait up to 60s for xcode-select to register the new install
VERIFY_WAIT=0
until xcode-select -p &>/dev/null; do
    sleep 5
    VERIFY_WAIT=$(( VERIFY_WAIT + 5 ))
    if [ $VERIFY_WAIT -ge 60 ]; then
        write_log "xcode-select did not register CLT after 60s — may need a retry." "Error"
        complete_script 1
    fi
done

CLT_PATH=$(xcode-select -p)
CLT_VERSION=$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables \
    2>/dev/null | awk '/version:/ {print $2}')

write_log "Xcode CLT verified: ${CLT_VERSION:-unknown} at $CLT_PATH" "Success"

# Write a receipt file so other scripts can detect CLT presence
# without relying solely on xcode-select
RECEIPT_DIR="/Library/Logs/IntuneLogs/Scripts/$SCRIPT_NAME"
echo "{\"installed\": true, \"version\": \"${CLT_VERSION}\", \"path\": \"${CLT_PATH}\", \"date\": \"$(date)\"}" \
    > "$RECEIPT_DIR/receipt.json"
write_log "Receipt written to $RECEIPT_DIR/receipt.json" "Debug"

complete_script 0
