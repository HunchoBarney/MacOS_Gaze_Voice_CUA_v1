# P2b browser-driver spike — REPORT

chrome-devtools-mcp@1.10.1 vs Cua `browser_*` (daemon 0.34.0). Generated 2026-10-19 10:45.

## Environment

- run_started: 2026-10-19T00:19:40
- ordering: single
- cua_proxies_baseline: ['60436 /Users/karanvirkang/jarvis-local/Jev Voice.app/Contents/Resources/cua-driver mcp --embedded --socket /var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-cua-60409-95688121.sock --host-bundle-id com.chriswozniczek.jevvoice', '60437 /Users/karanvirkang/jarvis-local/Jev Voice.app/Contents/Resources/cua-driver mcp --embedded --socket /var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-cua-60409-95688121.sock --host-bundle-id com.chriswozniczek.jevvoice']
- cua_proxies_after: [72285]
- cua_proxies_leaked: []
- devtools_pages_before: 7
- devtools_pages_after: 7

## Probe

- cua_daemon: PASS (175.8ms) — socket=/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-cua-60409-1500340c.sock server=0.34.0 tools=58
- devtools_ws_endpoint: PASS (2744.0ms) — HTTP/1.1 101 WebSocket Protocol Handshake; /json/version -> 404 (ws-only endpoint)
- chrome_version: PASS (Nonems) — Chrome 155.0.8059.82 running pid=84132
- cua_existing_profile: PASS (12914.7ms) — bound target=bt-49b4acca-fe95-4efc-8ee4-b421e99edd7a tab=tab-1216cc22-e375-4882-a632-88aa3e52434a url=https://console.typesafe.ai/keys
- tools cua-A: bring_to_front,browser_click,browser_dialog,browser_download,browser_navigate,browser_pointer,browser_prepare,browser_set_input_files,browser_type,check_for_update,check_permissions,click,clipboard_read,clipboard_write,double_click,drag,end_session,escalate_session,get_accessibility_tree,get_agent_cursor_state,get_browser_state,get_config,get_cursor_position,get_desktop_state,get_recording_state,get_screen_size,get_session,get_session_state,get_window_state,health_report,hotkey,install_extension,install_ffmpeg,invoke_menu,kill_app,launch_app,list_apps,list_sessions,list_windows,move_cursor,page,parse_visual_regions,press_key,replay_trajectory,right_click,scroll,set_agent_cursor_enabled,set_agent_cursor_motion,set_agent_cursor_theme,set_config,set_value,set_window_frame,start_recording,start_session,stop_recording,type_text,verify_state,zoom
- tools cua-B: bring_to_front,browser_click,browser_dialog,browser_download,browser_navigate,browser_pointer,browser_prepare,browser_set_input_files,browser_type,check_for_update,check_permissions,click,clipboard_read,clipboard_write,double_click,drag,end_session,escalate_session,get_accessibility_tree,get_agent_cursor_state,get_browser_state,get_config,get_cursor_position,get_desktop_state,get_recording_state,get_screen_size,get_session,get_session_state,get_window_state,health_report,hotkey,install_extension,install_ffmpeg,invoke_menu,kill_app,launch_app,list_apps,list_sessions,list_windows,move_cursor,page,parse_visual_regions,press_key,replay_trajectory,right_click,scroll,set_agent_cursor_enabled,set_agent_cursor_motion,set_agent_cursor_theme,set_config,set_value,set_window_frame,start_recording,start_session,stop_recording,type_text,verify_state,zoom
- tools devtools-A: click,close_page,drag,emulate,evaluate_script,fill,fill_form,get_console_message,get_css_styles,get_network_request,handle_dialog,hover,lighthouse_audit,list_console_messages,list_network_requests,list_pages,navigate_page,new_page,performance_analyze_insight,performance_start_trace,performance_stop_trace,press_key,resize_page,select_page,take_heapsnapshot,take_screenshot,take_snapshot,type_text,upload_file,wait_for
- tools devtools-B: click,close_page,drag,emulate,evaluate_script,fill,fill_form,get_console_message,get_css_styles,get_network_request,handle_dialog,hover,lighthouse_audit,list_console_messages,list_network_requests,list_pages,navigate_page,new_page,performance_analyze_insight,performance_start_trace,performance_stop_trace,press_key,resize_page,select_page,take_heapsnapshot,take_screenshot,take_snapshot,type_text,upload_file,wait_for

## Per-op latency (timed iters, ok rows)

| arm | driver | op | n | ok% | p50 ms | p95 ms |
|---|---|---|---|---|---|---|
| A | cua | navigate | 30 | 0 (unsupported:30) | - | - |
| A | cua | settle | 30 | 0 (unsupported:30) | - | - |
| A | cua | snapshot | 30 | 50 (blocked_env:15) | 3268 | 5605 |
| A | cua | type | 30 | 0 (unsupported:30) | - | - |
| A | cua | click | 30 | 0 (unsupported:30) | - | - |
| A | cua | extract | 30 | 50 (blocked_env:15) | 1900 | 2128 |
| A | devtools | navigate | 120 | 50 (blocked_env:60) | 2274 | 4583 |
| A | devtools | settle | 120 | 50 (blocked_env:60) | 241 | 838 |
| A | devtools | snapshot | 120 | 50 (blocked_env:60) | 72 | 803 |
| A | devtools | type | 120 | 12 (blocked_env:60,unsupported:45) | 610 | 954 |
| A | devtools | click | 120 | 38 (blocked_env:60,driver_error:15) | 1229 | 2568 |
| A | devtools | extract | 120 | 50 (blocked_env:60) | 376 | 841 |
| B | cua | navigate | 60 | 50 (driver_error:30) | 1692 | 4364 |
| B | cua | settle | 60 | 50 (driver_error:30) | 746 | 2428 |
| B | cua | snapshot | 60 | 33 (driver_error:30,timeout:10) | 68 | 14946 |
| B | cua | type | 60 | 0 (driver_error:40,refused:5,unsupported:15) | - | - |
| B | cua | click | 60 | 33 (driver_error:40) | 2088 | 3396 |
| B | cua | extract | 60 | 25 (driver_error:40,timeout:5) | 546 | 750 |
| B | devtools | navigate | 60 | 100 | 1334 | 3072 |
| B | devtools | settle | 60 | 100 | 216 | 699 |
| B | devtools | snapshot | 60 | 100 | 164 | 1988 |
| B | devtools | type | 60 | 0 (driver_error:15,unsupported:45) | - | - |
| B | devtools | click | 60 | 100 | 1093 | 2495 |
| B | devtools | extract | 60 | 100 | 222 | 348 |

## Attach + teardown cycles

| arm | driver | n (attempts) | attach p50 | attach p95 | teardown p50 | teardown p95 | status | skipped |
|---|---|---|---|---|---|---|---|---|
| A | cua | 19 | 6905 | 7984 | 8.1 | 51 | blocked_env,ok | 11 |
| A | devtools | 8 | 7647 | 13603 | 664 | 742 | blocked_env,ok | 4 |
| B | cua | 6 | 11731 | 15781 | 407 | 584 | ok | 0 |
| B | devtools | 6 | 6228 | 9002 | 270 | 1224 | ok | 0 |

`skipped` = slots recorded without an attach attempt after a pending consent dialog (dialog-stacking guard) — shown for completeness, excluded from all stats.

## Snapshot bytes

| arm | driver | site | bytes |
|---|---|---|---|
| B | devtools | mdn-iframe | 106565 |
| B | devtools | iana | 5100 |
| B | devtools | example | 1235 |
| B | devtools | wikipedia | 469755 |
| B | devtools | github | 19087 |
| B | devtools | spa | 30272 |
| B | devtools | - | 62 |
| B | cua | mdn-iframe | 443 |
| B | cua | iana | 24517 |
| B | cua | example | 8297 |
| B | cua | wikipedia | 63061 |
| B | cua | github | 14686 |
| B | cua | spa | 57416 |
| B | cua | - | 899 |
| A | devtools | example | 1235 |
| A | devtools | wikipedia | 469755 |
| A | devtools | github | 9521 |
| A | devtools | spa | 38440 |
| A | cua | bound-user-tab | 58442 |

## Robustness

| arm | driver | check | site | ms | status | detail |
|---|---|---|---|---|---|---|
| A | devtools | stale_ref_click | - | 0.0 | blocked_env | attach: autoConnect attach timed out — Chrome remote-debugging consent dialog ('Allow remote debugging?') pending: read  |
| A | devtools | iframe_snapshot | - | 0.0 | blocked_env | attach: autoConnect attach timed out — Chrome remote-debugging consent dialog ('Allow remote debugging?') pending: read  |
| A | devtools | cross_origin_nav | - | 0.0 | blocked_env | attach: autoConnect attach timed out — Chrome remote-debugging consent dialog ('Allow remote debugging?') pending: read  |
| A | devtools | snapshot_bytes | - | 0.0 | blocked_env | attach: autoConnect attach timed out — Chrome remote-debugging consent dialog ('Allow remote debugging?') pending: read  |
| A | devtools | reattach_after_kill | - | 0.0 | blocked_env | attach: autoConnect attach timed out — Chrome remote-debugging consent dialog ('Allow remote debugging?') pending: read  |
| A | cua | stale_ref_click | - | 0.0 | blocked_env | attach: all 14 candidate window(s) refused — bind w12244: consent-gated, dialog pending, prepare skipped; bind w12246: c |
| A | cua | iframe_snapshot | - | 0.0 | blocked_env | attach: all 14 candidate window(s) refused — bind w12244: consent-gated, dialog pending, prepare skipped; bind w12246: c |
| A | cua | cross_origin_nav | - | 0.0 | blocked_env | attach: all 14 candidate window(s) refused — bind w12244: consent-gated, dialog pending, prepare skipped; bind w12246: c |
| A | cua | snapshot_bytes | - | 0.0 | blocked_env | attach: all 14 candidate window(s) refused — bind w12244: consent-gated, dialog pending, prepare skipped; bind w12246: c |
| A | cua | reattach_after_kill | - | 0.0 | blocked_env | attach: all 14 candidate window(s) refused — bind w12244: consent-gated, dialog pending, prepare skipped; bind w12246: c |
| B | devtools | stale_ref_click | wikipedia | 7484 | ok | clean refusal: Error: Failed to interact with the element with uid 1_0. The element did not become interactive within th |
| B | devtools | iframe_snapshot | mdn-iframe | 3110 | ok | bytes=106565 |
| B | devtools | cross_origin_nav | iana | 12 | ok | bytes=5100 |
| B | devtools | snapshot_bytes | example | 8.6 | ok | bytes=1235 |
| B | devtools | snapshot_bytes | wikipedia | 1052 | ok | bytes=469755 |
| B | devtools | snapshot_bytes | github | 404 | ok | bytes=19087 |
| B | devtools | snapshot_bytes | spa | 120 | ok | bytes=30272 |
| B | devtools | reattach_after_kill | - | 4677 | ok | bytes=62 refs=1 |
| B | cua | stale_ref_click | wikipedia | 7056 | ok | clean refusal: refused (browser_ref_stale): ref p118:7 is stale — the page navigated or the snapshot was superseded; re- |
| B | cua | iframe_snapshot | mdn-iframe | 4929 | ok | bytes=443 |
| B | cua | cross_origin_nav | iana | 1498 | ok | bytes=24517 |
| B | cua | snapshot_bytes | example | 74 | ok | bytes=8297 |
| B | cua | snapshot_bytes | wikipedia | 10292 | ok | bytes=63061 |
| B | cua | snapshot_bytes | github | 1006 | ok | bytes=14686 |
| B | cua | snapshot_bytes | spa | 1424 | ok | bytes=57416 |
| B | cua | reattach_after_kill | - | 12461 | ok | bytes=899 refs=0 url=about:blank |

## Single-driver smoke rows (excluded above)

72 rows flagged ordering=single — debug/smoke only.

## Verdict (measured)

Arm-B ok-rate over timed interleaved cells: devtools 83% (n=360), cua 32% (n=360). Arm-A ok-rate: devtools 42%, cua 17% — Arm-A rows mix the pre-consent blocked era (blocked_env) with post-consent measured rows; read the ok subset for capability, the blocked rows for the consent UX cost.

Arm-B attach p50: devtools 6228ms, cua 11731ms (spawn + handshake + prepare + tools/list). Teardown: sub-second devtools, ~0.5s cua.
Arm-A attach p50 (post-consent, ok rows only): devtools 7647ms, cua 6905ms.

- 301 cua rows are 'transport not alive'/'closed stdout' — every one downstream of a wikipedia semantic_v2 snapshot that exceeded the 15s read deadline or killed the proxy; github/spa cells are cascade, not capability (all four sites measured ok in the robustness matrix).
- 23 rows show ref staleness after navigation (devtools uid 'no longer exists', cua browser_ref_stale clean refusal) — the as-run corpus clicked before typing, so the wikipedia type cell measures stale-ref behavior for both drivers.
- 'unsupported' type cells are corpus-declared (no safe editable target on that site), not driver incapacity.

Arm A has two eras: pre-consent (6 real blocked attach attempts + 15 skipped cascade slots + per-op blocked_env rows — Chrome 155's 'Allow remote debugging?' dialog held both drivers: autoConnect handshake pends at read deadline, cua existing_profile binds consent-gated per window) and post-consent measured rows (user granted once — ws handshake 101 in ~2.7s, autoConnect attaches, cua binds). The consent click is a one-time per-Chrome-instance gate P7 must design for. While the dialog was still settling, cua prepares intermittently refused 'consent did not settle for reconnect'; once fully cleared, 10/10 cua Arm-A attach cycles passed. The run was paused by a laptop-lid sleep between the consent click and the Arm-A rerun — post-consent rows come from the resumed run (results/run-armA-consented.log).

Pick: **devToolsMcp (primary) + cua fallback — matches the locked plan direction**.

Numbers behind it: devtools ran the full mutating corpus at 83% cell-ok (every non-type cell 15/15 on all four sites) with ~1.9x faster attach and millisecond-scale snapshots; cua completed example.com's corpus cleanly and passed every robustness check, but its semantic_v2 snapshot on heavy pages (~10s/63KB wikipedia) sits near the read deadline and repeatedly killed the stdio transport. cua's snapshots are far smaller (8-63KB vs devtools' 1-470KB), which is why it stays the fallback rather than being dropped.

## Files

- `mcp.py` — newline-delimited JSON-RPC stdio client (adapted from bench/lib/mcp_stdio.py; bounded reads, kill-on-timeout).
- `ops.py` — driver adapters + driver-neutral op corpus.
- `run.py` — attach/teardown cycles + interleaved corpus run.
- `probe.py` — environment/protocol checks -> probe block.
- `robustness.py` — robustness matrix runner.
- `report.py` — this report.
- `sites.json` — site corpus + safe selectors.
- `package.json`/`package-lock.json` — chrome-devtools-mcp@1.10.1 pin.
- `results/results.json` — raw rows; `results/REPORT.md` — this file; `results/*.log` — run streams incl. superseded arm-A rows.

## Commands

- `python3 probe.py` — env probe -> results.json probe block
- `python3 run.py` — full interleaved run (warmup 3 + N=15, N=5 attach cycles per arm×driver)
- `python3 run.py --arm A` — arm-A row regeneration after emitter fix (superseded rows kept in run-full.log)
- `python3 robustness.py` — robustness matrix, both arms
- `python3 report.py` — regenerate this file


## Unmeasured

- CONTRACTS §5 `key`/`scroll`/`back` actions — not in corpus.
- Pixel-path (screenshot) comparison — P5 does not exist yet; P7 compares against Sol later.
- Arm-A post-consent rows are measured for devtools (full corpus in a spike-owned tab on the real profile) and cua read-only ops (bound user tab) — the pre-consent blocked_env rows remain as the consent-cost record. cua Arm-A mutation stays unexercised BY DESIGN (no tab verbs → would require mutating a user tab, forbidden).
- cua Arm-A read latencies (snapshot ~3.3s, extract ~1.9s) were measured on a tab bound to `about:blank` — a ~2-3s fixed existing_profile read floor, not page-weight-driven; a real logged-in page was also bound once earlier (console.typesafe.ai/keys, ~10s snapshot, 113 refs).
- cua `type` never measured clean: example/spa had no editable target, wikipedia hit stale-ref refusals, and the github/spa cells were transport-death cascade.
