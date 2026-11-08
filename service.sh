#!/bin/sh
# 🦊 Foxify — Spotify Connect Daemon for Yandex Station Mini 2
# Lightweight, self-contained Spotify Connect daemon with clean ALSA audio pipeline (no PulseAudio needed)

set -e

# Detect package/binary layout
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/../share/avelc.foxify/bin/soloist" ]; then
    SHARE_DIR="$(cd "$SELF_DIR/../share/avelc.foxify" && pwd)"
elif [ -f "/data/yam/share/avelc.foxify/bin/soloist" ]; then
    SHARE_DIR="/data/yam/share/avelc.foxify"
elif [ -f "$SELF_DIR/bin/soloist" ]; then
    SHARE_DIR="$SELF_DIR"
elif [ -f "/data/spotify/bin/soloist" ]; then
    SHARE_DIR="/data/spotify"
else
    SHARE_DIR="$SELF_DIR"
fi

BIN="$SHARE_DIR/bin/soloist"
GLIBC="$SHARE_DIR/glibc"
LIB="$SHARE_DIR/lib"
INTERP="$GLIBC/ld-linux-armhf.so.3"

# Persistent directories (YAM v2 standards + standalone fallback)
if [ -n "${YAM_VAR:-}" ]; then
    DEFAULT_DATA_DIR="$YAM_VAR/foxify/data"
    DEFAULT_CONF_DIR="$YAM_VAR/foxify/config"
elif [ -d "/data/yam/var" ]; then
    DEFAULT_DATA_DIR="/data/yam/var/foxify/data"
    DEFAULT_CONF_DIR="/data/yam/var/foxify/config"
else
    DEFAULT_DATA_DIR="/data/soloist_data"
    DEFAULT_CONF_DIR="/data/foxify"
fi

DATA_DIR="${SOLOIST_DATA_DIR:-$DEFAULT_DATA_DIR}"
CONF_DIR="${FOXIFY_CONF_DIR:-$DEFAULT_CONF_DIR}"

# Runtime directories
if [ -n "${YAM_RUN:-}" ]; then
    DEFAULT_RUN_DIR="$YAM_RUN/foxify"
elif [ -d "/tmp/yam" ]; then
    DEFAULT_RUN_DIR="/tmp/yam/foxify"
else
    DEFAULT_RUN_DIR="/tmp/foxify"
fi

RUN_DIR="${FOXIFY_RUN_DIR:-$DEFAULT_RUN_DIR}"
CACHE_DIR="${SOLOIST_CACHE_DIR:-$RUN_DIR/cache}"
LOG_DIR="${SOLOIST_LOG_DIR:-$RUN_DIR/logs}"
PID_FILE="$RUN_DIR/soloist.pid"
LOG_FILE="$LOG_DIR/soloist.log"
PULSE_LOG="/tmp/pulse_debug.log"

CONF_KEY_FILE="$CONF_DIR/api_key.txt"
CONF_NAME_FILE="$CONF_DIR/device_name.txt"
CONF_CURVE_FILE="$CONF_DIR/volume_curve.txt"

# Resolve Device Name
get_device_name() {
    if [ -n "${FOXIFY_DEVICE_NAME:-}" ]; then
        echo "$FOXIFY_DEVICE_NAME"
    elif [ -s "$CONF_NAME_FILE" ]; then
        cat "$CONF_NAME_FILE" | tr -d '\r\n'
    elif [ -s "$SELF_DIR/device_name.txt" ]; then
        cat "$SELF_DIR/device_name.txt" | tr -d '\r\n'
    elif [ -s /data/soloist_device_name.txt ]; then
        cat /data/soloist_device_name.txt | tr -d '\r\n'
    else
        echo "Foxify Mini 2"
    fi
}

# Resolve API Key
get_api_key() {
    if [ -n "${SOLOIST_API_KEY:-}" ]; then
        echo "$SOLOIST_API_KEY"
    elif [ -s "$CONF_KEY_FILE" ]; then
        cat "$CONF_KEY_FILE" | tr -d '\r\n '
    elif [ -s "$SELF_DIR/api_key.txt" ]; then
        cat "$SELF_DIR/api_key.txt" | tr -d '\r\n '
    elif [ -s /data/soloist_api_key.txt ]; then
        cat /data/soloist_api_key.txt | tr -d '\r\n '
    elif [ -s /data/spotify/api_key.txt ]; then
        cat /data/spotify/api_key.txt | tr -d '\r\n '
    fi
}

mask_key() {
    _key="$1"
    _len=$(echo "$_key" | awk '{print length}')
    if [ "$_len" -le 12 ]; then
        echo "********"
    else
        _pfx=$(echo "$_key" | cut -c 1-8)
        _sfx=$(echo "$_key" | awk '{print substr($0, length($0)-3, 4)}')
        echo "${_pfx}...${_sfx}"
    fi
}

is_curve_enabled() {
    if [ -n "${FOXIFY_PERCEPTUAL_VOLUME:-}" ]; then
        case "$FOXIFY_PERCEPTUAL_VOLUME" in
            1|[yY]*|[tT]*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    if [ -s "$CONF_CURVE_FILE" ]; then
        case "$(cat "$CONF_CURVE_FILE" | tr -d '\r\n ')" in
            1|[yY]*|[tT]*|[oO][nN]*) return 0 ;;
            *) return 1 ;;
        esac
    elif [ -s /data/soloist_volume_curve.txt ]; then
        case "$(cat /data/soloist_volume_curve.txt | tr -d '\r\n ')" in
            1|[yY]*|[tT]*|[oO][nN]*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}

set_curve() {
    ACTION="${1:-}"
    case "$ACTION" in
        on|enable|1|yes)
            mkdir -p "$CONF_DIR"
            echo "on" > "$CONF_CURVE_FILE"
            if [ -d /data ] && [ -w /data ]; then
                echo "on" > /data/soloist_volume_curve.txt 2>/dev/null || true
            fi
            echo "✅ [Экспериментально] Перцептивная кривая громкости включена (gamma=1.5)."
            echo "   Громкость 1–15% настраивается плавнее для комфортного ночного прослушивания."
            echo "   Изменения вступают в силу немедленно."
            ;;
        off|disable|0|no)
            mkdir -p "$CONF_DIR"
            echo "off" > "$CONF_CURVE_FILE"
            if [ -d /data ] && [ -w /data ]; then
                echo "off" > /data/soloist_volume_curve.txt 2>/dev/null || true
            fi
            echo "✅ Перцептивная кривая громкости выключена."
            echo "   Используется стандартная линейная шкала (1:1 со слайдером Spotify)."
            echo "   Изменения вступают в силу немедленно."
            ;;
        *)
            if is_curve_enabled; then
                echo "ℹ️  Экспериментальная кривая громкости: ВКЛЮЧЕНА (gamma=1.5)"
                echo "   Чтобы выключить: foxify curve off"
            else
                echo "ℹ️  Экспериментальная кривая громкости: ВЫКЛЮЧЕНА (по умолчанию, линейная)"
                echo "   Чтобы включить:  foxify curve on"
            fi
            ;;
    esac
}

exec_soloist() {
    [ -e /data/soloist ] || ln -sf "$SHARE_DIR" /data/soloist 2>/dev/null || true
    if "$BIN" --version >/dev/null 2>&1; then
        "$BIN" "$@"
    else
        "$INTERP" --library-path "$GLIBC:$LIB" "$BIN" "$@"
    fi
}

setup_audio_hardware() {
    # 0. Kernel ABI fix & Multicast routing for Amlogic ARM64 kernel running 32-bit userspace
    # (Prevents atomic CAS spinlock in glibc std::call_once that hangs ZeroConf HTTP server)
    echo 2 > /proc/sys/abi/cp15_barrier 2>/dev/null || true
    ifconfig p2p0 down 2>/dev/null || true
    ip route add 224.0.0.0/4 dev wlan0 2>/dev/null || true

    # 1. Unmute amplifier & standby
    amixer cset numid=9 off 2>/dev/null || true
    amixer cset numid=189 off 2>/dev/null || true
    amixer sset 'SPK Master' 240 2>/dev/null || true
    amixer sset 'SPK Master' on 2>/dev/null || true
    amixer set 'Master' unmute 2>/dev/null || true

    # 2. Enable Lane0 Stereo Mix (Left + Right -> Mono speaker)
    amixer cset numid=148 1 2>/dev/null || true

    # 3. Enable Mini 2 hardware acoustic EQ and DRC for clean speaker compensation and distortion prevention
    amixer sset 'SPK DRC' on 2>/dev/null || true
    amixer sset 'SPK EQ' on 2>/dev/null || true

    # 4. Configure ALSA high-quality Speex DSP resampler (eliminates harsh linear aliasing)
    echo 'defaults.pcm.rate_converter "speexrate_medium"' > /data/.asoundrc 2>/dev/null || true

    # 5. Clean stale IPC semaphores only if vanilla engine is not active
    if ! pgrep -f "quasar|maind" >/dev/null 2>&1; then
        killall -9 aplay 2>/dev/null || true
        for id in $(ipcs -m 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+$'); do ipcrm -m $id 2>/dev/null || true; done
        for id in $(ipcs -s 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+$'); do ipcrm -s $id 2>/dev/null || true; done
    fi
}

configure_320kbps() {
    mkdir -p "$DATA_DIR/settings"
    for pref in "$DATA_DIR/settings/prefs" $(find "$DATA_DIR/settings" -name "prefs" 2>/dev/null); do
        if [ -f "$pref" ]; then
            grep -q 'audio.play_bitrate_enumeration=2' "$pref" 2>/dev/null || {
                printf '\naudio.play_bitrate_enumeration=2\naudio.play_bitrate_non_metered_enumeration=2\naudio.sync_bitrate_enumeration=2\n' >> "$pref"
            }
        fi
    done
}

start_voice_listener() {
    VOICE_SCRIPT=""
    if [ -x "$SHARE_DIR/voice.sh" ]; then
        VOICE_SCRIPT="$SHARE_DIR/voice.sh"
    elif [ -x "$SELF_DIR/voice.sh" ]; then
        VOICE_SCRIPT="$SELF_DIR/voice.sh"
    fi

    if [ -n "$VOICE_SCRIPT" ]; then
        "$VOICE_SCRIPT" run >/dev/null 2>&1 &
    fi
}

start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ℹ️ Foxify уже запущен (PID: $(cat "$PID_FILE"))"
        return 0
    fi

    API_KEY="$(get_api_key)"
    if [ -z "$API_KEY" ]; then
        echo "❌ Ошибка: API ключ не найден!" >&2
        echo "Установите ключ командой: foxify set-key <spak_...>" >&2
        echo "Или задайте переменную SOLOIST_API_KEY" >&2
        exit 1
    fi

    mkdir -p "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR" "$CONF_DIR"
    setup_audio_hardware
    configure_320kbps

    DEVICE_NAME="$(get_device_name)"
    echo "🦊 Запуск Foxify ('$DEVICE_NAME')..."

    export PULSE_SERVER="unix:/tmp/soloist-pulse.sock"
    if is_curve_enabled; then
        export FOXIFY_PERCEPTUAL_VOLUME="1"
    else
        unset FOXIFY_PERCEPTUAL_VOLUME || true
    fi
    [ -e /data/soloist ] || ln -sf "$SHARE_DIR" /data/soloist 2>/dev/null || true

    RUN_CMD="$BIN"
    if ! "$BIN" --version >/dev/null 2>&1; then
        RUN_CMD="$INTERP --library-path $GLIBC:$LIB $BIN"
    fi

    setsid $RUN_CMD \
        -n "$DEVICE_NAME" \
        -k "$API_KEY" \
        -D "$DATA_DIR" \
        -C "$CACHE_DIR" \
        -z 256 \
        -i 20 \
        -w 127.0.0.1:8989 \
        -v </dev/null >> "$LOG_FILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PID_FILE"
    sleep 2

    if kill -0 "$PID" 2>/dev/null; then
        echo "✅ Foxify успешно запущен! PID: $PID"
        start_voice_listener
        echo "📱 Откройте Spotify на телефоне/ПК и выберите '$DEVICE_NAME'"
    else
        echo "❌ Ошибка запуска. Проверьте лог: foxify logs"
        exit 1
    fi
}

start_fg() {
    API_KEY="$(get_api_key)"
    if [ -z "$API_KEY" ]; then
        echo "❌ Ошибка: API ключ не найден!" >&2
        echo "Установите ключ командой: foxify set-key <spak_...>" >&2
        echo "Или задайте переменную SOLOIST_API_KEY" >&2
        exit 1
    fi

    mkdir -p "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR" "$CONF_DIR"
    setup_audio_hardware
    configure_320kbps

    DEVICE_NAME="$(get_device_name)"
    echo "🦊 [Foreground / Supervisor] Запуск Foxify ('$DEVICE_NAME')..."
    export PULSE_SERVER="unix:/tmp/soloist-pulse.sock"
    if is_curve_enabled; then
        export FOXIFY_PERCEPTUAL_VOLUME="1"
    else
        unset FOXIFY_PERCEPTUAL_VOLUME || true
    fi

    start_voice_listener
    [ -e /data/soloist ] || ln -sf "$SHARE_DIR" /data/soloist 2>/dev/null || true

    RUN_CMD="$BIN"
    if ! "$BIN" --version >/dev/null 2>&1; then
        RUN_CMD="$INTERP --library-path $GLIBC:$LIB $BIN"
    fi

    exec $RUN_CMD \
        -n "$DEVICE_NAME" \
        -k "$API_KEY" \
        -D "$DATA_DIR" \
        -C "$CACHE_DIR" \
        -z 256 \
        -i 20 \
        -w 127.0.0.1:8989 \
        -v
}

stop() {
    echo "🛑 Остановка Foxify..."
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE")"
        kill "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    killall -9 soloist aplay voice.sh 2>/dev/null || true
    echo "✅ Остановлено."
}

set_key() {
    NEW_KEY="$1"
    if [ -z "$NEW_KEY" ]; then
        echo "❌ Ошибка: укажите Spotify API ключ."
        echo "Использование: foxify set-key <spak_...>"
        echo "Получить ключ: https://developer.spotify.com/dashboard"
        exit 1
    fi
    NEW_KEY="$(echo "$NEW_KEY" | tr -d '\r\n ')"
    mkdir -p "$CONF_DIR"
    echo "$NEW_KEY" > "$CONF_KEY_FILE"
    chmod 600 "$CONF_KEY_FILE" 2>/dev/null || true

    # Backwards compatibility sync if /data is available
    if [ -d /data ] && [ -w /data ]; then
        echo "$NEW_KEY" > /data/soloist_api_key.txt 2>/dev/null || true
        chmod 600 /data/soloist_api_key.txt 2>/dev/null || true
    fi

    echo "✅ Ключ Spotify API успешно сохранён: $(mask_key "$NEW_KEY")"
    case "$NEW_KEY" in
        spak_*) ;;
        *)
            echo "⚠️  Примечание: Ключи Spotify Connect обычно начинаются с 'spak_'."
            echo "    Убедитесь, что скопировали Client Token полностью."
            ;;
    esac

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ℹ️  Сервис Foxify сейчас запущен. Чтобы применить новый ключ, выполните:"
        echo "    foxify restart"
    fi
}

set_name() {
    NEW_NAME="$*"
    if [ -z "$NEW_NAME" ]; then
        echo "❌ Ошибка: укажите новое имя устройства."
        echo "Использование: foxify set-name <Имя>"
        echo "Пример: foxify set-name \"Гостиная\""
        exit 1
    fi
    mkdir -p "$CONF_DIR"
    echo "$NEW_NAME" > "$CONF_NAME_FILE"
    if [ -d /data ] && [ -w /data ]; then
        echo "$NEW_NAME" > /data/soloist_device_name.txt 2>/dev/null || true
    fi

    echo "✅ Имя устройства изменено на: '$NEW_NAME'"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ℹ️  Сервис Foxify сейчас запущен. Чтобы применить новое имя, выполните:"
        echo "    foxify restart"
    fi
}

status() {
    DEV_NAME="$(get_device_name)"
    KEY="$(get_api_key)"

    echo "🦊 Foxify — Spotify Connect для Станции Мини 2"
    echo "──────────────────────────────────────────────"
    echo "  Имя в Spotify: '$DEV_NAME'"
    if [ -n "$KEY" ]; then
        echo "  API Ключ:      $(mask_key "$KEY") (настроен)"
    else
        echo "  API Ключ:      ❌ Не настроен! (задайте: foxify set-key <spak_...>)"
    fi
    echo "  Аудио-тракт:   ALSA Master softvol (-6 dB headroom, Speex DSP resampler)"
    if is_curve_enabled; then
        echo "  Громкость:     ⚡ Экспериментальная перцептивная кривая (gamma=1.5, выкл: foxify curve off)"
    else
        echo "  Громкость:     Стандартная линейная шкала (вкл кривую: foxify curve on)"
    fi

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        PID="$(cat "$PID_FILE")"
        echo "  Сервис:        ● Активен (PID: $PID)"
        echo "──────────────────────────────────────────────"
        echo "🎵 Текущий статус воспроизведения:"
        exec_soloist ctl -w 127.0.0.1:8989 -D "$DATA_DIR" now 2>/dev/null || echo "  (нет активной сессии воспроизведения)"
    else
        echo "  Сервис:        ○ Остановлен"
        echo "──────────────────────────────────────────────"
        echo "💡 Для запуска выполните: foxify start"
        exit 1
    fi
}

ctl() {
    exec_soloist ctl -w 127.0.0.1:8989 -D "$DATA_DIR" "$@"
}

logs() {
    if [ -f "$LOG_FILE" ]; then
        echo "📋 Просмотр логов Foxify ($LOG_FILE):"
        exec tail -n 30 -f "$LOG_FILE"
    else
        echo "Лог-файл ещё не создан ($LOG_FILE). Сервис ещё не запускался?"
    fi
}

case "${1:-}" in
    start)       start ;;
    start_fg)    start_fg ;;
    stop)        stop ;;
    restart)     stop; sleep 1; start ;;
    status)      status ;;
    set-key)     shift; set_key "$@" ;;
    set-name)    shift; set_name "$@" ;;
    curve|set-curve) shift; set_curve "$@" ;;
    play)        ctl play ;;
    pause)       ctl pause ;;
    next)        ctl next ;;
    prev)        ctl prev ;;
    now)         ctl now ;;
    volume)      shift; ctl volume "$@" ;;
    ctl)         shift; ctl "$@" ;;
    log|logs)    logs ;;
    *)
        echo "🦊 Foxify — Spotify Connect для Станции Мини 2"
        echo "Использование: $0 <команда> [аргументы]"
        echo ""
        echo "Управление сервисом:"
        echo "  $0 start              Запустить сервис в фоне"
        echo "  $0 stop               Остановить сервис и воспроизведение"
        echo "  $0 restart            Перезапустить сервис"
        echo "  $0 status             Проверить статус, ключ и текущий трек"
        echo "  $0 logs               Смотреть журнал работы в реальном времени"
        echo ""
        echo "Настройка:"
        echo "  $0 set-key <ключ>     Сохранить Spotify API ключ (spak_...)"
        echo "  $0 set-name <имя>     Изменить отображаемое имя колонки"
        echo "  $0 curve [on|off]     ⚡ [Экспериментально] Логарифмическая кривая громкости"
        echo ""
        echo "Воспроизведение:"
        echo "  $0 now                Показать играющий трек, статус и громкость"
        echo "  $0 play               Возобновить воспроизведение"
        echo "  $0 pause              Поставить на паузу"
        echo "  $0 next               Следующий трек"
        echo "  $0 prev               Предыдущий трек"
        echo "  $0 volume <0-100>     Установить громкость"
        echo "  $0 ctl <команда>      Выполнить прямую команду soloist ctl"
        echo ""
        exit 2
        ;;
esac
