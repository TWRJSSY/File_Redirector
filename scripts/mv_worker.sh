#!/system/bin/sh
# mv_worker.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 搬运工：执行单个文件的移动（同分区 mv / 跨分区 cp+校验）


[ -f "$1" ] || exit 0
. "$MODDIR/scripts/common.sh"

SRC="$1"
DST_DIR="$2"
FNAME=$(basename "$SRC")

[ -d "$DST_DIR" ] || mkdir -p "$DST_DIR" 2>/dev/null || \
    { log_msg "ERROR" "FILE" "创建目录失败: $DST_DIR"; exit 1; }

# 重名处理：最多尝试99次
DST="$DST_DIR/$FNAME"
_n=1
while [ -e "$DST" ] && [ "$_n" -lt 100 ]; do
    case "$FNAME" in
        *.*) DST="$DST_DIR/${FNAME%.*}_${_n}.${FNAME##*.}" ;;
        *)   DST="$DST_DIR/${FNAME}_${_n}" ;;
    esac
    _n=$(( _n + 1 ))
done
[ -e "$DST" ] && { log_msg "WARN" "FILE" "重名冲突，跳过: $FNAME"; exit 0; }

# 同分区直接 mv
_src_dev=$(stat -c '%d' "$(dirname "$SRC")"  2>/dev/null || printf 'x')
_dst_dev=$(stat -c '%d' "$DST_DIR" 2>/dev/null || printf 'y')
if [ "$_src_dev" = "$_dst_dev" ]; then
    if mv "$SRC" "$DST" 2>/dev/null && [ -f "$DST" ]; then
        log_msg "INFO" "FILE" "mv: $SRC → $DST"
        sh "$VAR_MEDIA_FIX" move "$DST" "$SRC" 2>>"$LOG_FILE"
        exit 0
    fi
    log_msg "WARN" "FILE" "同分区 mv 失败，尝试 cp 兜底: $SRC"
fi

# 跨分区：文件为空时静默跳过，进 retry 队列等下一轮
_fsize=$(wc -c < "$SRC" 2>/dev/null | tr -d ' ')
if [ "${_fsize:-0}" -eq 0 ] 2>/dev/null; then
    exit 1
fi

# 跨分区：cp → 大小+MD5校验 → rm，失败重试一次
_try=1
while [ "$_try" -le 2 ]; do
    [ -f "$SRC" ] || { log_msg "INFO" "FILE" "源文件已消失: $SRC"; exit 0; }
    [ "$_try" -eq 2 ] && sleep 2

    cp "$SRC" "$DST" 2>/dev/null || { rm -f "$DST" 2>/dev/null; _try=$(( _try + 1 )); continue; }

    _ss=$(wc -c < "$SRC" 2>/dev/null | tr -d ' ')
    _ds=$(wc -c < "$DST" 2>/dev/null | tr -d ' ')
    if [ "$_ss" != "$_ds" ]; then
        log_msg "ERROR" "FILE" "大小不符(第${_try}次): $FNAME"
        rm -f "$DST" 2>/dev/null; _try=$(( _try + 1 )); continue
    fi

    _sm=$(md5sum "$SRC" 2>/dev/null | cut -d' ' -f1)
    _dm=$(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$_sm" ] || [ "$_sm" != "$_dm" ]; then
        log_msg "ERROR" "FILE" "MD5不符(第${_try}次): $FNAME"
        rm -f "$DST" 2>/dev/null; _try=$(( _try + 1 )); continue
    fi

    rm "$SRC" 2>/dev/null || true
    log_msg "INFO" "FILE" "cp+校验(第${_try}次): $SRC → $DST"
    sh "$VAR_MEDIA_FIX" move "$DST" "$SRC" 2>>"$LOG_FILE"
    exit 0
done

log_msg "ERROR" "FILE" "搬运失败: $SRC → $DST_DIR"
exit 1
