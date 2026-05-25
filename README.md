# BrewerBoard Roku Channel

A native Roku SceneGraph channel that mirrors the web `/display/[code]`
taplist. Talks to `https://brewerboard.com/api/display/[code]` for data
and persists the paired 6-digit code in Roku's Registry so the TV
reconnects automatically after reboot.

## Architecture

```
TV remote → CodeEntryScene (6-digit keypad)
                ↓ submittedCode
            MainScene (registry persist)
                ↓ screenCode
            DisplayScene
                ├─ refreshTimer (30s)
                └─ DisplayLoaderTask → GET /api/display/[code]
                                ↓ response
                         renderPayload() → beer rows
```

Three scenes, one task, one polling timer. All state lives in Roku's
Registry under section `brewerboard`, key `screen_code`. To unpair a TV,
the operator presses **BACK** on the remote inside the display — that
triggers `requestSignOut`, which clears the Registry and re-mounts the
code-entry screen.

## Prerequisites

- A Roku TV or stick with **developer mode** enabled:
  - From the home screen, press **Home × 3, Up × 2, Right, Left, Right, Left, Right**
  - Pick a dev password and note the device's LAN IP
- The TV and your Mac on the same network
- `zip` and `curl` on your Mac (both ship with macOS)

## Sideload the channel

The fastest way is the bundled script:

```bash
./scripts/sideload.sh <tv-ip>
```

It will prompt for your dev username (`rokudev`) and the password you set
in dev-mode setup, then bundle the channel and POST it to the TV's
Developer Application Installer at `http://<tv-ip>/`.

If the install succeeds, the channel launches automatically and you'll
see the 6-digit code entry screen on the TV.

## Iterate locally

1. Run the Next.js app:

   ```bash
   cd ~/Projects/tapdisplay && npm run dev
   ```

2. Find your Mac's LAN IP:

   ```bash
   ipconfig getifaddr en0
   ```

3. In `components/DisplayScene.brs`, swap `m.API_BASE` inside `init()`:

   ```brightscript
   m.API_BASE = "http://<your-mac-ip>:3000"
   ```

   Important: Roku won't trust your local dev cert, so use plain `http`
   (no `s`) for local. The production target stays on HTTPS.

4. Re-run `./scripts/sideload.sh <tv-ip>` to push the change.

## Inspecting logs / errors

Roku exposes a per-channel BrightScript debug console over telnet:

```bash
telnet <tv-ip> 8085
```

Every `print` statement in the channel shows up there. Useful for
verifying the HTTP fetch and seeing parse errors.

## File map

| File | Purpose |
|---|---|
| `manifest` | Channel metadata: title, icons, splash, version, resolution |
| `source/main.brs` | Channel entry point — creates the SceneGraph screen and message loop |
| `components/MainScene.xml/.brs` | Root scene — routes between code entry and display |
| `components/CodeEntryScene.xml/.brs` | 6-digit code entry with custom D-pad keypad |
| `components/DisplayScene.xml/.brs` | Beer-list rendering + polling timer |
| `components/DisplayLoaderTask.xml/.brs` | HTTPS GET task that fetches `/api/display/[code]` |
| `images/icon_*.png` | Channel icons (HD 290×218, FHD 540×405) |
| `images/splash_*.png` | Splash screens (HD 1280×720, FHD 1920×1080) |
| `scripts/sideload.sh` | Zips + uploads to the TV's dev installer |

## Channel store assets

For Roku Channel Store submission you'll need (in addition to the
sideload assets):

- Channel icon — 540×405 (focused) and 540×405 (unfocused, slightly dimmer)
- Channel poster art — 290×218 + 540×405 + 1920×1080
- Screenshots — at least 4, 1920×1080
- Description text, privacy policy URL, support email

These can come later. Sideloading works fine without them.

## Known v1 gaps (intentional)

- **Slideshows** — the payload contains `screen.screen_slideshow_images` but they aren't rendered yet.
- **Custom Google Fonts** — Roku doesn't load remote fonts. We use system fonts; brand fonts require shipping `.ttf` files in `pkg:/fonts/`.
- **Beer sizes** (`beer_sizes` array) — not displayed in row v1; the schema is there in the payload when we want it.
- **Header texts / dividers** — payload includes them, no UI yet.
- **Animations** — no transitions between scenes; instant swap.
- **Category grouping** — beers render in `_screen_sort` order without category headings.

Each gap is a separate PR-sized chunk; the v1 priority is a working
end-to-end pipeline.
