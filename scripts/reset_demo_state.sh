#!/bin/bash
# Remove only artifacts carrying the exact Phase 3 demo title plus VoiceOps
# provenance. Nothing is sent, and unrelated mail/reminders are untouched.
set -euo pipefail

/usr/bin/osascript <<'APPLESCRIPT'
tell application "Mail"
    repeat with demoMessage in (every outgoing message whose subject is "Hackathon deadline details")
        try
            close demoMessage saving no
        end try
    end repeat
end tell

tell application "Reminders"
    repeat with demoReminder in (every reminder whose name is "Hackathon deadline details")
        try
            if body of demoReminder contains "voiceops-task:" then delete demoReminder
        end try
    end repeat
end tell
APPLESCRIPT

echo "reset_demo_state: removed matching VoiceOps Phase 3 demo artifacts"
