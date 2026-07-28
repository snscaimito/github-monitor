# GitHub Monitor

A lightweight macOS menu-bar prototype for monitoring GitHub Actions in selected repositories.

It uses the existing authenticated [`gh`](https://cli.github.com/) CLI to read workflow runs. No token is stored by the app and it does not access repository contents.

## Run

```sh
gh auth login
swift run
```

Choose **Find Recent Action Repositories** in the menu-bar popover. It discovers repositories through `gh`, keeps only those with an Actions run updated in the last 30 days, and lets you choose which ones to monitor. The selected repositories refresh every 30 seconds; clicking a run opens it in GitHub.
