#!/bin/bash

# Clash for AutoDL 健康检查脚本
# 用于检测 Clash 服务状态和配置问题

echo "======================================"
echo "Clash for AutoDL 健康检查"
echo "======================================"
echo ""

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

# 检查函数
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

# 1. 检查 Clash 进程
echo "1. 检查 Clash 进程状态"
if pgrep -f "clash-linux-amd64\|mihomo" > /dev/null; then
    PID=$(pgrep -f "clash-linux-amd64\|mihomo")
    check_status "进程状态" "PASS" "Clash 正在运行 (PID: $PID)"
else
    check_status "进程状态" "FAIL" "Clash 进程未运行"
fi
echo ""

# 2. 检查端口监听
echo "2. 检查端口监听状态"
PORTS=("7890" "7891" "7892" "6006")
PORT_NAMES=("HTTP/SOCKS5代理" "HTTP代理" "SOCKS5代理" "控制面板")

for i in ${!PORTS[@]}; do
    if lsof -i :${PORTS[$i]} > /dev/null 2>&1; then
        check_status "${PORT_NAMES[$i]}端口 (${PORTS[$i]})" "PASS" "端口正在监听"
    else
        check_status "${PORT_NAMES[$i]}端口 (${PORTS[$i]})" "FAIL" "端口未监听"
    fi
done
echo ""

# 3. 检查配置文件
echo "3. 检查配置文件"
CONFIG_FILE="/root/clash-for-AutoDL/conf/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    if [ -s "$CONFIG_FILE" ]; then
        # 检查 YAML 语法
        if command -v yq > /dev/null 2>&1; then
            if yq eval '.' "$CONFIG_FILE" > /dev/null 2>&1; then
                check_status "配置文件语法" "PASS" "YAML 语法正确"
            else
                check_status "配置文件语法" "FAIL" "YAML 语法错误"
            fi
        else
            check_status "配置文件语法" "WARN" "无法检查 YAML 语法 (yq 未安装)"
        fi
        
        # 检查是否包含代理节点
        if grep -q "proxies:" "$CONFIG_FILE"; then
            PROXY_COUNT=$(grep -c "name:" "$CONFIG_FILE" || echo 0)
            if [ $PROXY_COUNT -gt 0 ]; then
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

# 检查 .env 文件
if [ -f "/root/clash-for-AutoDL/.env" ]; then
    source /root/clash-for-AutoDL/.env
    if [ -n "$CLASH_URL" ]; then
        check_status "订阅地址" "PASS" "已配置订阅地址"
    else
        check_status "订阅地址" "FAIL" ".env 中未设置 CLASH_URL"
    fi
else
    check_status ".env 文件" "FAIL" ".env 文件不存在"
fi
echo ""

# 5. 网络连接测试
echo "5. 网络连接测试"
# 测试本地代理
if curl -s -x http://127.0.0.1:7890 -m 5 http://www.google.com > /dev/null 2>&1; then
    check_status "代理连接 (Google)" "PASS" "可以通过代理访问"
else
    check_status "代理连接 (Google)" "FAIL" "无法通过代理访问"
fi

# 测试 GitHub
if curl -s -x http://127.0.0.1:7890 -m 5 https://api.github.com > /dev/null 2>&1; then
    check_status "代理连接 (GitHub)" "PASS" "可以通过代理访问"
else
    check_status "代理连接 (GitHub)" "FAIL" "无法通过代理访问"
fi
echo ""

# 6. 日志检查
echo "6. 检查日志文件"
LOG_FILE="/tmp/clash_for_autodl.log"
if [ -f "$LOG_FILE" ]; then
    # 检查最近的错误
    RECENT_ERRORS=$(tail -n 100 "$LOG_FILE" | grep -i "error\|fail" | wc -l)
    if [ $RECENT_ERRORS -eq 0 ]; then
        check_status "日志错误" "PASS" "最近没有错误日志"
    else
        check_status "日志错误" "WARN" "发现 $RECENT_ERRORS 条错误日志"
    fi
else
    check_status "日志文件" "WARN" "日志文件不存在"
fi
echo ""

# 7. 安全检查
echo "7. 安全检查"
# 检查敏感文件
if [ -f "/root/clash-for-AutoDL/conf/clash_for_windows_config.yaml" ]; then
    check_status "敏感配置文件" "FAIL" "发现包含敏感信息的配置文件"
else
    check_status "敏感配置文件" "PASS" "未发现敏感配置文件"
fi

# 检查 git 状态
if [ -d "/root/clash-for-AutoDL/.git" ]; then
    cd /root/clash-for-AutoDL
    if git ls-files | grep -q "clash_for_windows_config.yaml"; then
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

# 生成建议
if [ $ERRORS -gt 0 ] || [ $WARNINGS -gt 0 ]; then
    echo "建议修复以下问题："
    echo ""
    
    if ! pgrep -f "clash-linux-amd64\|mihomo" > /dev/null; then
        echo "1. 启动 Clash 服务："
        echo "   cd /root/clash-for-AutoDL && source ./start.sh"
        echo ""
    fi
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "2. 配置文件为空，请检查订阅地址是否正确"
        echo "   检查 .env 文件中的 CLASH_URL"
        echo ""
    fi
    
    if [ -z "$http_proxy" ]; then
        echo "3. 设置代理环境变量："
        echo "   proxy_on"
        echo ""
    fi
    
    if [ -f "/root/clash-for-AutoDL/conf/clash_for_windows_config.yaml" ]; then
        echo "4. 删除敏感配置文件："
        echo "   rm /root/clash-for-AutoDL/conf/clash_for_windows_config.yaml"
        echo "   并从 Git 历史中完全删除"
        echo ""
    fi
fi

# 退出码
if [ $ERRORS -gt 0 ]; then
    exit 1
else
    exit 0
fi