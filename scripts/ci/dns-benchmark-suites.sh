#!/usr/bin/env bash
set -euo pipefail

dns_bench_profile_suites() {
  local profile="$1"
  case "$profile" in
    quick)
      echo "control_dns_cache component_upstream_hotpath"
      ;;
    dns-module|full|all)
      echo "control_dns_cache component_upstream_hotpath"
      ;;
    *)
      return 1
      ;;
  esac
}

dns_bench_suite_package() {
  local suite="$1"
  case "$suite" in
    control_dns_cache)
      echo "./control"
      ;;
    component_upstream_hotpath)
      echo "./component/dns"
      ;;
    *)
      return 1
      ;;
  esac
}

dns_bench_suite_filter() {
  local suite="$1"
  case "$suite" in
    control_dns_cache)
      echo "^BenchmarkDnsCache_(FillInto|IncludeAnyIp|IncludeIp)$"
      ;;
    component_upstream_hotpath)
      echo "^BenchmarkUpstreamResolver_GetUpstream_(Serial|Parallel)$"
      ;;
    *)
      return 1
      ;;
  esac
}

dns_bench_suite_exclude() {
  local suite="$1"
  case "$suite" in
    control_dns_cache|component_upstream_hotpath)
      echo ""
      ;;
    *)
      return 1
      ;;
  esac
}

dns_bench_suite_overlay() {
  local suite="$1"
  case "$suite" in
    control_dns_cache|component_upstream_hotpath)
      echo "scripts/ci/benchmarks"
      ;;
    *)
      return 1
      ;;
  esac
}
