#!/bin/bash

# Clash for AutoDL 健康检查脚本
# 用于检测 Clash 服务状态和配置问题

Server_Dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
Conf_Dir="$Server_Dir/conf"
Log_Dir="$Server_Dir/logs"
Config_File="$Conf_Dir/config.yaml"
Env_File="$Server_Dir/.env"
PID_FILE="$Server_Dir/clash.pid"
CONTROL_PORT="9090"

# 自动读取实际代理端口，避免配置使用 mixed-port=9981 但健康检查仍检查 7890
YQ_BINARY="$Server_Dir/bin/yq"
PROXY_PORT="7890"

if [ -x "$YQ_BINARY" ] && [ -f "$Config_File" ]; then
    DETECTED_PROXY_PORT=$("$YQ_BINARY" eval '."mixed-port" // .port // 7890' "$Config_File" 2>/dev/null)
    if [[ "$DETECTED_PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$DETECTED_PROXY_PORT" -gt 0 ]; then
        PROXY_PORT="$DETECTED_PROXY_PORT"
    fi
fi

cat <<EOF_HEADER
======================================
Clash for AutoDL 健康检查
======================================
项目目录: $Server_Dir
配置文件: $Config_File
PID 文件: $PID_FILE
控制端口: $CONTROL_PORT

EOF_HEADER

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

read_managed_pid() {
    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        echo "$pid"
        return 0
    fi

    return 1
}

is_managed_service_running() {
    local pid
    pid=$(read_managed_pid) || return 1
    kill -0 "$pid" 2>/dev/null
}

# 1. 检查 Clash 进程
PID=""
echo "1. 检查 Clash 进程状态"
if is_managed_service_running; then
    PID=$(read_managed_pid)
    check_status "进程状态" "PASS" "由本项目 PID 文件管理的服务正在运行 (PID: $PID)"
else
    if [ -f "$PID_FILE" ]; then
        check_status "进程状态" "FAIL" "PID 文件存在但进程不可用，请删除或重新启动: $PID_FILE"
    else
        check_status "进程状态" "FAIL" "未找到本项目 PID 文件，服务未运行或不是由当前脚本启动"
    fi
fi
echo ""

# 2. 检查端口监听和控制接口
echo "2. 检查端口和控制接口"
if curl -fsS --max-time 2 "http://127.0.0.1:${CONTROL_PORT}/configs" > /dev/null 2>&1; then
    check_status "控制接口 (${CONTROL_PORT})" "PASS" "控制接口可访问"
else
    check_status "控制接口 (${CONTROL_PORT})" "FAIL" "无法访问控制接口 http://127.0.0.1:${CONTROL_PORT}/configs"
fi

if command -v lsof > /dev/null 2>&1; then
    PORTS=("$PROXY_PORT" "$CONTROL_PORT")
    PORT_NAMES=("HTTP/SOCKS5代理" "控制面板")
    for i in "${!PORTS[@]}"; do
        if lsof -i :"${PORTS[$i]}" > /dev/null 2>&1; then
            check_status "${PORT_NAMES[$i]}端口 (${PORTS[$i]})" "PASS" "端口正在监听"
        else
            check_status "${PORT_NAMES[$i]}端口 (${PORTS[$i]})" "FAIL" "端口未监听"
        fi
    done
else
    check_status "端口监听检查" "WARN" "lsof 未安装，跳过端口监听检查"
fi
echo ""

# 3. 检查配置文件
echo "3. 检查配置文件"
if [ -f "$Config_File" ]; then
    if [ -s "$Config_File" ]; then
        YQ_BINARY="$Server_Dir/bin/yq"
        if [ -x "$YQ_BINARY" ]; then
            if "$YQ_BINARY" eval '.' "$Config_File" > /dev/null 2>&1; then
                check_status "配置文件语法" "PASS" "YAML 语法正确"
            else
                check_status "配置文件语法" "FAIL" "YAML 语法错误"
            fi
        elif command -v yq > /dev/null 2>&1; then
            if yq eval '.' "$Config_File" > /dev/null 2>&1; then
                check_status "配置文件语法" "PASS" "YAML 语法正确"
            else
                check_status "配置文件语法" "FAIL" "YAML 语法错误"
            fi
        else
            check_status "配置文件语法" "WARN" "无法检查 YAML 语法 (yq 未安装)"
        fi

        if grep -q "proxies:" "$Config_File"; then
            PROXY_COUNT=$(grep -c "name:" "$Config_File" || echo 0)
            if [ "$PROXY_COUNT" -gt 0 ]; then
                check_status "代理节点" "PASS" "找到 $PROXY_COUNT 个代理节点"
            else
                check_status "代理节点" "FAIL" "未找到代理节点"
            fi
        else
            check_status "代理节点" "FAIL" "配置文件中没有 proxies 部分"
        fi
    else
        check_status "配置文件" "FAIL" "配置文件为空"
    fi
else
    check_status "配置文件" "FAIL" "配置文件不存在"
fi
echo ""

# 4. 检查环境变量
echo "4. 检查环境变量"
if [ -n "$http_proxy" ] || [ -n "$https_proxy" ]; then
    check_status "代理环境变量" "PASS" "已设置 (http_proxy=$http_proxy)"
else
    check_status "代理环境变量" "WARN" "未设置代理环境变量"
fi

if [ -f "$Env_File" ]; then
    # shellcheck disable=SC1090
    source "$Env_File"
    if [ -n "$CLASH_URL" ]; then
        check_status "订阅地址" "PASS" "已配置订阅地址"
    else
        check_status "订阅地址" "FAIL" ".env 中未设置 CLASH_URL"
    fi
else
    check_status ".env 文件" "FAIL" ".env 文件不存在: $Env_File"
fi
echo ""

# 5. 网络连接测试
echo "5. 网络连接测试"
if curl -s -x "http://127.0.0.1:${PROXY_PORT}" -m 5 http://www.google.com > /dev/null 2>&1; then
    check_status "代理连接 (Google)" "PASS" "可以通过代理访问"
else
    check_status "代理连接 (Google)" "FAIL" "无法通过代理访问"
fi

if curl -s -x "http://127.0.0.1:${PROXY_PORT}" -m 5 https://api.github.com > /dev/null 2>&1; then
    check_status "代理连接 (GitHub)" "PASS" "可以通过代理访问"
else
    check_status "代理连接 (GitHub)" "FAIL" "无法通过代理访问"
fi
echo ""

# 6. 日志检查
echo "6. 检查日志文件"
LOG_FILE="$Log_Dir/mihomo.log"
if [ -f "$LOG_FILE" ]; then
    RECENT_ERRORS=$(tail -n 100 "$LOG_FILE" | grep -i "error\|fail\|fatal" | wc -l)
    if [ "$RECENT_ERRORS" -eq 0 ]; then
        check_status "日志错误" "PASS" "最近没有错误日志"
    else
        check_status "日志错误" "WARN" "发现 $RECENT_ERRORS 条错误/失败日志"
    fi
else
    check_status "日志文件" "WARN" "日志文件不存在: $LOG_FILE"
fi
echo ""

# 7. 安全检查
echo "7. 安全检查"
SENSITIVE_CONFIG="$Conf_Dir/clash_for_windows_config.yaml"
if [ -f "$SENSITIVE_CONFIG" ]; then
    check_status "敏感配置文件" "FAIL" "发现包含敏感信息的配置文件: $SENSITIVE_CONFIG"
else
    check_status "敏感配置文件" "PASS" "未发现敏感配置文件"
fi

if [ -d "$Server_Dir/.git" ]; then
    if git -C "$Server_Dir" ls-files | grep -q "clash_for_windows_config.yaml"; then
        check_status "Git 追踪" "FAIL" "敏感文件被 Git 追踪"
    else
        check_status "Git 追踪" "PASS" "敏感文件未被 Git 追踪"
    fi
fi
echo ""

# 总结
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

    if ! is_managed_service_running; then
        echo "1. 启动 Clash 服务："
        echo "   cd $Server_Dir && source ./start.sh"
        echo ""
    fi

    if [ ! -s "$Config_File" ]; then
        echo "2. 配置文件为空或不存在，请检查订阅地址是否正确"
        echo "   检查 $Env_File 文件中的 CLASH_URL"
        echo ""
    fi

    if [ -z "$http_proxy" ]; then
        echo "3. 设置代理环境变量："
        echo "   proxy_on"
        echo ""
    fi

    if [ -f "$SENSITIVE_CONFIG" ]; then
        echo "4. 删除敏感配置文件："
        echo "   rm $SENSITIVE_CONFIG"
        echo "   并从 Git 历史中完全删除"
        echo ""
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
else
    exit 0
fi
