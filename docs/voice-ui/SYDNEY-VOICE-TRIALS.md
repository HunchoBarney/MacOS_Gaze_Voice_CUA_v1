# Sydney candidate: coordinated physical trials

Candidate: `.context/voice-current/Jev Voice.app`, source `433f473` plus the
working-tree voice acceptance patch archived as `.context/voice-current/candidate.patch`.
Executable SHA-256: `8cb7278a07e02bcf8003963a3451b092c8467ebd690998e2b959b0cce34fc7e5`.
This is a test candidate, not accepted delivery. It has not replaced the installed
app or been launched for physical testing. Semantic and physical gates remain open.

**Start:** tell the agent “ready for voice trials.” The agent acquires the shared
desktop lock, coordinates quitting the other app copy, launches this exact bundle,
starts content-free timing logs, and confirms Voice settings reports Ready. Renew
macOS permissions only if requested by this build. Use the normal selected mic.
Do not begin until the agent confirms logging and readiness.

For each row, report the displayed words (especially first/final words), any
unexpected behavior, and whether the intended app appeared. “Not visible” is a
valid observation; do not guess. The agent records capture, interpretation/handoff,
and desktop outcome separately. A stale-window/task-dependency error is not proof
of missed speech. Intentional silence is not a recognition failure.

| Trial | Say | Fn release |
| --- | --- | --- |
| I1 | Open Calculator. | Immediately after “Calculator” |
| I2 | Could you bring up Notes? | Immediately after “Notes” |
| I3 | Don't open Safari. | Immediately after “Safari”; expect no open request |
| I4 | Open Notes—no, Maps. | Speak continuously; release after “Maps” |
| I5 | Open Calendar. | Immediately after “Calendar” |
| L1 | Open Calculator. | Keep holding silently for two seconds after speaking |
| L2 | Could you bring up Calculator? | Keep holding silently for two seconds after speaking |

For L1/L2, note whether the UI responds while held and whether anything repeats
on release. The agent checks actual before-release handoff and later recognition
revisions; an app appearing later is a separate execution measurement. Each hold
is an intentional new request; repeated Calculator trials must not be deduplicated.

Then coordinate these checks one at a time:

- **Silent/UI:** silent Fn hold/release dismisses without an error or new task;
  capsule stays responsive without flicker. Cold-start early release must not
  begin listening later.
- **Cancellation/manual:** say “Search for” and press Escape before completing;
  release and confirm no delayed handoff. Test task Stop/Stop All only on owned
  disposable test tasks. In manual mode, no handoff before explicit approval;
  the agent restores the original setting afterward.
- **Sleep/wake and lock/unlock:** hardware pauses, then returns to Ready without
  restarting the old hold or replaying speech. Try one short spoken request after
  each recovery, separate from the seven measured trials above.
- **Device recovery:** if another mic is available, coordinate selection and loss/
  recovery. An unavailable explicitly selected device must not silently fall back.
  Restore the original selection. Unavailable hardware remains untested.

The agent owns log correlation, duplicate/cancellation checks, build identity,
and evidence updates. No need for you to diagnose Cua or inspect logs.
The separate 30-hold programmatic microphone benchmark also needs macOS microphone
permission for its test process; app permission alone does not grant it. Coordinate
that grant if available, otherwise its required samples remain blocked.
