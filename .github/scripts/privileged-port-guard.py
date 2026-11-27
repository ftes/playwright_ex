"""Allow privileged Mix setup only on the checked, current PR head."""

import json
import os
import re
import subprocess
import sys


PINS = ("DRIVER_VERSION", "NODE_VERSION", "priv/driver_checksums.exs")
SHA = r"[0-9a-f]{40}"


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def git(*args):
    return capture("git", "-c", "core.hooksPath=/dev/null", *args)


def current_head(pr, repo, branch, expected=None):
    head, base = pr["head"], pr["base"]
    sha = head["sha"]
    if (pr["state"] == "open" and head["ref"] == branch and not branch.startswith("upstream-pilot/")
            and (head["repo"] or {}).get("full_name") == repo and base["repo"]["full_name"] == repo
            and re.fullmatch(SHA, sha) and (expected is None or sha == expected)):
        return sha
    return None


def same_pins(trusted, head):
    base = git("merge-base", "--all", trusted, head)
    if not re.fullmatch(SHA, base):
        return False
    for path in PINS:
        original = git("ls-tree", base, "--", path)
        if not original.startswith("100644 blob ") or original != git("ls-tree", head, "--", path):
            return False
    return True


def main(mode):
    trusted = git("rev-parse", "HEAD")
    if git("rev-parse", "--is-shallow-repository") != "false":
        raise ValueError("Expected full default-branch history")
    if mode == "require" and trusted != os.environ["TRUSTED"]:
        raise ValueError("Trusted checkout changed")
    outputs = {"trusted": trusted}
    if mode != "snapshot" or os.environ["IS_PR"] == "true":
        repo = os.environ["GITHUB_REPOSITORY"]
        number = int(os.environ["NUMBER"])
        branch = os.environ["BRANCH"]
        expected = None if mode == "snapshot" else os.environ["EXPECTED_HEAD"]
        pr = json.loads(capture("gh", "api", f"repos/{repo}/pulls/{number}"))
        head = current_head(pr, repo, branch, expected)
        if head and subprocess.run(["git", "cat-file", "-e", f"{head}^{{commit}}"],
                                   stderr=subprocess.DEVNULL).returncode:
            git("fetch", "--quiet", "--no-tags", "origin", head)
        if not head or not same_pins(trusted, head):
            message = "PR moved or changes the upstream driver pins; privileged setup declined."
            if mode == "require":
                raise ValueError(message)
            print(message)
            return
        outputs["head"] = head
    if mode != "require":
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in (outputs | {"allowed": "true"}).items():
                print(f"{key}={value}", file=output)


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except (KeyError, ValueError, subprocess.CalledProcessError):
        sys.exit("Could not verify the trusted checkout and current PR head; privileged setup declined.")
