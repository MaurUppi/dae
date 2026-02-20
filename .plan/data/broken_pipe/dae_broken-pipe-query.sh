#!/bin/bash

# 默认配置
TIME_RANGE="12h"
TOP_N=0  # 0表示显示全部
OUTPUT_FORMAT="table"  # table 或 csv

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -since|--since)
            TIME_RANGE="$2"
            shift 2
            ;;
        -top|--top)
            TOP_N="$2"
            shift 2
            ;;
        -csv|--csv)
            OUTPUT_FORMAT="csv"
            shift
            ;;
        -h|--help)
            cat << EOF
用法: $0 [选项]

选项:
  -since TIME_RANGE   指定查询时间范围（默认: 12h）
  -top N              只显示前 N 个结果（默认: 全部）
  -csv                以 CSV 格式输出
  -h, --help          显示此帮助信息

时间格式:
  30s    - 30秒
  30m    - 30分钟
  12h    - 12小时
  7d     - 7天
  1w     - 1周

示例:
  $0                      # 默认12小时，表格格式
  $0 -since 24h           # 最近24小时
  $0 -since 7d -top 20    # 最近7天，只显示前20个
  $0 -since 1d -csv       # 最近1天，CSV格式输出

EOF
            exit 0
            ;;
        *)
            echo "❌ 未知参数: $1"
            echo "使用 -h 或 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 验证时间格式
if ! [[ "$TIME_RANGE" =~ ^[0-9]+[smhdw]$ ]]; then
    echo "❌ 错误：时间格式不正确"
    echo "正确格式: 数字+单位 (s=秒, m=分钟, h=小时, d=天, w=周)"
    exit 1
fi

# 验证 TOP_N
if ! [[ "$TOP_N" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误：-top 参数必须是正整数"
    exit 1
fi

# 开始分析
if [ "$OUTPUT_FORMAT" = "csv" ]; then
    echo "count,ip:port"
else
    echo "=== DAE Broken Pipe 快速分析 ==="
    echo ""
    echo "📊 正在统计最近 ${TIME_RANGE} 的数据..."
fi

TOTAL_COUNT=$(journalctl -u dae.service --since "-${TIME_RANGE}" -g "broken pipe" | wc -l)

if [ "$TOTAL_COUNT" -eq 0 ]; then
    if [ "$OUTPUT_FORMAT" != "csv" ]; then
        echo "✅ 未发现 broken pipe 错误（最近 ${TIME_RANGE}）"
    fi
    exit 0
fi

if [ "$OUTPUT_FORMAT" != "csv" ]; then
    echo "📊 最近 ${TIME_RANGE} 统计（共 ${TOTAL_COUNT} 条 broken pipe 错误）"
    echo ""
fi

# 统计并显示
if [ "$TOP_N" -gt 0 ]; then
    RESULT=$(journalctl -u dae.service --since "-${TIME_RANGE}" -g "broken pipe" -o cat | \
             awk 'match($0, /->([0-9.]+:[0-9]+)/, a) {ip[a[1]]++} END {for (i in ip) print ip[i], i}' | \
             sort -rn | head -n "$TOP_N")
else
    RESULT=$(journalctl -u dae.service --since "-${TIME_RANGE}" -g "broken pipe" -o cat | \
             awk 'match($0, /->([0-9.]+:[0-9]+)/, a) {ip[a[1]]++} END {for (i in ip) print ip[i], i}' | \
             sort -rn)
fi

# 输出格式化
if [ "$OUTPUT_FORMAT" = "csv" ]; then
    echo "$RESULT" | awk '{print $1 "," $2}'
else
    echo "$RESULT" | awk '{printf "%6d  %s\n", $1, $2}'
    echo ""
    UNIQUE_COUNT=$(echo "$RESULT" | wc -l)
    echo "📌 统计摘要："
    echo "   - 总错误数: ${TOTAL_COUNT}"
    echo "   - 唯一目标: ${UNIQUE_COUNT} 个"
    if [ "$TOP_N" -gt 0 ]; then
        echo "   - 显示前 ${TOP_N} 个"
    fi
    echo ""
    echo "💡 提示："
    echo "   - 使用 -top 20 仅显示前20个结果"
    echo "   - 使用 -csv 导出为CSV格式"
    echo "   - 使用 -h 查看完整帮助"
fi