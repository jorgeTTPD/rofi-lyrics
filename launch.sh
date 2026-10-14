#!/usr/bin/env bash
# Lanza rofi de letras, le asegura el foco y late el karaoke (F5 = refrescar).
# Ancho dinámico: mide la línea más larga de la canción actual y ajusta
# window {width} vía -theme-str + LYRICS_WRAP para que rofi no se coma versos.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lyrics"
LRC="$CACHE/lrc"
SEP=$'\x1f'
# Mismo adelanto que lyrics.sh: despertar antes del timestamp para que el
# resaltado caiga sobre el vocal. Afinable: LYRICS_OFFSET=0.4 super+i
OFFSET=${LYRICS_OFFSET:-0.7}
mkdir -p "$CACHE"
# Fuerza que el primer pintado emita el theme (lyrics.sh lo omite cuando
# no cambió, pero un rofi recién abierto parte de los valores por defecto).
rm -f "$CACHE/last.theme"

PPC_NUM=990     # 9.9px/char medido en pantalla con JetBrainsMono Nerd 12 (monospace)
PPC_DEN=100
ROW_CHROME=54     # window padding 32 + borde 2 + element padding 20
HEADER_CHROME=150 # window 34 + headerbox padding 24 + spacing 12 + cover 80
MIN_PX=340
MAX_PX=880
MIN_CHARS=28
MAX_CHARS=82
WRAP_MARGIN=1

_pick_player_fast() {
    local status player
    status=$(timeout 2 playerctl -p cmus status 2>/dev/null)
    if [ "$status" = "Playing" ]; then
        printf 'cmus'
        return 0
    fi
    while IFS= read -r player; do
        [ -z "$player" ] && continue
        status=$(timeout 2 playerctl -p "$player" status 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ "$status" = "playing" ]; then
            printf '%s' "$player"
            return 0
        fi
    done <<< "$(timeout 3 playerctl -l 2>/dev/null)"
    timeout 2 playerctl -l 2>/dev/null | head -n 1
}

calc_width() {
    local artist="$1" title="$2" album="$3" key max lc hc lpx hpx px wrap
    [ -z "$title" ] && { printf '%s %s' "$MIN_PX" "$MIN_CHARS"; return 0; }
    key=$(printf '%s|%s|%s' "$artist" "$title" "$album" | md5sum | cut -c1-16)
    max=0
    if [ -f "$LRC/$key.tsv" ]; then
        max=$(awk -F'\t' '{l=length($2); if(l>m)m=l} END{print m+0}' "$LRC/$key.tsv")
    elif [ -f "$LRC/$key.plain" ]; then
        max=$(awk '{l=length($0); if(l>m)m=l} END{print m+0}' "$LRC/$key.plain")
    fi
    # Ancho en chars por zona (letra y header tienen distinto chrome).
    lc=$((max + WRAP_MARGIN))
    [ "$lc" -lt "$MIN_CHARS" ] 2>/dev/null && lc="$MIN_CHARS"
    [ "$lc" -gt "$MAX_CHARS" ] 2>/dev/null && lc="$MAX_CHARS"
    hc=$(( ${#title} + ${#artist} + 3 + WRAP_MARGIN ))
    [ "$hc" -lt "$MIN_CHARS" ] 2>/dev/null && hc="$MIN_CHARS"
    [ "$hc" -gt "$MAX_CHARS" ] 2>/dev/null && hc="$MAX_CHARS"
    wrap="$lc"
    [ "$hc" -gt "$wrap" ] 2>/dev/null && wrap="$hc"
    lpx=$(( (lc * PPC_NUM) / PPC_DEN + ROW_CHROME ))
    hpx=$(( (hc * PPC_NUM) / PPC_DEN + HEADER_CHROME ))
    if [ "$hpx" -gt "$lpx" ] 2>/dev/null; then px="$hpx"; else px="$lpx"; fi
    [ "$px" -lt "$MIN_PX" ] && px=$MIN_PX
    [ "$px" -gt "$MAX_PX" ] && px=$MAX_PX
    printf '%s %s' "$px" "$wrap"
}

WIDTH="$MIN_PX"
WRAP="$MIN_CHARS"
pl=$(_pick_player_fast)
if [ -n "$pl" ]; then
    # Campos por separado (más robusto que --format con separador raro)
    _artist=$(timeout 2 playerctl -p "$pl" metadata artist 2>/dev/null)
    _title=$(timeout 2 playerctl -p "$pl" metadata title 2>/dev/null)
    _album=$(timeout 2 playerctl -p "$pl" metadata album 2>/dev/null)
    if [ -n "$_title" ]; then
        read -r WIDTH WRAP < <(calc_width "$_artist" "$_title" "$_album")
    fi
fi
export LYRICS_WRAP="$WRAP"

rofi \
    -kb-custom-1 "F5" \
    "$@" \
    -theme-str "window {width: ${WIDTH}px;}" &
pid=$!
w=""
for _ in $(seq 1 50); do
    for c in $(xdotool search --class rofi 2>/dev/null); do
        p=$(xprop -id "$c" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        if [ "$p" = "$pid" ]; then
            w="$c"
            break
        fi
    done
    [ -n "$w" ] && break
    sleep 0.1
done
[ -n "$w" ] && xdotool windowfocus --sync "$w" 2>/dev/null
# Ticker híbrido (opción B): duerme hasta el próximo timestamp del .tsv
# (margen 50ms), con tope 1s para absorber pausa/seek/cambio de tema.
# Sin tiempos (.plain/.none) → 2s; sin reproductor o en pausa → 1s.
_tick_sleep() {
    local pl status meta _artist _title _album key pos nxt delta
    pl=$(_pick_player_fast)
    [ -z "$pl" ] && { printf '1.0'; return 0; }
    status=$(timeout 2 playerctl -p "$pl" status 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [ "$status" != "playing" ] && { printf '1.0'; return 0; }
    meta=$(timeout 2 playerctl -p "$pl" metadata --format "{{artist}}${SEP}{{title}}${SEP}{{album}}" 2>/dev/null)
    IFS="$SEP" read -r _artist _title _album <<< "$meta"
    [ -z "$_title" ] && { printf '1.0'; return 0; }
    key=$(printf '%s|%s|%s' "$_artist" "$_title" "$_album" | md5sum | cut -c1-16)
    if [ -f "$LRC/$key.tsv" ]; then
        pos=$(timeout 2 playerctl -p "$pl" position 2>/dev/null)
        case "$pos" in ''|*[!0-9.]*) pos=0 ;; esac
        case "$OFFSET" in ''|*[!0-9.]*) off=0.7 ;; *) off="$OFFSET" ;; esac
        nxt=$(awk -v p="$pos" -v off="$off" -F'\t' '$1 + 0 > p + off {print $1; exit}' "$LRC/$key.tsv" 2>/dev/null)
        [ -z "$nxt" ] && { printf '1.0'; return 0; }
        delta=$(awk -v n="$nxt" -v p="$pos" -v off="$off" 'BEGIN { d = n - p - off - 0.05; if (d < 0.12) d = 0.12; if (d > 1.0) d = 1.0; printf "%.2f", d }' 2>/dev/null)
        case "$delta" in ''|*[!0-9.]*) delta="0.5" ;; esac
        printf '%s' "$delta"
    elif [ -f "$LRC/$key.plain" ] || [ -f "$LRC/$key.none" ]; then
        printf '2.0'
    else
        printf '1.0'
    fi
}

while kill -0 "$pid" 2>/dev/null; do
    _s=$(_tick_sleep)
    case "$_s" in ''|*[!0-9.]*) _s="0.5" ;; esac
    sleep "$_s"
    [ -n "$w" ] && xdotool key --window "$w" F5 2>/dev/null
done &
tick=$!
wait "$pid"
kill "$tick" 2>/dev/null
