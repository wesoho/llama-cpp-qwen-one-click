#!/bin/bash
#===============================================================================
# auto_tune.sh — 自动性能调优脚本
#
# 功能：
#   1. 探测硬件环境（CPU 核心数、内存、架构、GPU）
#   2. 对每个已下载模型，用 llama-bench 快速测试不同线程数
#   3. 对 ≥1.5B 模型，额外测试 KV 缓存量化 (q4_0 / q8_0)
#   4. 选出最优参数，写入 JSON 配置文件
#   5. Web 服务读取该配置，自动应用最优参数
#
# 用法：
#   ./auto_tune.sh                    # 调优所有已下载模型
#   ./auto_tune.sh /path/to/model.gguf  # 调优指定模型
#
# 输出：/root/.llm_optimized_config.json
#===============================================================================

set -e

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
print_info()    { echo -e "${BLUE}[TUNE]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()    { echo -e "\n${CYAN}===== $1 =====${NC}"; }

# ── 路径配置 ──
INSTALL_DIR="${INSTALL_DIR:-/root}"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
LLAMA_BENCH="${LLAMA_DIR}/build/bin/llama-bench"
MODEL_DIR="${INSTALL_DIR}/models"
CONFIG_FILE="${INSTALL_DIR}/.llm_optimized_config.json"

# ── 硬件探测 ──
ARCH=$(uname -m)
CPU_CORES=$(nproc 2>/dev/null || echo 4)
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_AVAIL_GB=$(echo "scale=1; ${MEM_AVAIL_KB}/1048576" | bc 2>/dev/null || echo "7.0")

# GPU 检测
HAS_GPU=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    HAS_GPU=true
fi

# ── 模型定义 ──
declare -A MODEL_FILES
MODEL_FILES[0.5b]="qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODEL_FILES[1.5b]="qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_FILES[3b]="qwen2.5-3b-instruct-q4_k_m.gguf"

declare -A MODEL_NAMES
MODEL_NAMES[0.5b]="Qwen2.5-0.5B-Instruct"
MODEL_NAMES[1.5b]="Qwen2.5-1.5B-Instruct"
MODEL_NAMES[3b]="Qwen2.5-3B-Instruct"

declare -A MODEL_SIZES
MODEL_SIZES[0.5b]="469 MB"
MODEL_SIZES[1.5b]="1.1 GB"
MODEL_SIZES[3b]="2.0 GB"

# 模型参数量（用于决定是否测试 KV 量化）
declare -A MODEL_PARAMS
MODEL_PARAMS[0.5b]="0.5"
MODEL_PARAMS[1.5b]="1.5"
MODEL_PARAMS[3b]="3.0"

#===============================================================================
# 生成候选线程数
# 策略：基于核心数生成 3-5 个候选值，绝不用满全部核心
#===============================================================================
gen_thread_candidates() {
    local cores=$1
    local candidates=()

    # 候选 1: cores // 2 （半核，适合小模型）
    local half=$((cores / 2))
    [ "$half" -ge 2 ] && candidates+=("$half")

    # 候选 2: cores - 2 （留 2 核给 OS，适合大模型）
    local leave2=$((cores - 2))
    [ "$leave2" -ge 2 ] && candidates+=("$leave2")

    # 候选 3: cores - 1 （留 1 核给 OS）
    local leave1=$((cores - 1))
    [ "$leave1" -ge 2 ] && candidates+=("$leave1")

    # 候选 4: 4 （通用最优值，很多模型在 4 线程表现好）
    [ "$cores" -ge 4 ] && candidates+=("4")

    # 候选 5: 3 （原脚本默认值，作为对照）
    candidates+=("3")

    # 去重 + 排序 + 限制最大值不超过 cores-1
    local max_t=$((cores - 1))
    echo "${candidates[@]}" | tr ' ' '\n' | sort -n | uniq | \
        awk -v max="$max_t" '$1 >= 2 && $1 <= max' | head -5
}

#===============================================================================
# 运行单次基准测试，返回生成速度 (tg)
#===============================================================================
run_bench_tg() {
    local model_path="$1"
    local threads="$2"
    shift 2
    local extra_opts="$@"  # KV cache opts etc.

    # 用短测试 (32 tokens) 快速评估
    local result
    result=$(timeout 45 "${LLAMA_BENCH}" \
        -m "${model_path}" \
        -t "${threads}" \
        -p 32 -n 32 \
        -ngl 0 \
        ${extra_opts} \
        2>/dev/null | grep "tg32" | grep -oP 'tg32\s*\|\s*\K[\d.]+' | head -1)

    echo "${result:-0}"
}

run_bench_pp() {
    local model_path="$1"
    local threads="$2"
    shift 2
    local extra_opts="$@"

    local result
    result=$(timeout 45 "${LLAMA_BENCH}" \
        -m "${model_path}" \
        -t "${threads}" \
        -p 32 -n 32 \
        -ngl 0 \
        ${extra_opts} \
        2>/dev/null | grep "pp32" | grep -oP 'pp32\s*\|\s*\K[\d.]+' | head -1)

    echo "${result:-0}"
}

#===============================================================================
# 对单个模型进行调优
#===============================================================================
tune_model() {
    local model_id="$1"
    local model_file="${MODEL_FILES[$model_id]}"
    local model_path="${MODEL_DIR}/${model_file}"
    local model_name="${MODEL_NAMES[$model_id]}"
    local model_params="${MODEL_PARAMS[$model_id]}"

    if [ ! -f "${model_path}" ]; then
        print_warn "${model_name}: 模型文件不存在，跳过"
        return 1
    fi

    if [ ! -f "${LLAMA_BENCH}" ]; then
        print_error "llama-bench 不存在: ${LLAMA_BENCH}"
        return 1
    fi

    print_step "调优 ${model_name} (${model_id})"
    print_info "文件: ${model_path}"
    print_info "参数量: ${model_params}B"

    # 生成候选线程数
    local thread_candidates
    thread_candidates=$(gen_thread_candidates "${CPU_CORES}")
    print_info "候选线程数: $(echo ${thread_candidates} | tr '\n' ' ')"

    local best_tg=0
    local best_threads=0
    local best_kv=""
    local best_pp=0

    # 测试不同线程数（无 KV 量化基线）
    for t in ${thread_candidates}; do
        print_info "  测试 t=${t} (基线)..."
        local tg pp
        tg=$(run_bench_tg "${model_path}" "${t}")
        pp=$(run_bench_pp "${model_path}" "${t}")
        print_info "    → tg=${tg} t/s, pp=${pp} t/s"

        if (( $(echo "${tg} > ${best_tg}" | bc -l 2>/dev/null || echo 0) )); then
            best_tg=${tg}
            best_threads=${t}
            best_kv=""
            best_pp=${pp}
        fi
    done

    # 对 ≥1.5B 模型，测试 KV 缓存量化
    if (( $(echo "${model_params} >= 1.5" | bc -l 2>/dev/null || echo 0) )); then
        print_info "测试 KV 缓存量化 (使用最优线程 t=${best_threads})..."

        for kv in "q4_0" "q8_0"; do
            print_info "  测试 KV=${kv}..."
            local tg pp
            tg=$(run_bench_tg "${model_path}" "${best_threads}" "-ctk" "${kv}" "-ctv" "${kv}")
            pp=$(run_bench_pp "${model_path}" "${best_threads}" "-ctk" "${kv}" "-ctv" "${kv}")
            print_info "    → tg=${tg} t/s, pp=${pp} t/s"

            if (( $(echo "${tg} > ${best_tg}" | bc -l 2>/dev/null || echo 0) )); then
                best_tg=${tg}
                best_kv="${kv}"
                best_pp=${pp}
            fi
        done
    fi

    # batch_threads: 用更多线程处理 prompt（但不超过 cores-1）
    local batch_threads=$((CPU_CORES > 2 ? CPU_CORES - 1 : CPU_CORES))

    print_success "${model_name} 最优配置:"
    print_info "  线程: ${best_threads}"
    print_info "  批处理线程: ${batch_threads}"
    print_info "  KV 缓存: ${best_kv:-无}"
    print_info "  生成速度: ${best_tg} t/s"
    print_info "  Prompt 速度: ${best_pp} t/s"

    # 输出 JSON 片段到临时文件
    local kv_json="null"
    [ -n "${best_kv}" ] && kv_json="\"${best_kv}\""

    echo "  \"${model_id}\": {
    \"name\": \"${model_name}\",
    \"file\": \"${model_path}\",
    \"size\": \"${MODEL_SIZES[$model_id]}\",
    \"threads\": ${best_threads},
    \"batch_threads\": ${batch_threads},
    \"batch\": 512,
    \"ctx\": 2048,
    \"ngl\": 0,
    \"kv_cache\": ${kv_json},
    \"gen_speed\": ${best_tg},
    \"prompt_speed\": ${best_pp},
    \"tuned\": true
  }" >> "${CONFIG_FILE}.fragment.${model_id}"
}

#===============================================================================
# 主流程
#===============================================================================
print_step "自动性能调优"
print_info "架构: ${ARCH}"
print_info "CPU 核心: ${CPU_CORES}"
print_info "可用内存: ${MEM_AVAIL_GB} GB"
print_info "GPU: ${HAS_GPU}"
print_info "llama-bench: ${LLAMA_BENCH}"

if [ ! -f "${LLAMA_BENCH}" ]; then
    print_warn "llama-bench 未找到，使用启发式默认参数"
    # 生成启发式配置
    heuristic_threads=$((CPU_CORES > 4 ? 4 : CPU_CORES - 1))
    [ "$heuristic_threads" -lt 1 ] && heuristic_threads=1
    heuristic_batch=$((CPU_CORES > 2 ? CPU_CORES - 1 : CPU_CORES))

    cat > "${CONFIG_FILE}" << EOF
{
  "hardware": {
    "arch": "${ARCH}",
    "cores": ${CPU_CORES},
    "mem_gb": ${MEM_AVAIL_GB},
    "gpu": ${HAS_GPU}
  },
  "tuned": false,
  "tune_method": "heuristic",
  "models": {
    "0.5b": {
      "name": "Qwen2.5-0.5B-Instruct",
      "file": "${MODEL_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf",
      "size": "469 MB",
      "threads": ${heuristic_threads},
      "batch_threads": ${heuristic_batch},
      "batch": 512, "ctx": 2048, "ngl": 0,
      "kv_cache": null,
      "gen_speed": 0, "prompt_speed": 0,
      "tuned": false
    },
    "1.5b": {
      "name": "Qwen2.5-1.5B-Instruct",
      "file": "${MODEL_DIR}/qwen2.5-1.5b-instruct-q4_k_m.gguf",
      "size": "1.1 GB",
      "threads": $((CPU_CORES > 6 ? 6 : heuristic_threads)),
      "batch_threads": ${heuristic_batch},
      "batch": 512, "ctx": 2048, "ngl": 0,
      "kv_cache": "q8_0",
      "gen_speed": 0, "prompt_speed": 0,
      "tuned": false
    },
    "3b": {
      "name": "Qwen2.5-3B-Instruct",
      "file": "${MODEL_DIR}/qwen2.5-3b-instruct-q4_k_m.gguf",
      "size": "2.0 GB",
      "threads": $((CPU_CORES > 6 ? 6 : heuristic_threads)),
      "batch_threads": ${heuristic_batch},
      "batch": 512, "ctx": 2048, "ngl": 0,
      "kv_cache": "q4_0",
      "gen_speed": 0, "prompt_speed": 0,
      "tuned": false
    }
  }
}
EOF
    print_success "启发式配置已写入: ${CONFIG_FILE}"
    cat "${CONFIG_FILE}"
    exit 0
fi

# 清理旧片段
rm -f "${CONFIG_FILE}".fragment.*

# 调优所有已下载模型
tuned_count=0
for model_id in 0.5b 1.5b 3b; do
    if tune_model "${model_id}"; then
        tuned_count=$((tuned_count + 1))
    fi
done

if [ "$tuned_count" -eq 0 ]; then
    print_warn "没有可调优的模型（模型文件可能未下载）"
    exit 1
fi

# 组装 JSON 配置文件
print_step "生成配置文件"

{
    echo "{"
    echo "  \"hardware\": {"
    echo "    \"arch\": \"${ARCH}\","
    echo "    \"cores\": ${CPU_CORES},"
    echo "    \"mem_gb\": ${MEM_AVAIL_GB},"
    echo "    \"gpu\": ${HAS_GPU}"
    echo "  },"
    echo "  \"tuned\": true,"
    echo "  \"tune_method\": \"benchmark\","
    echo "  \"tune_time\": \"$(date '+%Y-%m-%d %H:%M:%S')\","
    echo "  \"models\": {"

    first=true
    for model_id in 0.5b 1.5b 3b; do
        fragment="${CONFIG_FILE}.fragment.${model_id}"
        if [ -f "${fragment}" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi
            cat "${fragment}"
        fi
    done

    echo ""
    echo "  }"
    echo "}"
} > "${CONFIG_FILE}"

# 清理片段
rm -f "${CONFIG_FILE}".fragment.*

print_success "配置已写入: ${CONFIG_FILE}"
echo ""
cat "${CONFIG_FILE}"
