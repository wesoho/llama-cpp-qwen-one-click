# 🦙 LLM 本地部署方案 (llama.cpp + Qwen2.5 + 自动性能调优)

![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![CPU](https://img.shields.io/badge/inference-CPU%20only-ff6b35)
![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-blue)
![Models](https://img.shields.io/badge/models-Qwen2.5%200.5B%2F1.5B%2F3B-615ced)
![AutoTune](https://img.shields.io/badge/auto--tune-benchmark%20optimized-success)
![Python](https://img.shields.io/badge/python-3.6%2B%20stdlib%20only-3776AB?logo=python&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

基于 [llama.cpp](https://github.com/ggerganov/llama.cpp) 的**纯 CPU** 大语言模型本地部署方案，支持 ARM64 / x86_64，自带 Web 聊天界面，**自动性能调优**，并可通过 Cloudflare 隧道获得公网 HTTPS 地址。

> 🎯 **典型场景**：没有 GPU、没有公网 IP 的容器 / 云主机想跑一个能对外访问的中文聊天机器人。
> 实测机型：HiSilicon Kunpeng 920 · 8 vCPU · 14 GB 内存 · aarch64 · 0 GPU。

## ✨ 功能特性

- **一键安装**：自动检测硬件、编译、下载模型、**自动调优**、启动服务
- **★ 自动性能调优**：对每个模型跑微基准测试，自动找到最优线程数和 KV 缓存配置
- **CPU 推理**：无需 GPU，支持 ARM NEON/SVE/DotProd 指令集优化
- **智能选型**：根据可用内存自动选择默认模型
- **在线切换**：Web 界面下拉菜单切换 3B/1.5B/0.5B，自动应用调优后最优参数
- **Web 聊天**：内置美观的聊天界面，支持流式输出
- **公网访问**：通过 Cloudflare 隧道提供 HTTPS 公网地址
- **源码下载**：Web 界面可直接下载所有脚本和源码
- **中文优化**：使用 Qwen2.5 系列模型，中文表现优秀

## 📋 系统要求

| 项目 | 最低要求 | 推荐 |
|------|---------|------|
| CPU | 2核 | 4核+ |
| 内存 | 2GB | 6GB+ |
| 磁盘 | 5GB | 10GB+ |
| 架构 | x86_64 / aarch64 | aarch64 (ARM优化) |
| 系统 | Linux（EulerOS / Ubuntu / Debian / CentOS） | 同左 |
| 工具 | cmake≥3.14, gcc≥7, g++, make, git, curl, python3≥3.6, bc | 同左 |

## 🚀 快速开始

### 方式一：一行命令（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/wesoho/llama-cpp-qwen-one-click/main/install.sh | bash
```

### 方式二：手动下载运行

```bash
git clone https://github.com/wesoho/llama-cpp-qwen-one-click.git
cd llama-cpp-qwen-one-click
chmod +x install.sh auto_tune.sh
./install.sh
```

脚本会自动完成以下 8 步：
1. 检测硬件环境（CPU核心、内存、架构、GPU）
2. 编译 llama.cpp（含 ARM 原生优化）
3. 下载全部 3 个 Qwen2.5 模型（3B/1.5B/0.5B）
4. **★ 自动性能调优** — 对每个模型测试不同线程数和 KV 缓存配置
5. 启动 llama-server API 服务（使用调优后最优参数）
6. 启动 Web 聊天界面
7. 启动 Cloudflare 隧道（公网 HTTPS 访问）
8. 输出访问地址和下载链接

## ⚡ 自动性能调优（核心新功能）

### 为什么需要自动调优？

不同服务器的 CPU 核心数、架构、内存带宽差异很大，硬编码的参数无法适配所有环境。

**实际案例**：

| 服务器 | 原脚本参数 | 调优后参数 | 提速 |
|--------|-----------|-----------|------|
| 4核 Kunpeng (原测试机) | t=3, KV q4_0 | t=3, KV q4_0 | 基线 |
| **8核 Kunpeng (本服务器)** | t=3 (浪费5核) | **t=6, 无KV** | **+83%** |

### 调优原理

`auto_tune.sh` 会对每个已下载的模型执行以下步骤：

1. **生成候选线程数**：基于 CPU 核心数生成 3-5 个候选值
   - `cores//2`（半核，适合小模型）
   - `cores-2`（留 2 核给 OS）
   - `cores-1`（留 1 核给 OS）
   - `4`（通用最优值）
   - `3`（原脚本默认值，作为对照）
   - **绝不用满全部核心**（实测 t=8 必崩）

2. **微基准测试**：用 `llama-bench -p 32 -n 32` 快速测试每个候选值

3. **KV 缓存量化**：对 ≥1.5B 模型，额外测试 `q4_0` 和 `q8_0` 量化

4. **选出最优配置**：以生成速度 (tg) 为主要指标

5. **写入 JSON 配置**：保存到 `/root/.llm_optimized_config.json`

### 调优结果示例（8核 aarch64 服务器）

```json
{
  "hardware": {"arch": "aarch64", "cores": 8, "mem_gb": 9.1, "gpu": false},
  "tuned": true,
  "tune_method": "benchmark",
  "models": {
    "0.5b": {"threads": 6, "kv_cache": null, "gen_speed": 62.14},
    "1.5b": {"threads": 6, "kv_cache": null, "gen_speed": 29.13},
    "3b":   {"threads": 6, "kv_cache": null, "gen_speed": 14.74}
  }
}
```

### 重新调优

Web 界面点击 **「⚡ 重新调优」** 按钮，或调用 API：

```bash
curl -X POST http://localhost:8899/auto_tune
```

查看调优状态：

```bash
curl http://localhost:8899/tune_status
```

### 启发式默认参数

当 `llama-bench` 不可用时（如编译失败），脚本回退到启发式默认值：

| CPU 核心数 | 生成线程 | 批处理线程 |
|-----------|---------|-----------|
| 2 | 1 | 2 |
| 4 | 2 | 3 |
| 8 | 6 | 7 |
| 16 | 6 | 15 |

## 🧠 模型选择

| 可用内存 | 默认模型 | 大小 | 调优后速度 | 说明 |
|---------|---------|------|:---:|------|
| > 3 GB | Qwen2.5-3B-Instruct | 2.0 GB | ~14.7 t/s | 质量优先 |
| > 1.5 GB | Qwen2.5-1.5B-Instruct | 1.1 GB | ~29.1 t/s | ⭐ 速度/质量平衡 |
| ≤ 1.5 GB | Qwen2.5-0.5B-Instruct | 469 MB | ~62.1 t/s | 极致速度 |

> 以上速度为 8 核 aarch64 服务器调优后实测结果。

## ⚡ 性能优化

### 自动调优 vs 硬编码参数

| 模型 | 原脚本 (t=3) | 自动调优 (t=6) | 提速 |
|------|:---:|:---:|:---:|
| Qwen2.5-0.5B | 39.7 t/s | **62.1 t/s** | +57% |
| Qwen2.5-1.5B | 15.7 t/s | **29.1 t/s** | +85% |
| Qwen2.5-3B | 8.0 t/s | **14.7 t/s** | +83% |

### 关键发现

- **线程数 t=6 是 8 核服务器的万能最优**（留 2 核给 OS）
- **t=7 开始抖动**，生成速度不稳定
- **t=8（全核）必崩** — 必须给 OS 留核
- **KV 缓存量化在多核环境下效果不明显**（瓶颈从内存带宽转到计算）
- 小模型线程多了不一定快（0.5B 在 t=7 时反而暴跌）

### ARM 优化

编译时启用 `-march=native -mtune=native`，自动利用：
- **NEON**：ARM SIMD 向量指令
- **SVE**：可伸缩向量引擎
- **DotProd**：点积指令
- **i8mm**：INT8 矩阵乘法指令
- **BF16**：BFloat16 支持

## 🌐 Web 服务

### 聊天界面

访问 `http://localhost:8899/` 即可使用，特性：
- **在线模型切换**：下拉菜单选择模型，自动应用调优后参数
- **⚡ 重新调优按钮**：一键重新运行性能调优
- 流式输出，实时显示生成内容
- 显示推理速度统计和调优状态
- 响应式设计，支持移动端

### API 接口

```bash
# OpenAI 兼容 API（流式）
curl http://localhost:8899/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"你好"}],"max_tokens":100,"stream":true}'

# 切换模型
curl -X POST http://localhost:8899/switch_model \
    -H "Content-Type: application/json" -d '{"model_id":"1.5b"}'

# ★ 自动调优
curl -X POST http://localhost:8899/auto_tune

# ★ 调优状态
curl http://localhost:8899/tune_status

# 查看可用模型
curl http://localhost:8899/models

# 系统信息
curl http://localhost:8899/info

# 健康检查
curl http://localhost:8899/health
```

### 文件下载

- `http://localhost:8899/download/install.sh` — 安装脚本
- `http://localhost:8899/download/auto_tune.sh` — 调优脚本
- `http://localhost:8899/download/README.md` — 本文档
- `http://localhost:8899/download/llm_web_service.py` — Web 服务源码

## 📁 仓库文件

```
llama-cpp-qwen-one-click/
├── install.sh                    # 一键安装脚本（8 步流程，含自动调优）
├── auto_tune.sh                  # ★ 自动性能调优脚本（新增）
├── llm_web_service.py            # Web 服务：聊天 + API代理 + 模型切换 + 调优API
├── README.md                     # 本文档
├── LICENSE                       # MIT
└── docs/
    └── screenshot-chat.png       # 聊天界面截图
```

## 📁 部署后的文件结构

```
/root/
├── install.sh                    # 一键安装脚本
├── auto_tune.sh                  # 自动调优脚本
├── llm_web_service.py            # Web 服务
├── README.md                     # 本文档
├── .llm_optimized_config.json    # ★ 调优配置文件（JSON）
├── .current_model                # 当前模型状态
├── llama.cpp/                    # llama.cpp 源码和编译产物
│   └── build/bin/
│       ├── llama-server          # API 服务
│       ├── llama-cli             # 命令行工具
│       └── llama-bench           # 基准测试工具
├── models/                       # 模型文件
│   ├── qwen2.5-3b-instruct-q4_k_m.gguf    # 3B (2.0GB)
│   ├── qwen2.5-1.5b-instruct-q4_k_m.gguf  # 1.5B (1.1GB)
│   └── qwen2.5-0.5b-instruct-q4_k_m.gguf  # 0.5B (469MB)
├── llama-server.log              # API 服务日志
├── llm_web_service.log           # Web 服务日志
└── cloudflared.log               # 隧道日志
```

## 🛠️ 服务管理

```bash
# 查看服务状态
pgrep -a llama-server
pgrep -a "python3 llm_web_service"
pgrep -a cloudflared

# 重新运行调优
bash /root/auto_tune.sh

# 通过 API 重新调优
curl -X POST http://localhost:8899/auto_tune

# 切换模型
curl -X POST http://localhost:8899/switch_model \
    -H "Content-Type: application/json" -d '{"model_id":"1.5b"}'

# 查看调优配置
cat /root/.llm_optimized_config.json

# 基准测试
~/llama.cpp/build/bin/llama-bench -m ~/models/qwen2.5-3b-instruct-q4_k_m.gguf -t 6 -p 128 -n 128

# 停止所有服务
pkill -f llama-server; pkill -f llm_web_service; pkill -f cloudflared
```

## ⚠️ 部署环境注意事项

1. **公网地址每次都会变** — Cloudflare Quick Tunnel 每次启动分配新 URL
2. **服务是后台进程，重启即失效** — 需重新执行 `./install.sh`
3. **本方案不支持 GPU** — 固定 `-DGGML_CUDA=OFF -ngl 0`
4. **不要暴露到不可信网络** — Web 服务无鉴权
5. **调优需要 llama-bench** — 如果编译失败，回退到启发式默认参数

## 📄 License

MIT
