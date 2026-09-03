#!/bin/bash
#===============================================================================
# LLM 一键安装脚本 (llama.cpp + Qwen2.5-3B + Web聊天 + Cloudflare隧道)
# 
# 功能:
#   1. 检测硬件环境 (CPU/内存/GPU/架构)
#   2. 编译安装 llama.cpp (含ARM NEON优化)
#   3. 根据硬件自动选择并下载合适的大模型
#   4. 优化推理参数 (线程/batch/context)
#   5. 启动 llama-server API服务
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
print_step "步骤 1/7: 环境检测"

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

# bc 用于浮点比较（缺失时自动补装；装不上也能跑，只是模型选型退回保守值）
if ! command -v bc &>/dev/null; then
    print_warn "bc 未安装，尝试自动安装..."
    (yum install -y bc 2>/dev/null || apt-get install -y bc 2>/dev/null) || true
    if command -v bc &>/dev/null; then
        print_success "bc 安装完成"
    else
        print_warn "bc 安装失败，模型选型将使用保守默认值"
    fi
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

# 解析默认模型
DEFAULT_ENTRY="${MODELS_ALL[$DEFAULT_MODEL_IDX]}"
MODEL_NAME=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f1)
MODEL_FILE=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f2)
MODEL_SIZE=$(echo "$DEFAULT_ENTRY" | cut -d'|' -f4)

GEN_THREADS=$((CPU_CORES > 4 ? 4 : CPU_CORES - 1))
[ "$GEN_THREADS" -lt 1 ] && GEN_THREADS=1
BATCH_THREADS=$CPU_CORES

print_info "默认模型: ${MODEL_NAME} (Q4_K_M, ${MODEL_SIZE})"
print_info "将下载全部 3 个模型以支持 Web 界面在线切换"
print_info "推理线程: ${GEN_THREADS} (生成), ${BATCH_THREADS} (批处理)"

#===============================================================================
# 步骤 2: 编译安装 llama.cpp
#===============================================================================
print_step "步骤 2/7: 编译安装 llama.cpp"

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
            CLONE_OK=true
            print_success "克隆成功"
            break
        fi
        rm -rf "${LLAMA_DIR}" 2>/dev/null || true
    done
    if [ "${CLONE_OK}" = false ]; then
        print_error "llama.cpp 克隆失败，请检查网络连接"
        exit 1
    fi
    
    print_info "配置编译 (ARM原生优化)..."
    mkdir -p "${LLAMA_DIR}/build"
    cd "${LLAMA_DIR}/build"
    
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=ON \
        -DGGML_CUDA=OFF \
        -DGGML_BLAS=OFF \
        -DLLAMA_CURL=OFF \
        -DCMAKE_C_FLAGS="-march=native -mtune=native" \
        -DCMAKE_CXX_FLAGS="-march=native -mtune=native" \
        2>/dev/null
    
    print_info "编译中 (可能需要几分钟)..."
    make -j${CPU_CORES} llama-server llama-cli llama-bench 2>/dev/null
    
    if [ -f "${LLAMA_DIR}/build/bin/llama-server" ]; then
        print_success "llama.cpp 编译完成"
    else
        print_error "编译失败"
        exit 1
    fi
fi

LLAMA_BIN="${LLAMA_DIR}/build/bin/llama-server"
LLAMA_CLI="${LLAMA_DIR}/build/bin/llama-cli"

#===============================================================================
# 步骤 3: 下载模型
#===============================================================================
print_step "步骤 3/7: 下载模型 (全部 3 个，支持在线切换)"

mkdir -p "${MODEL_DIR}"

for entry in "${MODELS_ALL[@]}"; do
    M_NAME=$(echo "$entry" | cut -d'|' -f1)
    M_FILE=$(echo "$entry" | cut -d'|' -f2)
    M_URL=$(echo "$entry" | cut -d'|' -f3)
    M_SIZE=$(echo "$entry" | cut -d'|' -f4)
    M_PATH="${MODEL_DIR}/${M_FILE}"

    if [ -f "${M_PATH}" ]; then
        print_success "${M_NAME} 已存在 (${M_SIZE})"
        continue
    fi

    print_info "下载 ${M_NAME} (Q4_K_M, ${M_SIZE})..."
    DOWNLOAD_OK=false
    MIRRORS=(
        "https://hf-mirror.com"
        "https://huggingface.co"
    )
    for mirror in "${MIRRORS[@]}"; do
        url="${mirror}/${M_URL}"
        print_info "尝试: ${mirror}..."
        if curl -fSL -o "${M_PATH}" --connect-timeout 15 --max-time 600 "$url" 2>/dev/null; then
            DOWNLOAD_OK=true
            print_success "下载成功: ${M_NAME}"
            break
        fi
    done

    if [ "$DOWNLOAD_OK" = false ]; then
        print_warn "${M_NAME} 下载失败，跳过（不影响其他模型使用）"
        rm -f "${M_PATH}"
    fi
done

MODEL_PATH="${MODEL_DIR}/${MODEL_FILE}"
if [ ! -f "${MODEL_PATH}" ]; then
    print_error "默认模型 ${MODEL_NAME} 下载失败"
    exit 1
fi
print_success "模型就绪，默认: ${MODEL_NAME}"

#===============================================================================
# 步骤 4: 优化参数测试
#===============================================================================
print_step "步骤 4/7: 优化推理参数"

# 测试生成速度
print_info "测试生成速度..."
SPEED_TEST=$(timeout 30 ${LLAMA_CLI} -m "${MODEL_PATH}" -t ${GEN_THREADS} -n 16 -p "你好" -st --simple-io -ngl 0 -b 512 2>&1 | grep -oP 'Generation: \K[0-9.]+' || echo "0")
print_info "生成速度: ${SPEED_TEST} tokens/s"
print_success "优化参数: threads=${GEN_THREADS}, batch_threads=${BATCH_THREADS}, batch=512, ctx=2048"

#===============================================================================
# 步骤 5: 启动 llama-server
#===============================================================================
print_step "步骤 5/7: 启动 llama-server API服务"

# 停止已有进程
pkill -f "llama-server" 2>/dev/null || true
sleep 1

# 3B 模型使用 KV 缓存 q4_0 量化（生成提速 44%）
KV_CACHE_OPTS=""
if [ "${DEFAULT_MODEL_ID}" = "3b" ]; then
    KV_CACHE_OPTS="-ctk q4_0 -ctv q4_0"
    print_info "3B 模型启用 KV 缓存 q4_0 量化 (生成提速 ~44%)"
fi

setsid ${LLAMA_BIN} \
    -m "${MODEL_PATH}" \
    -t ${GEN_THREADS} \
    -tb ${BATCH_THREADS} \
    -b 512 \
    -c 2048 \
    -ngl 0 \
    ${KV_CACHE_OPTS} \
    --host 0.0.0.0 \
    --port ${LLAMA_SERVER_PORT} \
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

# 保存当前模型状态（供 Web 服务读取）
echo "${DEFAULT_MODEL_ID}" > "${INSTALL_DIR}/.current_model"

#===============================================================================
# 步骤 6: 启动 Web 聊天服务
#===============================================================================
print_step "步骤 6/7: 启动 Web 聊天服务"

# 停止已有 web 服务
pkill -f "python3 ${WEB_SERVICE}" 2>/dev/null || true
pkill -f "python3 ${INSTALL_DIR}/web_service.py" 2>/dev/null || true
sleep 1

# 如果 Web 服务脚本不存在，从仓库自动下载（便于 curl | bash 一行安装）
REPO_RAW="https://raw.githubusercontent.com/wesoho/llama-cpp-qwen-one-click/main"
if [ ! -f "${WEB_SERVICE}" ]; then
    print_warn "Web 服务脚本不存在，尝试自动下载..."
    WS_OK=false
    for ws_url in \
        "https://cdn.jsdelivr.net/gh/wesoho/llama-cpp-qwen-one-click@main/llm_web_service.py" \
        "https://ghfast.top/${REPO_RAW}/llm_web_service.py" \
        "https://gh-proxy.com/${REPO_RAW}/llm_web_service.py" \
        "${REPO_RAW}/llm_web_service.py"; do
        print_info "尝试: ${ws_url}"
        if curl -fSL -o "${WEB_SERVICE}" --connect-timeout 10 --max-time 60 "${ws_url}" 2>/dev/null; then
            WS_OK=true
            print_success "llm_web_service.py 下载成功"
            break
        fi
    done
    if [ "${WS_OK}" = false ]; then
        print_error "llm_web_service.py 下载失败，请手动放置到 ${WEB_SERVICE}"
        exit 1
    fi
    chmod +x "${WEB_SERVICE}"
fi

# README.md 一并放到 /root，供 Web 界面 /download/README.md 下载
if [ ! -f "${INSTALL_DIR}/README.md" ]; then
    for rm_url in \
        "https://cdn.jsdelivr.net/gh/wesoho/llama-cpp-qwen-one-click@main/README.md" \
        "https://ghfast.top/${REPO_RAW}/README.md" \
        "${REPO_RAW}/README.md"; do
        curl -fSL -o "${INSTALL_DIR}/README.md" --connect-timeout 10 --max-time 60 "${rm_url}" 2>/dev/null && break
    done
fi

setsid python3 "${WEB_SERVICE}" > "${WEB_SERVICE_LOG}" 2>&1 &
WEB_PID=$!
echo $WEB_PID > "${INSTALL_DIR}/llm_web_service.pid"
sleep 2

if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${WEB_PORT}/" | grep -q "200"; then
    print_success "Web 服务已启动 (PID=${WEB_PID}, 端口=${WEB_PORT})"
else
    print_error "Web 服务启动失败"
    cat "${WEB_SERVICE_LOG}"
    exit 1
fi

#===============================================================================
# 步骤 7: 启动 Cloudflare 隧道
#===============================================================================
print_step "步骤 7/7: 启动 Cloudflare 隧道"

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
            chmod +x /tmp/cloudflared
            mv /tmp/cloudflared "${CLOUDFLARED_BIN}"
            print_success "cloudflared 安装完成"
            break
        fi
    done
fi

# 停止已有隧道
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
# 完成
#===============================================================================
print_step "安装完成!"

echo -e """
${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}
${GREEN}║           LLM 聊天服务已就绪!                                ║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  模型:       ${MODEL_NAME} (Q4_K_M)                        ${GREEN}║${NC}
${GREEN}║${NC}  生成速度:   ~${SPEED_TEST} tokens/s                              ${GREEN}║${NC}
${GREEN}║${NC}  本地聊天:   http://localhost:${WEB_PORT}                     ${GREEN}║${NC}
${GREEN}║${NC}  外网访问:   ${TUNNEL_URL}  ${GREEN}║${NC}
${GREEN}║${NC}  API端点:   http://localhost:${WEB_PORT}/v1/chat/completions  ${GREEN}║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  下载安装脚本: ${TUNNEL_URL}/download/install.sh        ${GREEN}║${NC}
${GREEN}║${NC}  下载README:  ${TUNNEL_URL}/download/README.md          ${GREEN}║${NC}
${GREEN}║${NC}  下载Web源码: ${TUNNEL_URL}/download/llm_web_service.py ${GREEN}║${NC}
${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}
${GREEN}║${NC}  停止服务:   kill ${LLAMA_PID} ${WEB_PID} ${CFA_PID}                  ${GREEN}║${NC}
${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}
"""

echo -e "${YELLOW}提示:${NC}"
echo -e "  - 聊天界面支持流式输出，可直接在浏览器中使用"
echo -e "  - Web 界面顶部下拉菜单可在线切换 3B/1.5B/0.5B 模型"
echo -e "  - 快速隧道 URL 每次启动会变化"
echo -e "  - 重新运行本脚本可重启所有服务"
