#!/bin/bash
#===============================================================================
# LLM 一键安装脚本 (llama.cpp + Qwen2.5 + Web聊天 + 自动性能调优)
#
# 功能:
#   1. 检测硬件环境 (CPU/内存/GPU/架构)
#   2. 编译安装 llama.cpp (含ARM NEON优化)
#   3. 根据硬件自动选择并下载合适的大模型
#   4. ★ 自动性能调优 — 对每个模型跑微基准测试，找到最优线程数和KV缓存配置
#   5. 启动 llama-server API服务 (使用调优后的参数)
#   6. 启动 Web 聊天界面
#   7. 启动 Cloudflare 隧道 (公网HTTPS访问)
#
# 使用: chmod +x install.sh && ./install.sh
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
INSTALL_DIR="/root"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODEL_DIR="${INSTALL_DIR}/models"
WEB_SERVICE="${INSTALL_DIR}/llm_web_service.py"
AUTO_TUNE_SCRIPT="${INSTALL_DIR}/auto_tune.sh"
CONFIG_FILE="${INSTALL_DIR}/.llm_optimized_config.json"
LLAMA_SERVER_LOG="${INSTALL_DIR}/llama-server.log"
WEB_SERVICE_LOG="${INSTALL_DIR}/llm_web_service.log"
LLAMA_SERVER_PORT=8080
WEB_PORT=8899

# 打印函数
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()    { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

#===============================================================================
# 步骤 1: 环境检测
#===============================================================================
print_step "步骤 1/8: 环境检测"

ARCH=$(uname -m)
CPU_CORES=$(nproc 2>/dev/null || echo 4)
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_GB=$(echo "scale=1; ${MEM_TOTAL_KB}/1048576" | bc 2>/dev/null || echo "7.2")
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_AVAIL_GB=$(echo "scale=1; ${MEM_AVAIL_KB}/1048576" | bc 2>/dev/null || echo "5.8")

print_info "系统架构: ${ARCH}"
print_info "CPU 核心数: ${CPU_CORES}"
print_info "内存总量: ${MEM_TOTAL_GB} GB"
print_info "可用内存: ${MEM_AVAIL_GB} GB"

# GPU 检测
HAS_GPU=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    HAS_GPU=true
    print_info "GPU: 检测到 NVIDIA GPU"
else
    print_info "GPU: 未检测到 GPU (将使用CPU推理)"
fi

# bc 用于浮点比较
if ! command -v bc &>/dev/null; then
    print_warn "bc 未安装，尝试自动安装..."
    (yum install -y bc 2>/dev/null || apt-get install -y bc 2>/dev/null) || true
fi

# 检查必要工具
for tool in cmake gcc g++ make git curl python3; do
    if ! command -v $tool &>/dev/null; then
        print_error "$tool 未安装，请先安装: yum install -y $tool 或 apt-get install -y $tool"
        exit 1
    fi
done
print_success "环境检测通过"

# ── 模型定义（全部下载，支持 Web 界面在线切换）──
MODELS_ALL=(
    "Qwen2.5-3B-Instruct|qwen2.5-3b-instruct-q4_k_m.gguf|Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf|2.0 GB|3b"
    "Qwen2.5-1.5B-Instruct|qwen2.5-1.5b-instruct-q4_k_m.gguf|Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf|1.1 GB|1.5b"
    "Qwen2.5-0.5B-Instruct|qwen2.5-0.5b-instruct-q4_k_m.gguf|Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf|469 MB|0.5b"
)

# 根据内存选择默认模型
if (( $(echo "${MEM_AVAIL_GB} > 3.0" | bc -l 2>/dev/null || echo 0) )); then
    DEFAULT_MODEL_IDX=0   # 3B
    DEFAULT_MODEL_ID="3b"
elif (( $(echo "${MEM_AVAIL_GB} > 1.5" | bc -l 2>/dev/null || echo 0) )); then
    DEFAULT_MODEL_IDX=1   # 1.5B
    DEFAULT_MODEL_ID="1.5b"
else
    DEFAULT_MODEL_IDX=2   # 0.5B
    DEFAULT_MODEL_ID="0.5b"
fi

DEFAULT_ENTRY="${MODELS_ALL[$DEFAULT_MODEL_IDX]}"
MODEL_NAME=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f1)
MODEL_FILE=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f2)
MODEL_SIZE=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f4)

print_info "默认模型: ${MODEL_NAME} (Q4_K_M, ${MODEL_SIZE})"
print_info "将下载全部 3 个模型以支持 Web 界面在线切换"

#===============================================================================
# 步骤 2: 编译安装 llama.cpp
#===============================================================================
print_step "步骤 2/8: 编译安装 llama.cpp"

if [ -f "${LLAMA_DIR}/build/bin/llama-server" ]; then
    print_success "llama.cpp 已编译: ${LLAMA_DIR}/build/bin/llama-server"
else
    print_info "克隆 llama.cpp..."
    rm -rf "${LLAMA_DIR}" 2>/dev/null || true
    CLONE_OK=false
    for repo_url in \
        "https://ghfast.top/https://github.com/ggerganov/llama.cpp.git" \
        "https://gh-proxy.com/https://github.com/ggerganov/llama.cpp.git" \
        "https://github.com/ggerganov/llama.cpp.git"; do
        print_info "尝试: ${repo_url}"
        if git clone --depth 1 "${repo_url}" "${LLAMA_DIR}" 2>/dev/null; then
            CLONE_OK=true; print_success "克隆成功"; break
        fi
        rm -rf "${LLAMA_DIR}" 2>/dev/null || true
    done
    if [ "${CLONE_OK}" = false ]; then
        print_error "llama.cpp 克隆失败，请检查网络连接"; exit 1
    fi

    print_info "配置编译 (ARM原生优化)..."
    mkdir -p "${LLAMA_DIR}/build"; cd "${LLAMA_DIR}/build"
    cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DGGML_CUDA=OFF \
        -DGGML_BLAS=OFF -DLLAMA_CURL=OFF \
        -DCMAKE_C_FLAGS="-march=native -mtune=native" \
        -DCMAKE_CXX_FLAGS="-march=native -mtune=native" 2>/dev/null
    print_info "编译中 (可能需要几分钟)..."
    make -j${CPU_CORES} llama-server llama-cli llama-bench 2>/dev/null
    if [ -f "${LLAMA_DIR}/build/bin/llama-server" ]; then
        print_success "llama.cpp 编译完成"
    else
        print_error "编译失败"; exit 1
    fi
fi

LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
LLAMA_CLI="${LLAMA_DIR}/build/bin/llama-cli"

#===============================================================================
# 步骤 3: 下载模型
#===============================================================================
print_step "步骤 3/8: 下载模型 (全部 3 个，支持在线切换)"

mkdir -p "${MODEL_DIR}"

for entry in "${MODELS_ALL[@]}"; do
    M_NAME=$(echo "$entry" | cut -d'|' -f1)
    M_FILE=$(echo "$entry" | cut -d'|' -f2)
    M_URL=$(echo "$entry" | cut -d'|' -f3)
    M_SIZE=$(echo "$entry" | cut -d'|' -f4)
    M_PATH="${MODEL_DIR}/${M_FILE}"

    if [ -f "${M_PATH}" ]; then
        print_success "${M_NAME} 已存在 (${M_SIZE})"; continue
    fi

    print_info "下载 ${M_NAME} (Q4_K_M, ${M_SIZE})..."
    DOWNLOAD_OK=false
    for mirror in "https://hf-mirror.com" "https://huggingface.co"; do
        url="${mirror}/${M_URL}"
        if curl -fSL -o "${M_PATH}" --connect-timeout 15 --max-time 600 "$url" 2>/dev/null; then
            DOWNLOAD_OK=true; print_success "下载成功: ${M_NAME}"; break
        fi
    done
    if [ "$DOWNLOAD_OK" = false ]; then
        print_warn "${M_NAME} 下载失败，跳过"; rm -f "${M_PATH}"
    fi
done

MODEL_PATH="${MODEL_DIR}/${MODEL_FILE}"
if [ ! -f "${MODEL_PATH}" ]; then
    print_error "默认模型 ${MODEL_NAME} 下载失败"; exit 1
fi
print_success "模型就绪，默认: ${MODEL_NAME}"

#===============================================================================
# 步骤 4: ★ 自动性能调优
#===============================================================================
print_step "步骤 4/8: 自动性能调优"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# 确保 auto_tune.sh 在位
if [ ! -f "${AUTO_TUNE_SCRIPT}" ]; then
    if [ -f "${REPO_DIR}/auto_tune.sh" ]; then
        cp "${REPO_DIR}/auto_tune.sh" "${AUTO_TUNE_SCRIPT}"
        print_info "复制 auto_tune.sh 到 ${INSTALL_DIR}"
    else
        REPO_RAW="https://raw.githubusercontent.com/wesoho/llama-cpp-qwen-one-click/main"
        for at_url in \
            "https://cdn.jsdelivr.net/gh/wesoho/llama-cpp-qwen-one-click@main/auto_tune.sh" \
            "https://ghfast.top/${REPO_RAW}/auto_tune.sh" \
            "${REPO_RAW}/auto_tune.sh"; do
            if curl -fSL -o "${AUTO_TUNE_SCRIPT}" --connect-timeout 10 --max-time 60 "${at_url}" 2>/dev/null; then
                print_info "auto_tune.sh 下载成功"; break
            fi
        done
    fi
fi

if [ -f "${AUTO_TUNE_SCRIPT}" ]; then
    chmod +x "${AUTO_TUNE_SCRIPT}"
    print_info "运行自动调优 (对每个模型测试不同线程数和KV缓存配置)..."
    print_info "这可能需要 2-5 分钟，请耐心等待..."
    if bash "${AUTO_TUNE_SCRIPT}" 2>&1; then
        print_success "自动调优完成"
    else
        print_warn "自动调优出现问题，将使用启发式默认参数"
    fi
else
    print_warn "auto_tune.sh 未找到，使用启发式默认参数"
fi

# 从配置文件读取最优参数
GEN_THREADS=0; BATCH_THREADS=0; KV_CACHE=""; TUNED_SPEED=0

if [ -f "${CONFIG_FILE}" ] && command -v python3 &>/dev/null; then
    GEN_THREADS=$(python3 -c "
import json
try:
    with open('${CONFIG_FILE}') as f: cfg=json.load(f)
    print(cfg['models']['${DEFAULT_MODEL_ID}']['threads'])
except: print(0)
" 2>/dev/null || echo 0)
    BATCH_THREADS=$(python3 -c "
import json
try:
    with open('${CONFIG_FILE}') as f: cfg=json.load(f)
    print(cfg['models']['${DEFAULT_MODEL_ID}']['batch_threads'])
except: print(0)
" 2>/dev/null || echo 0)
    KV_CACHE=$(python3 -c "
import json
try:
    with open('${CONFIG_FILE}') as f: cfg=json.load(f)
    print(cfg['models']['${DEFAULT_MODEL_ID}'].get('kv_cache') or '')
except: print('')
" 2>/dev/null || echo "")
    TUNED_SPEED=$(python3 -c "
import json
try:
    with open('${CONFIG_FILE}') as f: cfg=json.load(f)
    print(cfg['models']['${DEFAULT_MODEL_ID}'].get('gen_speed',0))
except: print(0)
" 2>/dev/null || echo 0)
fi

# 回退到启发式默认值
if [ -z "${GEN_THREADS}" ] || [ "${GEN_THREADS}" = "0" ]; then
    GEN_THREADS=$((CPU_CORES > 6 ? 6 : CPU_CORES - 1))
    [ "$GEN_THREADS" -lt 1 ] && GEN_THREADS=1
fi
if [ -z "${BATCH_THREADS}" ] || [ "${BATCH_THREADS}" = "0" ]; then
    BATCH_THREADS=$((CPU_CORES > 2 ? CPU_CORES - 1 : CPU_CORES))
fi

print_info "最优参数: threads=${GEN_THREADS}, batch_threads=${BATCH_THREADS}, kv_cache=${KV_CACHE:-无}"
if [ -n "${TUNED_SPEED}" ] && [ "${TUNED_SPEED}" != "0" ]; then
    print_info "调优测得生成速度: ${TUNED_SPEED} t/s"
fi

#===============================================================================
# 步骤 5: 启动 llama-server
#===============================================================================
print_step "步骤 5/8: 启动 llama-server API服务"

pkill -f "llama-server" 2>/dev/null || true
sleep 1

KV_CACHE_OPTS=""
if [ -n "${KV_CACHE}" ] && [ "${KV_CACHE}" != "" ]; then
    KV_CACHE_OPTS="-ctk ${KV_CACHE} -ctv ${KV_CACHE}"
    print_info "启用 KV 缓存量化: ${KV_CACHE}"
fi

setsid ${LLAMA_BIN} \
    -m "${MODEL_PATH}" \
    -t ${GEN_THREADS} \
    -tb ${BATCH_THREADS} \
    -b 512 -c 2048 -ngl 0 \
    ${KV_CACHE_OPTS} \
    --host 0.0.0.0 --port ${LLAMA_SERVER_PORT} \
    > "${LLAMA_SERVER_LOG}" 2>&1 &
LLAMA_PID=$!
echo $LLAMA_PID > "${INSTALL_DIR}/llama-server.pid"

print_info "等待模型加载..."
sleep 8

if curl -s http://localhost:${LLAMA_SERVER_PORT}/health | grep -q "ok"; then
    print_success "llama-server 已启动 (PID=${LLAMA_PID}, 端口=${LLAMA_SERVER_PORT})"
else
    print_warn "llama-server 可能还在加载中，请稍后检查日志: ${LLAMA_SERVER_LOG}"
fi

echo "${DEFAULT_MODEL_ID}" > "${INSTALL_DIR}/.current_model"

#===============================================================================
# 步骤 6: 启动 Web 聊天服务
#===============================================================================
print_step "步骤 6/8: 启动 Web 聊天服务"

pkill -f "python3 ${WEB_SERVICE}" 2>/dev/null || true
pkill -f "python3 ${INSTALL_DIR}/web_service.py" 2>/dev/null || true
sleep 1

REPO_RAW="https://raw.githubusercontent.com/wesoho/llama-cpp-qwen-one-click/main"
if [ ! -f "${WEB_SERVICE}" ]; then
    if [ -f "${REPO_DIR}/llm_web_service.py" ]; then
        cp "${REPO_DIR}/llm_web_service.py" "${WEB_SERVICE}"
        print_info "复制 llm_web_service.py 到 ${INSTALL_DIR}"
    else
        print_warn "Web 服务脚本不存在，尝试自动下载..."
        WS_OK=false
        for ws_url in \
            "https://cdn.jsdelivr.net/gh/wesoho/llama-cpp-qwen-one-click@main/llm_web_service.py" \
            "https://ghfast.top/${REPO_RAW}/llm_web_service.py" \
            "https://gh-proxy.com/${REPO_RAW}/llm_web_service.py" \
            "${REPO_RAW}/llm_web_service.py"; do
            if curl -fSL -o "${WEB_SERVICE}" --connect-timeout 10 --max-time 60 "${ws_url}" 2>/dev/null; then
                WS_OK=true; print_success "llm_web_service.py 下载成功"; break
            fi
        done
        if [ "${WS_OK}" = false ]; then
            print_error "llm_web_service.py 下载失败"; exit 1
        fi
    fi
    chmod +x "${WEB_SERVICE}"
fi

# README.md 和 auto_tune.sh 一并放到 /root
for extra_file in README.md auto_tune.sh; do
    if [ ! -f "${INSTALL_DIR}/${extra_file}" ] && [ -f "${REPO_DIR}/${extra_file}" ]; then
        cp "${REPO_DIR}/${extra_file}" "${INSTALL_DIR}/${extra_file}"
    fi
done

setsid python3 "${WEB_SERVICE}" > "${WEB_SERVICE_LOG}" 2>&1 &
WEB_PID=$!
echo $WEB_PID > "${INSTALL_DIR}/llm_web_service.pid"
sleep 2

if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${WEB_PORT}/" | grep -q "200"; then
    print_success "Web 服务已启动 (PID=${WEB_PID}, 端口=${WEB_PORT})"
else
    print_error "Web 服务启动失败"; cat "${WEB_SERVICE_LOG}"; exit 1
fi

#===============================================================================
# 步骤 7: 启动 Cloudflare 隧道
#===============================================================================
print_step "步骤 7/8: 启动 Cloudflare 隧道"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_LOG="${INSTALL_DIR}/cloudflared.log"

if [ ! -f "${CLOUDFLARED_BIN}" ]; then
    print_info "安装 cloudflared..."
    case "${ARCH}" in
        x86_64)  CFA_FILE="cloudflared-linux-amd64" ;;
        aarch64) CFA_FILE="cloudflared-linux-arm64" ;;
        armv7l)  CFA_FILE="cloudflared-linux-arm" ;;
        *) print_error "不支持的架构: ${ARCH}"; exit 1 ;;
    esac
    GITHUB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/${CFA_FILE}"
    for mirror in "https://ghfast.top" "https://gh-proxy.com" "https://mirror.ghproxy.com" ""; do
        url="${mirror:+${mirror}/}${GITHUB_URL}"
        if curl -fSL -o /tmp/cloudflared --connect-timeout 10 --max-time 120 "$url" 2>/dev/null; then
            chmod +x /tmp/cloudflared; mv /tmp/cloudflared "${CLOUDFLARED_BIN}"
            print_success "cloudflared 安装完成"; break
        fi
    done
fi

pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

setsid ${CLOUDFLARED_BIN} tunnel --url "http://localhost:${WEB_PORT}" > "${CLOUDFLARED_LOG}" 2>&1 &
CFA_PID=$!
print_info "等待隧道建立..."
sleep 8

TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "${CLOUDFLARED_LOG}" 2>/dev/null | head -1)
if [ -n "${TUNNEL_URL}" ]; then
    print_success "Cloudflare 隧道已建立 (PID=${CFA_PID})"
else
    print_warn "隧道 URL 尚未出现，请稍后查看日志: ${CLOUDFLARED_LOG}"
    TUNNEL_URL="(请查看 ${CLOUDFLARED_LOG} 获取地址)"
fi

#===============================================================================
# 步骤 8: 完成
#===============================================================================
print_step "步骤 8/8: 安装完成!"

SPEED_DISPLAY="${TUNED_SPEED:-未测}"
[ "${SPEED_DISPLAY}" = "0" ] && SPEED_DISPLAY="未测"

echo -e """
${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}
${GREEN}║           LLM 聊天服务已就绪!                                ║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  模型:       ${MODEL_NAME} (Q4_K_M)                        ${GREEN}║${NC}
${GREEN}║${NC}  生成速度:   ~${SPEED_DISPLAY} tokens/s                              ${GREEN}║${NC}
${GREEN}║${NC}  推理线程:   ${GEN_THREADS} (自动调优)                           ${GREEN}║${NC}
${GREEN}║${NC}  本地聊天:   http://localhost:${WEB_PORT}                     ${GREEN}║${NC}
${GREEN}║${NC}  外网访问:   ${TUNNEL_URL}  ${GREEN}║${NC}
${GREEN}║${NC}  API端点:   http://localhost:${WEB_PORT}/v1/chat/completions  ${GREEN}║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  下载安装脚本: ${TUNNEL_URL}/download/install.sh        ${GREEN}║${NC}
${GREEN}║${NC}  下载README:  ${TUNNEL_URL}/download/README.md          ${GREEN}║${NC}
${GREEN}║${NC}  下载Web源码: ${TUNNEL_URL}/download/llm_web_service.py ${GREEN}║${NC}
${GREEN}║${NC}  下载调优脚本: ${TUNNEL_URL}/download/auto_tune.sh      ${GREEN}║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  停止服务:   kill ${LLAMA_PID} ${WEB_PID} ${CFA_PID}                  ${GREEN}║${NC}
${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}
"""

echo -e "${YELLOW}提示:${NC}"
echo -e "  - 聊天界面支持流式输出，可直接在浏览器中使用"
echo -e "  - Web 界面顶部下拉菜单可在线切换 3B/1.5B/0.5B 模型"
echo -e "  - ★ 参数已通过自动调优优化，适配当前 ${CPU_CORES} 核 ${ARCH} 服务器"
echo -e "  - ★ 可通过 API 重新调优: curl -X POST http://localhost:${WEB_PORT}/auto_tune"
echo -e "  - 快速隧道 URL 每次启动会变化"
echo -e "  - 重新运行本脚本可重启所有服务"
