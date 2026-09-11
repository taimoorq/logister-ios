#!/usr/bin/env python3
"""Create an immutable tag on verified main, then explicitly dispatch publication.

An existing tag is a recovery checkpoint, not evidence of a published package.
This script never moves tags and fails closed on provider errors. Registry
identity verification remains the publishing workflow's responsibility.
"""
import argparse
import json
import os
import re
import subprocess


def command(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result


def prepare(tag, workflow, paths, candidate, repository, run=command):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Automatic publication requires a stable vX.Y.Z tag")
    if workflow not in ("release.yml", "publish.yml") or not paths:
        raise ValueError("Expected a publish workflow and explicit publishable paths")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Invalid repository identity")

    def current():
        run("git", "fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        head = run("git", "rev-parse", "HEAD").stdout.strip()
        main = run("git", "rev-parse", "refs/remotes/origin/main").stdout.strip()
        return head == candidate == main

    if not current():
        return "Skipping stale CI; the candidate is no longer current main."
    exists = run("git", "ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/{tag}", check=False)
    if exists.returncode not in (0, 2):
        raise RuntimeError("Tag lookup failed; publication state is unknown")
    if exists.returncode == 0:
        run("git", "fetch", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
        run("git", "merge-base", "--is-ancestor", f"{tag}^{{commit}}", "refs/remotes/origin/main")
        diff = run("git", "diff", "--quiet", tag, candidate, "--", *paths, check=False)
        if diff.returncode:
            raise RuntimeError("Publishable inputs changed since the tag (or comparison failed); bump the version before release")
        release = run("gh", "api", f"repos/{repository}/releases/tags/{tag}", check=False)
        if release.returncode == 0:
            metadata = json.loads(release.stdout)
            if metadata.get("tag_name") != tag:
                raise RuntimeError("GitHub release identity mismatch")
            if not metadata.get("draft", True):
                return f"{tag} already has a public release; use release.yml/publish.yml recovery if registry reconciliation fails."
        elif "(HTTP 404)" not in release.stderr:
            raise RuntimeError("GitHub release lookup failed; publication state is unknown")
    else:
        if not current():
            return "Skipping stale CI; main advanced before tagging."
        run("git", "config", "user.name", "github-actions[bot]")
        run("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
        run("git", "tag", "-a", tag, candidate, "-m", f"Release {tag}")
        run("git", "push", "origin", f"refs/tags/{tag}")
    # GITHUB_TOKEN tag pushes do not trigger push workflows. Dispatch from main
    # to preserve trusted-publisher identity, checking out this exact tag inside.
    run("gh", "workflow", "run", workflow, "--repo", repository, "--ref", "main", "-f", f"tag={tag}")
    return f"Publication dispatched for {tag}; registry and GitHub verification are still required."


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--paths", nargs="+", required=True)
    args = parser.parse_args()
    print(prepare(args.tag, args.workflow, args.paths, os.environ["CANDIDATE_SHA"], os.environ["GITHUB_REPOSITORY"]))
