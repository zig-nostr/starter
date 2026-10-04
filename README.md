# Starter

A template for a native [Nostr](https://nostr.com) app, and a working example of one.

The example is a reader for long-form articles ([NIP-23](https://github.com/nostr-protocol/nips/blob/master/23.md), kind 30023). It asks a few relays for recent articles, checks every signature, keeps the articles in a local database, lists them, and opens one for reading. It has no keys, no signing and no publishing, so there is nothing in it you have to trust or remove before you start.

It is built on the zig-nostr stack: Zig 0.16 for the code, the [Native SDK](https://github.com/vercel-labs/native) for the window, and the [`nostr`](https://github.com/zig-nostr/nostr) library for everything protocol (relays, events, verification, the local store). The point of the repository is that you can read every file in it. Copy it, rename it, and change what it asks for.

## What you get

- A native window drawn by the toolkit itself. No browser, no web view.
- A list that opens from disk. Articles are saved, so the second launch shows them before any relay has answered.
- One worker thread per relay, each with a time limit on connecting and on reading. A relay that never answers cannot hold anything up.
- Every event verified before it is stored, and only the newest version of each article kept.
- A reading view that renders the article's markdown, one page at a time.
- Tests that need neither a window nor a network, including a loopback relay for the fetch code.
- CI for macOS and Linux.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.16.0. The exact version is in `.zigversion`.
- The Native SDK command line: `npm install -g @native-sdk/cli@0.10.1`. Use that version, because it has to match the framework pinned in `build.zig.zon`.
- On macOS, the Xcode command line tools.
- On Linux, `libgtk-4-dev`.

The window has been run on macOS. On Linux, CI builds the app and runs the tests but does not open a window.

## Run it

```sh
git clone https://github.com/zig-nostr/starter
cd starter
native dev
```

`native dev` builds a Debug binary and runs it. Edit `src/app.native` while it is open and the window follows, without losing its state.

The relays it asks are in `src/relays.zig`. To ask others, set `STARTER_RELAYS` to a comma-separated list:

```sh
STARTER_RELAYS="wss://relay.damus.io,wss://nos.lol" native dev
```

Saved articles live in `~/.starter/articles.mdb`. Delete the file to start empty.

Other commands:

```sh
native test        # run the tests (same as `zig build test`)
native check       # validate app.native and app.zon against the model
native build       # an optimized binary in zig-out/bin/
```

Run `zig build model-contract` once before `native check`, or the check skips the half that looks at the model.

## How it fits together

```
relay --\
relay ----> one thread each --> store.accept --> database file
relay --/    (relays.zig)       (store.zig)            |
                  |                                    | read
                  | bumps Fetcher.version              v
                  \--------------------> a timer notices, model.reload
                                                       |
                                       Model --> app.native --> window
```

Three rules hold it together, and they are the part worth copying.

1. The model never touches the network. It reads the database and holds what the window shows.
2. Worker threads never touch the model. They write into the database and bump a counter. A repeating timer in the window's thread sees the counter move and reloads.
3. Every event from a relay goes through one function, `store.accept`, before it is stored.

### The files

**`src/main.zig`** is the wiring and nothing else. It opens the database, builds the relay fetcher, describes the window, and hands the app to the Native SDK. The relay list is picked here, from `STARTER_RELAYS` or the defaults.

**`src/model.zig`** is the app. `Model` is all the state, `Msg` is everything that can happen, and `update` is the one function that changes the model. The view reads public functions on `Model` (`visible`, `pageText`, `status`), so a screen's logic can be tested by calling `update` and looking at the result. `boot` runs once before the first frame: it reads the list from disk, asks the relays, and starts the timer.

**`src/app.native`** is the view, written as markup. It binds to the model (`{status}`), repeats over lists (`<for each="visible" ...>`), and sends messages (`on-press="open:{a.index}"`). It cannot change anything itself. There are two screens, the list and the reader, and `<if test="{isReading}">` chooses between them. The article body is one `<markdown>` element.

**`src/articles.zig`** is what a NIP-23 event means. It reads the title (the `title` tag, or the first line of the content), the date (`published_at` when it is sane, otherwise `created_at`), the summary, and builds the short npub shown under each title. It also cuts a long article into pages, because the markdown turns into widgets and one view can only hold so many. Nothing in this file touches a relay, the database or the window, so its tests build events by hand.

**`src/store.zig`** opens the database (the library's LMDB store) and has `accept`, the door every relay event goes through. `accept` refuses an event that is not the kind and topic asked for, whose text is not valid UTF-8, or whose signature or id is wrong. The rest is the library's: `ingest` keeps only the newest version of each pubkey and `d` tag, which is what makes an addressable event addressable. A relay that is behind and sends an old draft again gets `.stale` back and nothing changes.

**`src/relays.zig`** is the fetching. A `Fetcher` starts one thread per relay. A thread dials (with a time limit), sends one subscription, passes each event to `accept`, and stops at the relay's end-of-stored-events marker. `Fetcher.tally` counts the relays that actually answered, and the status line shows that count rather than the number of relays in the list.

**`src/tests.zig`**, **`src/testkit.zig`** and **`src/testrelay.zig`** are the tests and what they stand on: a throwaway database with signing keys, and a relay that listens on loopback. `tests.zig` builds the real markup into a widget tree and presses real widgets, then lays the screens out at the smallest, default and a larger window size and runs the toolkit's layout and accessibility audits on them.

**`build.zig`**, **`build.zig.zon`**, **`app.zon`** and **`.zigversion`** are the build. `build.zig` is the Native SDK's standard app build plus the `nostr` dependency. `build.zig.zon` pins both dependencies by hash, with the Native SDK taken from the zig-nostr fork that Plaza uses so the two build the same way. `app.zon` names the app and describes its window.

### What the list does with an article

The query is `{"kinds": [30023], "#t": ["nostr"], "limit": 50}`. Public relays carry a great deal of spam under kind 30023, so the topic tag narrows it; see "Ask for something else" below to remove it. The list shows each article's title, its summary if it has one, the shortened npub of its author and the date, newest first. The date is the one the author published on, not the last edit, so fixing a typo does not move an old article to the top.

## Make it yours

### Rename it

The name appears in a handful of places. `app.zon` has `.id`, `.name` and `.display_name`. `build.zig` passes `.name` to `addAppArtifacts`, and `build.zig.zon` has `.name`. `src/main.zig` has `app_name`, the window title and the bundle id. `src/store.zig` has `data_dir`, the folder under your home directory: change it, or two apps built from this template will share a database.

For `build.zig.zon`, delete the `.fingerprint` line and run `zig build`. Zig prints a fresh one to paste back.

### Ask for something else

What the app asks for is `wanted` in `src/articles.zig`. It is an ordinary `nostr.filter.Filter`.

- To see every article a relay will give you, delete the `.tags` line. Expect spam.
- To read one author's articles, add `.authors = &[_][32]u8{ ... }`.
- To read a different kind, change `kind` and rework `Row.from` and `worthListing`, which decide how an event becomes a row.

The same filter is applied again to every event a relay sends back, in `store.accept`, so changing `wanted` changes both what is asked and what is kept.

A kind in the 30000 range is addressable, and the store keeps the newest version of each. A kind in the regular range is not, and the store keeps every event. That is usually what you want for notes, and not for articles.

### Ask other relays

Edit `default_urls` in `src/relays.zig`, or set `STARTER_RELAYS`. Up to eight are used.

### Add a screen

A screen is a field in the model, a message to reach it, and a branch in the markup. For a screen that lists the relays:

1. In `model.zig`, add `show_relays` and `hide_relays` to `Msg`, a `relays_open: bool = false` field to `Model` (and its name to `view_unbound`, or bind it), and handle both in `update`.
2. In `app.native`, the list is the `<else>` branch of `<if test="{isReading}">`. Inside that `<else>`, add `<if test="{relays_open}">` with your screen in it, and move the list into the `<else>` of the new `<if>`. Give the list a button with `on-press="show_relays"` and your screen one with `on-press="hide_relays"`. If you bind the field directly, take it out of `view_unbound`.
3. In `tests.zig`, build the tree, press the button with the `press` helper, and check what is on screen.

Run `native check` after each step. It names the exact line when a binding or a message does not exist.

### Add signing, later

This app does not sign anything, and that is deliberate. If you add posting, keep the key out of this process. [Notary](https://github.com/zig-nostr/notary) is a native NIP-46 signer that holds the key and asks before it signs, and the `nostr` library has NIP-46 on the client side (`nostr.nip46`). The reader then sends a request to the signer and gets a signed event back. What you gain is that a bug in a reader can never leak a key it never had.

### Package it

```sh
native build
native package
```

`native package` wraps the binary it finds in `zig-out/bin/` into `zig-out/package/starter.app`. Add `--signing adhoc` for an ad-hoc signature. Notarization and distribution are not set up here; `native --help` lists what the command can do.

## Things to know

- **Spam.** The default topic filter exists because of it. A relay that ignores the filter is handled: the same test is applied to what comes back.
- **It asks once.** The reader asks each relay at launch and when you press Refresh, then closes the subscription. It does not hold one open, so a new article appears on the next Refresh. Keeping a subscription open is a change to `fetchOne` in `relays.zig`: do not stop at EOSE, and keep reading.
- **Pages.** A long article is shown a page at a time, cut at paragraph boundaries and never inside a code block, with controls in the top corner. A single code block longer than a page is cut and carries on as plain text on the next one.
- **Images and links.** Remote images are not loaded: the alt text is shown instead. Links open in the system browser only when they are plain `http` or `https`; anything else is dropped.
- **Text the font lacks.** The toolkit's bundled font covers Latin and Cyrillic. Other scripts and emoji can draw as boxes in the toolkit's own renderer, which is what `native automate screenshot` uses. [Plaza](https://github.com/zig-nostr/plaza) registers extra font faces for this (`registered_fonts` in its `src/main.zig`).
- **Dates** are shown in UTC.
- **Nothing is encrypted at rest.** The database holds public events, as relays do.

## License

MIT. See [LICENSE](LICENSE).
