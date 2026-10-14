#!/usr/bin/env python3
"""Fetch lyrics from several sources.
Args: artist title album duration cachedir key [filepath].

Chain (stops at first synced hit, keeps best plain as fallback):
  1. sidecar .lrc next to the audio file (synced)
  2. embedded LYRICS tag in the audio file (synced if timestamped, else plain)
  3. lrclib (synced or plain)
  4. Genius search + page scrape (plain, needs .genius.token beside this script)

Writes key.tsv (start<TAB>text), key.plain, or key.none. Prints which one.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from html.parser import HTMLParser

TAG_RE = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")
WORD_RE = re.compile(r"<[^>]*>")
SECTION_RE = re.compile(r"^\[.+\]$")
UA = {"User-Agent": "lyrics-rofi/1.0"}
TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".genius.token")


def http_json(url, headers=None, timeout=6):
    req = urllib.request.Request(url, headers=headers or UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def http_text(url, headers=None, timeout=10):
    req = urllib.request.Request(url, headers=headers or UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="replace")


def parse_lrc(text):
    lines = []
    for raw in text.splitlines():
        m = TAG_RE.match(raw.strip())
        if not m:
            continue
        start = int(m.group(1)) * 60 + float(m.group(2))
        body = WORD_RE.sub("", raw[m.end() :]).strip()
        if body:
            lines.append((start, body))
    lines.sort(key=lambda x: x[0])
    return lines


def clean_plain(lines):
    text = [ln.strip() for ln in lines]
    text = [ln for ln in text if ln]
    # Genius prepends header junk: start at first [Section] when present.
    for i, ln in enumerate(text):
        if SECTION_RE.match(ln):
            return text[i:]
    return text


def sidecar_lrc(filepath):
    if not filepath:
        return None
    base, _ = os.path.splitext(filepath)
    for cand in (base + ".lrc", base + ".LRC"):
        if os.path.isfile(cand):
            try:
                with open(cand, encoding="utf-8", errors="replace") as fh:
                    lines = parse_lrc(fh.read())
                if lines:
                    return lines
            except OSError:
                continue
    return None


def embedded_lyrics(filepath):
    if not filepath or not os.path.isfile(filepath):
        return None, None
    try:
        out = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format_tags",
                "-of",
                "json",
                filepath,
            ],
            capture_output=True,
            timeout=15,
            check=False,
        )
        tags = json.loads(out.stdout or "{}").get("format", {}).get("tags", {})
    except Exception:
        return None, None
    text = ""
    for k, v in tags.items():
        kl = k.lower()
        if kl in ("lyrics", "unsyncedlyrics", "uslt") or kl.startswith("lyrics"):
            if isinstance(v, str) and v.strip():
                text = v.strip()
                break
    if not text:
        return None, None
    lines = parse_lrc(text)
    if lines:
        return lines, None
    plain = clean_plain(text.splitlines())
    return None, (plain or None)


def _score_sync(lines, file_dur):
    """Puntaje para elegir entre varios synced: más líneas gana;
    desempata por cercanía de duración y menor hueco máximo."""
    n = len(lines)
    times = [t for t, _ in lines]
    gaps = [b - a for a, b in zip(times, times[1:])] if n > 1 else [0]
    try:
        fd = float(file_dur or 0)
    except (TypeError, ValueError):
        fd = 0
    dur_diff = abs(times[-1] - fd) if fd > 0 and n else 0
    return (n, -dur_diff, -max(gaps))


def lrclib(artist, title, album, dur):
    params = urllib.parse.urlencode(
        {"track_name": title, "artist_name": artist, "album_name": album}
    )
    urls = []
    if dur and dur != "0":
        urls.append(f"https://lrclib.net/api/get?{params}&duration={dur}")
    urls.append(f"https://lrclib.net/api/search?{params}")
    urls.append(
        "https://lrclib.net/api/search?q=" + urllib.parse.quote(f"{artist} {title}")
    )
    synced = None
    synced_score = None
    plain = None
    for url in urls:
        try:
            data = http_json(url)
        except Exception:
            continue
        results = data if isinstance(data, list) else [data]
        for res in results:
            if not isinstance(res, dict):
                continue
            if res.get("syncedLyrics"):
                lines = parse_lrc(res["syncedLyrics"])
                if lines:
                    score = _score_sync(lines, dur)
                    if synced_score is None or score > synced_score:
                        synced_score = score
                        synced = lines
            if plain is None and res.get("plainLyrics"):
                text = clean_plain(res["plainLyrics"].splitlines())
                if text:
                    plain = text
    return synced, plain


class _LyricHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.blocks = []
        self.inside = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "div" and a.get("data-lyrics-container") == "true":
            self.inside = True
            self.depth = 0
            self.blocks.append("")
        elif self.inside and tag == "div":
            self.depth += 1
        elif self.inside and tag == "br":
            self.blocks[-1] += "\n"

    def handle_endtag(self, tag):
        if self.inside and tag == "div":
            if self.depth == 0:
                self.inside = False
            else:
                self.depth -= 1

    def handle_data(self, data):
        if self.inside:
            self.blocks[-1] += data


def genius_plain(artist, title):
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError:
        return None
    if not token:
        return None
    headers = dict(UA)
    headers["Authorization"] = "Bearer " + token
    try:
        q = urllib.parse.quote(f"{artist} {title}")
        data = http_json(
            f"https://api.genius.com/search?q={q}", headers=headers, timeout=8
        )
        hits = data.get("response", {}).get("hits", [])
    except Exception:
        return None
    want = artist.lower()
    urls = []
    for hit in hits[:5]:
        res = (hit or {}).get("result", {})
        if res.get("type", "song") != "song" and hit.get("type") != "song":
            continue
        full = (res.get("full_title") or "").lower()
        anames = (res.get("artist_names") or "").lower()
        page = res.get("url") or ""
        if page and (want in full or want in anames):
            urls.insert(0, page)
        elif page:
            urls.append(page)
    page_headers = {
        "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36")
    }
    for page in urls[:3]:
        try:
            html = http_text(page, headers=page_headers, timeout=10)
        except Exception:
            continue
        parser = _LyricHTML()
        try:
            parser.feed(html)
        except Exception:
            continue
        lines = [ln.strip() for b in parser.blocks for ln in b.split("\n")]
        text = clean_plain(lines)
        if len(text) >= 4:
            return text
    return None


def main():
    args = sys.argv[1:8]
    artist, title, album, dur, cdir, key = args[0:6]
    filepath = args[6] if len(args) > 6 else ""
    synced = None
    plain = None
    src = ""

    synced = sidecar_lrc(filepath)
    if synced:
        src = "sidecar"
    if not synced and filepath:
        synced, emb_plain = embedded_lyrics(filepath)
        if synced:
            src = "embedded"
        elif emb_plain and plain is None:
            plain = emb_plain
    if not synced:
        lrc_synced, lrc_plain = lrclib(artist, title, album, dur)
        if lrc_synced:
            synced = lrc_synced
            src = "lrclib"
        elif lrc_plain and plain is None:
            plain = lrc_plain
    if not synced and plain is None:
        g_plain = genius_plain(artist, title)
        if g_plain:
            plain = g_plain
    if synced:
        with open(f"{cdir}/{key}.tsv", "w") as f:
            for start, body in synced:
                f.write(f"{start:.2f}\t{body}\n")
        print(f"synced:{src}")
    elif plain:
        with open(f"{cdir}/{key}.plain", "w") as f:
            f.write("\n".join(plain) + "\n")
        print("plain")
    else:
        open(f"{cdir}/{key}.none", "w").close()
        print("none")


main()
