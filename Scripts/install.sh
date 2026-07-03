#!/bin/bash
# 构建并安装 CY Pro Notch 到 /Applications（日用版与开发目录解耦）
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh release

pkill -x "CY Pro Notch" 2>/dev/null || true
pkill -x ProNotch 2>/dev/null || true
sleep 1

# 强制把新版重注册为 pronotch:// 的处理者，避免旧版/调试版残留抢占 URL 路由
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "/Applications/ProNotch.app" >/dev/null 2>&1 || true
"$LSREGISTER" -u "/Applications/CY Pro Notch.app" >/dev/null 2>&1 || true

# 旧版本移入废纸篓（不直接删除），再放入新版本
if [ -d "/Applications/ProNotch.app" ]; then
    mv "/Applications/ProNotch.app" ~/.Trash/"ProNotch-旧版-$(date +%Y%m%d%H%M%S).app"
fi
if [ -d "/Applications/CY Pro Notch.app" ]; then
    mv "/Applications/CY Pro Notch.app" ~/.Trash/"CY-Pro-Notch-旧版-$(date +%Y%m%d%H%M%S).app"
fi
ditto --rsrc "build/CY Pro Notch.app" "/Applications/CY Pro Notch.app"
# 优先用本机固定的自签名证书签：签名身份稳定，TCC（屏幕录制）与钥匙串权限跨重装保留，
# 不必每次重装都重新授权。没有该证书（如别人的机器）则回退 ad-hoc 临时签名。
SIGN_ID="ProNotch Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "/Applications/CY Pro Notch.app" >/dev/null 2>&1 || true
else
    codesign --force --sign - "/Applications/CY Pro Notch.app" >/dev/null 2>&1 || true
fi

"$LSREGISTER" -f "/Applications/CY Pro Notch.app" >/dev/null 2>&1 || true

open "/Applications/CY Pro Notch.app"
echo "已安装并启动: /Applications/CY Pro Notch.app"
