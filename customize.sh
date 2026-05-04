#!/system/bin/sh
# customize.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 安装脚本：处理首装/升级逻辑、迁移用户配置、设置文件权限


MOD_ID="file_redirector"
INSTALLED="/data/adb/modules/$MOD_ID"
VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)

if [ -f "$INSTALLED/service.sh" ] || [ -f "$INSTALLED/redirect.rules" ]; then
    MODE="升级"
else
    MODE="安装"
fi

echo
echo "========================================="
echo "        ${MODE}模块: 文件重定向 ${VER}"
echo "========================================="
echo

if [ "$MODE" = "升级" ]; then
    echo "[*] 保留用户设置和规则..."
    if [ -f "$INSTALLED/service.sh" ]; then
        for key in STARTUP_SCAN MEDIA_WAIT LOG_KEEP_DAYS DISPATCH_INTERVAL; do
            val=$(grep "^${key}=" "$INSTALLED/service.sh" | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
            [ -n "$val" ] && sed -i "s/^${key}=.*/${key}=${val}/" "$MODPATH/service.sh"
        done
    fi
    [ -f "$INSTALLED/.webui_theme" ] && cp "$INSTALLED/.webui_theme" "$MODPATH/.webui_theme"
    if [ -f "$INSTALLED/redirect.rules" ]; then
        if cp "$INSTALLED/redirect.rules" "$MODPATH/redirect.rules" 2>/dev/null; then
            echo "已保留旧规则文件"
        else
            echo "规则文件复制失败，解压默认规则"
            unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
        fi
    else
        unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
    fi
    echo "已保留旧设置"
else
    unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
    echo "默认规则已解压"
fi

echo "[*] 设置文件权限..."
set_perm "$MODPATH/service.sh"     root root 0755
set_perm "$MODPATH/uninstall.sh"   root root 0755
set_perm "$MODPATH/redirect.rules" root root 0644
[ -f "$MODPATH/tools/inotifywait" ] && set_perm "$MODPATH/tools/inotifywait" root root 0755
for so in "$MODPATH/tools/"*.so; do
    [ -f "$so" ] && set_perm "$so" root root 0644
done
for script in "$MODPATH/scripts/"*.sh; do
    [ -f "$script" ] && set_perm "$script" root root 0755
done
echo "设置完成！"

rm -f "$MODPATH/LICENSE" "$MODPATH/changelog.md"

echo
echo "========================================="
echo "        模块${MODE}完成 🎉"
echo "========================================="
echo
