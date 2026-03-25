#!/bin/bash

# Clash for AutoDL 健康检查脚本
# 用于检测 Clash 服务状态和配置问题

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR"
CONF_DIR="$SERVER_DIR/conf"
LOG_DIR="$SERVER_DIR/logs"
CONFIG_FILE="$CONF_DIR/config.yaml"
ENV_FILE="$SERVER_DIR/.env"
YQ_BIN="$SERVER_DIR/bin/yq"

PROXY_PORT="7890"
CONTROLLER_ADDR="127.0.0.1:9090"
CONTROLLER_PORT="9090"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查结果计数
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNINGS=0
ERRORS=0

check_status() {
    local check_name="$1"
    local status="$2"
    local message="$3"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [ "$status" = "PASS" ]; then
        echo -e "${GREEN}[✓]${NC} ${check_name}: ${message}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}[!]${NC} ${check_name}: ${message}"
        WARNINGS=$((WARNINGS + 1))
    else
        echo -e "${RED}[✗]${NC} ${check_name}: ${message}"
        ERRORS=$((ERRORS + 1))
    fi
}

sanitize_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ]; then
        echo "$port"
    else
        echo ""
    fi
}

resolve_ports() {
    local mixed_port=""
    local plain_port=""
    local controller=""

    if [ -x "$YQ_BIN" ] && [ -f "$CONFIG_FILE" ]; then
        mixed_port="$($YQ_BIN eval '."mixed-port"' "$CONFIG_FILE" 2>/dev/null || true)"
        plain_port="$($YQ_BIN eval '.port' "$CONFIG_FILE" 2>/dev/null || true)"
        controller="$($YQ_BIN eval '."external-controller"' "$CONFIG_FILE" 2>/dev/null || true)"
    elif command -v yq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
        mixed_port="$(yq eval '."mixed-port"' "$CONFIG_FILE" 2>/dev/null || true)"
        plain_port="$(yq eval '.port' "$CONFIG_FILE" 2>/dev/null || true)"
        controller="$(yq eval '."external-controller"' "$CONFIG_FILE" 2>/dev/null || true)"
    fi

    mixed_port="$(sanitize_port "$mixed_port")"
    plain_port="$(sanitize_port "$plain_port")"

    if [ -n "$mixed_port" ]; then
        PROXY_PORT="$mixed_port"
    elif [ -n "$plain_port" ]; then
        PROXY_PORT="$plain_port"
    fi

    if [ -n "${controller:-}" ] && [ "$controller" != "null" ]; then
        CONTROLLER_ADDR="$controller"
    fi

    CONTROLLER_PORT="${CONTROLLER_ADDR##*:}"
    CONTROLLER_PORT="$(sanitize_port "$CONTROLLER_PORT")"
    [ -z "$CONTROLLER_PORT" ] && CONTROLLER_PORT="9090"
}

resolve_ports

LOG_FILE="$LOG_DIR/mihomo.log"
if [ ! -f "$LOG_FILE" ]; then
    LOG_FILE="$LOG_DIR/clash.log"
fi

echo "======================================"
echo "Clash for AutoDL 健康检查"
echo "======================================"
echo ""

# 1. 检查 Clash 进程
echo "1. 检查 Clash 进程状态"
if pgrep -f "clash-linux-amd64\|mihomo" > /dev/null; then
    PID=$(pgrep -f "clash-linux-amd64\|mihomo" | tr '\n' ' ')
    check_status "进程状态" "PASS" "Clash/Mihomo 正在运行 (PID: $PID)"
else
    check_status "进程状态" "FAIL" "Clash/Mihomo 进程未运行"
fi
echo ""

# 2. 检查端口监听
echo "2. 检查端口监听状态"
check_status "当前端口口径" "PASS" "代理端口=${PROXY_PORT}，控制端口=${CONTROLLER_PORT} (external-controller=${CONTROLLER_ADDR})"

if lsof -i :"$PROXY_PORT" > /dev/null 2>&1; then
    check_status "代理端口 (${PROXY_PORT})" "PASS" "端口正在监听"
else
    check_status "代理端口 (${PROXY_PORT})" "FAIL" "端口未监听"
fi

if lsof -i :"$CONTROLLER_PORT" > /dev/null 2>&1; then
    check_status "控制端口 (${CONTROLLER_PORT})" "PASS" "端口正在监听"
else
    check_status "控制端口 (${CONTROLLER_PORT})" "FAIL" "端口未监听"
fi
echo ""

# 3. 检查配置文件
echo "3. 检查配置文件"
if [ -f "$CONFIG_FILE" ]; then
    if [ -s "$CONFIG_FILE" ]; then
        if [ -x "$YQ_BIN" ] || command -v yq > /dev/null 2>&1; then
            YQ_CMD="$YQ_BIN"
            [ ! -x "$YQ_CMD" ] && YQ_CMD="$(command -v yq)"
            if "$YQ_CMD" eval '.' "$CONFIG_FILE" > /dev/null 2>&1; then
                check_status "配置文件语法" "PASS" "YAML 语法正确"
            else
                check_status "配置文件语法" "FAIL" "YAML 语法错误"
            fi

            PROXY_COUNT=$("$YQ_CMD" eval '.proxies | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
            PROXY_COUNT="$(sanitize_port "$PROXY_COUNT")"
            [ -z "$PROXY_COUNT" ] && PROXY_COUNT=0
        else
            check_status "配置文件语法" "WARN" "无法检查 YAML 语法 (yq 未安装)"
            if grep -q "^proxies:" "$CONFIG_FILE"; then
                PROXY_COUNT=$(awk '/^proxies:/{flag=1;next}/^proxy-groups:/{flag=0}flag && /- +name:/{c++}END{print c+0}' "$CONFIG_FILE")
            else
                PROXY_COUNT=0
            fi
        fi

        if [ "$PROXY_COUNT" -gt 0 ]; then
            check_status "代理节点" "PASS" "找到 $PROXY_COUNT 个代理节点"
        else
            check_status "代理节点" "FAIL" "未找到代理节点"
        fi
    else
        check_status "配置文件" "FAIL" "配置文件为空"
    fi
else
    check_status "配置文件" "FAIL" "配置文件不存在: $CONFIG_FILE"
fi
echo ""

# 4. 检查环境变量
echo "4. 检查环境变量"
if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ]; then
    if echo "${http_proxy:-}${https_proxy:-}" | grep -q ":null"; then
        check_status "代理环境变量" "FAIL" "发现 :null，建议重新运行 start.sh 或手动 export 为 127.0.0.1:${PROXY_PORT}"
    else
        check_status "代理环境变量" "PASS" "已设置 (http_proxy=${http_proxy:-未设置})"
    fi
else
    check_status "代理环境变量" "WARN" "未设置代理环境变量"
fi

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    if [ -n "${CLASH_URL:-}" ]; then
        check_status "订阅地址" "PASS" "已配置订阅地址"
    else
        check_status "订阅地址" "FAIL" ".env 中未设置 CLASH_URL"
    fi
else
    check_status ".env 文件" "FAIL" ".env 文件不存在: $ENV_FILE"
fi
echo ""

# 5. 网络与控制接口测试
echo "5. 网络与控制接口测试"
if curl -s --max-time 5 "http://127.0.0.1:${CONTROLLER_PORT}/version" | grep -q '{'; then
    check_status "控制接口 (/version)" "PASS" "控制接口可访问"

    GLOBAL_NOW=$(curl -s --max-time 5 "http://127.0.0.1:${CONTROLLER_PORT}/proxies/GLOBAL" | ( [ -x "$YQ_BIN" ] && "$YQ_BIN" eval '.now' - 2>/dev/null || command -v yq >/dev/null 2>&1 && yq eval '.now' - 2>/dev/null || sed -n 's/.*"now":"\([^"]*\)".*/\1/p' ))
    if [ "${GLOBAL_NOW:-}" = "DIRECT" ]; then
        check_status "策略组 GLOBAL" "WARN" "当前为 DIRECT，可能导致通过 ${PROXY_PORT} 的请求仍走直连；可在 Dashboard/API 手动切换"
    elif [ -n "${GLOBAL_NOW:-}" ] && [ "$GLOBAL_NOW" != "null" ]; then
        check_status "策略组 GLOBAL" "PASS" "当前选择: ${GLOBAL_NOW}"
    else
        check_status "策略组 GLOBAL" "WARN" "无法读取 GLOBAL 当前策略（可能需要 Secret）"
    fi
else
    if pgrep -f "clash-linux-amd64\|mihomo" > /dev/null; then
        check_status "控制接口 (/version)" "FAIL" "进程存在但 controller 不可用，请检查 external-controller 配置和日志"
    else
        check_status "控制接口 (/version)" "FAIL" "controller 不可用，且进程未运行"
    fi
fi

if curl -s -x "http://127.0.0.1:${PROXY_PORT}" -m 5 http://www.google.com > /dev/null 2>&1; then
    check_status "代理连接 (Google)" "PASS" "可以通过代理访问"
else
    check_status "代理连接 (Google)" "FAIL" "无法通过代理访问"
fi

echo ""

# 6. 日志检查
echo "6. 检查日志文件"
if [ -f "$LOG_FILE" ]; then
    RECENT_ERRORS=$(tail -n 100 "$LOG_FILE" | grep -i "error\|fail" | wc -l)
    if [ "$RECENT_ERRORS" -eq 0 ]; then
        check_status "日志错误" "PASS" "最近没有错误日志 (${LOG_FILE})"
    else
        check_status "日志错误" "WARN" "发现 $RECENT_ERRORS 条错误日志 (${LOG_FILE})"
    fi
else
    check_status "日志文件" "WARN" "日志文件不存在 (期望: $LOG_DIR/mihomo.log 或 $LOG_DIR/clash.log)"
fi

echo ""

# 7. 安全检查
echo "7. 安全检查"
SENSITIVE_FILE="$CONF_DIR/clash_for_windows_config.yaml"
if [ -f "$SENSITIVE_FILE" ]; then
    check_status "敏感配置文件" "FAIL" "发现包含敏感信息的配置文件: $SENSITIVE_FILE"
else
    check_status "敏感配置文件" "PASS" "未发现敏感配置文件"
fi

if [ -d "$SERVER_DIR/.git" ]; then
    if git -C "$SERVER_DIR" ls-files | grep -q "clash_for_windows_config.yaml"; then
        check_status "Git 追踪" "FAIL" "敏感文件被 Git 追踪"
    else
        check_status "Git 追踪" "PASS" "敏感文件未被 Git 追踪"
    fi
fi

echo ""
echo "======================================"
echo "检查总结"
echo "======================================"
echo -e "总检查项: ${TOTAL_CHECKS}"
echo -e "${GREEN}通过: ${PASSED_CHECKS}${NC}"
echo -e "${YELLOW}警告: ${WARNINGS}${NC}"
echo -e "${RED}失败: ${ERRORS}${NC}"
echo ""

if [ "$ERRORS" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then
    echo "建议修复以下问题："
    echo ""

    if ! pgrep -f "clash-linux-amd64\|mihomo" > /dev/null; then
        echo "1. 启动 Clash 服务："
        echo "   cd $SERVER_DIR && source ./start.sh"
        echo ""
    fi

    if [ ! -s "$CONFIG_FILE" ]; then
        echo "2. 配置文件为空或不存在，请检查 .env 中的 CLASH_URL"
        echo ""
    fi

    if echo "${http_proxy:-}${https_proxy:-}" | grep -q ":null"; then
        echo "3. 检测到 :null 环境变量，建议重新运行 start.sh 或手动设置："
        echo "   export http_proxy=http://127.0.0.1:${PROXY_PORT}"
        echo "   export https_proxy=http://127.0.0.1:${PROXY_PORT}"
        echo ""
    elif [ -z "${http_proxy:-}" ]; then
        echo "3. 设置代理环境变量："
        echo "   proxy_on"
        echo ""
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
else
    exit 0
fi
