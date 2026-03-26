#!/bin/bash

# 获取脚本工作目录绝对路径
export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
Log_Dir="$Server_Dir/logs"
PID_FILE="$Log_Dir/mihomo.pid"

# 关闭监视模式,不再报告后台作业状态
set +m

# 自定义函数

# 显示成功消息
success() {
  echo -en "\033[60G[\033[1;32m  OK  \033[0;39m]\r"
  return 0
}

# 显示失败消息
failure() {
  local rc=$?
  echo -en "\033[60G[\033[1;31mFAILED\033[0;39m]\r"
  [ -x /bin/plymouth ] && /bin/plymouth --details
  return $rc
}

# 执行操作并显示结果
action() {
  local STRING=$1
  echo -n "$STRING "
  shift
  "$@" && success "$STRING" || failure "$STRING"
  local rc=$?
  echo
  return $rc
}

# 判断命令是否正常执行
if_success() {
  local ReturnStatus=${3:-0}  # 如果 \$3 未设置或为空，则默认为 0
  if [ "$ReturnStatus" -eq 0 ]; then
    action "$1" /bin/true
  else
    action "$2" /bin/false
    exit 1
  fi
}

# 安全删除文件
safe_remove() {
  local file="$1"
  if [ -f "$file" ]; then
    rm "$file"
    echo "已删除文件: $file"
  else
    echo "文件不存在,跳过删除: $file"
  fi
}

collect_runtime_pids() {
  local pid pids

  if [ -f "$PID_FILE" ]; then
    pid="$(tr -cd '0-9' < "$PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi

  pids="$(pgrep -f 'mihomo-linux|mihomo|clash-linux' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$pids" ]; then
    echo "$pids"
    return 0
  fi

  return 1
}

# 主要操作

# 关闭clash服务
Text1="clash/mihomo 进程关闭成功！"
Text2="clash/mihomo 进程关闭失败！"
PIDS="$(collect_runtime_pids || true)"
ReturnStatus=0
if [ -n "$PIDS" ]; then
  kill $PIDS 2>/dev/null || ReturnStatus=$?
  sleep 1
  if pgrep -f 'mihomo-linux|mihomo|clash-linux' >/dev/null 2>&1; then
    kill -9 $PIDS 2>/dev/null || true
  fi
fi
rm -f "$PID_FILE"
if_success "$Text1" "$Text2" "$ReturnStatus"

# 定义路径变量
Conf_Dir="$Server_Dir/conf"

# 删除配置文件和日志
safe_remove "$Conf_Dir/config.yaml"
safe_remove "$Conf_Dir/cache.db"
rm -rf "$Log_Dir"

# 清除环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY

# 从 .bashrc 中删除函数和相关行
functions_to_remove=("proxy_on" "proxy_off" "shutdown_system")
for func in "${functions_to_remove[@]}"; do
  sed -i -E "/^function[[:space:]]+${func}[[:space:]]*()/,/^}$/d" ~/.bashrc
done

sed -i '/^# 开启系统代理/d; /^# 关闭系统代理/d; /^# 新增关闭系统函数/d; /^# 检查clash进程是否正常启动/d; /proxy_on/d; /^#.*proxy_on/d' ~/.bashrc
sed -i '/^$/N;/^\n$/D' ~/.bashrc

# 重新加载.bashrc文件
source ~/.bashrc

echo -e "\033[32m \n[√]服务关闭成功\n \033[0m"

# 询问用户是否删除工作目录
read -p "是否删除工作目录 ${Server_Dir}? [y/n]: " answer
case $answer in
  [Yy]* )
    echo "正在删除工作目录 ${Server_Dir}..."
    rm -rf "$Server_Dir"
    echo "工作目录已删除。"
    ;;
  [Nn]* )
    echo "未删除工作目录。"
    ;;
  * )
    echo "请输入 'y' 或 'n'。"
    ;;
esac

# 恢复监视模式
set -m
