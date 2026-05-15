#!/bin/bash

# 定义颜色变量
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置文件路径
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SERVER_DIR/conf"
CONFIG_FILE="$CONF_DIR/config.yaml"
RAW_CONFIG_FILE="$CONF_DIR/config_raw.yaml"
DECODED_CONFIG_FILE="$CONF_DIR/config_decoded.yaml"
TEMPLATE_FILE="$CONF_DIR/template.yaml"
INSERT_MARKER="# __CLASH_FOR_AUTODL_PROXIES__"
# Keep this value aligned with the template MATCH target in conf/template.yaml.
PRIMARY_PROXY_GROUP="🚀 节点选择"
CONTROL_PORT="9090"

# 代理计数器
PROXY_COUNT=0
DUPLICATE_COUNT=0

# 临时文件用于重复名称处理，并作为生成代理组的代理名列表
TEMP_NAME_FILE="/tmp/clash_proxy_names.tmp"


# 将任意字符串格式化为 YAML 安全的双引号字符串
yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"\n' "$value"
}

# 记录并返回去重后的代理名称，供代理组生成逻辑使用
register_proxy_name() {
    local name="$1"
    local candidate="$name"
    local suffix=1

    while [ -f "$TEMP_NAME_FILE" ] && grep -Fxq "$candidate" "$TEMP_NAME_FILE"; do
        candidate="${name}-${suffix}"
        suffix=$((suffix + 1))
    done

    if [ "$candidate" != "$name" ]; then
        DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
    fi

    echo "$candidate" >> "$TEMP_NAME_FILE"
    printf '%s\n' "$candidate"
}

# URL安全的base64解码函数
decode_base64_url() {
    local input="$1"
    # 替换URL安全字符
    input="${input//-/+}"
    input="${input//_/\/}"
    
    # 添加padding
    case $((${#input} % 4)) in
        2) input="${input}==" ;;
        3) input="${input}=" ;;
    esac
    
    # 优先使用python3进行解码
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import base64; print(base64.b64decode('$input').decode('utf-8', errors='ignore'))" 2>/dev/null && return 0
    fi
    
    # 备用方案使用base64命令
    echo "$input" | base64 -d 2>/dev/null || echo ""
}

# 解析SS链接
parse_ss() {
    local ss_url="$1"
    local ss_content=${ss_url#ss://}
    
    # 分离base64部分和服务器部分: base64@server:port#name
    local base64_part=$(echo "$ss_content" | cut -d@ -f1)
    local server_part=$(echo "$ss_content" | cut -d@ -f2 | cut -d# -f1)
    local name_part=$(echo "$ss_content" | cut -d# -f2)
    
    # 解码base64部分 (method:password)
    local decoded=$(decode_base64_url "$base64_part")
    
    if [ -z "$decoded" ]; then
        echo "# Failed to decode SS link"
        return 1
    fi
    
    # 解析格式: method:password
    local method=$(echo "$decoded" | cut -d: -f1)
    local password=$(echo "$decoded" | cut -d: -f2-)
    
    # 解析服务器和端口
    local server=$(echo "$server_part" | cut -d: -f1)
    local port=$(echo "$server_part" | cut -d: -f2)
    
    # 解析节点名称（URL解码）
    local name="SS-${server}-${port}"
    if [ -n "$name_part" ]; then
        # 使用python进行URL解码，处理特殊字符
        if command -v python3 >/dev/null 2>&1; then
            local decoded_name=$(python3 -c "import urllib.parse; import sys; print(urllib.parse.unquote(sys.argv[1]).strip())" "$name_part" 2>/dev/null)
            if [ -n "$decoded_name" ]; then
                name="$decoded_name"
            fi
        fi
    fi
    
    # 检查重复名称并记录成功解析的代理名称
    name=$(register_proxy_name "$name")
    
    # 输出Clash格式配置（紧凑格式）
    echo "  - { name: $(yaml_quote "$name"), type: ss, server: $(yaml_quote "$server"), port: $port, cipher: $(yaml_quote "$method"), password: $(yaml_quote "$password"), udp: true }"
    
    PROXY_COUNT=$((PROXY_COUNT + 1))
}

# 解析SSR链接
parse_ssr() {
    local ssr_url="$1"
    local ssr_content=${ssr_url#ssr://}
    
    # 解码SSR链接
    local decoded=$(decode_base64_url "$ssr_content")
    
    if [ -z "$decoded" ]; then
        echo "# Failed to decode SSR link"
        return 1
    fi
    
    # 解析格式: server:port:protocol:method:obfs:password_base64/?params
    local server=$(echo "$decoded" | cut -d: -f1)
    local port=$(echo "$decoded" | cut -d: -f2)
    local protocol=$(echo "$decoded" | cut -d: -f3)
    local method=$(echo "$decoded" | cut -d: -f4)
    local obfs=$(echo "$decoded" | cut -d: -f5)
    local password_and_params=$(echo "$decoded" | cut -d: -f6-)
    
    # 从password_and_params中提取password和参数
    local password_base64=$(echo "$password_and_params" | cut -d/ -f1)
    local params_part=$(echo "$password_and_params" | cut -d/ -f2- | cut -d? -f2-)
    
    # 解码密码
    local password=$(decode_base64_url "$password_base64")
    
    # 解析参数
    local obfsparam=""
    local protocolparam=""
    local remarks=""
    
    if [ -n "$params_part" ]; then
        # 使用正则表达式提取参数
        if [[ "$params_part" =~ obfsparam=([^&]*) ]]; then
            obfsparam=$(decode_base64_url "${BASH_REMATCH[1]}")
        fi
        if [[ "$params_part" =~ protocolparam=([^&]*) ]]; then
            protocolparam=$(decode_base64_url "${BASH_REMATCH[1]}")
        fi
        if [[ "$params_part" =~ remarks=([^&]*) ]]; then
            remarks=$(decode_base64_url "${BASH_REMATCH[1]}")
        fi
    fi
    
    # 生成代理名称
    local name="SSR-${server}-${port}"
    if [ -n "$remarks" ]; then
        name="$remarks"
    fi
    
    # 检查重复名称并记录成功解析的代理名称
    name=$(register_proxy_name "$name")
    
    # 输出Clash格式配置
    cat << EOF
  - name: $(yaml_quote "$name")
    type: ssr
    server: $server
    port: $port
    cipher: $method
    password: $password
    protocol: $protocol
    obfs: $obfs
EOF
    
    if [ -n "$protocolparam" ]; then
        echo "    protocol-param: $protocolparam"
    fi
    if [ -n "$obfsparam" ]; then
        echo "    obfs-param: $obfsparam"
    fi
    
    PROXY_COUNT=$((PROXY_COUNT + 1))
}

# 解析VLESS链接
parse_vless() {
    local vless_url="$1"
    
    # 移除vless://前缀
    local vless_content=${vless_url#vless://}
    
    # 解析格式: uuid@server:port?params#name
    local uuid=$(echo "$vless_content" | cut -d@ -f1)
    local server_port_params=$(echo "$vless_content" | cut -d@ -f2)
    local server=$(echo "$server_port_params" | cut -d: -f1)
    local port_params=$(echo "$server_port_params" | cut -d: -f2)
    local port=$(echo "$port_params" | cut -d? -f1 | sed 's/[^0-9]//g')
    local params=$(echo "$port_params" | cut -d? -f2 | cut -d# -f1)
    local name=$(echo "$port_params" | cut -d# -f2 | sed 's/%20/ /g')
    
    # 默认参数
    local encryption="none"
    local network="tcp"
    local security=""
    local sni=""
    local alpn=""
    local path=""
    local host=""
    
    # 解析参数
    if [ -n "$params" ]; then
        IFS='&' read -ra PARAM_ARRAY <<< "$params"
        for param in "${PARAM_ARRAY[@]}"; do
            key=$(echo "$param" | cut -d= -f1)
            value=$(echo "$param" | cut -d= -f2)
            case "$key" in
                "encryption") encryption="$value" ;;
                "security") security="$value" ;;
                "sni") sni="$value" ;;
                "alpn") alpn="$value" ;;
                "path") path="$value" ;;
                "host") host="$value" ;;
                "type") network="$value" ;;
            esac
        done
    fi
    
    # 生成代理名称
    if [ -z "$name" ]; then
        name="VLESS-${server}-${port}"
    fi
    
    # 清理名称中的尾部空白字符
    name=$(echo "$name" | sed 's/[[:space:]]*$//')
    
    # 检查重复名称并记录成功解析的代理名称
    name=$(register_proxy_name "$name")
    
    # 输出Clash格式配置
    cat << EOF
  - name: $(yaml_quote "$name")
    type: vless
    server: $server
    port: $port
    uuid: $uuid
    cipher: auto
    network: $network
EOF
    
    if [ -n "$security" ] && [ "$security" != "none" ]; then
        echo "    tls: true"
        if [ -n "$sni" ]; then
            echo "    servername: $sni"
        fi
        if [ -n "$alpn" ]; then
            echo "    alpn: [$alpn]"
        fi
    fi
    
    if [ "$network" = "ws" ]; then
        echo "    ws-opts:"
        if [ -n "$path" ]; then
            echo "      path: $path"
        fi
        if [ -n "$host" ]; then
            echo "      headers:"
            echo "        Host: $host"
        fi
    fi
    
    PROXY_COUNT=$((PROXY_COUNT + 1))
}

# 解析VMESS链接
parse_vmess() {
    local vmess_url="$1"
    local vmess_content=${vmess_url#vmess://}
    
    # 解码VMESS链接
    local decoded=$(decode_base64_url "$vmess_content")
    
    if [ -z "$decoded" ]; then
        echo "# Failed to decode VMESS link"
        return 1
    fi
    
    # 使用python解析JSON（如果可用）
    if command -v python3 >/dev/null 2>&1; then
        local parsed
        parsed=$(python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
    def get(key, default=""):
        value = data.get(key, default)
        return "" if value is None else str(value)
    fields = [
        get("add", ""),
        get("port", ""),
        get("id", ""),
        get("aid", "0"),
        get("net", "tcp"),
        get("type", "none"),
        get("host", ""),
        get("path", ""),
        get("tls", ""),
        get("ps", ""),
        get("scy", "auto"),
    ]
    print("\t".join(fields))
except Exception:
    print("ERROR")
' <<< "$decoded")
        
        if [ "$parsed" = "ERROR" ]; then
            echo "# Failed to parse VMESS JSON"
            return 1
        fi
        
        IFS=$'\t' read -r server port uuid aid network type host path tls name cipher <<< "$parsed"
    else
        echo "# Python3 not available for VMESS parsing"
        return 1
    fi
    
    # 生成代理名称
    if [ -z "$name" ]; then
        name="VMESS-${server}-${port}"
    fi
    
    # 检查重复名称并记录成功解析的代理名称
    name=$(register_proxy_name "$name")
    
    # 输出Clash格式配置
    cat << EOF
  - name: $(yaml_quote "$name")
    type: vmess
    server: $server
    port: $port
    uuid: $uuid
    alterId: $aid
    cipher: $cipher
    network: $network
EOF
    
    if [ -n "$tls" ] && [ "$tls" != "none" ]; then
        echo "    tls: true"
    fi
    
    if [ "$network" = "ws" ]; then
        echo "    ws-opts:"
        if [ -n "$path" ]; then
            echo "      path: $path"
        fi
        if [ -n "$host" ]; then
            echo "      headers:"
            echo "        Host: $host"
        fi
    fi
    
    PROXY_COUNT=$((PROXY_COUNT + 1))
}

# 智能引用代理名称，供转换器生成 proxy-groups 时使用
format_proxy_name() {
    local name="$1"
    local escaped_name="${name//\'/\'\'}"

    # 始终使用单引号包裹，避免逗号/括号/空格等字符破坏 YAML flow sequence 语法
    echo "'$escaped_name'"
}

# 从解析出的代理名列表生成固定的代理组配置
write_proxy_groups() {
    local output_file="$1"
    local formatted_names=""
    local group_members=""

    while IFS= read -r name; do
        if [ -n "$name" ]; then
            formatted_names="$formatted_names, $(format_proxy_name "$name")"
        fi
    done < "$TEMP_NAME_FILE"

    formatted_names="${formatted_names#, }"

    if [ -n "$formatted_names" ]; then
        group_members="自动选择, 故障转移, $formatted_names"
    else
        group_members="DIRECT"
        formatted_names="DIRECT"
    fi

    cat >> "$output_file" << EOF

proxy-groups:
    - { name: $PRIMARY_PROXY_GROUP, type: select, proxies: [$group_members] }
    - { name: 自动选择, type: url-test, proxies: [$formatted_names], url: 'http://www.gstatic.com/generate_204', interval: 86400 }
    - { name: 故障转移, type: fallback, proxies: [$formatted_names], url: 'http://www.gstatic.com/generate_204', interval: 7200 }
EOF
}

# 模板负责维护规则；若模板规则末尾没有 MATCH，转换器自动补上主代理组兜底规则
template_rules_end_with_match() {
    awk '
        /^rules:[[:space:]]*$/ { in_rules = 1; next }
        in_rules && $0 !~ /^[[:space:]]*($|#)/ { last = $0 }
        END {
            gsub(/^[[:space:]]*-[[:space:]]*/, "", last)
            gsub(/^['"'"']|['"'"']$/, "", last)
            exit(index(last, "MATCH,") == 1 ? 0 : 1)
        }
    ' "$TEMPLATE_FILE"
}

# 主转换函数
convert_subscription() {
    local input_file="$1"
    local output_file="$2"
    
    # 清理临时文件
    rm -f "$TEMP_NAME_FILE"
    touch "$TEMP_NAME_FILE"
    
    # 重置计数器
    PROXY_COUNT=0
    DUPLICATE_COUNT=0
    
    echo -e "${YELLOW}开始转换订阅链接...${NC}"
    
    # 读取原始配置文件
    if [ ! -f "$input_file" ]; then
        echo -e "${RED}错误：输入文件不存在 - $input_file${NC}"
        return 1
    fi
    
    # 备份原始文件
    cp "$input_file" "$RAW_CONFIG_FILE"
    
    # 检查文件是否是base64编码的订阅链接
    local temp_decoded="/tmp/decoded_subscription.txt"
    local raw_subscription
    raw_subscription=$(cat "$input_file")
    if decode_base64_url "$raw_subscription" > "$temp_decoded" 2>/dev/null && [ -s "$temp_decoded" ] && grep -Eq '^(ss|ssr|vless|vmess)://' "$temp_decoded"; then
        echo -e "${YELLOW}检测到base64编码的订阅链接，进行解码...${NC}"
        input_file="$temp_decoded"
    fi
    
    # 模板负责基础设置和规则；转换器只在明确标记处生成代理节点和代理组
    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo -e "${RED}错误：模板文件不存在 - $TEMPLATE_FILE${NC}"
        rm -f "$TEMP_NAME_FILE" "$temp_decoded"
        return 1
    fi
    if ! grep -Fxq "$INSERT_MARKER" "$TEMPLATE_FILE"; then
        echo -e "${RED}错误：模板缺少插入标记 - $INSERT_MARKER${NC}"
        rm -f "$TEMP_NAME_FILE" "$temp_decoded"
        return 1
    fi
    if ! grep -Eq '^rules:[[:space:]]*$' "$TEMPLATE_FILE"; then
        echo -e "${RED}错误：模板缺少 rules: 规则段 - $TEMPLATE_FILE${NC}"
        rm -f "$TEMP_NAME_FILE" "$temp_decoded"
        return 1
    fi

    # 先写入同目录临时文件，全部生成成功后再替换目标文件，避免留下半成品配置
    local output_dir
    local output_base
    local output_tmp
    output_dir=$(dirname "$output_file")
    output_base=$(basename "$output_file")
    output_tmp=$(mktemp "$output_dir/.${output_base}.tmp.XXXXXX") || {
        echo -e "${RED}错误：无法创建临时输出文件 - $output_dir${NC}"
        rm -f "$TEMP_NAME_FILE" "$temp_decoded"
        return 1
    }

    # 固定生成顺序 1/5：复制模板头部到插入点（不包含标记行）
    awk -v marker="$INSERT_MARKER" '$0 == marker { exit } { print }' "$TEMPLATE_FILE" > "$output_tmp"
    echo "" >> "$output_tmp"

    # 固定生成顺序 2/5：写入 proxies:
    echo "proxies:" >> "$output_tmp"
    
    # 创建临时文件存储未识别的协议
    local unrecognized_file="/tmp/unrecognized_protocols.txt"
    > "$unrecognized_file"
    
    # 固定生成顺序 3/5：逐条写入解析出的代理节点
    while IFS= read -r line; do
        # 跳过空行和注释
        [ -z "$line" ] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # 检测协议类型并解析
        if [[ "$line" =~ ^ss:// ]]; then
            parse_ss "$line" >> "$output_tmp"
        elif [[ "$line" =~ ^ssr:// ]]; then
            parse_ssr "$line" >> "$output_tmp"
        elif [[ "$line" =~ ^vless:// ]]; then
            parse_vless "$line" >> "$output_tmp"
        elif [[ "$line" =~ ^vmess:// ]]; then
            parse_vmess "$line" >> "$output_tmp"
        else
            echo "# 未识别的协议: $line" >> "$unrecognized_file"
        fi
    done < "$input_file"
    
    # 在代理配置结束后添加未识别的协议注释
    if [ -s "$unrecognized_file" ]; then
        echo "" >> "$output_tmp"
        echo "# 未识别的协议列表:" >> "$output_tmp"
        cat "$unrecognized_file" >> "$output_tmp"
        echo "" >> "$output_tmp"
    fi
    
    # 清理临时文件
    rm -f "$unrecognized_file"
    
    # 固定生成顺序 4/5：根据代理名列表生成 proxy-groups，不再从模板分段提取
    write_proxy_groups "$output_tmp"

    # 固定生成顺序 5/5：从模板复制 rules: 到文件末尾
    sed -n '/^rules:[[:space:]]*$/,$p' "$TEMPLATE_FILE" >> "$output_tmp"
    if ! template_rules_end_with_match; then
        echo "    - 'MATCH,$PRIMARY_PROXY_GROUP'" >> "$output_tmp"
    fi

    if ! mv "$output_tmp" "$output_file"; then
        echo -e "${RED}错误：无法写入输出文件 - $output_file${NC}"
        rm -f "$output_tmp" "$TEMP_NAME_FILE" "$temp_decoded"
        return 1
    fi

    # 清理临时文件
    rm -f "$TEMP_NAME_FILE"
    rm -f "$temp_decoded"
    
    echo -e "${GREEN}转换完成！${NC}"
    echo -e "${GREEN}共转换了 $PROXY_COUNT 个代理节点${NC}"
    
    # 保存解码后的配置文件
    cp "$output_file" "$DECODED_CONFIG_FILE"
    
    return 0
}

# 自动设置代理模式
set_proxy_mode() {
    local config_file="$1"
    local mode="${2:-rule}"  # 默认为rule模式
    local controller_url="http://127.0.0.1:${CONTROL_PORT}/configs"

    # 转换器可能在服务启动前运行；只有控制接口可用时才尝试设置模式。
    if ! curl -fsS --max-time 2 "$controller_url" >/dev/null 2>&1; then
        echo -e "${YELLOW}Mihomo 控制接口未就绪，跳过自动设置代理模式: $controller_url${NC}"
        return 1
    fi

    if curl -fsS --max-time 5 -X PUT "$controller_url" \
        -H "Content-Type: application/json" \
        -d "{\"mode\": \"$mode\"}" >/dev/null 2>&1; then
        echo -e "${GREEN}代理模式已设置为: $mode${NC}"
    else
        echo -e "${YELLOW}无法设置代理模式，请手动在面板中设置${NC}"
    fi
}
# 主函数
main() {
    local input_file="${1:-$RAW_CONFIG_FILE}"
    local output_file="${2:-$CONFIG_FILE}"
    
    echo -e "${YELLOW}启动自定义订阅转换器${NC}"
    
    # 检查输入文件
    if [ ! -f "$input_file" ]; then
        echo -e "${RED}错误：输入文件不存在 - $input_file${NC}"
        exit 1
    fi
    
    # 执行转换
    if convert_subscription "$input_file" "$output_file"; then
        echo -e "${GREEN}转换成功！输出文件: $output_file${NC}"
        
        # 设置代理模式
        set_proxy_mode "$output_file" "rule"
        
        exit 0
    else
        echo -e "${RED}转换失败！${NC}"
        exit 1
    fi
}

# 如果直接运行此脚本
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
