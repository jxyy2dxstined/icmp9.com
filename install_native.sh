#!/bin/sh

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 辅助函数 ---
info() { printf "${GREEN}[INFO] %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}[WARN] %s${NC}\n" "$1"; }
error() { printf "${RED}[ERROR] %s${NC}\n" "$1"; }

# --- 0. Root 检查 ---
if [ "$(id -u)" != "0" ]; then
    error "❌ 请使用 Root 用户运行此脚本！(输入 'sudo -i' 切换)"
    exit 1
fi

printf "${GREEN}=============================================${NC}\n"
printf "${GREEN}   ICMP9 全球落地聚合节点部署脚本 (原生系统直装版)  ${NC}\n"
printf "${GREEN}   支持 Debian / Ubuntu / Alpine.             ${NC}\n"
printf "${GREEN}=============================================${NC}\n"

# --- 风险提示与用户确认 ---
printf "\n${RED}                    ⚠️  警告  ⚠️                    ${NC}\n"
printf "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"
printf "${YELLOW}1. 本脚本将修改VPS配置的Nginx,Xray,Cloudflared原有服务，原配置会失效;${NC}\n"
printf "${YELLOW}2. 建议在纯净系统或专用服务器上运行;${NC}\n"
printf "${YELLOW}3. 作者不对因使用本脚本造成的任何数据丢失负责。${NC}\n"
printf "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

printf "\n您是否已知晓上述风险并确认继续安装？ [y/N]: "
read -r CONFIRM
case "$CONFIRM" in
    [yY][eE][sS]|[yY]) 
        printf "${GREEN}>>> 用户已确认，继续执行安装...${NC}\n"
        ;;
    *)
        printf "${RED}>>> 用户取消安装，脚本退出。${NC}\n"
        exit 1
        ;;
esac

# --- 1. 系统检测与依赖安装 ---
info "🔍 正在检测系统环境..."

OS_TYPE="unknown"
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    # Alpine 依赖安装
    info "📦 检测到 Alpine Linux，正在安装依赖..."
    ulimit -n 65535
    apk update
    apk add --no-cache bash wget curl unzip nano nginx

elif [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] || [ "$ID" = "ubuntu" ]; then
        OS_TYPE="debian"
        # Debian/Ubuntu 依赖安装
        info "📦 检测到 Debian/Ubuntu，正在安装依赖..."
        ulimit -n 65535
        apt-get update
        apt-get install -y wget curl unzip nano nginx
    fi
fi

if [ "$OS_TYPE" = "unknown" ]; then
    error "❌ 不支持的操作系统！仅支持 Debian, Ubuntu 或 Alpine。"
    exit 1
fi

# ICMP9 可用落地节点 API 连通性检查
info "📡 正在检查 ICMP9 可用落地节点 API 连接状态..."

API_URL="https://api.icmp9.com/online.php"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -A "Mozilla/5.0" "$API_URL")

if [ "$HTTP_CODE" = "200" ]; then
    info "✅ 可用落地节点 API 连接正常，准备开始部署..."
else
    error "❌ 可用落地节点 API 连接检查未通过！"
    error "⛔️ 脚本已停止运行。"
    exit 1
fi

# --- 2. 核心组件安装 ---

WORK_DIR="/root/icmp9"

mkdir -p "${WORK_DIR}/config" "${WORK_DIR}/subscribe" "${WORK_DIR}/xray"
cd "${WORK_DIR}" || exit

# 架构判断
ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
  aarch64 | arm64) ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
  x86_64 | amd64) ARCH="64"; CF_ARCH="amd64" ;;
  *) error "❌ 不支持的 CPU 架构: ${ARCH_RAW}"; exit 1 ;;
esac

# --- 3. 用户配置输入 ---
printf "\n${YELLOW}>>> 请输入配置参数 <<<${NC}\n"

# API_KEY
while [ -z "$API_KEY" ]; do
    printf "1. 请输入 ICMP9_API_KEY (UUID格式, 必填): "
    read -r API_KEY
done

# 隧道模式
printf "\n2. 请选择 Cloudflare 隧道模式:\n"
printf "   [1] 临时隧道 (随机域名，无需配置)\n"
printf "   [2] 固定隧道 (需要自备域名和Token)\n"
printf "   请选择 [1/2] (默认: 1): "
read -r MODE_INPUT
if [ -z "$MODE_INPUT" ]; then MODE_INPUT="1"; fi

if [ "$MODE_INPUT" = "2" ]; then
    TUNNEL_MODE="fixed"
    while [ -z "$CLOUDFLARED_DOMAIN" ]; do
        printf "   -> 请输入绑定域名 (CLOUDFLARED_DOMAIN) (必填): "
        read -r CLOUDFLARED_DOMAIN
    done
    while [ -z "$TOKEN" ]; do
        printf "   -> 请输入 Cloudflare Tunnel Token (必填): "
        read -r TOKEN
    done
else
    TUNNEL_MODE="temp"
    CLOUDFLARED_DOMAIN=""
    TOKEN=""               
    info "   -> 已选择临时隧道"
fi

# VPS是否IPv6 Only
printf "\n3. VPS是否IPv6 Only (True/False) [默认: False]: "
read -r IPV6_INPUT

IPV6_ONLY=$(echo "${IPV6_INPUT:-false}" | tr '[:upper:]' '[:lower:]')

# Cloudflare CDN优选IP或域名
printf "4. 请输入Cloudflare CDN优选IP或域名 [默认: icook.tw]: "
read -r CDN_INPUT
if [ -z "$CDN_INPUT" ]; then CDN_DOMAIN="icook.tw"; else CDN_DOMAIN=$CDN_INPUT; fi

# Xray监听起始端口
printf "5. 请输入Xray监听起始端口 [默认: 39001]: "
read -r PORT_INPUT
if [ -z "$PORT_INPUT" ]; then START_PORT="39001"; else START_PORT=$PORT_INPUT; fi

# 节点标识
printf "6. 请输入节点标识 [默认: ICMP9]: "
read -r NODE_TAG_INPUT
if [ -z "$NODE_TAG_INPUT" ]; then NODE_TAG="ICMP9"; else NODE_TAG=$NODE_TAG_INPUT; fi


# --- 4. 安装二进制文件 ---
install_xray() {
    local version="v24.11.30"
    local install_path="$WORK_DIR/xray"
    local download_url="https://ghproxy.lvedong.eu.org/https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH}.zip"
    
    if [ -f "$install_path/xray" ]; then echo "ℹ️ Xray 已安装"; return; fi
    echo "⬇️ 下载 Xray..."
    wget -q -O "Xray.zip" "$download_url" || { echo "❌ Xray 下载失败"; exit 1; }
    unzip -qo "Xray.zip" -d "$install_path"
    chmod +x "$install_path/xray"
    rm -f "Xray.zip"
}

install_cloudflared() {
    local version="2025.11.1"
    local install_path="/usr/bin/cloudflared"    
    local url="https://ghproxy.lvedong.eu.org/https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-${CF_ARCH}"

    if [ -f "$install_path" ]; then echo "ℹ️ Cloudflared 已安装"; return; fi
    echo "⬇️ 下载 Cloudflared..."
    wget -q -O "$install_path" "$url" || { echo "❌ Cloudflared 下载失败"; exit 1; }
    chmod +x "$install_path"
}

ICMP9="/usr/bin/icmp9"
install_icmp9() {
    local url="https://ghproxy.lvedong.eu.org/https://github.com/nap0o/icmp9.com/releases/download/icmp9/icmp9-native-${OS_TYPE}-${CF_ARCH}"

    echo "⬇️ 正在下载/更新 icmp9..."
    wget -q -O "$ICMP9" "$url" || { echo "❌ icmp9 下载失败"; exit 1; }
    chmod +x "$ICMP9"
}

info "📦 正在安装/更新核心组件..."
install_xray
install_cloudflared
install_icmp9

# --- 5. 如果临时隧道，先启动以获取域名 ---

if [ "$TUNNEL_MODE" = "temp" ]; then
    info "🚀 正在优先启动临时隧道以获取分配的域名..."
    
    # 清理旧进程
    if pgrep -f "cloudflared tunnel --url" > /dev/null; then
        pkill -f "cloudflared tunnel --url"
        sleep 2
        pkill -9 -f "cloudflared tunnel --url" 2>/dev/null
    fi
    
    # 清理日志
    rm -f /tmp/cloudflared.log
    touch /tmp/cloudflared.log
    
    # 计算 Edge IP 选项
    EDGE_IP_OPT="auto"
    if echo "$IPV6_ONLY" | grep -iq "true"; then
        EDGE_IP_OPT="6"
    fi
    
    # 启动 Cloudflared (使用 58080 端口，后续 Nginx 会监听这个端口)
    nohup /usr/bin/cloudflared tunnel --edge-ip-version ${EDGE_IP_OPT} --url http://localhost:58080 --no-autoupdate > /tmp/cloudflared.log 2>&1 &
    CF_PID=$!

    info "⏳ 正在等待 Cloudflare 分配域名 (超时 60s)..."
    TIMEOUT=60
    INTERVAL=2
    ELAPSED=0
    FOUND_URL=""

    while [ $ELAPSED -lt $TIMEOUT ]; do
        # 提取域名 (去重并去除 https:// 前缀)
        FOUND_URL=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /tmp/cloudflared.log | head -n 1 | sed 's/https:\/\///')
        
        if [ -n "$FOUND_URL" ]; then
            break
        fi
        
        if ! kill -0 "$CF_PID" 2>/dev/null; then
             error "❌ Cloudflared 进程意外退出！请检查 /tmp/cloudflared.log"
             exit 1
        fi
        
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    if [ -n "$FOUND_URL" ]; then
        CLOUDFLARED_DOMAIN="$FOUND_URL"
        info "✅ 成功获取临时域名: $CLOUDFLARED_DOMAIN"
    else
        error "❌ 获取临时域名失败/超时，请检查网络或日志。"
        exit 1
    fi
fi

# --- 6. 导出环境变量并生成配置 ---

info "📝 正在生成配置文件..."

export ICMP9_OS_TYPE="$OS_TYPE"
export ICMP9_API_KEY="$API_KEY"
export ICMP9_CLOUDFLARED_TOKEN="$TOKEN"
export ICMP9_CLOUDFLARED_DOMAIN="$CLOUDFLARED_DOMAIN"
export ICMP9_IPV6_ONLY="$IPV6_ONLY"
export ICMP9_CDN_DOMAIN="$CDN_DOMAIN"
export ICMP9_START_PORT="$START_PORT"
export ICMP9_NODE_TAG="$NODE_TAG"
export ICMP9_TUNNEL_MODE="$TUNNEL_MODE"

# 写入环境文件以便持久化或调试
ENV_FILE="/root/icmp9/icmp9.env"

cat > "$ENV_FILE" <<EOF
ICMP9_OS_TYPE="$OS_TYPE"
ICMP9_API_KEY="$API_KEY"
ICMP9_CLOUDFLARED_TOKEN="$TOKEN"
ICMP9_CLOUDFLARED_DOMAIN="$CLOUDFLARED_DOMAIN"
ICMP9_IPV6_ONLY="$IPV6_ONLY"
ICMP9_CDN_DOMAIN="$CDN_DOMAIN"
ICMP9_START_PORT="$START_PORT"
ICMP9_NODE_TAG="$NODE_TAG"
ICMP9_TUNNEL_MODE="$TUNNEL_MODE"
EOF
chmod 600 "$ENV_FILE"

# 调用 icmp9 二进制生成 Nginx/Xray 配置
if [ -f "$ICMP9" ]; then
    "$ICMP9"
else
    error "❌ 找不到 icmp9 二进制文件"
    exit 1
fi

# --- 7. 部署服务文件与启动 ---
info "🚀 正在部署并启动服务..."

# 1. 部署通用配置文件
if [ -f "${WORK_DIR}/config/nginx.conf" ]; then
    mv "${WORK_DIR}/config/nginx.conf" /etc/nginx/nginx.conf
else
    error "❌ Nginx 配置文件生成失败"
    exit 1
fi

if [ -f "${WORK_DIR}/config/xray.json" ]; then
    mkdir -p "${WORK_DIR}/xray"
    mv "${WORK_DIR}/config/xray.json" "${WORK_DIR}/xray/xray.json"
else
    error "❌ Xray 配置文件生成失败"
    exit 1
fi

# 2. 根据系统类型部署服务
if [ "$OS_TYPE" = "alpine" ]; then
    # --- Alpine (OpenRC) ---
    if [ -f "${WORK_DIR}/config/xray.service" ]; then
        mv "${WORK_DIR}/config/xray.service" /etc/init.d/xray
        chmod +x /etc/init.d/xray
        mkdir -p /run/nginx
        chown nginx:nginx /run/nginx 2>/dev/null
        rc-update add xray default
        rc-service xray restart
    fi

    # 只有固定隧道才配置服务文件，临时隧道已经在上面 nohup 跑起来了
    if [ "$TUNNEL_MODE" = "fixed" ]; then
        if [ -f "${WORK_DIR}/config/cloudflared.service" ]; then
            mv "${WORK_DIR}/config/cloudflared.service" /etc/init.d/cloudflared
            chmod +x /etc/init.d/cloudflared
            rc-update add cloudflared default
            rc-service cloudflared restart
        fi
    fi
    
    nginx -t && rc-service nginx restart

else
    # --- Debian/Ubuntu (Systemd) ---
    if [ -f "${WORK_DIR}/config/xray.service" ]; then
        mv "${WORK_DIR}/config/xray.service" /etc/systemd/system/xray.service
        systemctl enable xray
    fi

    if [ "$TUNNEL_MODE" = "fixed" ]; then
        if [ -f "${WORK_DIR}/config/cloudflared.service" ]; then
            mv "${WORK_DIR}/config/cloudflared.service" /etc/systemd/system/cloudflared.service
            systemctl enable cloudflared
        fi            
    fi
    
    systemctl daemon-reload
    systemctl restart xray
    [ "$TUNNEL_MODE" = "fixed" ] && systemctl restart cloudflared
    nginx -t && systemctl restart nginx
fi

rm -rf "${WORK_DIR}/config"

# --- 8. 输出结果 ---

SUBSCRIBE_URL="https://${CLOUDFLARED_DOMAIN}/${API_KEY}"

printf "\n${GREEN}✅ 部署完成${NC}\n"
printf "\n${GREEN}✈️ 节点订阅地址:${NC}\n"
printf "${YELLOW}%s${NC}\n\n" "$SUBSCRIBE_URL"

if [ "$TUNNEL_MODE" = "temp" ]; then
    printf "${CYAN}ℹ️ 提示: 临时隧道已在后台运行，重启VPS后域名会变化，需要重新运行脚本获取新订阅地址。${NC}\n"
fi