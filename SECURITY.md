# Security Policy

Agent Island approves tool calls for coding agents and runs a local server, so
security reports matter to us.

## Supported versions

Only the [latest release](https://github.com/soummyaanon/DEV-island-releases/releases/latest)
gets security fixes.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
**[Report a vulnerability](https://github.com/soummyaanon/DEV-island/security/advisories/new)**.

Include what you found, how to reproduce it, and the impact you expect. You'll
get an acknowledgement within a few days and updates as the fix progresses;
once it ships, you'll be credited in the release notes unless you'd rather not.

## Scope notes

- The daemon listens on `127.0.0.1:7433` only and rejects requests from
  browsers (any request with an `Origin` header).
- Hook scripts live in `~/.agent-island/bin` and are installed into
  `~/.claude/settings.json` and `~/.cursor/hooks.json`.
- Reports about another process on the same Mac reading local files are
  generally out of scope unless they cross a macOS security boundary.
