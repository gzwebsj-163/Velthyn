<p align="center">
  <img src="https://img.shields.io/badge/Velthyn-MoCode-blue?style=for-the-badge" alt="Velthyn">
  <img src="https://img.shields.io/badge/license-MIT-green.svg?style=for-the-badge" alt="License: MIT">
</p>

<h1 align="center">Velthyn 🚀</h1>

<p align="center">
  <b>MoCode — 服务器后端 + 桌面客户端 一体化开源仓库</b><br/>
  Docker 部署的 AI Agent 服务器核心 与 macOS Electron 桌面客户端
</p>

---

## 📦 仓库结构

```
Velthyn/
├── server/       # 服务器端 AI Agent 核心(docker 部署)
│   ├── channel/    # 多平台接入(Web / WeChat / Feishu / DingTalk ...)
│   ├── agent/      # Agent 核心(规划 / 工具 / 记忆 / 知识)
│   ├── bridge/     # 桥接层
│   ├── models/     # 多模型接入(Claude / GPT / Gemini / DeepSeek / Qwen ...)
│   ├── plugins/    # 插件系统
│   ├── common/     # 公共工具
│   └── Dockerfile  # Docker 构建
└── desktop/      # macOS Electron 桌面客户端
    ├── main.js       # Electron 主进程
    ├── preload.js
    ├── scripts/      # 构建脚本
    └── package.json
```

## 🧠 server/ — 服务器端 AI Agent 核心

Docker 部署的多通道 AI 智能体核心,支持:
- **多通道接入**:Web 控制台、微信、飞书、钉钉、企微、QQ、Telegram、Slack 等
- **多模型支持**:Claude、GPT、Gemini、DeepSeek、Qwen、GLM、Kimi、MiniMax、豆包等,Web 控制台一键切换
- **Agent 能力**:任务规划、工具调用、长期记忆、知识库、Skills 技能
- **MCP 集成**:支持 MCP 多服务器系统

### 快速启动(server)

```bash
cd server
docker build -t velthyn-server .
# 或直接使用 Dockerfile 指定的基础镜像运行
```

## 💻 desktop/ — macOS 桌面客户端

基于 Electron 的 macOS 桌面应用(支持 Intel x64 和 Apple Silicon arm64)。

- 启动内置 Python 后端(端口 9899)
- 加载 Web 前端聊天界面
- 系统托盘常驻

### 启动(desktop)

```bash
cd desktop
npm install
npm start
```

### 构建

```bash
npm run build:mac          # 构建 macOS dmg
npm run build:all          # 构建所有平台
```

## 📄 License

[MIT](LICENSE) © 2026 gzwebsj-163
