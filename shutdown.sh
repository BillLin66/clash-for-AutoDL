#!/bin/bash

# 获取脚本工作目录绝对路径
Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Conf_Dir="$Server_Dir/conf"
Log_Dir="$Server_Dir/logs"
PID_FILE="$Server_Dir/clash.pid"

# 关闭监视模式,不再报告后台作业状态
set +m

# 自定义函数
success() {
  echo -en "\033[60G[\033[1;32m  OK  \033[0;39m]\r"
  return 0
}

failure() {
  local rc=$?
  echo -en "\033[60G[\033[1;31mFAILED\033[0;39m]\r"
  [ -x /bin/plymouth ] && /bin/plymouth --details
  return $rc
}

action() {
  local STRING=$1
  echo -n "$STRING "
  shift
  "$@" && success "$STRING" || failure "$STRING"
  local rc=$?
  echo
  return $rc
}

if_success() {
  local ReturnStatus=${3:-0}
  if [ "$ReturnStatus" -eq 0 ]; then
    action "$1" /bin/true
  else
    action "$2" /bin/false
    exit 1
  fi
}

safe_remove() {
  local file="$1"
  if [ -f "$file" ]; then
    rm "$file"
    echo "已删除文件: $file"
  else
    echo "文件不存在,跳过删除: $file"
  fi
}

is_managed_service_running() {
  if [ ! -f "$PID_FILE" ]; then
    return 1
  fi

  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  rm -f "$PID_FILE"
  return 1
}

stop_managed_service() {
  if ! is_managed_service_running; then
    echo "未发现由本项目 PID 文件管理的 Clash/Mihomo 进程。"
    return 0
  fi

  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" &>/dev/null || true

  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      return 0
    fi
    sleep 1
  done

  echo "进程未在超时时间内退出，尝试强制关闭 (PID: $pid)..."
  kill -9 "$pid" &>/dev/null || true
  rm -f "$PID_FILE"
  return 0
}

# 关闭clash服务：仅处理当前项目 PID 文件记录的进程，避免误杀其他实例
Text1="clash进程关闭成功！"
Text2="clash进程关闭失败！"
stop_managed_service
ReturnStatus=$?
if_success "$Text1" "$Text2" "$ReturnStatus"

# 删除配置文件和日志
safe_remove "$Conf_Dir/config.yaml"
safe_remove "$Conf_Dir/cache.db"
rm -rf "$Log_Dir"

# 清除环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY

# 从 .bashrc 中删除函数和相关行
functions_to_remove=("proxy_on" "proxy_off" "shutdown_system")
for func in "${functions_to_remove[@]}"; do
  sed -i -E "/^function[[:space:]]+${func}[[:space:]]*\(\)/,/^}$/d" ~/.bashrc
done

sed -i '/^# 开启系统代理/d; /^# 关闭系统代理/d; /^# 新增关闭系统函数/d; /^# 关闭系统函数/d; /^# 检查clash进程是否正常启动/d; /proxy_on/d; /^#.*proxy_on/d' ~/.bashrc
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
