"""Move an upstream port between isolated Actions jobs."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen


CI = "41939eef91514e8ac6b33a1d6e7923edc42f4628"  # v1.0.14
CONTROL_HASH = "32095ffd96a6d98994f262b2fc978299b0bd5b043ad45b9c9f2fe41683e9993f"
PINS = {"DRIVER_VERSION", "NODE_VERSION", "priv/driver_checksums.exs"}
MECHANICAL = PINS | {"lib/playwright/protocol/validator.ex", "lib/playwright/protocol/metainfo.ex",
                      "lib/playwright/isomorphic/device_descriptors.ex", "test/upstream_registry.md"}
PORT = {"README.md", "CHANGELOG.md", "usage-rules.md", "NOTICE", "dev/mix/playwright/api_rules.ex"}
SHA = r"[0-9a-f]{40}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args, **options):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *map(str, args)],
        **options,
    )


def rev(expression):
    return git("rev-parse", expression).decode().strip()


def allowed(name, phase):
    if any(part.startswith(".") or ".env" in part for part in name.split("/")):
        return False
    generated = name in MECHANICAL or name.startswith("lib/playwright/api/")
    port = name in PORT or (name != "lib/playwright/driver.ex"
                           and name.startswith(("lib/playwright/", "test/", "guides/")))
    return {"prepared": generated, "proposal": port and not generated, "checked": generated or port}[phase]


def validate_paths(phase, baseline="HEAD", **options):
    raw = git("diff", "--cached", "--raw", "--no-renames", "-z", baseline, **options)
    fields = raw.rstrip(b"\0").split(b"\0") if raw else []
    for header, path in zip(fields[::2], fields[1::2], strict=True):
        old, new, *_ = header[1:].split()
        name = os.fsdecode(path)
        require(allowed(name, phase) and {old, new} <= {b"000000", b"100644"},
                f"Unexpected {phase} path or mode: {name!r}")


def seal(file, phase, baseline="HEAD", **options):
    validate_paths(phase, baseline, **options)
    file.write_bytes(git("diff", "--cached", "--binary", "--full-index",
                         "--no-ext-diff", "--no-textconv", baseline, **options))


def apply(file, phase, *, worktree=True, baseline="HEAD"):
    require(file.is_file() and not file.is_symlink() and file.stat().st_size <= 4_000_000,
            "Invalid port patch artifact")
    if file.stat().st_size:
        git("apply", "--index" if worktree else "--cached", "--whitespace=nowarn", file)
    else:
        require(phase == "proposal", "Expected a nonempty port patch")
    validate_paths(phase, baseline)


def infer(prepared, proposal, to):
    apply(prepared / "patch", "prepared")
    scaffold = rev_tree()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = (root / "tree").resolve()
        source.mkdir()
        git("checkout-index", "--all", f"--prefix={source}/")
        for path in source.rglob("*"):
            if path.is_symlink():
                require(not path.readlink().is_absolute() and path.resolve().is_relative_to(source),
                        "Checkout has a symlink outside the model workspace")
        context = source / "tmp"
        context.mkdir()
        for name in ("upstream.diff", "parity.txt"):
            target = context / name
            shutil.copyfile(prepared / name, target)
            target.chmod(0o444)
        upstream = context / "upstream"
        upstream.mkdir()
        with tarfile.open(prepared / "upstream.tar.gz") as archive:
            files = (member for member in archive if (member.isfile() or member.isdir())
                     and not any(part.startswith(".") for part in member.name.split("/")))
            archive.extractall(upstream, members=files, filter="data")
        settings = {
            "providers": {"claude-agent": {"models": {"ci-sonnet": {"modelID": "sonnet", "name": "Sonnet"}}}},
            "permissions": [
                {"action": action, "resource": "*", "effect": effect}
                for action, effect in (("*", "deny"), ("read", "allow"), ("glob", "allow"), ("grep", "allow"),
                                       ("edit", "allow"), ("external_directory", "deny"))
            ] + [{"action": "edit", "resource": pattern, "effect": "deny"}
                 for pattern in ("tmp/*", ".github/*", ".gitattributes", "**/.gitattributes")],
            "policies": [{"action": name, "resource": "*", "effect": "deny"}
                         for name in ("plugin.use", "mcp.use", "skill.use")],
            "share": "disabled", "formatter": False, "lsp": False, "snapshots": False,
            "agents": {"ci": {"mode": "primary", "steps": 100}},
        }
        home = root / "home"
        home.mkdir()
        env = {
            "PATH": os.environ["PATH"], "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / "config"), "XDG_DATA_HOME": str(home / "data"),
            "XDG_CACHE_HOME": str(home / "cache"), "XDG_STATE_HOME": str(home / "state"),
            "CLAUDE_CONFIG_DIR": str(home / "claude"),
            "CLAUDE_CODE_OAUTH_TOKEN": os.environ["CLAUDE_CODE_OAUTH_TOKEN"],
            "OPENCODE_CONFIG_CONTENT": json.dumps(settings), "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
            "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
        }
        opencode = ["opencode", "--standalone"]
        with tempfile.TemporaryFile(mode="w+") as events:
            subprocess.run(opencode + ["auth", "login", "claude-agent", "--method", "claude-login"],
                           cwd=source, env=env, stdin=subprocess.DEVNULL, stdout=events,
                           stderr=events, check=True)
            events.seek(0)
            events.truncate()
            subprocess.run(opencode + ["run", "--archived", "--format", "json", "--agent", "ci",
                                       "--model", "claude-agent/ci-sonnet",
                                       f"Port Playwright {to}. Follow PORTING.md and AGENTS.md. Read "
                                       "tmp/upstream.diff, tmp/upstream/ and tmp/parity.txt as reference data. "
                                       "Apply only semantic port edits and the Unreleased changelog entry. "
                                       "Do not hand-edit generated files or change tooling, dependencies, or CI. "
                                       "Update relevant ported tests without weakening them. No shell is available."],
                           cwd=source, env=env, stdin=subprocess.DEVNULL, stdout=events, check=True)
            events.seek(0)
            stopped = False
            for line in events:
                event = json.loads(line)
                require(event["type"] != "error", "OpenCode reported an inference error")
                if event["type"] == "step_finish":
                    stopped = event["part"]["reason"] == "stop"
            require(stopped, "OpenCode did not complete the port")
        index = root / "index"
        env = dict(os.environ, GIT_DIR=rev("--absolute-git-dir"), GIT_WORK_TREE=str(source),
                   GIT_INDEX_FILE=str(index), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        git("read-tree", scaffold, env=env, cwd=source)
        git("add", "-A", "--", ".", ":(exclude)tmp", env=env, cwd=source)
        proposal.parent.mkdir()
        seal(proposal, "proposal", scaffold, env=env, cwd=source)


def publication():
    # Reuse the existing App exchange, exact-ref lease and PR identity checks.
    url = f"https://raw.githubusercontent.com/ftes/ci/{CI}/opencode-scheduled/scheduled.py"
    with urlopen(url, timeout=30) as response:
        source = response.read()
    require(hashlib.sha256(source).hexdigest() == CONTROL_HASH, "Unexpected shared publisher")
    control = {"__name__": "shared_publisher"}
    exec(compile(source, url, "exec"), control)
    return control


def publish(checked, parent, to, source_sha):
    apply(checked, "checked", worktree=False)
    require(rev_tree() == os.environ["SEALED_TREE"], "Checked patch does not match the sealed tree")
    require(git("show", ":DRIVER_VERSION").decode() == to + "\n", "Candidate driver pin changed")
    shared = publication()
    base = os.environ["BASE"]
    branch = f"upstream-pilot/{'replay-' if base != 'main' else ''}{to}"
    remote, prs, api = (shared[name] for name in ("remote_head", "branch_prs", "api"))
    require(shared["REPO"] == "ftes/playwright_ex" and remote(base) == parent, "The target base moved")
    if remote(branch) or prs(branch):
        print(f"Already handled: {branch}")
        return
    title = f"Update to Playwright {to}"
    body = (f"Manual upstream port pilot for [{to}](https://github.com/microsoft/playwright/releases/tag/v{to}) "
            f"at `{source_sha}`. Review upstream fidelity and the remaining PORTING.md checklist before marking ready.\n\n"
            f"Checked candidate: https://github.com/ftes/playwright_ex/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    sha = shared["commit"](title, f"Upstream: {source_sha}", parent)
    with shared["app_token"]() as token:
        require(remote(base) == parent and not remote(branch) and not prs(branch, token),
                "The publication refs changed")
        shared["push"](branch, token, "")
        require(remote(base) == parent and remote(branch) == sha, "The publication refs changed after the push")
        pr = api("pulls", method="POST", token=token,
                 payload={"head": branch, "base": base, "title": title, "body": body, "draft": True})
        require(shared["published_pr_matches"](pr, branch, sha, parent) and pr["draft"] and pr["state"] == "open",
                "Unexpected PR returned; leave it for a maintainer")
        report("pr", pr["html_url"])
        print(pr["html_url"])


def rev_tree():
    return git("write-tree").decode().strip()


def report(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"{key}={value}", file=output)


def main(phase):
    parent, to = os.environ["EXPECTED_BASE"], os.environ["TO"]
    require(re.fullmatch(SHA, parent) and rev("HEAD") == parent, "Unexpected port checkout")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", to), "Expected a stable release")
    root = Path(os.environ["RUNNER_TEMP"])
    prepared, proposal, checked = (root / f"pilot-{name}" / "patch" for name in ("prepared", "proposal", "checked"))
    if phase == "prepared":
        git("add", "-A")
        seal(prepared, "prepared")
    elif phase == "infer":
        infer(prepared.parent, proposal, to)
    elif phase == "scaffold":
        apply(prepared, "prepared")
    elif phase == "proposal":
        apply(proposal, "proposal", baseline=rev_tree())
    elif phase == "checked":
        git("add", "-A")
        checked.parent.mkdir()
        seal(checked, "checked")
        report("tree", rev_tree())
    elif phase == "check-tree":
        require(rev_tree() == os.environ["SEALED_TREE"] and not git("diff", "--name-only")
                and not git("ls-files", "--others", "--exclude-standard"),
                "Verification changed the checked tree")
    elif phase == "publish":
        source_sha = os.environ["TO_SHA"]
        require(re.fullmatch(SHA, source_sha), "Invalid pinned upstream revision")
        publish(checked, parent, to, source_sha)
    else:
        raise ValueError("Unknown port phase")


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except subprocess.CalledProcessError as error:
        sys.exit(f"Pilot command failed ({error.returncode}): {error.cmd[0]}")
    except ValueError as error:
        sys.exit(str(error))
