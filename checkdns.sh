#!/bin/bash
set -euo pipefail

# 将CONFIG_FILE设置为脚本所在目录下的conf.trj
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_FILE="$SCRIPT_DIR/conf.trj"

# 创建logs目录用于存储运行日志
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/script_log_$(date +'%Y-%m-%d').log"
MATCH_MISS_FILE="$LOG_DIR/match_mis_log_$(date +'%Y-%m-%d').log"
RETAIN_DAYS=300

# 创建日志目录（如果不存在）
mkdir -p "$LOG_DIR"

# 解析选项
parse_options() {
  print_all=false  # 初始化为 false
  while getopts "ah" opt; do
    case $opt in
      a)
        print_all=true  # 如果提供了 -a 选项，设置为 true
        ;;
      h)
        show_help
        exit 0
        ;;
      \?)
        echo "无效选项: -$OPTARG" >&2
        show_help
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))
}

# 日志函数
log() {
  local message="$1"
  local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  if [ "$2" == "true" ]; then
    printf "[%s] %s\n" "$timestamp" "$message" >> "$LOG_FILE"
  else
    echo "$message" >> "$LOG_FILE"
  fi
}

ip_to_long() {
  # 接受一个参数，即 IPv4 地址
  local ip="$1"
  # 初始化一个变量用于存储转换后的长整数
  local ip_long=0
  
  # 使用点号作为分隔符，将 IPv4 地址分割成四个部分，并存储在数组 ip_parts 中  
  IFS='.' read -ra ip_parts <<< "$ip"
  # 遍历每个部分
  for ((i = 0; i < 4; i++)); do
    # 将当前部分的值左移8位（一个字节），然后与 ip_long 进行按位或操作
    ip_long=$((ip_long << 8 | ip_parts[i]))
  done

  # 输出转换后的长整数
  echo "$ip_long"
}

resolve_domain_ips() {
  # 接受一个 DNS 服务器地址作为参数
  local dns_server="$1"
  # 接受一个要查询的域名作为参数
  local domain="$2"
  # 使用 dig 命令查询域名信息，并将输出保存在变量 output 中
  local output=$(dig +short @"$dns_server" "$domain")

  # 使用 grep 命令从提取的结果中匹配并提取出 IP 地址
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$output"
}

parse_cidr() {
  local cidr="$1"
  IFS=$' \t\n/' read -r subnet_ip mask_length <<< "$cidr"
  echo "$subnet_ip $mask_length"
}

is_in_subnet() {
  local check_ip="$1"
  local mask_length="$2"
  local subnet_ip="$3"
  local check_ip_long=$(ip_to_long "$check_ip")
  local subnet_ip_long=$(ip_to_long "$subnet_ip")
  local mask=$((0xFFFFFFFF << (32 - mask_length)))
  local network_ip_long=$((subnet_ip_long & mask))
  local broadcast_ip_long=$((network_ip_long | (~mask & 0xFFFFFFFF)))
  ((check_ip_long >= network_ip_long && check_ip_long <= broadcast_ip_long))
}

check_domain() {
  local domain="$1"
  local ip_address="$2"
  shift 2

  for subnet in "$@"; do
    local subnet_ip=""
    local mask_length=""
    IFS=' ' read -r subnet_ip mask_length <<< "$(parse_cidr "$subnet")"

    if is_in_subnet "$ip_address" "$mask_length" "$subnet_ip"; then
      log "$domain $ip_address 命中" "false"
      if [ "$print_all" == "true" ]; then
        echo "$domain $ip_address 命中"
      fi
      return
    fi
  done
  log "$domain $ip_address 未命中" "false"
  echo "$domain $ip_address 未命中"
}

read_config() {
  local config_file="$1"
  local dns_servers=()
  local domains=()
  local subnets=()

  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      "dns_server:"*)
        dns_servers+=("${line#dns_server:}")
        ;;
      "domain:"*)
        domains+=("${line#domain:}")
        ;;
      "subnet:"*)
        subnets+=("${line#subnet:}")
        ;;
    esac
  done < "$config_file"

  echo "${dns_servers[@]}|${domains[@]}|${subnets[@]}"
}

iterate_domains() {
  local config_data="$1"
  IFS='|' read -r -a config_array <<< "$config_data"
  local dns_servers=(${config_array[0]})
  local domains=(${config_array[1]})
  local subnets=(${config_array[2]})

  for ((i = 0; i < ${#domains[@]}; i+=2)); do
    domain="${domains[i]}"
    status="${domains[i+1]}"

    dns_server="${dns_servers[0]}"

    if [ "$status" -ge 0 ] && [ "$status" -lt ${#dns_servers[@]} ]; then
      dns_server="${dns_servers[status]}"
    else
      echo "Invalid status for domain $domain: $status"
    fi

    resolved_ips=($(resolve_domain_ips "$dns_server" "$domain"))

    for ip_address in "${resolved_ips[@]}"; do
      check_domain "$domain" "$ip_address" "${subnets[@]}"
    done
  done
}

cleanup_old_logs() {
  find "$LOG_DIR" -type f -mtime +$RETAIN_DAYS -exec rm {} \;
}

# 显示帮助信息
show_help() {
  echo "用法: $(basename "$0") [-a]"
  echo "  -a    打印所有命中的记录"
  echo "  -h    显示帮助信息"
}

main() {
  log "脚本开始执行" "true"
  config_data=$(read_config "$CONFIG_FILE")
  iterate_domains "$config_data"
  log "脚本执行完成" "true"
}

# 主要脚本逻辑
parse_options "$@"  # 解析选项
main "$@"
#main "$@" >> "$MATCH_MISS_FILE"
cleanup_old_logs
