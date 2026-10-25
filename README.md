# check-secrets

A GitHub Action that fails a workflow when a commit in a push or a pull request adds a file under a `secrets/` folder, or a line matching a known credential format: cloud access keys, hosted-service API tokens, and private-key blocks.
It names the commit, the file, and the line, and never prints the value.

## Use

Check out the full history, then run the action as the first step after the checkout, pinned by its commit SHA:

```yaml
steps:
  - uses: actions/checkout@<commit SHA>  # vX.Y.Z
    with:
      fetch-depth: 0

  - uses: tunecrew/check-secrets@<commit SHA>  # vX.Y.Z
```

The action needs no input, no secret, and no permission beyond `contents: read`.

## What it scans

- A push: every commit from the branch's previous tip to its new one.
  After a force-push it fetches the previous tip once, and fails when it cannot.
- A push that creates the branch: the pushed commit against its parent.
- A pull request: every commit from its base to its head.
- A root commit, which has no parent: no range, so only the tracked and unignored `secrets/` paths are checked, with a warning.

A shallow checkout, an unknown event, or any failed git command fails the step: a scan that could not run is never a pass.

## Run it locally

From inside a repository:

```shell
sh check-secrets.sh                                # what is staged for commit
sh check-secrets.sh --range origin/main..HEAD      # the commits a branch adds
```

`sh check-secrets.sh --help` lists every check.

## Source

This repository is published from a private repository, where the scripts are developed and tested; changes made here are overwritten by the next release.

## Licence

Copyright © 2026 Christopher Edmonds. All rights reserved; no licence is granted.
The repository is public so GitHub Actions can fetch it, not so others can reuse it.
