# Security Policy

This is a personal-use automation tool, not a maintained product with an SLA — but if you find
a real vulnerability (something that could leak credentials, execute unintended commands, or
provision infrastructure you didn't ask for), please report it responsibly.

## Reporting a vulnerability

Please use GitHub's [private vulnerability reporting](../../security/advisories/new) — the
**"Report a vulnerability"** button under this repo's **Security** tab — instead of a public
issue. It opens a private draft advisory so nothing gets disclosed before a fix ships, and keeps
the whole thread with maintainer replies in one place.

There's no bug bounty and no guaranteed response time, but reports will be looked at and a fix
or mitigation will be pushed as soon as practical. Credit is welcome if you'd like it.

## Scope

In scope: the PowerShell scripts in this repo (`OciProvisioner.ps1`, `Register-ScheduledTask.ps1`)
and the CI/tooling around them.

Out of scope: the OCI CLI itself, Oracle Cloud Infrastructure, and ntfy.sh — report issues in
those upstream.

## A note on secrets

All credentials, OCIDs, and topic names belong in the git-ignored `config.json` — see
`config.json.example`. If you believe real secrets ever landed in this repo's tracked history,
please report it privately rather than filing a public issue.
