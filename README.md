# rofi-lyrics

Synced karaoke lyrics panel (rofi script mode) following the active player. Click a line to seek. Auto width + dominant-color highlight from cover art.

Bound to `super+i` in my bspwm setup.

## Files
- `lyrics.sh` — rofi mode: player pick, fetch-on-miss, karaoke highlight, seek, dynamic wrap/width
- `launch.sh` — launches rofi, forces focus, ticks F5 on next timestamp (hybrid ticker)
- `lyrics-fetch.py` — fetch chain (args: `artist title album duration cachedir key [filepath]`)
- `lyrics.rasi` — east-side translucent theme

## Fetch chain
1. sidecar `.lrc` next to the audio file (synced)
2. embedded `LYRICS` tag via `ffprobe` (synced if timestamped, else plain)
3. [lrclib](https://lrclib.net) (synced or plain, best-score pick)
4. Genius search + page scrape (plain, needs token)

Writes `$XDG_CACHE_HOME/lyrics/lrc/<key>.{tsv,plain,none}`.

## Deps
`rofi playerctl python3 ffmpeg/ffprobe imagemagick xdotool xprop` + optional `cmus metaflac`

## Install
```bash
mkdir -p ~/.config/rofi/lyrics ~/.cache/lyrics
cp launch.sh lyrics.sh lyrics-fetch.py lyrics.rasi ~/.config/rofi/lyrics/
chmod +x ~/.config/rofi/lyrics/{launch.sh,lyrics.sh,lyrics-fetch.py}
```

## sxhkd (super+i)
```
super + i
    pkill -x rofi || ~/.config/rofi/lyrics/launch.sh -show lyrics -modes "lyrics:$HOME/.config/rofi/lyrics/lyrics.sh" -theme "$HOME/.config/rofi/lyrics/lyrics.rasi"
```

## Genius token (optional, plain-lyrics fallback only)
```bash
echo -n "YOUR_GENIUS_TOKEN" > ~/.config/rofi/lyrics/.genius.token
chmod 600 ~/.config/rofi/lyrics/.genius.token
```
Never commit this file (it's gitignored).

Tuning: `LYRICS_OFFSET=0.4 super+i` (default `0.7`) compensates playerctl+repaint lag.
