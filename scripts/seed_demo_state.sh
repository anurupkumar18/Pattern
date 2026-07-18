#!/bin/bash
# Seed the Phase 3 active-Mail fixture. This creates one unsent local compose
# window only; it never sends mail or changes a remote account.
set -euo pipefail

/usr/bin/osascript <<'APPLESCRIPT'
tell application "Mail"
    set demoMessage to make new outgoing message with properties {subject:"Hackathon deadline details", content:"VoiceOps demo commitment" & return & return & "Please complete the hackathon submission before the deadline." & return & "Deadline: July 31, 2026" & return & "Important details: include the product demo link and final evaluation results.", visible:true}
    activate
end tell

tell application "Calendar"
    set writableCalendars to every calendar whose writable is true
    if (count of writableCalendars) is 0 then error "No writable Calendar is configured"
    set targetCalendar to item 1 of writableCalendars
    set meetingStart to (current date) + (15 * minutes)
    set meetingEnd to meetingStart + (30 * minutes)
    set demoEvent to make new event at end of events of targetCalendar with properties {summary:"VoiceOps Product Review", start date:meetingStart, end date:meetingEnd, description:"voiceops-demo-event", url:"https://meet.example.com/voiceops-review"}
    show demoEvent
    activate
end tell
APPLESCRIPT

echo "seed_demo_state: opened one unsent Mail fixture and one upcoming Calendar meeting"
echo "Speak: Using this email, remind me two days before the deadline and include the important details."
echo "Or: Prepare me for my next meeting using what's already open."
