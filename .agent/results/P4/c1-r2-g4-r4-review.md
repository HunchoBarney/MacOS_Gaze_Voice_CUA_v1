# C1 R4 G4 source and artifact review

Fresh read-only reviewer6a1c0fc8 returned **PASS** for the defined C1 source and
signed-artifact boundary. P4-5/P4-6 and overall phase acceptance remain false.
Reviewer checked the new proposal-reference delta, byte/identity controls,
failing-before proof,25 passing chooser tests,319 passing consumer tests and
the exact signed bundle. No blocking source/artifact findings.

Candidate: /var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-c1-final-r4-0d6djymc/Jev Voice.app.
Signed executable:65155dbeae7cee3f8f3ce24968dc5c24951df235800f0d4836bfd22c7022adf3.
Unsigned executable:b968f9615fd53f1d420c56b9a688fbab84ad7208df2fcfcc274d2441b5ad20a1.
Source:c1-r2-candidate-source-r4/manifest.json.
Stage:../P12/c1-final-r4-stage.json.
Components:../P12/c1-final-r4-component-manifest.json.
Eight package controls pass; strict signature and unchanged rollback verified.
The prior1434-test full G3 predates this private helper change;319 affected
consumer tests run after it. This distinction is deliberate.

**Subsequent G5 still FAILS**. c1-scroll-r2-refs/comparison.json records
max_tokens_exceeded from actor9170;1162.945208ms blocked response, no scroll,
no false done, unchanged target/decoy contents and cleanup restoring one
pre-existing document. No successful latency claim.

Actual actor9170 unified log at2026-11-16 06:47:19:
before sharing state240559bytes/questions54322bytes/28questions;
wire state100201bytes/questions60090bytes/28questions.
Question bytes fell from R3's129321 to60090, but context still does not fit.
No further production edit until actual request structure is captured.
G6 microphone/duplex/physical input remains untested on these candidates.
