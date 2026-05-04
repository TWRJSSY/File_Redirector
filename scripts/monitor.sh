#!/system/bin/sh
# monitor.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 监控器：inotifywait 监听目录变化，将新文件写入队列


MODDIR="${MODDIR:-/data/adb/modules/file_redirector}"
. "$MODDIR/scripts/common.sh"

DIR_CHECK_INTERVAL=5
PIPELINE_PID=""
WATCHDOG_PID=""

_cleanup() {
    [ -n "$PIPELINE_PID" ] && kill "$PIPELINE_PID" 2>/dev/null
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
    rm -f "$QUEUE_DIR/.valid_dirs.$$" \
          "$QUEUE_DIR/.pending_dirs.$$" \
          "$QUEUE_DIR/.inotify_err.$$" \
          2>/dev/null
    find "$QUEUE_DIR" -name ".db_$$_*" -type f 2>/dev/null | \
        while IFS= read -r _f; do rm -f "$_f" 2>/dev/null; done
    exit 0
}
trap _cleanup INT TERM HUP

# ── 目录分类：已存在(VALID) / 待出现(PENDING) ──
classify_dirs() {
    VALID_FILE="$QUEUE_DIR/.valid_dirs.$$"
    PENDING_FILE="$QUEUE_DIR/.pending_dirs.$$"
    : > "$VALID_FILE"; : > "$PENDING_FILE"
    [ -f "$PARSED_RULES_FILE" ] || return
    cut -d'|' -f1 "$PARSED_RULES_FILE" | sort -u | while IFS= read -r _d; do
        [ -z "$_d" ] && continue
        if [ -d "$_d" ]; then
            printf '%s\n' "$_d" >> "$VALID_FILE"
        else
            printf '%s\n' "$_d" >> "$PENDING_FILE"
        fi
    done
}

# ── 看门狗子进程：轮询待出现目录 ──
start_watchdog() {
    (
        while true; do
            sleep "$DIR_CHECK_INTERVAL"
            [ -s "$1" ] || continue
            while IFS= read -r _d; do
                if [ -d "$_d" ]; then
                    log_msg "INFO" "SCAN" "看门狗：目录出现 $_d"
                    find "$_d" -type f 2>/dev/null >> "$QUEUE_IN"
                    rm -f "$1" 2>/dev/null
                    exit 0
                fi
            done < "$1"
        done
    ) &
    WATCHDOG_PID=$!
}

TAB=$(printf '\t')

# ── 主循环 ──
while true; do
    classify_dirs

    _vcount=$(wc -l < "$VALID_FILE" 2>/dev/null | tr -d ' ') || _vcount=0
    [ -s "$VALID_FILE" ] || _vcount=0

    if [ "$_vcount" -eq 0 ]; then
        log_msg "WARN" "SCAN" "无可监控目录，等待目录出现..."
        start_watchdog "$PENDING_FILE"
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
        rm -f "$VALID_FILE" "$PENDING_FILE"
        sleep 2
        continue
    fi

    _pcount=$(wc -l < "$PENDING_FILE" 2>/dev/null | tr -d ' ') || _pcount=0
    [ -s "$PENDING_FILE" ] || _pcount=0
    log_msg "INFO" "SCAN" "inotifywait 监控 ${_vcount} 个目录，等待出现 ${_pcount} 个"

    _db_prefix="$QUEUE_DIR/.db_$$_"
    _inotify_err="$QUEUE_DIR/.inotify_err.$$"

    # 构建目录参数列表（set -- 处理含空格路径）
    set --
    while IFS= read -r _d; do set -- "$@" "$_d"; done < "$VALID_FILE"

    # 启动 inotifywait 管道
    LD_LIBRARY_PATH="$MODDIR/tools${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$INOTIFYWAIT_BIN" -m -q -r \
        --format "%w${TAB}%f${TAB}%e" \
        -e close_write -e moved_to \
        "$@" 2>"$_inotify_err" | \
    while IFS="$TAB" read -r _dir _fname _event; do
        [ -z "$_fname" ] && continue
        _dir=$(canon_path "${_dir%/}")
        _filepath="${_dir}/${_fname}"
        [ -e "$_filepath" ] || continue

        # 防抖：同一文件1秒内重复事件合并
        _db_key=$(printf '%s' "$_filepath" | md5sum 2>/dev/null | cut -c1-16)
        _db_file="${_db_prefix}${_db_key}"
        _now=$(date +%s 2>/dev/null || printf '0')
        if [ -f "$_db_file" ]; then
            _last=$(cat "$_db_file" 2>/dev/null || printf '0')
            _diff=$(( _now - _last ))
            [ "$_diff" -lt 1 ] && continue
        fi
        printf '%s\n' "$_now" > "$_db_file"
        printf '%s\n' "$_filepath" >> "$QUEUE_IN"
    done &
    PIPELINE_PID=$!

    # 等1秒确认管道未立即失败
    sleep 1
    if ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
        if [ -s "$_inotify_err" ]; then
            while IFS= read -r _e; do
                log_msg "ERROR" "SYS" "inotifywait: $_e"
            done < "$_inotify_err"
        else
            log_msg "ERROR" "SYS" "inotifywait 启动后立即退出"
        fi
        rm -f "$VALID_FILE" "$PENDING_FILE" "$_inotify_err"
        PIPELINE_PID=""
        sleep 10
        continue
    fi
    rm -f "$_inotify_err"

    # inotifywait 建立后补扫一次（覆盖监控建立前漏掉的文件）
    while IFS= read -r _d; do
        [ -d "$_d" ] && find "$_d" -type f 2>/dev/null >> "$QUEUE_IN"
    done < "$VALID_FILE"

    # 启动看门狗监视待出现目录
    WATCHDOG_PID=""
    [ -s "$PENDING_FILE" ] && start_watchdog "$PENDING_FILE"

    # 等待管道退出或看门狗触发
    while true; do
        if ! kill -0 "$PIPELINE_PID" 2>/dev/null; then
            log_msg "INFO" "SCAN" "inotifywait 退出，重建监控"
            break
        fi
        if [ -n "$WATCHDOG_PID" ] && ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
            break
        fi
        sleep 2
    done

    kill "$PIPELINE_PID" 2>/dev/null
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
    PIPELINE_PID=""; WATCHDOG_PID=""
    rm -f "$VALID_FILE" "$PENDING_FILE"
    find "$QUEUE_DIR" -name ".db_$$_*" -type f 2>/dev/null | \
        while IFS= read -r _f; do rm -f "$_f" 2>/dev/null; done
    sleep 1
done
