#!/usr/bin/env python3
"""P2c environment probe -> results/results.json "probe" block.

Real protocol calls against the vendored codex app-server
(build/vendor/CodexRuntime/bin/codex, pinned 0.160.0): initialize,
configRequirements/read (VERBATIM — declared requirements, distinct from
the writable Config.computer_use surface), config/read (effective
config), model/list. Exits non-zero with status blocked_env when the
binary/auth/initialize fails. Stdlib only.
"""

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appserver as A

RESULTS = os.path.join(A.HERE, "results", "results.json")
SKY_CLIENT = os.path.expanduser(
    "~/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/"
    "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")


def load_results():
    if os.path.isfile(RESULTS):
        with open(RESULTS) as f:
            return json.load(f)
    return {}


def save_results(data):
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    tmp = RESULTS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, RESULTS)


def cli(home, *args):
    """Vendored codex CLI under the restricted env -> (rc, stdout+stderr)."""
    try:
        r = subprocess.run([A.CODEX_BIN] + list(args), capture_output=True,
                           text=True, timeout=60, env=A.child_env(home),
                           cwd=A.HERE)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return -1, "%s: %s" % (type(exc).__name__, exc)


def main():
    no_auth = "--no-auth" in sys.argv  # negative control: auth absent
    probe = {"probed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
             "codex_bin": os.path.relpath(A.CODEX_BIN, A.REPO),
             "pinned_version": A.CODEX_VERSION, "status": "ok",
             "blocked": []}
    if not os.access(A.CODEX_BIN, os.X_OK):
        probe["status"] = "blocked_env"
        probe["blocked"].append("vendored codex missing: %s" % A.CODEX_BIN)
        return finish(probe)
    home = A.make_home("probe-noauth" if no_auth else "probe", "")
    if no_auth:
        os.unlink(os.path.join(home, "auth.json"))
        probe["negative_control"] = "--no-auth: auth.json symlink removed"
    probe["codex_home"] = os.path.relpath(home, A.REPO)
    probe["auth_json_symlink"] = os.path.islink(
        os.path.join(home, "auth.json"))

    rc, out = cli(home, "--version")
    probe["version_output"] = out
    probe["version_matches_pin"] = out.strip().endswith(A.CODEX_VERSION)
    rc, out = cli(home, "features", "list")
    probe["features"] = [re.sub(r"\s+", " ", l).strip()
                         for l in out.splitlines()
                         if re.match(r"(computer_use|browser_use)\b", l)]
    rc, out = cli(home, "login", "status")
    probe["login_status"] = out
    if rc != 0 or "Logged in" not in out:
        probe["status"] = "blocked_env"
        probe["blocked"].append("codex login status rc=%d" % rc)

    srv = A.AppServer(home).start()
    try:
        init = srv.initialize()
        probe["initialize"] = init
        probe["codex_home_reported"] = init.get("codexHome")
        probe["config_requirements_read"] = srv.call(
            "configRequirements/read")
        cfg = srv.call("config/read", {"includeLayers": True,
                                       "cwd": os.path.join(A.HERE,
                                                           "sandbox")})
        conf = cfg.get("config") or {}
        probe["effective_config"] = {
            k: conf.get(k) for k in (
                "model", "model_reasoning_effort", "approval_policy",
                "approvals_reviewer", "sandbox_mode", "computer_use",
                "browser_use", "desktop", "auto_review", "apps",
                "default_permissions")}
        probe["effective_config_note"] = (
            "config/read of a fresh CODEX_HOME (empty config.toml); null = "
            "unset -> codex built-in default applies")
        probe["config_layers"] = [
            {k: (l.get(k) if k != "config" else sorted((l.get("config")
                 or {}).keys())) for k in l}
            for l in (cfg.get("layers") or [])]
        models = srv.call("model/list", {"includeHidden": True})
        probe["models"] = [m.get("id") or m.get("model")
                           for m in models.get("data", [])]
        probe["sol_family"] = [m for m in probe["models"] if "sol" in m]
        feats = srv.call("experimentalFeature/list", {})
        probe["experimental_features_cu"] = [
            {k: f.get(k) for k in ("name", "stage", "enabled",
                                   "defaultEnabled")}
            for f in feats.get("data", [])
            if re.search(r"computer|browser", f.get("name", ""))]
        probe["notifications_seen"] = sorted(
            {n["method"] for n in srv.notifications})
    except A.RPCError as exc:
        probe["status"] = "blocked_env"
        probe["blocked"].append("app-server: %s" % exc)
    finally:
        srv.close()

    # Where the computer tool would come from: NOT in CodexRuntime.
    probe["cu_host"] = {
        "vendored_runtime_has_cu_host": any(
            "computer" in n.lower() or "sky" in n.lower()
            for _, ds, fs in os.walk(os.path.dirname(os.path.dirname(
                A.CODEX_BIN))) for n in ds + fs),
        "sky_client_path": SKY_CLIENT.replace(os.path.expanduser("~"), "~"),
        "sky_client_present": os.access(SKY_CLIENT, os.X_OK),
        "provenance": "installed by the ChatGPT/Codex desktop app under "
                      "~/.codex/computer-use (not part of the vendored "
                      "CodexRuntime)"}
    return finish(probe)


def finish(probe):
    if not probe.get("negative_control"):
        data = load_results()
        data["probe"] = probe
        save_results(data)
    for k in ("status", "version_output", "login_status", "features",
              "codex_home_reported", "config_requirements_read",
              "sol_family", "cu_host", "blocked"):
        print("%s: %s" % (k, json.dumps(probe.get(k))))
    return 0 if probe["status"] == "ok" else 2


if __name__ == "__main__":
    sys.exit(main())
