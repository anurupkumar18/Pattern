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

tell application "Calendar"
    repeat with targetCalendar in calendars
        repeat with demoEvent in (every event of targetCalendar whose description is "voiceops-demo-event")
            try
                delete demoEvent
            end try
        end repeat
    end repeat
end tell

tell application "Notes"
    repeat with demoNote in (every note whose name starts with "VoiceOps Brief")
        try
            if body of demoNote contains "voiceops-task:" then delete demoNote
        end try
    end repeat
end tell
APPLESCRIPT

echo "reset_demo_state: removed matching VoiceOps Phase 3 demo artifacts"
