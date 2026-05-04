#!/system/bin/sh
# media_fix.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 媒体修复小连招：修正文件权限、更新媒体库记录、广播扫描通知


. "$MODDIR/scripts/common.sh"

# 删除媒体库中的旧路径记录（同时处理 /sdcard 和 /storage/emulated/0 两种形式）
_delete_record() {
    _p="$1"
    case "$_p" in
        /sdcard/*)             _p2="/storage/emulated/0/${_p#/sdcard/}" ;;
        /storage/emulated/0/*) _p2="/sdcard/${_p#/storage/emulated/0/}" ;;
        *)                     _p2="$_p" ;;
    esac
    _e1=$(sq_escape "$_p")
    _e2=$(sq_escape "$_p2")
    for _uri in content://media/external/files content://media/external/images/media; do
        content delete --uri "$_uri" --where "_data='${_e1}'" >/dev/null 2>&1 || true
        content delete --uri "$_uri" --where "_data='${_e2}'" >/dev/null 2>&1 || true
    done
}

case "$1" in
    move)
        # Strike1: 权限修复
        [ -f "$2" ] && { chown 1023:1023 "$2" 2>/dev/null || true; chmod 0664 "$2" 2>/dev/null || true; }
        # Strike2: 删旧媒体库记录
        _delete_record "$3"
        # Strike3: 广播新路径
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://${2}" >/dev/null 2>&1 || true
        am broadcast -a android.intent.action.MEDIA_MOUNTED \
            -d "file://$(dirname "$2")" >/dev/null 2>&1 || true
        sleep "${MEDIA_WAIT:-3}"
        ;;
    delete)
        # 仅删除媒体库记录（文件已被其他方式处理）
        _delete_record "$2"
        ;;
    *)
        log_msg "ERROR" "SYS" "media_fix: 未知动作 $1"
        exit 1
        ;;
esac
