#!/system/bin/sh
# common.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 公共库：日志、路径规范化、规则解析、存储等待等基础函数


log_msg() {
    _lv="$1"; _tag="$2"; shift 2
    case "$_tag" in FILE|SYS|SCAN) ;; *) _tag="SYS" ;; esac
    printf '%s [%s][%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$_lv" "$_tag" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

rotate_log() {
    [ -f "$LOG_FILE" ] || return
    _sz=$(wc -c < "$LOG_FILE" 2>/dev/null) || return
    [ "$_sz" -gt "${MAX_LOG_BYTES:-524288}" ] || return
    _half=$(( ${MAX_LOG_BYTES:-524288} / 2 ))
    tail -c "$_half" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && \
        mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || \
        rm -f "${LOG_FILE}.tmp" 2>/dev/null
}

# ── 按天清理日志（启动时调用一次）──
clean_old_log() {
    [ -f "$LOG_FILE" ] || return
    _days="${LOG_KEEP_DAYS:-7}"
    # 取日志第一行的时间戳 MM-DD，推算日志起始时间
    _first=$(head -n 1 "$LOG_FILE" 2>/dev/null) || return
    _date=$(printf '%s' "$_first" | cut -c1-5)
    [ -z "$_date" ] && return
    _log_month=$(printf '%s' "$_date" | cut -d'-' -f1)
    _log_day=$(printf '%s' "$_date" | cut -d'-' -f2)
    _now_month=$(date '+%m' 2>/dev/null) || return
    _now_day=$(date '+%d' 2>/dev/null) || return
    # 用月*30+日近似天数，跨年按365处理
    _log_days=$(( _log_month * 30 + _log_day ))
    _now_days=$(( _now_month * 30 + _now_day ))
    _age=$(( _now_days - _log_days ))
    [ "$_age" -lt 0 ] && _age=$(( _age + 365 ))
    if [ "$_age" -ge "$_days" ] 2>/dev/null; then
        : > "$LOG_FILE"
        log_msg "INFO" "SYS" "日志已清空（超过 ${_days} 天，始于 ${_date}）"
    fi
}

# ── 路径规范化：统一转为 /storage/emulated/0 形式，去尾部斜杠 ──
canon_path() {
    _p="${1%/}"
    case "$_p" in
        /sdcard)         _p="/storage/emulated/0" ;;
        /sdcard/*)       _p="/storage/emulated/0/${_p#/sdcard/}" ;;
        /mnt/sdcard)     _p="/storage/emulated/0" ;;
        /mnt/sdcard/*)   _p="/storage/emulated/0/${_p#/mnt/sdcard/}" ;;
        /data/media/0)   _p="/storage/emulated/0" ;;
        /data/media/0/*) _p="/storage/emulated/0/${_p#/data/media/0/}" ;;
    esac
    printf '%s' "$_p"
}

# ── 等待存储挂载（最多3分钟）──
wait_for_storage() {
    _try=0
    while [ "$_try" -lt 60 ]; do
        ls /storage/emulated/0/ >/dev/null 2>&1 && return 0
        sleep 3 & wait $! 2>/dev/null || true
        _try=$(( _try + 1 ))
    done
    log_msg "WARN" "SYS" "等待存储超时，尝试继续启动"
}

# ── 规则解析 ──
# 格式：源目录|匹配模式|目标目录
# 输出：VALID|src|pattern|dst 或 INVALID|原始行
parse_rules() {
    [ -f "$RULES_FILE" ] || return
    while IFS= read -r _raw; do
        _line=$(printf '%s' "$_raw" | tr -d '\r')
        case "$_line" in ''|'#'*) continue ;; esac

        _src="${_line%%|*}";  _rest="${_line#*|}"
        _pat="${_rest%%|*}";  _dst="${_rest#*|}"

        _src=$(printf '%s' "$_src" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        _pat=$(printf '%s' "$_pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        _dst=$(printf '%s' "$_dst" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        _src=$(canon_path "$_src")
        _dst=$(canon_path "$_dst")

        if [ -z "$_src" ] || [ -z "$_dst" ]; then
            printf 'INVALID|%s\n' "$_raw"; continue
        fi
        printf 'VALID|%s|%s|%s\n' "$_src" "$_pat" "$_dst"
    done < "$RULES_FILE"
}

# ── 文件名通配匹配（空模式=全匹配）──
filename_matches() {
    [ -z "$2" ] && return 0
    case "$1" in $2) return 0 ;; esac
    return 1
}

# ── SQL 单引号转义（供 media_fix.sh 使用）──
sq_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
