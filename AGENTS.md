# AGENTS.md

A guide to this repository for people and coding agents who change it. For what the app is and how to build on it, read [`README.md`](README.md) first.

## Project overview

`starter` is a native Nostr app that doubles as a template: a read-only reader for NIP-23 long-form articles (kind 30023). It asks a few relays for articles, verifies and keeps them in a local LMDB database, lists them, and opens one for reading. It holds no key and publishes nothing.

The stack is Zig 0.16.0 (pinned in `.zigversion`), the [Native SDK](https://github.com/vercel-labs/native) for the window (pinned in `build.zig.zon` to a fork, with the same url and hash Plaza uses), and the [`nostr`](https://github.com/zig-nostr/nostr) library for relays, event verification and the store.

## Commands

```sh
native dev                      # build Debug and run, with markup hot reload
native test                     # the test suite (same as `zig build test`)
native check                    # validate app.native and app.zon against the model
native build                    # ReleaseFast binary in zig-out/bin/
zig fmt --check src build.zig build.zig.zon app.zon
```

CI runs `zig build model-contract`, `native check`, `native test`, `native build` and the format check on macOS, and `zig build`, `zig build test` and the format check on Linux. Run `zig build model-contract` before `native check`, or the typed half of the check is skipped. `native check` has to print no warnings.

The `native` CLI version (0.10.1) and the framework pinned in `build.zig.zon` move together. Change both in one commit, or the automation harness stops reading snapshots without any build failing.

To run the window with its test hooks: `native build -Dautomation=true`, then drive it with `native automate` (`wait`, `snapshot`, `assert`, `widget-click`, `screenshot main-canvas`). Run it with `HOME` pointed at a scratch directory, because the database goes under `$HOME/.starter`.

## Layout

```
src/
  main.zig       # wiring: opens the store, builds the fetcher, starts the window
  model.zig      # Model, Msg, update, boot: all app state and every change to it
  app.native     # the view, as markup over the model
  articles.zig   # what a NIP-23 event means: title, date, summary, rows, pages
  store.zig      # the LMDB store and store.accept, the door every relay event uses
  relays.zig     # one worker thread per relay, with time limits
  tests.zig      # update and view tests, no window and no network
  testkit.zig    # test fixture: a temp database and signing keys
  testrelay.zig  # test fixture: a loopback relay
build.zig        # app build plus the nostr dependency
build.zig.zon    # dependencies, pinned by hash
app.zon          # app identity, window, permissions
```

## How data moves

Worker threads (`relays.zig`) dial relays, send one subscription, and pass every event through `store.accept`, which checks the filter, the text encoding and the signature before the event is stored. They never touch the `Model`. They bump `Fetcher.version`, and a repeating timer in `model.zig` notices and re-reads the store into the list. Only `update` changes the `Model`, and only on the window's thread.

## Conventions

- Zig 0.16 idioms (`std.Io`, unmanaged `ArrayList`, `main(std.process.Init)`). `native skills get zig` lists the old-to-new changes by compile error.
- Everything a view reads is a public field or function inside `Model` (or a method on an item type). A function next to the struct, not inside it, is invisible to the markup.
- State the markup does not read directly goes in `Model.view_unbound`, so `native check` stays quiet.
- Validate anything that came off the network at the boundary (`store.accept`), once, so code after it can assume well-formed input.
- Every network wait has a time limit. A new fetch gets one.
- Never hand-roll cryptography. Signing and verification come from the `nostr` library.
- A change ships with a test that fails without it. The tests for parsing are pure functions over hand-built events; the tests for the store use a temp database; the tests for the view build the real markup and press real widgets.
- Keep files small and single-purpose. A new subsystem gets its own file and its own tests.
- Match the existing comment style: say why, not what.

## Commit and PR conventions

[Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`, `chore:`, with a body that explains the reason. One concern per pull request, with its tests and docs. `main` is changed only through reviewed pull requests from short-lived branches.

## Security

This app holds no secret key and must not grow one casually. If you add signing, keep the key in a separate process and talk to it over NIP-46. Text in articles is written by strangers: links are opened only when `model.isSafeExternalUrl` accepts them, remote images are not loaded, and invalid UTF-8 is refused before storage.
