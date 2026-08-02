#!/usr/bin/env python3
"""Report whether TAP_GITHUB_TOKEN can still write to the Homebrew tap.

The release workflow deliberately never fails when the tap update does not
land, because by that point the release is already published and a red build
would misrepresent a good one. The cost of that choice is that a missing,
revoked, expired or wrongly-scoped token is silent: releases stay green and the
cask quietly stops tracking them.

This is the other half. It runs on its own, before and independently of any
release, so it is free to fail loudly, and says exactly which of the ways it
can be wrong it is.

Read-only: asks the API what the token may do rather than trying it.
"""

import json
import os
import sys
import urllib.error
import urllib.request

REPO = "ThinkVelta/homebrew-tap"
SECRET = "TAP_GITHUB_TOKEN"


def fail(message: str) -> int:
    print(f"::error::{message}")
    return 1


def main() -> int:
    token = os.environ.get("TAP_TOKEN", "")
    if not token:
        return fail(
            f"{SECRET} is not set on this repository, so releases will publish "
            f"and then print the cask version and digest to set by hand."
        )

    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "agent-tracker-tap-access-check",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            repo = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return fail(
                f"{SECRET} was rejected (401). It has expired or been revoked. "
                f"Issue a new fine-grained token for {REPO} with Contents: "
                f"Read and write, and replace the secret."
            )
        if exc.code == 404:
            return fail(
                f"{SECRET} cannot see {REPO} (404). The usual cause is the "
                f"token being issued against a personal account rather than "
                f"the ThinkVelta organization, or {REPO} not being among its "
                f"selected repositories."
            )
        return fail(f"{SECRET} check failed: HTTP {exc.code} {exc.reason}.")
    except urllib.error.URLError as exc:
        return fail(f"Could not reach the GitHub API: {exc.reason}.")

    if not repo.get("permissions", {}).get("push"):
        return fail(
            f"{SECRET} can read {REPO} but not write to it. Give it "
            f"Contents: Read and write; read alone cannot push the cask bump."
        )

    print(f"{SECRET} can write to {REPO}. The cask bump will land.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
