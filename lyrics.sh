#!/usr/bin/env bash
# Letras sincronizadas estilo karaoke — modo script de rofi
set -u

ROFI_DIR="$HOME/.config/rofi/lyrics"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lyrics"
LRC="$CACHE/lrc"
LP_SOCK="${XDG_CACHE_HOME:-$HOME/.cache}/localplayer/cmus.sock"
LP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/localplayer"
LP_SONGS="$LP_CACHE/songs.tsv"
LP_THUMBS="$LP_CACHE/thumbs"
LP_NOCOVER="$LP_CACHE/nocover.jpg"
SEP=$'\x1f'
# Ancho máximo (en caracteres) de cada fila; rofi no hace wrap, así que
# partimos las líneas largas en varias filas para que nunca se recorten.
# 9.9px/char medido en pantalla (JetBrainsMono Nerd 12, monospace:
# captura del propio rofi: 276px/28 chars, 267px/27 chars, inicio texto +28px).
# Chrome medido del rasi: filas = window padding 32 + borde 2 + element
# padding 20 = 54; header = window 34 + headerbox padding 24 + spacing 12
# + cover 80 = 150. launch.sh usa la misma fórmula para window {width}.
# Dinámico: toma la cadena más larga (letra o título) y ajusta WRAP +
# window width en cada refresh, así cortas se achican y largas se alargan.
PPC_NUM=990
PPC_DEN=100
ROW_CHROME=54
HEADER_CHROME=150
WRAP_MARGIN=1
MIN_PX=340
MAX_PX=880
MIN_CHARS=28
MAX_CHARS=82
WRAP=${LYRICS_WRAP:-60}
WRAP_PX=$MIN_PX
# Adelanto global (segundos) para compensar el retraso de la cadena
# (playerctl + awk + repintado rofi). Afinable sin editar:
#   LYRICS_OFFSET=0.4 super+i   (menor = menos adelanto)
OFFSET=${LYRICS_OFFSET:-0.7}
# Color de selección según carátula (album art color scheming).
# DEFAULT_SELECTED = azul del rasi; COLORCACHE evita recalcular con magick.
DEFAULT_SELECTED="#89b4fa"
COLORCACHE="$CACHE/colors"
# fold_text() deja aquí sus filas (array global: evita forkear un subshell)
FOLDED=()

mkdir -p "$CACHE" "$LRC" "$COLORCACHE"

esc() { # escapa markup en bash (sin forkear sed)
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

mode_opt() { # clave valor — cabecera de modo: \0clave\x1fvalor\n
    printf '\0%s%s%s\n' "$1" "$SEP" "$2"
}

row() { # texto [active:0/1] [info] — fila con resaltado y destino de seek
    local text="$1" active="${2:-0}" info="${3:-}" first=1
    printf '%s' "$text"
    if [ "$active" = "1" ]; then
        printf '\0active%s%s' "$SEP" "true"
        first=0
    fi
    if [ -n "$info" ]; then
        if [ "$first" = "1" ]; then
            printf '\0info%s%s' "$SEP" "$info"
        else
            printf '%sinfo%s%s' "$SEP" "$SEP" "$info"
        fi
    fi
    printf '\n'
}

fold_text() { # texto — deja en FOLDED[] las filas de $WRAP columnas (por palabras)
    local text="$1" width="$WRAP" line="" word cand
    local -a words=()
    FOLDED=()
    read -ra words <<< "$text"
    for word in "${words[@]}"; do
        if [ -z "$line" ]; then cand="$word"; else cand="$line $word"; fi
        if [ "${#cand}" -le "$width" ]; then
            line="$cand"
        else
            [ -n "$line" ] && FOLDED+=("$line")
            line=""
            while [ "${#word}" -gt "$width" ]; do
                FOLDED+=("${word:0:width}")
                word="${word:width}"
            done
            line="$word"
        fi
    done
    [ -n "$line" ] && FOLDED+=("$line")
}

pick_player() { # reproductor activo (prioridad: sonando > pausa > con título)
    local player status title pri cur=0 best=""
    # Atajo: cmus sonando es lo habitual; evita escanear otros reproductores
    # (alguno, p. ej. el navegador, responde lento y retrasa el karaoke).
    status=$(playerctl -p cmus status 2>/dev/null)
    if [ "$status" = "Playing" ]; then
        printf 'cmus'
        return 0
    fi
    while IFS= read -r player; do
        [ -z "$player" ] && continue
        status=$(playerctl -p "$player" status 2>/dev/null | tr '[:upper:]' '[:lower:]')
        title=$(playerctl -p "$player" metadata title 2>/dev/null)
        pri=0
        if [ "$status" = "playing" ]; then
            pri=3
        elif [ "$status" = "paused" ]; then
            pri=2
        elif [ -n "$title" ]; then
            pri=1
        fi
        if [ "$pri" -gt "$cur" ]; then
            best="$player"
            cur="$pri"
        fi
    done <<< "$(playerctl -l 2>/dev/null)"
    printf '%s' "$best"
}

track_info() {
    # Publica: P_PLAYER P_ARTIST P_TITLE P_ALBUM P_POS P_DUR P_STATUS
    P_PLAYER=""; P_ARTIST=""; P_TITLE=""; P_ALBUM=""
    P_POS=""; P_DUR=""; P_STATUS=""
    P_PLAYER=$(pick_player)
    [ -n "$P_PLAYER" ] || return 1
    P_STATUS=$(playerctl -p "$P_PLAYER" status 2>/dev/null | tr '[:upper:]' '[:lower:]')
    IFS=$'\x1f' read -r P_ARTIST P_TITLE P_ALBUM __len < \
        <(playerctl -p "$P_PLAYER" metadata --format "{{artist}}${SEP}{{title}}${SEP}{{album}}${SEP}{{mpris:length}}" 2>/dev/null)
    [ -n "$P_TITLE" ] || return 1
    P_POS=$(playerctl -p "$P_PLAYER" position 2>/dev/null)
    if [ -n "${__len:-}" ]; then
        P_DUR=$(awk -v l="$__len" 'BEGIN { printf "%d", l / 1000000 }')
    else
        P_DUR=0
    fi
    if [ -z "$P_POS" ]; then
        case "$P_PLAYER" in
            cmus|cmus.*)
                P_POS=$(cmus-remote --server "$LP_SOCK" -Q 2>/dev/null | awk '$1 == "position" {print $2; exit}')
                [ -z "$P_POS" ] && P_POS=$(cmus-remote -Q 2>/dev/null | awk '$1 == "position" {print $2; exit}')
                ;;
        esac
    fi
    [ -z "$P_POS" ] && P_POS=0
    return 0
}

cover_for_track() { # artista álbum [ruta] — imprime ruta de portada o ""
    local artist="$1" album="$2" f="${3:-}" key out data
    if [ -z "$f" ] && [ -f "$LP_SONGS" ]; then
        # Misma tabla que localplayer: artista\t título → álbum + ruta
        data=$(awk -F'\t' -v a="$artist" -v t="$P_TITLE" '$2 == a && $3 == t {print $4 "\t" $5; exit}' "$LP_SONGS")
        if [ -n "$data" ]; then
            [ -z "$album" ] && album="${data%%$'\t'*}"
            f="${data#*$'\t'}"
        fi
    fi
    if [ -n "$artist" ] && [ -n "$album" ]; then
        key=$(printf '%s|%s' "$artist" "$album" | md5sum | cut -c1-16)
    elif [ -n "$f" ]; then
        key=$(printf '%s' "$f" | md5sum | cut -c1-16)
    else
        [ -f "$LP_NOCOVER" ] && { printf '%s' "$LP_NOCOVER"; return 0; }
        return 1
    fi
    out="$LP_THUMBS/$key.jpg"
    [ -f "$out" ] && { printf '%s' "$out"; return 0; }
    if [ -n "$f" ] && [ -f "$f" ]; then
        mkdir -p "$LP_THUMBS"
        case "$f" in
            *.flac|*.FLAC)
                metaflac --export-picture-to="$out" "$f" >/dev/null 2>&1 ;;
            *.mp3|*.MP3|*.m4a|*.M4A|*.ogg|*.OGG|*.opus|*.OPUS|*.wav|*.WAV)
                ffmpeg -y -v error -i "$f" -an -vcodec copy -frames:v 1 "$out" >/dev/null 2>&1 ;;
        esac
        [ -f "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    [ -f "$LP_NOCOVER" ] && { printf '%s' "$LP_NOCOVER"; return 0; }
    return 1
}

cmus_current_file() {
    local f
    f=$(timeout 2 cmus-remote --server "$LP_SOCK" -Q 2>/dev/null | awk '/^file /{sub(/^file /,""); print; exit}')
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
    return 1
}

seek_to() { # segundos — salta a esa posición y reproduce
    local target="$1" pl cur diff
    case "$target" in ''|*[!0-9.]*) return 1 ;; esac
    pl=$(pick_player)
    [ -n "$pl" ] || return 1
    case "$pl" in
        cmus|cmus.*)
            # El MPRIS de cmus no acepta posición absoluta fiable: salto
            # relativo con cmus-remote (su next MPRIS tampoco avanza).
            cur=$(timeout 2 playerctl -p "$pl" position 2>/dev/null)
            if [ -z "$cur" ]; then
                cur=$(timeout 2 cmus-remote --server "$LP_SOCK" -Q 2>/dev/null | awk '$1 == "position" {print $2; exit}')
                [ -z "$cur" ] && cur=$(timeout 2 cmus-remote -Q 2>/dev/null | awk '$1 == "position" {print $2; exit}')
            fi
            diff=$(awk -v t="$target" -v c="${cur:-0}" 'BEGIN { d = t - c; printf "%+d", (d >= 0 ? int(d + 0.5) : -int(-d + 0.5)) }')
            if [ "$diff" != "+0" ] && [ "$diff" != "-0" ]; then
                timeout 3 cmus-remote --server "$LP_SOCK" --seek "$diff" >/dev/null 2>&1 \
                    || timeout 3 cmus-remote --seek "$diff" >/dev/null 2>&1
            fi
            # -p con la pista sonando la reinicia desde 0: solo reanudar
            # si quedó en pausa/detenido (reproducir siempre, sin reiniciar).
            if [ "$(timeout 2 playerctl -p "$pl" status 2>/dev/null)" != "Playing" ]; then
                timeout 3 cmus-remote --server "$LP_SOCK" -p >/dev/null 2>&1 \
                    || timeout 3 cmus-remote -p >/dev/null 2>&1
            fi
            ;;
        *)
            timeout 3 playerctl -p "$pl" position "$target" >/dev/null 2>&1
            timeout 3 playerctl -p "$pl" play >/dev/null 2>&1
            ;;
    esac
    return 0
}

dominant_color() { # cover.jpg — imprime #rrggbb vibrante (cacheado) o default
    local cover="$1" base hexfile hex
    [ -n "$cover" ] && [ -f "$cover" ] || { printf '%s' "$DEFAULT_SELECTED"; return 0; }
    # Sin carátula real no hay nada que extraer: conserva el azul del rasi.
    [ "$cover" = "$LP_NOCOVER" ] && { printf '%s' "$DEFAULT_SELECTED"; return 0; }
    base=$(basename "$cover")
    base="${base%.*}"
    hexfile="$COLORCACHE/$base.hex"
    if [ -f "$hexfile" ] && [ "$hexfile" -nt "$cover" ]; then
        hex=$(cat "$hexfile" 2>/dev/null)
        case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
            printf '%s' "$hex"; return 0 ;; esac
    fi
    # Histograma de 6 colores: puntúa píxeles × saturación, descarta grises,
    # negros y blancos puros; luego fija luminancia al rango legible [90,200]
    # para que el texto oscuro (@dark) contraste sobre el seleccionado.
    hex=$(timeout 5 magick "$cover" -resize 80x80! -colors 6 -format "%c" histogram:info:- 2>/dev/null | awk '
        {
            count = $1; sub(/:$/, "", count)
            if (match($0, /\(([0-9.]+),([0-9.]+),([0-9.]+)\)/)) {
                rgb = substr($0, RSTART + 1, RLENGTH - 2)
                n = split(rgb, c, ",")
                r = c[1] + 0; g = c[2] + 0; b = c[3] + 0
                mx = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b)
                mn = (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b)
                sat = mx - mn
                if (match($0, /#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/))
                    hx = substr($0, RSTART, 7)
                else
                    next
                score = count * sat
                if (score > best_score && sat >= 25 && mx >= 50 && mx <= 235) {
                    best_score = score; best_hx = hx
                }
                if (count * (1 + sat / 60) > fb_score) {
                    fb_score = count * (1 + sat / 60); fb_hx = hx
                }
            }
        }
        END {
            hx = (best_score > 0) ? best_hx : fb_hx
            if (hx == "") exit 1
            print hx
        }')
    if [ -z "$hex" ]; then
        hex=$(timeout 5 magick "$cover" -resize 1x1 txt:- 2>/dev/null | grep -om1 '#[0-9A-Fa-f]\{6\}')
    fi
    case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) hex="$DEFAULT_SELECTED" ;; esac
    # Normaliza luminancia a [90,200] escalando canales (conserva el tono).
    if [ "$hex" != "$DEFAULT_SELECTED" ]; then
        hex=$(printf '%s' "$hex" | awk '
            {
                hx = $0; sub(/^#/, "", hx)
                r = strtonum("0x" substr(hx, 1, 2)) + 0
                g = strtonum("0x" substr(hx, 3, 2)) + 0
                b = strtonum("0x" substr(hx, 5, 2)) + 0
                lum = (299 * r + 587 * g + 114 * b) / 1000
                if (lum < 90 && lum > 0) {
                    f = 90 / lum
                    r = (r * f > 255) ? 255 : int(r * f)
                    g = (g * f > 255) ? 255 : int(g * f)
                    b = (b * f > 255) ? 255 : int(b * f)
                } else if (lum > 200) {
                    f = 200 / lum
                    r = int(r * f); g = int(g * f); b = int(b * f)
                }
                printf "#%02X%02X%02X", r, g, b
            }')
    fi
    case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) hex="$DEFAULT_SELECTED" ;; esac
    printf '%s' "$hex" > "$hexfile" 2>/dev/null
    printf '%s' "$hex"
}

max_len_for_key() { # key — imprime largo máximo de línea (0 si no hay fichero)
    local key="$1"
    if [ -f "$LRC/$key.tsv" ]; then
        awk -F'\t' '{l=length($2); if(l>m)m=l} END{print m+0}' "$LRC/$key.tsv"
    elif [ -f "$LRC/$key.plain" ]; then
        awk '{l=length($0); if(l>m)m=l} END{print m+0}' "$LRC/$key.plain"
    else
        printf '0'
    fi
}

apply_dyn_wrap() { # max_len [header_len] — ajusta WRAP + WRAP_PX globales
    local m="${1:-0}" h="${2:-0}" lc hc lpx hpx
    # Punto de partida: lo que launch.sh ya calculó (ventana inicial).
    if [ -n "${LYRICS_WRAP:-}" ]; then
        case "$LYRICS_WRAP" in ''|*[!0-9]*) ;; *) WRAP="$LYRICS_WRAP" ;; esac
    fi
    # Ancho en chars por zona (letra y header tienen distinto chrome),
    # con 1 char de aire para que la línea más larga quede a un espacio
    # del borde. El plegado usa el mayor para no partir de más.
    lc=$((m + WRAP_MARGIN))
    [ "$lc" -lt "$MIN_CHARS" ] 2>/dev/null && lc="$MIN_CHARS"
    [ "$lc" -gt "$MAX_CHARS" ] 2>/dev/null && lc="$MAX_CHARS"
    hc=$((h + WRAP_MARGIN))
    [ "$hc" -lt "$MIN_CHARS" ] 2>/dev/null && hc="$MIN_CHARS"
    [ "$hc" -gt "$MAX_CHARS" ] 2>/dev/null && hc="$MAX_CHARS"
    if [ "$m" -gt 0 ] 2>/dev/null; then
        WRAP="$lc"
        [ "$hc" -gt "$WRAP" ] 2>/dev/null && WRAP="$hc"
    elif [ -n "${LYRICS_WRAP:-}" ]; then
        case "$LYRICS_WRAP" in ''|*[!0-9]*) ;; *) WRAP="$LYRICS_WRAP" ;; esac
    else
        WRAP="$hc"
    fi
    # Si hay medida real manda ella (cubre caché fría y cambio de tema);
    # si no, se conserva LYRICS_WRAP de launch.sh.
    if [ "$m" -gt 0 ] 2>/dev/null || [ "$h" -gt 0 ] 2>/dev/null; then
        lpx=$(( (lc * PPC_NUM) / PPC_DEN + ROW_CHROME ))
        hpx=$(( (hc * PPC_NUM) / PPC_DEN + HEADER_CHROME ))
        if [ "$hpx" -gt "$lpx" ] 2>/dev/null; then WRAP_PX="$hpx"; else WRAP_PX="$lpx"; fi
        [ "$WRAP_PX" -lt "$MIN_PX" ] 2>/dev/null && WRAP_PX="$MIN_PX"
        [ "$WRAP_PX" -gt "$MAX_PX" ] 2>/dev/null && WRAP_PX="$MAX_PX"
    fi
}

print_rows() {
    local key idx prev n=0 t line
    mode_opt "prompt" " Letras ⏎ línea"
    mode_opt "no-custom" "true"
    mode_opt "keep-filter" "true"
    mode_opt "keep-selection" "true"
    mode_opt "use-hot-keys" "true"
    mode_opt "markup-rows" "true"

    if ! track_info; then
        mode_opt "message" "Sin reproducción"
        row "$(esc "Abre super+p y pon música ♪")"
        return
    fi

    key=$(printf '%s|%s|%s' "$P_ARTIST" "$P_TITLE" "$P_ALBUM" | md5sum | cut -c1-16)
    if [ ! -f "$LRC/$key.tsv" ] && [ ! -f "$LRC/$key.plain" ] && [ ! -f "$LRC/$key.none" ]; then
        tfile=""
        case "$P_PLAYER" in
            cmus|cmus.*) tfile=$(cmus_current_file) || tfile="" ;;
        esac
        if [ -z "$tfile" ] && [ -f "$LP_SONGS" ]; then
            tfile=$(awk -F'\t' -v a="$P_ARTIST" -v t="$P_TITLE" '$2 == a && $3 == t {print $5; exit}' "$LP_SONGS")
        fi
        python3 "$ROFI_DIR/lyrics-fetch.py" "$P_ARTIST" "$P_TITLE" "$P_ALBUM" "$P_DUR" "$LRC" "$key" "$tfile" >/dev/null 2>&1
    fi

    # Salto de línea adaptativo: mide la cadena más larga (letra o
    # encabezado) y ajusta WRAP + ancho de ventana en este mismo refresh,
    # así corrige caché fría y cambio de tema sin relanzar rofi.
    _header_len=$((${#P_TITLE} + ${#P_ARTIST} + 3))
    apply_dyn_wrap "$(max_len_for_key "$key")" "$_header_len"

    local state_icon="▶"
    [ "$P_STATUS" = "playing" ] && state_icon="⏸"
    mode_opt "message" "<b>$(esc "$P_TITLE")</b>&#10;$(esc "$P_ARTIST")  $state_icon"
    local _cover _cfile="" _sel="$DEFAULT_SELECTED"
    local _theme="window { width: ${WRAP_PX}px; }"
    case "$P_PLAYER" in
        cmus|cmus.*) _cfile=$(cmus_current_file) || _cfile="" ;;
    esac
    if _cover=$(cover_for_track "$P_ARTIST" "$P_ALBUM" "$_cfile"); then
        _theme="$_theme icon-cover { filename: \"$_cover\"; }"
        _sel=$(dominant_color "$_cover")
    fi
    case "$_sel" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) _sel="$DEFAULT_SELECTED" ;; esac
    _theme="element normal.active { background-color: ${_sel}FF; } element alternate.active { background-color: ${_sel}FF; } element selected.active { background-color: ${_sel}FF; } $_theme"
    # Reaplicar el theme en cada refresh (cada 0.5s) hace parpadear el
    # recuadro: solo se emite cuando ancho, color o cover cambian de verdad.
    _theme_sig="${WRAP_PX}|${_sel}|${_cover:-}"
    if [ "$_theme_sig" != "$(cat "$CACHE/last.theme" 2>/dev/null)" ]; then
        mode_opt "theme" "$_theme"
        printf '%s' "$_theme_sig" > "$CACHE/last.theme" 2>/dev/null
    fi

    if [ -f "$LRC/$key.tsv" ]; then
        case "$OFFSET" in ''|*[!0-9.]*) off=0.7 ;; *) off="$OFFSET" ;; esac
        idx=$(awk -v p="$P_POS" -v off="$off" -F'\t' '$1 <= p + off {i = NR - 1} END {print i + 0}' "$LRC/$key.tsv")
        # Pliega cada línea a filas de $WRAP; recuerda la 1ª fila activa.
        # Cada fila lleva su timestamp (info seek) para saltar con Enter.
        local -a texts=() actives=() infos=()
        local i=0 sel_idx=-1 ch
        while IFS=$'\t' read -r t line; do
            [ -z "${line:-}" ] && line="· · ·"
            fold_text "$line"
            [ "${#FOLDED[@]}" -eq 0 ] && FOLDED=("$line")
            for ch in "${FOLDED[@]}"; do
                if [ "$i" -eq "$idx" ]; then
                    texts+=("<b>$(esc "$ch")</b>")
                    actives+=(1)
                    [ "$sel_idx" -lt 0 ] && sel_idx="$n"
                else
                    texts+=("$(esc "$ch")")
                    actives+=(0)
                fi
                infos+=("seek:$t")
                n=$((n + 1))
            done
            i=$((i + 1))
        done < "$LRC/$key.tsv"
        prev=$(cat "$CACHE/last.idx" 2>/dev/null || echo -1)
        if [ "$sel_idx" -ge 0 ] && [ "$sel_idx" != "$prev" ]; then
            mode_opt "new-selection" "$sel_idx"
        fi
        printf '%s' "$sel_idx" > "$CACHE/last.idx"
        for ch in "${!texts[@]}"; do
            row "${texts[$ch]}" "${actives[$ch]}" "${infos[$ch]}"
        done
        [ "$n" -eq 0 ] && row "$(esc "Sin letra disponible")"
    elif [ -f "$LRC/$key.plain" ]; then
        local ch
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            fold_text "$line"
            [ "${#FOLDED[@]}" -eq 0 ] && FOLDED=("$line")
            for ch in "${FOLDED[@]}"; do
                row "$(esc "$ch")"
            done
        done < "$LRC/$key.plain"
    else
        row "$(esc "Sin letra disponible para esta canción")"
    fi
}

retv="${ROFI_RETV:-0}"
info="${ROFI_INFO:-}"

if [ "$retv" = "0" ] || [ "$retv" = "10" ]; then
    print_rows
    exit 0
fi

# Enter sobre una línea sincronizada: saltar a ese momento y reproducir.
case "$info" in
    seek:*)
        seek_to "${info#seek:}" && sleep 0.3
        print_rows
        exit 0
        ;;
esac

# Enter en el resto (letra plana, sin letra): alternar reproducción y refrescar
pl=$(pick_player)
[ -n "$pl" ] && playerctl -p "$pl" play-pause 2>/dev/null
sleep 0.3
print_rows
