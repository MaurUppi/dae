#!/usr/bin/env bash
set -euo pipefail

dns_bench_profile_suites() {
  local profile="$1"
  case "$profile" in
    quick)
      echo "control_core_flow component_upstream_hotpath"
      ;;
    dns-module|full|all)
      echo "control_core_flow control_singleflight_scale control_cache_hotpath control_cache_structures component_upstream_hotpath"
      ;;
    *)
      return 1
      ;;
  esac
}

dns_bench_suite_package() {
  local suite="$1"
  case "$suite" in
    control_core_flow|control_singleflight_scale|control_cache_hotpath|control_cache_structures)
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
    control_core_flow)
      echo "^Benchmark(PipelinedConn_Sequential|PipelinedConn_Concurrent|DnsController_Singleflight)$"
      ;;
    control_singleflight_scale)
      echo "^Benchmark(AsyncCacheWithSingleflight|SingleflightOverhead|HighQpsScenario|RealisticDnsQuery)$"
      ;;
    control_cache_hotpath)
      echo "^BenchmarkDnsCache_(PackedResponse|PackedResponse_Parallel|FillInto_Pack|FillInto_Pack_Parallel|GetPackedResponseWithApproximateTTL|GetPackedResponseWithApproximateTTL_Parallel|SyncMapLookup|SyncMapLookup_Parallel)$"
      ;;
    control_cache_structures)
      echo "^BenchmarkDnsCache_(SyncMap|SyncMap_Parallel|CacheKeyGeneration|CacheKeyGeneration_Parallel|BufferPool|BufferPool_Parallel|MakeCopy|MakeCopy_Parallel|MultipleAnswers|FillIntoWithTTL|FillIntoWithTTL_Parallel)$"
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
    control_core_flow|control_singleflight_scale|control_cache_hotpath|control_cache_structures)
      echo "control/tcp_test.go,control/tcp_splice_bench_test.go"
      ;;
    component_upstream_hotpath)
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
    component_upstream_hotpath)
      echo "scripts/ci/benchmarks"
      ;;
    control_core_flow|control_singleflight_scale|control_cache_hotpath|control_cache_structures)
      echo ""
      ;;
    *)
      return 1
      ;;
  esac
}
