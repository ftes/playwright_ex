"""Move an upstream port through a draft checkpoint and an exact checked patch."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.request import urlopen


CI = "843b4ef16d0776013b95c2c9f31c3e9c67a818b0"
CONTROL_HASH = "5295a27eda1db3561a439e0e55714a4eee9fce68d68472d84b3792e67cb84256"
PIN_FILES = {"DRIVER_VERSION", "NODE_VERSION", "priv/driver_checksums.exs"}
SCAFFOLD = PIN_FILES | {
    "lib/playwright/protocol/validator.ex", "lib/playwright/protocol/metainfo.ex",
    "lib/playwright/isomorphic/device_descriptors.ex", "test/upstream_registry.md",
}
PORT = {"README.md", "CHANGELOG.md", "usage-rules.md", "NOTICE", "dev/mix/playwright/api_rules.ex"}
PLACEHOLDER = "Port in progress."
SHA = r"[0-9a-f]{40}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def control():
    # The candidate never supplies the publisher or its Git configuration.
    url = f"https://raw.githubusercontent.com/ftes/ci/{CI}/opencode-scheduled/scheduled.py"
    with urlopen(url, timeout=30) as response:
        data = response.read()
    require(hashlib.sha256(data).hexdigest() == CONTROL_HASH, "Unexpected shared publication code")
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "scheduled.py"
        path.write_bytes(data)
        spec = importlib.util.spec_from_file_location("scheduled", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


def git(*args, env=None):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *map(str, args)],
        env=env,
    )


def rev(expression):
    return git("rev-parse", expression).decode().strip()


def allowed(path, kind):
    if any(part.startswith(".") or part.endswith(".env") for part in Path(path).parts):
        return False
    if kind == "scaffold":
        return path in SCAFFOLD or path.startswith("lib/playwright/api/")
    return ((path not in SCAFFOLD and path.startswith(("lib/", "test/", "guides/", "docs/")))
            or path in PORT) and not (kind == "model" and path.startswith("lib/playwright/api/"))


def files(kind, *, env=None):
    names = git("diff", "--cached", "--raw", "--no-renames", "-z", env=env).rstrip(b"\0").split(b"\0")
    changed = set()
    if names != [b""]:
        for header, name in zip(names[::2], names[1::2], strict=True):
            old_mode, new_mode, *_ = header[1:].split()
            path = os.fsdecode(name)
            require(allowed(path, kind) and {old_mode, new_mode} <= {b"000000", b"100644", b"100755"},
                    f"Unexpected {kind} path or mode: {path!r}")
            changed.add(path)
    return changed


def artifact(directory, required, optional=()):
    require(directory.is_dir() and not directory.is_symlink(), "No artifact directory")
    names = set()
    for path in directory.iterdir():
        limit = 24_000_000 if path.name == "upstream.diff" else 4_000_000 if path.name == "patch" else 32_000
        require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit,
                "Invalid artifact file")
        names.add(path.name)
    require(set(required) <= names <= set(required) | set(optional), "Unexpected artifact contents")


def apply(directory, kind, *, worktree=False):
    patch = directory / "patch"
    require(not git("status", "--porcelain"), "Expected a clean checkout for the artifact")
    if patch.is_file():
        git("apply", "--index" if worktree else "--cached", "--whitespace=nowarn", patch)
    return files(kind)


def save_patch(directory, kind, *, env=None):
    if files(kind, env=env):
        (directory / "patch").write_bytes(
            git("diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", env=env)
        )


def check_pins(version, node):
    for path, expected in (("DRIVER_VERSION", version), ("NODE_VERSION", node)):
        require(git("show", f":{path}").decode() == expected + "\n", f"Unexpected {path}")


def sealed_tree():
    tree = git("write-tree").decode().strip()
    require(tree == os.environ["SEALED_TREE"], "The artifact does not match the sealed tree")
    return tree


def plan(s, prep, output):
    artifact(prep, {"patch", "upstream.diff"})
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "tree"
        source.mkdir()
        with tarfile.open(fileobj=io.BytesIO(git("archive", "HEAD"))) as archive:
            archive.extractall(source, filter="data")
        (source / "tmp").mkdir(exist_ok=True)
        (source / "tmp/upstream.diff").write_bytes((prep / "upstream.diff").read_bytes())
        prompt = Path(".github/prompts/upstream-update.md").read_text()
        result = s.agent(prompt, '{"body":"Concise draft PR body"}', "improve", source=source)
        require(type(result) is dict and result.keys() == {"body"}, "Expected the draft body")
        output.mkdir()
        (output / "body").write_text(s.text(result["body"], 12000))
        env = dict(os.environ, GIT_DIR=rev("--absolute-git-dir"), GIT_WORK_TREE=str(source),
                   GIT_INDEX_FILE=str(root / "index"), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        git("read-tree", "HEAD", env=env)
        git("add", "-A", "--", ".", ":(exclude)tmp", env=env)
        save_patch(output, "model", env=env)


def matching_commit(s, sha, parent, title, message):
    s.verify_recovery(sha, parent, title, message, sealed_tree())


def checkpoint(s, prep, base, branch, title, marker, version, node):
    artifact(prep, {"patch", "upstream.diff"})
    apply(prep, "scaffold")
    check_pins(version, node)
    sealed_tree()
    sha = s.remote_head(branch)
    new = not sha
    retry = os.environ.get("RETRY") == "true"
    if sha:
        matching_commit(s, sha, base, title, marker)
    else:
        require(not any(pr["state"] == "open" or not retry for pr in s.branch_prs(branch)),
                "A previous PR already used this branch")
        sha = s.commit(title, marker, base)
    with s.app_token() as token:
        require(s.remote_head(s.BASE) == base, "The default branch moved")
        if new:
            s.push(branch, token, "")
        require(s.remote_head(branch) == sha, "The checkpoint branch moved")
        prs = [pr for pr in s.branch_prs(branch, token) if pr["state"] == "open" or pr["head"]["sha"] == sha]
        require(len(prs) <= 1, "Expected at most one checkpoint PR")
        pr = prs[0] if prs else s.api("pulls", token=token, method="POST", payload={
            "head": branch, "base": s.BASE, "title": title, "body": PLACEHOLDER, "draft": True,
        })
        s.require_published_pr(pr, branch, sha, base)
        require(pr["draft"] and pr["state"] == "open" and pr["title"] == title and pr["body"] == PLACEHOLDER
                and s.remote_head(s.BASE) == base and s.remote_head(branch) == sha,
                "The checkpoint no longer matches; leaving the draft for a maintainer")
        with open(os.environ["GITHUB_OUTPUT"], "a") as report:
            print(f"head={sha}\npr={pr['number']}", file=report)
        print(pr["html_url"])


def finish(s, checked, base, branch, title, marker, parent, number, version, node):
    artifact(checked, {"body"}, {"patch"})
    changed = apply(checked, "final")
    check_pins(version, node)
    sealed_tree()
    body = s.text((checked / "body").read_text(), 12000)
    require(not body.startswith("Port in progress"), "A completed port cannot use the checkpoint body")
    body += "\n\nVerified: driver checksums, protocol and API generation, formatting, compilation, Credo, parity, and Chromium tests."
    subject = f"Port Playwright {version} changes"
    message = f"{marker}\nDraft body SHA256: {hashlib.sha256(body.encode()).hexdigest()}"
    target = {"number": number, "branch": branch, "head": parent}

    def available(head):
        pr = s.current(target | {"head": head})
        if (pr and pr["draft"] and pr["title"] == title and pr["body"] in (PLACEHOLDER, body)
                and pr["base"]["sha"] == base):
            return pr
        return None

    sha = s.remote_head(branch)
    require(sha and s.remote_head(s.BASE) == base, "The port branch or default branch changed")
    if sha != parent:
        require(changed, "The port branch moved")
        matching_commit(s, sha, parent, subject, message)
    elif changed:
        require(available(parent), "The draft is no longer under automation")
        sha = s.commit(subject, message, parent)
    with s.app_token() as token:
        require(s.remote_head(s.BASE) == base, "The default branch moved")
        if s.remote_head(branch) == parent and sha != parent:
            require(available(parent), "The draft is no longer under automation")
            s.push(branch, token, parent)
        for attempt in range(6):
            require(s.remote_head(branch) == sha and s.remote_head(s.BASE) == base,
                    "A branch moved; leaving the draft for a maintainer")
            pr = available(sha)
            if pr:
                if pr["body"] == PLACEHOLDER:
                    updated = s.api(f"pulls/{number}", token=token, method="PATCH", payload={"body": body})
                    s.require_published_pr(updated, branch, sha, base)
                    require(updated["draft"] and updated["state"] == "open" and updated["body"] == body
                            and updated["title"] == title and s.remote_head(branch) == sha
                            and s.remote_head(s.BASE) == base,
                            "The draft changed during finalization")
                print(pr["html_url"])
                return
            if attempt < 5:
                time.sleep(2)
        raise ValueError("Could not verify the checked draft head; leaving its body for a maintainer")


def main(mode):
    base, version, node = (os.environ[key] for key in ("BASE_SHA", "TO", "NODE"))
    require(re.fullmatch(SHA, base) and all(re.fullmatch(r"\d+\.\d+\.\d+", value) for value in (version, node)),
            "Invalid pinned release inputs")
    parent = os.environ.get("CHECKPOINT_SHA") or base
    require(re.fullmatch(SHA, parent) and rev("HEAD") == parent, "Unexpected checkout head")
    temporary = Path(os.environ["RUNNER_TEMP"])
    prep, proposal, checked = (temporary / name for name in ("port-prep", "port-proposal", "port-checked"))
    if mode == "prepare":
        check_pins(version, node)
        save_patch(prep, "scaffold")
    elif mode == "apply":
        artifact(proposal, {"body"}, {"patch"})
        apply(proposal, "model", worktree=True)
    elif mode == "checked":
        checked.mkdir()
        (checked / "body").write_bytes((proposal / "body").read_bytes())
        check_pins(version, node)
        save_patch(checked, "final")
    else:
        s = control()
        require(s.REPO == "ftes/playwright_ex"
                and s.BASE == json.loads(s.gh("api", f"repos/{s.REPO}"))["default_branch"], "Unexpected publisher repo or base")
        branch, title = f"upstream/{version}", f"Update to Playwright {version}"
        run_id = os.environ["GITHUB_RUN_ID"]
        require(run_id.isdigit(), "Invalid run ID")
        marker = f"OpenCode-Upstream: {run_id} {branch} {base}"
        if mode == "checkpoint":
            checkpoint(s, prep, base, branch, title, marker, version, node)
        elif mode == "plan":
            plan(s, prep, proposal)
        elif mode == "finish":
            finish(s, checked, base, branch, title, marker, parent, int(os.environ["PR"]), version, node)
        else:
            raise ValueError("Unknown port phase")


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except subprocess.CalledProcessError as error:
        sys.exit(f"Upstream port command failed with exit code {error.returncode}")
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
