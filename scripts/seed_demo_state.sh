#!/bin/bash
# Seed the Phase 3 active-Mail fixture. This creates one unsent local compose
# window only; it never sends mail or changes a remote account.
set -euo pipefail

/usr/bin/osascript <<'APPLESCRIPT'
tell application "Mail"
    set demoMessage to make new outgoing message with properties {subject:"Hackathon deadline details", content:"VoiceOps demo commitment" & return & return & "Please complete the hackathon submission before the deadline." & return & "Deadline: July 31, 2026" & return & "Important details: include the product demo link and final evaluation results.", visible:true}
    activate
end tell
APPLESCRIPT

echo "seed_demo_state: opened one unsent Mail compose fixture"
echo "Speak: Using this email, remind me two days before the deadline and include the important details."
