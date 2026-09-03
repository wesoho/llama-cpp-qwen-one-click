#!/usr/bin/env python3
"""
LLM Web 交互服务
- 端口 8899: 聊天界面 + API代理 + 文件下载 + 模型切换
- 代理 /v1/* 和 /completion 到 llama-server (端口 8080)
- 支持在线切换模型（3B/1.5B/0.5B），自动应用最优参数
- 提供 /download/ 下载 install.sh、README.md、llm_web_service.py
"""
import http.server, socketserver, os, platform, subprocess, json, time, socket, re, urllib.request, urllib.error, mimetypes, threading, signal

PORT = 8899
LLAMA_SERVER = "http://localhost:8080"
WEB_DIR = "/root"
LLAMA_BIN = "/root/llama.cpp/build/bin/llama-server"
MODEL_DIR = "/root/models"
STATE_FILE = "/root/.current_model"

# ── 模型配置（基于基准测试最优参数）──
MODELS = {
    "3b": {
        "name": "Qwen2.5-3B-Instruct",
        "file": f"{MODEL_DIR}/qwen2.5-3b-instruct-q4_k_m.gguf",
        "size": "2.0 GB",
        "params": ["-t", "3", "-tb", "4", "-b", "512", "-c", "2048", "-ngl", "0",
                    "-ctk", "q4_0", "-ctv", "q4_0"],
        "gen_speed": "~7.5 tokens/s",
        "prompt_speed": "~5.9 tokens/s",
        "quality": "⭐⭐⭐",
        "desc": "最佳质量 · KV缓存q4_0优化",
        "badge": "Qwen2.5-3B"
    },
    "1.5b": {
        "name": "Qwen2.5-1.5B-Instruct",
        "file": f"{MODEL_DIR}/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        "size": "1.1 GB",
        "params": ["-t", "3", "-tb", "4", "-b", "512", "-c", "2048", "-ngl", "0"],
        "gen_speed": "~14.5 tokens/s",
        "prompt_speed": "~19.6 tokens/s",
        "quality": "⭐⭐",
        "desc": "速度/质量平衡 · 推荐",
        "badge": "Qwen2.5-1.5B"
    },
    "0.5b": {
        "name": "Qwen2.5-0.5B-Instruct",
        "file": f"{MODEL_DIR}/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        "size": "469 MB",
        "params": ["-t", "3", "-tb", "4", "-b", "512", "-c", "2048", "-ngl", "0"],
        "gen_speed": "~36.9 tokens/s",
        "prompt_speed": "~55.6 tokens/s",
        "quality": "⭐⭐",
        "desc": "极致速度 · 简单问答",
        "badge": "Qwen2.5-0.5B"
    }
}

_current_model = "3b"
_switch_lock = threading.Lock()

def get_current_model():
    global _current_model
    try:
        with open(STATE_FILE) as f:
            mid = f.read().strip()
            if mid in MODELS:
                _current_model = mid
    except Exception:
        pass
    return _current_model

def save_current_model(mid):
    global _current_model
    _current_model = mid
    try:
        with open(STATE_FILE, "w") as f:
            f.write(mid)
    except Exception:
        pass

def switch_model(model_id):
    """切换模型：停止旧 llama-server，用最优参数启动新的"""
    if model_id not in MODELS:
        return {"success": False, "error": f"未知模型: {model_id}"}
    cfg = MODELS[model_id]
    if not os.path.isfile(cfg["file"]):
        return {"success": False, "error": f"模型文件不存在: {cfg['file']}"}

    with _switch_lock:
        # 1. 停止现有 llama-server (端口 8080)
        try:
            result = subprocess.run(["pgrep", "-f", "llama-server.*--port 8080"],
                                    capture_output=True, text=True, timeout=5)
            for pid in result.stdout.strip().split("\n"):
                pid = pid.strip()
                if pid:
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except Exception:
                        pass
            time.sleep(2)
            # 强制清理
            subprocess.run(["pkill", "-9", "-f", "llama-server.*--port 8080"],
                          capture_output=True, timeout=5)
            time.sleep(1)
        except Exception:
            pass

        # 2. 启动新 llama-server
        cmd = [LLAMA_BIN, "-m", cfg["file"]] + cfg["params"] + \
              ["--host", "0.0.0.0", "--port", "8080"]
        log_file = open("/root/llama-server.log", "w")
        subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT, start_new_session=True)
        log_file.close()

        # 3. 等待服务就绪（最多 30 秒）
        for i in range(60):
            try:
                req = urllib.request.urlopen(f"{LLAMA_SERVER}/health", timeout=2)
                if req.status == 200:
                    save_current_model(model_id)
                    return {"success": True, "model_id": model_id,
                            "model_name": cfg["name"], "model_size": cfg["size"],
                            "gen_speed": cfg["gen_speed"], "prompt_speed": cfg["prompt_speed"],
                            "quality": cfg["quality"], "desc": cfg["desc"],
                            "badge": cfg["badge"]}
            except Exception:
                pass
            time.sleep(0.5)

        return {"success": False, "error": "llama-server 启动超时（30秒）"}

def get_system_info():
    info = {}
    info["hostname"] = socket.gethostname()
    info["os_name"] = platform.system()
    info["os_release"] = platform.release()
    info["machine"] = platform.machine()
    info["python_version"] = platform.python_version()
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    info[f"distro_{k.lower()}"] = v.strip('"')
    except Exception: pass
    info["cpu_count"] = os.cpu_count() or 0
    info["cpu_model"] = "unknown"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name") or line.startswith("Hardware"):
                    info["cpu_model"] = line.split(":")[1].strip(); break
        if info["cpu_model"] == "unknown":
            info["cpu_model"] = platform.processor() or f"{info['machine']} architecture"
    except Exception: pass
    try:
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                parts = line.split()
                if len(parts) >= 2: mem[parts[0].rstrip(":")] = int(parts[1])
            info["mem_total"] = f"{mem.get('MemTotal', 0) / 1024:.1f} MB"
            info["mem_available"] = f"{mem.get('MemAvailable', 0) / 1024:.1f} MB"
    except Exception:
        info["mem_total"] = "unknown"; info["mem_available"] = "unknown"
    try:
        result = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, timeout=5)
        lines = result.stdout.strip().split("\n")
        if len(lines) >= 2:
            parts = lines[1].split()
            info["disk_total"] = parts[1]; info["disk_usage"] = parts[4]
    except Exception:
        info["disk_total"] = "unknown"; info["disk_usage"] = "unknown"
    try:
        result = subprocess.run(["ip", "-4", "addr"], capture_output=True, text=True, timeout=5)
        ips = []
        for line in result.stdout.split("\n"):
            if "inet " in line:
                ip = line.strip().split("inet ")[1].split("/")[0]
                if not ip.startswith("127."): ips.append(ip)
        info["ip_addresses"] = ", ".join(ips) if ips else "unknown"
    except Exception: info["ip_addresses"] = "unknown"
    try:
        with open("/proc/uptime") as f:
            up_s = float(f.read().split()[0])
            info["uptime"] = f"{int(up_s // 3600)} 小时 {int((up_s % 3600) // 60)} 分钟"
    except Exception: info["uptime"] = "unknown"
    info["current_time"] = time.strftime("%Y-%m-%d %H:%M:%S")
    # llama-server status
    try:
        req = urllib.request.urlopen(f"{LLAMA_SERVER}/health", timeout=3)
        info["llama_server_running"] = (req.status == 200)
    except Exception:
        info["llama_server_running"] = False
    # cloudflared status
    try:
        result = subprocess.run(["pgrep", "-a", "cloudflared"], capture_output=True, text=True, timeout=5)
        info["cloudflared_running"] = bool(result.stdout.strip())
    except Exception: info["cloudflared_running"] = False
    try:
        with open("/root/cloudflared.log") as f:
            match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", f.read())
            info["tunnel_url"] = match.group(0) if match else "未找到"
    except Exception: info["tunnel_url"] = "未找到"
    # current model info
    mid = get_current_model()
    cfg = MODELS.get(mid, MODELS["3b"])
    info["model_id"] = mid
    info["model_name"] = cfg["name"]
    info["model_size"] = cfg["size"]
    info["gen_speed"] = cfg["gen_speed"]
    info["prompt_speed"] = cfg["prompt_speed"]
    info["model_quality"] = cfg["quality"]
    info["model_desc"] = cfg["desc"]
    return info

def generate_chat_html():
    mid = get_current_model()
    return r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LLM 聊天 - Qwen2.5</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#1a1a2e;--surface:#16213e;--primary:#0f3460;--accent:#e94560;--text:#eee;--text-dim:#999;--user-bg:#0f3460;--ai-bg:#16213e;--success:#4ecca3;--warn:#f0a500}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;background:var(--bg);color:var(--text);height:100vh;display:flex;flex-direction:column;overflow:hidden}
.header{background:var(--surface);padding:10px 20px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 2px 10px rgba(0,0,0,.3);z-index:10;flex-wrap:wrap;gap:8px}
.header-left{display:flex;align-items:center;gap:12px}
.header h1{font-size:18px;display:flex;align-items:center;gap:8px}
.model-select{background:var(--primary);color:var(--text);border:1px solid rgba(255,255,255,.15);border-radius:8px;padding:4px 10px;font-size:13px;cursor:pointer;outline:none;transition:border-color .2s}
.model-select:hover{border-color:var(--accent)}
.model-select:focus{border-color:var(--accent)}
.header .links{display:flex;gap:12px;align-items:center}
.header a{color:var(--text-dim);text-decoration:none;font-size:13px;transition:color .2s}
.header a:hover{color:var(--accent)}
.model-info{font-size:11px;color:var(--text-dim);display:flex;gap:10px;align-items:center}
.model-info .speed{color:var(--success)}
.overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.7);display:flex;align-items:center;justify-content:center;z-index:100}
.overlay-content{text-align:center}
.spinner{width:48px;height:48px;border:4px solid rgba(255,255,255,.2);border-top-color:var(--accent);border-radius:50%;margin:0 auto 16px;animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.overlay-content p{color:var(--text);font-size:15px}
.chat-container{flex:1;overflow-y:auto;padding:20px;scroll-behavior:smooth}
.msg{max-width:800px;margin:0 auto 16px;display:flex;gap:12px;animation:fadeIn .3s}
@keyframes fadeIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.msg .avatar{width:36px;height:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:18px;flex-shrink:0}
.msg.user .avatar{background:var(--primary)}
.msg.ai .avatar{background:var(--accent)}
.msg .content{flex:1;padding:12px 16px;border-radius:12px;line-height:1.7;font-size:14px;white-space:pre-wrap;word-break:break-word}
.msg.user .content{background:var(--user-bg)}
.msg.ai .content{background:var(--ai-bg);border:1px solid rgba(255,255,255,.05)}
.msg .content pre{background:#0d1117;padding:10px;border-radius:8px;overflow-x:auto;margin:8px 0}
.msg .content code{font-family:"Fira Code",monospace;font-size:13px}
.msg .meta{font-size:11px;color:var(--text-dim);margin-top:4px}
.typing{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--accent);margin:0 2px;animation:typing 1.4s infinite}
.typing:nth-child(2){animation-delay:.2s}
.typing:nth-child(3){animation-delay:.4s}
@keyframes typing{0%,60%,100%{opacity:.3}30%{opacity:1}}
.input-area{background:var(--surface);padding:16px 20px;border-top:1px solid rgba(255,255,255,.05)}
.input-wrapper{max-width:800px;margin:0 auto;display:flex;gap:12px;align-items:flex-end}
#msgInput{flex:1;background:var(--bg);border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:12px 16px;color:var(--text);font-size:14px;resize:none;max-height:120px;min-height:44px;font-family:inherit;transition:border-color .2s}
#msgInput:focus{outline:none;border-color:var(--accent)}
#sendBtn{background:var(--accent);color:#fff;border:none;border-radius:12px;padding:12px 20px;cursor:pointer;font-size:14px;transition:opacity .2s;white-space:nowrap}
#sendBtn:hover{opacity:.85}
#sendBtn:disabled{opacity:.5;cursor:not-allowed}
.stats{max-width:800px;margin:0 auto;padding:4px 0 0;font-size:11px;color:var(--text-dim);text-align:right}
.welcome{text-align:center;padding:40px 20px;color:var(--text-dim)}
.welcome h2{color:var(--text);margin-bottom:8px}
.welcome p{font-size:14px;line-height:1.6}
.suggestions{max-width:800px;margin:16px auto;display:flex;gap:8px;flex-wrap:wrap}
.suggestion{background:var(--surface);border:1px solid rgba(255,255,255,.1);border-radius:8px;padding:8px 14px;cursor:pointer;font-size:13px;transition:all .2s}
.suggestion:hover{border-color:var(--accent);color:var(--accent)}
</style>
</head>
<body>
<div class="overlay" id="overlay" style="display:none">
  <div class="overlay-content">
    <div class="spinner"></div>
    <p id="overlayText">正在切换模型...</p>
  </div>
</div>
<div class="header">
  <div class="header-left">
    <h1>🤖 LLM 聊天</h1>
    <select class="model-select" id="modelSelect" onchange="switchModel()">
      <option value="3b">Qwen2.5-3B · 质量优先 (7.5 t/s)</option>
      <option value="1.5b">Qwen2.5-1.5B · 推荐 (14.5 t/s)</option>
      <option value="0.5b">Qwen2.5-0.5B · 极速 (36.9 t/s)</option>
    </select>
  </div>
  <div class="links">
    <span class="model-info" id="modelInfo"></span>
    <a href="/info" target="_blank">系统信息</a>
    <a href="/download/install.sh" download>安装脚本</a>
    <a href="/download/README.md" download>README</a>
    <a href="/download/llm_web_service.py" download>Web源码</a>
  </div>
</div>
<div class="chat-container" id="chatContainer">
  <div class="welcome" id="welcome">
    <h2>👋 欢迎使用 LLM 聊天服务</h2>
    <p id="welcomeText">加载中...</p>
  </div>
  <div class="suggestions">
    <div class="suggestion" onclick="sendSuggestion('你好，请介绍一下你自己')">介绍一下你自己</div>
    <div class="suggestion" onclick="sendSuggestion('写一首关于春天的诗')">写一首诗</div>
    <div class="suggestion" onclick="sendSuggestion('解释什么是机器学习')">解释机器学习</div>
    <div class="suggestion" onclick="sendSuggestion('用Python写一个快速排序算法')">写快速排序</div>
  </div>
</div>
<div class="input-area">
  <div class="input-wrapper">
    <textarea id="msgInput" placeholder="输入消息，按 Enter 发送，Shift+Enter 换行..." rows="1" onkeydown="handleKey(event)"></textarea>
    <button id="sendBtn" onclick="sendMessage()">发送</button>
  </div>
  <div class="stats" id="stats"></div>
</div>
<script>
let messages=[];
const chat=document.getElementById('chatContainer');
const input=document.getElementById('msgInput');
const btn=document.getElementById('sendBtn');
const stats=document.getElementById('stats');
const overlay=document.getElementById('overlay');
const overlayText=document.getElementById('overlayText');
const modelSelect=document.getElementById('modelSelect');
const modelInfo=document.getElementById('modelInfo');
const welcomeText=document.getElementById('welcomeText');

// 页面加载时获取当前模型
async function initModel(){
  try{
    const resp=await fetch('/models');
    const data=await resp.json();
    if(data.current){
      modelSelect.value=data.current;
      updateModelUI(data.models[data.current]);
    }
  }catch(e){}
}

function updateModelUI(cfg){
  modelInfo.innerHTML=`<span class="speed">⚡ ${cfg.gen_speed}</span> · ${cfg.quality} · ${cfg.model_size}`;
  welcomeText.innerHTML=`模型: <b>${cfg.name}</b> (${cfg.quality}) · 生成速度: <b>${cfg.gen_speed}</b><br>${cfg.desc} · 基于 llama.cpp · ARM64 CPU 推理`;
}

async function switchModel(){
  const modelId=modelSelect.value;
  overlay.style.display='flex';
  overlayText.textContent='正在切换到 '+modelSelect.options[modelSelect.selectedIndex].text+' ...';
  btn.disabled=true;
  try{
    const resp=await fetch('/switch_model',{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({model_id:modelId})
    });
    const data=await resp.json();
    if(data.success){
      updateModelUI(data);
      // 清空对话历史
      messages=[];
      chat.innerHTML='';
      const w=document.createElement('div');
      w.className='welcome';
      w.innerHTML=`<h2>✅ 模型已切换</h2><p id="welcomeText">当前模型: <b>${data.model_name}</b> · 生成速度: <b>${data.gen_speed}</b><br>${data.desc}</p>`;
      chat.appendChild(w);
      const s=document.createElement('div');
      s.className='suggestions';
      s.innerHTML=`<div class="suggestion" onclick="sendSuggestion('你好，请介绍一下你自己')">介绍一下你自己</div>
      <div class="suggestion" onclick="sendSuggestion('写一首关于春天的诗')">写一首诗</div>
      <div class="suggestion" onclick="sendSuggestion('解释什么是机器学习')">解释机器学习</div>
      <div class="suggestion" onclick="sendSuggestion('用Python写一个快速排序算法')">写快速排序</div>`;
      chat.appendChild(s);
      stats.textContent='';
    }else{
      overlayText.textContent='❌ 切换失败: '+(data.error||'未知错误');
      setTimeout(()=>{overlay.style.display='none'},3000);
      // 恢复选择
      initModel();
    }
  }catch(e){
    overlayText.textContent='❌ 请求失败: '+e.message;
    setTimeout(()=>{overlay.style.display='none'},3000);
  }
  overlay.style.display='none';
  btn.disabled=false;
  input.focus();
}

function handleKey(e){if(e.key==='Enter'&&!e.shiftDown){e.preventDefault();sendMessage()}}
function sendSuggestion(text){input.value=text;sendMessage()}

function addMsg(role,text){
  const div=document.createElement('div');
  div.className='msg '+role;
  div.innerHTML='<div class="avatar">'+(role==='user'?'👤':'🤖')+'</div><div class="content"></div>';
  chat.appendChild(div);
  const content=div.querySelector('.content');
  content.textContent=text;
  chat.scrollTop=chat.scrollHeight;
  return content;
}

function addTyping(){
  const div=document.createElement('div');
  div.className='msg ai';
  div.id='typingMsg';
  div.innerHTML='<div class="avatar">🤖</div><div class="content"><span class="typing"></span><span class="typing"></span><span class="typing"></span></div>';
  chat.appendChild(div);
  chat.scrollTop=chat.scrollHeight;
}

async function sendMessage(){
  const text=input.value.trim();
  if(!text)return;
  input.value='';input.style.height='auto';
  btn.disabled=true;
  addMsg('user',text);
  messages.push({role:'user',content:text});
  addTyping();
  const t0=performance.now();
  try{
    const resp=await fetch('/v1/chat/completions',{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({model:'qwen',messages:messages,max_tokens:512,stream:true})
    });
    document.getElementById('typingMsg')?.remove();
    const aiContent=addMsg('ai','');
    const reader=resp.body.getReader();
    const decoder=new TextDecoder();
    let fullText='',buf='';
    while(true){
      const{done,value}=await reader.read();
      if(done)break;
      buf+=decoder.decode(value,{stream:true});
      const lines=buf.split('\n');
      buf=lines.pop();
      for(const line of lines){
        if(line.startsWith('data: ')){
          const data=line.slice(6);
          if(data==='[DONE]')continue;
          try{
            const json=JSON.parse(data);
            const delta=json.choices[0]?.delta?.content||'';
            fullText+=delta;
            aiContent.textContent=fullText;
            chat.scrollTop=chat.scrollHeight;
          }catch(e){}
        }
      }
    }
    messages.push({role:'assistant',content:fullText});
    const dt=((performance.now()-t0)/1000).toFixed(1);
    const tps=(fullText.length/dt).toFixed(1);
    const meta=document.createElement('div');
    meta.className='meta';
    meta.textContent=`${dt}s · ~${tps} chars/s`;
    aiContent.parentElement.appendChild(meta);
    stats.textContent=`最后回复: ${dt}s · ${fullText.length} 字符`;
  }catch(e){
    document.getElementById('typingMsg')?.remove();
    addMsg('ai','❌ 请求失败: '+e.message+'\n\n请确认 llama-server 正在运行，或尝试切换模型。');
  }
  btn.disabled=false;
  input.focus();
}

input.addEventListener('input',()=>{input.style.height='auto';input.style.height=Math.min(input.scrollHeight,120)+'px'});
initModel();
</script>
</body>
</html>'''

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(generate_chat_html().encode("utf-8"))
        elif self.path == "/info":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(get_system_info(), ensure_ascii=False, indent=2).encode("utf-8"))
        elif self.path == "/models":
            mid = get_current_model()
            models_info = {}
            for k, v in MODELS.items():
                models_info[k] = {
                    "name": v["name"], "model_size": v["size"],
                    "gen_speed": v["gen_speed"], "prompt_speed": v["prompt_speed"],
                    "quality": v["quality"], "desc": v["desc"],
                    "available": os.path.isfile(v["file"])
                }
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({"current": mid, "models": models_info},
                                        ensure_ascii=False, indent=2).encode("utf-8"))
        elif self.path.startswith("/download/"):
            fname = self.path[len("/download/"):]
            fpath = os.path.join(WEB_DIR, fname)
            if os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    data = f.read()
                self.send_response(200)
                ct = mimetypes.guess_type(fname)[0] or "application/octet-stream"
                self.send_header("Content-Type", ct)
                self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"File not found")
        elif self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/switch_model":
            self._handle_switch_model()
        elif self.path.startswith("/v1/") or self.path.startswith("/completion") or self.path.startswith("/tokenize") or self.path.startswith("/infill"):
            self._proxy_to_llama()
        else:
            self.send_response(404)
            self.end_headers()

    def _handle_switch_model(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        try:
            data = json.loads(body)
            model_id = data.get("model_id", "")
        except Exception:
            model_id = ""
        result = switch_model(model_id)
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode("utf-8"))

    def _proxy_to_llama(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        url = LLAMA_SERVER + self.path
        req = urllib.request.Request(url, data=body, method="POST")
        for key in ["Content-Type", "Accept"]:
            val = self.headers.get(key)
            if val:
                req.add_header(key, val)
        try:
            resp = urllib.request.urlopen(req, timeout=120)
            self.send_response(resp.status)
            for key, val in resp.headers.items():
                if key.lower() not in ("transfer-encoding", "connection"):
                    self.send_header(key, val)
            self.end_headers()
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(f"Proxy error: {e}".encode())

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    # 初始化当前模型状态
    get_current_model()
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"LLM Web 服务已启动: http://0.0.0.0:{PORT}")
        print(f"聊天界面: http://localhost:{PORT}/")
        print(f"API代理: {LLAMA_SERVER}")
        print(f"可用模型: {', '.join(MODELS.keys())}")
        httpd.serve_forever()
