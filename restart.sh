#!/bin/bash

# Copyright (c) 2024 VocabVictors
# Author: VocabVictors <w93854@gmail.com>
# License: MIT
# Project: clash-for-AutoDL
# Description: Clash proxy service restart script for AutoDL environment

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONTROL_PORT="9090"

success() {
  echo -e "${GREEN}[  OK  ]${NC}"
  return 0
}

failure() {
  local rc=$?
  echo -e "${RED}[FAILED]${NC}"
  [ -x /bin/plymouth ] && /bin/plymouth --details
  return $rc
}

action() {
  local STRING=$1
  echo -n "$STRING "
  shift
  "$@" && success || failure
  local rc=$?
  echo
  return $rc
}

if_success() {
  local message_success=$1
  local message_failure=$2
  local return_status=${3:-0}

  if [ "$return_status" -eq 0 ]; then
    action "$message_success" /bin/true
  else
    action "$message_failure" /bin/false
    exit 1
  fi
}

Server_Dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
Conf_Dir="$Server_Dir/conf"
Log_Dir="$Server_Dir/logs"
PID_FILE="$Server_Dir/clash.pid"

[[ ! -d "$Conf_Dir" ]] && mkdir -p "$Conf_Dir"
[[ ! -d "$Log_Dir" ]] && mkdir -p "$Log_Dir"
[[ ! -d "$Server_Dir/bin" ]] && mkdir -p "$Server_Dir/bin"

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

close_clash_service() {
  if ! is_managed_service_running; then
    echo "未发现由本项目 PID 文件管理的 Clash/Mihomo 进程。"
    if_success "服务关闭成功！" "服务关闭失败！" 0
    return 0
  fi

  local pid
  pid=$(cat "$PID_FILE")
  echo "正在关闭由本项目管理的服务 (PID: $pid)..."
  kill "$pid" &>/dev/null || true

  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      if_success "服务关闭成功！" "服务关闭失败！" 0
      return 0
    fi
    sleep 1
  done

  echo "进程未在超时时间内退出，尝试强制关闭 (PID: $pid)..."
  kill -9 "$pid" &>/dev/null || true
  rm -f "$PID_FILE"
  if_success "服务关闭成功！" "服务关闭失败！" 0
}

get_cpu_arch() {
  if /bin/arch &>/dev/null; then
    /bin/arch
  elif /usr/bin/arch &>/dev/null; then
    /usr/bin/arch
  elif /bin/uname -m &>/dev/null; then
    /bin/uname -m
  else
    echo -e "${RED}[ERROR] Failed to obtain CPU architecture!${NC}"
    exit 1
  fi
}

wait_for_service_ready() {
  local pid="$1"
  local controller_url="http://127.0.0.1:${CONTROL_PORT}/configs"

  for _ in $(seq 1 15); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo -e "${RED}服务进程已退出，请检查日志: $Log_Dir/${2:-mihomo.log}${NC}"
      return 1
    fi

    if curl -fsS --max-time 2 "$controller_url" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  echo -e "${RED}控制接口未就绪: $controller_url${NC}"
  echo -e "${RED}请检查日志文件: $Log_Dir/${2:-mihomo.log}${NC}"
  return 1
}

start_binary() {
  local binary_path="$1"
  local log_name="$2"

  if [ ! -x "$binary_path" ]; then
    echo -e "${RED}错误: 二进制文件不可执行: $binary_path${NC}"
    return 1
  fi

  nohup "$binary_path" -d "$Conf_Dir" > "$Log_Dir/$log_name" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  if wait_for_service_ready "$pid" "$log_name"; then
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  return 1
}

start_clash_service() {
  local cpu_arch
  cpu_arch=$(get_cpu_arch)
  local mihomo_binary
  local clash_binary

  case $cpu_arch in
    x86_64|amd64)
      mihomo_binary="mihomo-linux-amd64"
      clash_binary="clash-linux-amd64"
      ;;
    aarch64|arm64)
      mihomo_binary="mihomo-linux-arm64"
      clash_binary="clash-linux-arm64"
      ;;
    armv7)
      mihomo_binary="mihomo-linux-armv7"
      clash_binary="clash-linux-armv7"
      ;;
    *)
      echo -e "${RED}[ERROR] Unsupported CPU Architecture: $cpu_arch${NC}"
      exit 1
      ;;
  esac

  if [ ! -f "$Conf_Dir/config.yaml" ]; then
    echo -e "${RED}错误: 配置文件不存在，请先运行 start.sh${NC}"
    exit 1
  fi

  local return_status=1
  if [ -f "$Server_Dir/bin/$mihomo_binary" ]; then
    echo "使用 Mihomo 启动服务..."
    start_binary "$Server_Dir/bin/$mihomo_binary" "mihomo.log"
    return_status=$?
  elif [ -f "$Server_Dir/bin/$clash_binary" ]; then
    echo "使用 Clash 启动服务..."
    start_binary "$Server_Dir/bin/$clash_binary" "clash.log"
    return_status=$?
  else
    echo -e "${RED}错误: 找不到可执行的二进制文件${NC}"
    return_status=1
  fi

  if_success "服务启动成功！" "服务启动失败！" "$return_status"
}

check_service_status() {
  if is_managed_service_running; then
    local pid
    pid=$(cat "$PID_FILE")
    if curl -fsS --max-time 2 "http://127.0.0.1:${CONTROL_PORT}/configs" >/dev/null 2>&1; then
      echo -e "${GREEN}服务运行中且控制接口可用 (PID: $pid)${NC}"
      return 0
    fi
    echo -e "${RED}服务进程存在，但控制接口不可用 (PID: $pid)${NC}"
    return 1
  fi

  echo -e "${RED}服务未运行${NC}"
  return 1
}

show_service_info() {
  echo "========================================="
  echo "Clash for AutoDL - 服务重启"
  echo "========================================="
  echo "配置目录: $Conf_Dir"
  echo "日志目录: $Log_Dir"
  echo "二进制目录: $Server_Dir/bin"
  echo "PID 文件: $PID_FILE"
  echo "控制端口: $CONTROL_PORT"
  echo ""
}

main() {
  show_service_info

  echo "正在重启Clash服务..."
  close_clash_service

  sleep 1
  [[ ! -d "$Log_Dir" ]] && mkdir -p "$Log_Dir"

  start_clash_service

  echo ""
  echo "检查服务状态..."
  check_service_status

  if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}服务重启成功！${NC}"
    echo "提示: 使用 'proxy_on' 开启代理"
  else
    echo -e "\n${RED}服务重启失败！${NC}"
    echo "请检查日志文件: $Log_Dir/"
    exit 1
  fi
}

main
