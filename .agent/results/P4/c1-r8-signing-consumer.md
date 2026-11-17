# R8 canonical VAD signing consumer

G2 scope extension proposal, not applied. User authorization remains C1 package
completion and the approved R8 canonical VAD reuse. The R8 owned list omitted
`scripts/sign-app.sh`, discovered as a consumer while moving the validator.
It currently imports untracked `.agent/results/P12/c1_manifest.py` before
signing, so a clean source checkout still depends on an evidence helper.

Proposed exact change inside the existing ConversationCapture presence guard:

```bash
    python3 "$REPO_ROOT/scripts/bundle-conversation-vad.py" \
        --source "$REPO_ROOT/build/vendor/ConversationVAD" \
        --app "$APP"
```

This replaces the P12 helper's `prepare-vad --destination
"$APP/Contents/Resources/ConversationVAD"` invocation. No other signing lines,
identity, entitlements, provenance handling, driver pin or resource version
change. Public bundler validates the exact same runtime hash
`be41b15f2b6c5c73c4824b99963b54bc6d5f58c3af04468132ddfe131c1c8062`.

Review criteria: same payload/destination and failure behavior; no signing or
authority weakening; removal of the clean-checkout evidence dependency. Only
after independent PASS, add this consumer to R8 ownership and apply the change.
