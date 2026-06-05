#!/bin/bash
# 🛰️ pgAgent Antigravity 2.0 Automation Hooks
# Formatting and native macOS notification system for background agentic operations.

set -e

COMMAND="${1:-}"

# Display usage instructions
usage() {
    echo "Usage:"
    echo "  $0 format <file_path>       - Format a Swift or Rust file in-place"
    echo "  $0 notify <title> <msg> [ok] - Trigger a native macOS notification (ok=true/false)"
    exit 1
}

if [ -z "$COMMAND" ]; then
    usage
fi

case "$COMMAND" in
    "format")
        FILE_PATH="${2:-}"
        if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
            echo "❌ Invalid file path specified."
            exit 1
        fi

        case "$FILE_PATH" in
            *.swift)
                if command -v swift-format >/dev/null 2>&1; then
                    echo "🧹 Formatting Swift file: $FILE_PATH"
                    swift-format format --in-place "$FILE_PATH" 2>/dev/null || true
                else
                    echo "⚠️ swift-format not installed. Skipping auto-format."
                fi
                ;;
            *.rs)
                if command -v rustfmt >/dev/null 2>&1; then
                    echo "🧹 Formatting Rust file: $FILE_PATH"
                    rustfmt "$FILE_PATH" 2>/dev/null || true
                else
                    echo "⚠️ rustfmt not installed. Skipping auto-format."
                fi
                ;;
            *)
                echo "ℹ️ No formatter registered for file type: $FILE_PATH"
                ;;
        esac
        ;;

    "notify")
        TITLE="${2:-🤖 Antigravity Update}"
        MESSAGE="${3:-Task completed successfully!}"
        STATUS="${4:-true}" # true = success, false = error

        # Ensure we are running on macOS and in a graphical environment before calling osascript
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if [ "$STATUS" = "true" ]; then
                SOUND="Glass"
                PREFIX="✅ "
            else
                SOUND="Basso"
                PREFIX="❌ "
            fi
            
            # Send Native macOS Notification
            osascript -e "display notification \"$PREFIX$MESSAGE\" with title \"$TITLE\" sound name \"$SOUND\"" 2>/dev/null || true
            echo "🔔 Sent macOS notification: $TITLE - $MESSAGE"
        else
            echo "ℹ️ Non-macOS environment. Skipping notification: $TITLE - $MESSAGE"
        fi
        ;;

    *)
        usage
        ;;
esac
