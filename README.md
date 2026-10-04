# Starter

The plumbing is solved; design your own interface.

Every native [Nostr](https://nostr.com) app has to do the same unglamorous things: dial relays without hanging, verify every event, keep what it received, read it back before it writes anything, and understand the event kinds it cares about. This repository does those, in small files that draw nothing and have one job each. On top of them sits a plain example interface, a list and a reading view for long-form articles ([NIP-23](https://github.com/nostr-protocol/nips/blob/master/23.md), kind 30023), so you can see the plumbing working. You replace that interface. It is not a design system, a theme or a set of components, and nothing in it is meant to be reused as UI: a native app should look like itself.

It is built on the zig-nostr stack: Zig 0.16 for the code, the [Native SDK](https://github.com/vercel-labs/native) for the window, and the [`nostr`](https://github.com/zig-nostr/nostr) library for everything protocol (relays, events, verification, the local store). The example has no keys, no signing and no publishing, so there is nothing in it you have to trust or remove before you start.

## What you get

The plumbing, which you keep:

- One worker thread per relay, each with a time limit on connecting and on reading. A relay that never answers cannot hold anything up.
- Every event checked against the question you asked, then verified (signature and id), before it is stored.
- A local database, so the second launch shows what the first one saved before any relay has answered.
- Replaceable events handled: only the newest version of each pubkey and `d` tag is kept, and an old copy sent again by a relay that is behind changes nothing.
- NIP-23 parsing: title, summary and the date an author published on.
- Tests that need neither a window nor a network, including a loopback relay for the fetch code.
- CI for macOS and Linux.

The example interface, which you replace:

- A list of saved articles and a reading view, with a status line. That is all.

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

The relays it asks are in `src/plumbing/relays.zig`. To ask others, set `STARTER_RELAYS` to a comma-separated list:

```sh
STARTER_RELAYS="wss://relay.damus.io,wss://nos.lol" native dev
```

Saved events live in `~/.starter/events.mdb`. Delete the file to start empty.

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
                  | bumps a counter                    v
                  |                       Data.articles, Data.article
                  |                                (data.zig, nip23.zig)
                  v                                    |
              Data.changes ---------------> your interface
                                             (model.zig, app.native)
```

Three rules hold it together, and they are the part worth keeping.

1. The interface never touches the network. It reads the database, through `Data`, and holds what the window shows.
2. Worker threads never touch the interface. They write into the database and bump a counter. A repeating timer in the window's thread sees the counter move and reads again.
3. Every event from a relay goes through one function, `store.accept`, before it is stored.

Two tests keep the line between the halves where it is: one fails if the interface imports anything from `src/plumbing/` other than `data.zig`, and one fails if a plumbing file imports the toolkit.

## The plumbing

Everything under `src/plumbing/` is non-visual. None of it knows there is a window.

**`relays.zig`** dials relays and reads from them, on background threads. A `Fetcher` starts one thread per relay. A thread dials (with a time limit), sends one subscription for the filter it was given, passes each event to `store.accept`, and stops at the relay's end-of-stored-events marker. It only reads: nothing in it publishes. `Fetcher.tally` counts the relays that actually answered, so a status line can say how many did rather than how many are in the list. It knows nothing about articles: the question it asks is a filter handed to `Fetcher.init`.

**`store.zig`** is the local store. It opens the library's LMDB database under your home directory, and it has `accept`, the door every relay event goes through. `accept` refuses an event that does not match the filter it is given, whose text is not valid UTF-8, or whose signature or id is wrong. The rest is the library's: `ingest` keeps only the newest version of each pubkey and `d` tag, which is what makes an addressable event addressable. A relay that is behind and sends an old draft again gets `.stale` back and nothing changes.

**`nip23.zig`** is what a NIP-23 event means, and the one question this app asks. It reads the title (the `title` tag, or the first line of the content), the summary, and the date (`published_at` when it is sane, otherwise `created_at`, so fixing a typo does not move an old article to the top). It also holds `wanted`, the filter. Nothing in this file touches a relay, the database or the window, so its tests build events by hand.

**`data.zig`** is the seam, described next.

**`testkit.zig`** and **`testrelay.zig`** are what the plumbing's tests stand on: a throwaway database with signing keys, and a relay that listens on loopback.

## The seam

`src/plumbing/data.zig` is the one small interface between the plumbing and whatever you draw. It has five calls, and your interface imports nothing else from `plumbing/`.

- `articles(gpa, limit)`: the saved articles, newest published first.
- `article(gpa, id)`: one saved article, whole, or null.
- `refresh()`: asks the relays again, and returns at once.
- `changes()`: a number that moves whenever a worker stored something or changed state.
- `progress()`: how many relays there are, how many are being asked, how many answered and how many failed.

None of them waits on the network. The pattern is: read with `articles`, remember what `changes` said, and on a timer read again when it says something different. If your app needs another kind of event, add a call here and keep your screens on this side of the line.

## The interface you replace

These files are the example's own. They are here to show how an interface reads the seam, and they are meant to be deleted or rewritten.

**`src/app.native`** is the view, written as markup. It binds to the model (`{status}`), repeats over lists (`<for each="visible" ...>`), and sends messages (`on-press="open:{a.index}"`). It cannot change anything itself. There are two screens, the list and the reader, and `<if test="{isReading}">` chooses between them.

**`src/model.zig`** is the state of those two screens. `Model` is all the state, `Msg` is everything that can happen, and `update` is the one function that changes the model. The view reads public functions on `Model`, so a screen's logic can be tested by calling `update` and looking at the result. `boot` runs once before the first frame: it reads the list from disk, asks the relays, and starts the timer.

**`src/display.zig`** is how this interface holds what it shows: a row of the list copied out of an article into fixed-size text, and a long article cut into pages, because the toolkit turns markdown into widgets and one view can only hold so many. A different interface holds different things.

**`src/tests.zig`** builds the real markup into a widget tree and presses real widgets, then lays the screens out at the smallest, default and a larger window size and runs the toolkit's layout and accessibility audits on them.

**`src/main.zig`** is the wiring and nothing else. It opens the store, builds the fetcher and `Data`, describes the window, and hands the app to the Native SDK. The relay list is picked here, from `STARTER_RELAYS` or the defaults.

**`build.zig`**, **`build.zig.zon`**, **`app.zon`** and **`.zigversion`** are the build. `build.zig` is the Native SDK's standard app build plus the `nostr` dependency. `build.zig.zon` pins both dependencies by hash, with the Native SDK taken from the zig-nostr fork that Plaza uses so the two build the same way. `app.zon` names the app and describes its window.

## Make it yours

### Ask for something else

What the app asks for is `wanted` in `src/plumbing/nip23.zig`. It is an ordinary `nostr.filter.Filter`.

- To see every article a relay will give you, delete the `.tags` line. Expect spam: public relays carry a great deal of it under kind 30023, which is why the default narrows to one topic.
- To read one author's articles, add `.authors = &[_][32]u8{ ... }`.
- To read a different kind, add a file beside `nip23.zig` that says what that kind means (its `kind`, its `wanted`, and a struct that reads the fields you need), then add a call to `data.zig` that returns it. Change the filter handed to `Fetcher.init` in `main.zig`.

The same filter is applied again to every event a relay sends back, in `store.accept`, so changing `wanted` changes both what is asked and what is kept.

A kind in the 30000 range is addressable, and the store keeps the newest version of each. A kind in the regular range is not, and the store keeps every event. That is usually what you want for notes, and not for articles.

### Do something else with it

Everything your app does with the data happens after `Data` hands it over. An `Article` is a title, a summary, a published date, an author and markdown content, and you decide what becomes of them: a reading list you sort yourself, a feed that shows only an author's work, a search, a count, an export. Call `articles` with a bigger or smaller limit, filter the result in your own code, open one with `article`. The plumbing neither knows nor cares what you build.

### Design your own screens

Start from a blank `app.native`. The two example screens are a list and a reader because those are the smallest thing that shows the data; yours will be different.

1. Decide what each screen needs from `Data`, and what it needs to remember (which article is open, what is typed in a box).
2. Put that in `Model`, add a `Msg` for each thing that can happen, and handle them in `update`. Keep the calls to `Data` the way `model.zig` makes them.
3. Write the markup. Run `native dev` and edit while it is open.
4. Test it the way `tests.zig` does: build the tree, press the widget, check what is on screen.

Run `native check` after each step. It names the exact line when a binding or a message does not exist. If you drop `display.zig` and `tests.zig` with the example screens, nothing in `src/plumbing/` changes.

### Ask other relays

Edit `default_urls` in `src/plumbing/relays.zig`, or set `STARTER_RELAYS`. Up to eight are used.

### Rename it

The name appears in a handful of places. `app.zon` has `.id`, `.name` and `.display_name`. `build.zig` passes `.name` to `addAppArtifacts`, and `build.zig.zon` has `.name`. `src/main.zig` has `app_name`, the window title and the bundle id. `src/plumbing/store.zig` has `data_dir`, the folder under your home directory: change it, or two apps built from this repository will share a database.

For `build.zig.zon`, delete the `.fingerprint` line and run `zig build`. Zig prints a fresh one to paste back.

### Add signing, later

This app does not sign anything, and that is deliberate. If you add posting, keep the key out of this process. [Notary](https://github.com/zig-nostr/notary) is a native NIP-46 signer that holds the key and asks before it signs, and the `nostr` library has NIP-46 on the client side (`nostr.nip46`). Your app sends a request to the signer and gets a signed event back, and any other NIP-46 signer works the same way. What you gain is that a bug in your interface can never leak a key it never had.

### Package it

```sh
native build
native package
```

`native package` wraps the binary it finds in `zig-out/bin/` into `zig-out/package/starter.app`. Add `--signing adhoc` for an ad-hoc signature. Notarization and distribution are not set up here; `native --help` lists what the command can do.

## Things to know

- **Spam.** The default topic filter exists because of it. A relay that ignores the filter is handled: the same test is applied to what comes back.
- **It asks once.** The fetcher asks each relay at launch and when `refresh` is called, then closes the subscription. It does not hold one open, so a new article appears on the next refresh. Keeping a subscription open is a change to `fetchOne` in `src/plumbing/relays.zig`: do not stop at EOSE, and keep reading.
- **Pages.** In the example, a long article is shown a page at a time, cut at paragraph boundaries and never inside a code block, with controls in the top corner. A single code block longer than a page is cut and carries on as plain text on the next one.
- **Images and links.** In the example, remote images are not loaded: the alt text is shown instead. Links open in the system browser only when they are plain `http` or `https`; anything else is dropped.
- **Text the font lacks.** The toolkit's bundled font covers Latin and Cyrillic. Other scripts and emoji can draw as boxes in the toolkit's own renderer, which is what `native automate screenshot` uses. [Plaza](https://github.com/zig-nostr/plaza) registers extra font faces for this (`registered_fonts` in its `src/main.zig`).
- **Dates** are shown in UTC.
- **Nothing is encrypted at rest.** The database holds public events, as relays do.

## License

MIT. See [LICENSE](LICENSE).
