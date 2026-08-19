---
name: devenv-chat-backup
description: |
  华为云 DevEnv 聊天历史自动备份与恢复 + GLM Proxy 备份 + 容器保活 统一方案。
  解决 DevEnv 容器重建导致 overlay 层数据丢失、聊天历史消失的问题。
  使用 GitHub 私有仓库定期备份，完全免费。支持一键自动恢复。
  当用户遇到以下情况时触发本 skill：
  (1) DevEnv 断连重连后历史记录丢失
  (2) 需要自动备份聊天会话数据
  (3) 容器重建后需要恢复聊天历史
  (4) 想搭建可靠的聊天历史备份方案
  (5) 需要备份 GLM Proxy 服务配置
  (6) 容器重启后需要一键恢复所有服务
  触发词：聊天历史丢失、历史记录消失、断连重连、容器重建、备份聊天、恢复聊天、
  DevEnv 备份、overlay 丢失、chat backup、history lost、session recovery、
  GLM Proxy 备份、一键恢复、auto-restore、容器保活
---

# DevEnv Chat Backup — 聊天历史备份 + GLM Proxy + 保活 统一方案

解决华为云 DevEnv 容器重建导致聊天历史丢失的问题。使用 GitHub 私有仓库自动备份，完全免费。
支持 GLM Proxy 服务备份、容器保活、一键自动恢复。

## 问题根因

华为云 DevEnv 使用 overlay 文件系统。容器重建时 overlay 层数据被清除，导致：
- 聊天会话文件（sessions/）全部消失
- memory.db、audit.db 等数据库丢失
- .bashrc 等配置文件被重置
- GLM Proxy 服务配置丢失

**这不是 bug，是 overlay FS 的设计特性。** 容器重建后只有镜像层的数据保留。

## 方案架构

```
┌──────────────────────────────────────────────────┐
│              DevEnv 容器                          │
│                                                    │
│  ┌──────────────┐    ┌──────────────────┐        │
│  │  聊天数据      │───→│  chat-backup.sh   │        │
│  │  sessions/    │    │  (备份/恢复)       │        │
│  │  memory.db    │    └────────┬─────────┘        │
│  │  GLM Proxy    │             │                   │
│  └──────────────┘             │                   │
│                               ▼                   │
│  ┌──────────────┐    ┌──────────────────┐        │
│  │  keepalive.sh │    │  auto-restore.sh  │        │
│  │  (保活守护)    │    │  (一键恢复)        │        │
│  └──────────────┘    └────────┬─────────┘        │
│                                │                   │
└────────────────────────────────┼──────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │  GitHub 私有仓库         │
                    │  (免费、可靠、可追溯)    │
                    └────────────────────────┘
```

### 为什么选 GitHub 私有仓库？

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| GitHub 私有仓库 | 免费、可靠、git 版本控制 | 需要配置 token | ✅ 采用 |
| 华为云 OBS | 对象存储、可靠 | 收费、需额外配置 | ❌ 否决 |
| 本地备份 | 简单 | 容器重建一起丢 | ❌ 否决 |

## 快速开始

### 1. 创建 GitHub 私有仓库

在 GitHub 创建一个私有仓库（如 `ai-shell-backup`），生成 Personal Access Token（需要 repo 权限）。

### 2. 部署备份脚本

```bash
# 配置 Git 凭证
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials

# 克隆仓库
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new

# 复制全部脚本到 /root/
cp /root/chat-backup-new/scripts/*.sh /root/
chmod +x /root/*.sh

# 修改脚本顶部的 REPO_URL 为你自己的仓库地址
# （编辑 /root/chat-backup.sh 第 19 行的 REPO_URL）

# ⚠️ 重要：配置 GitHub Token（私有仓库必须，否则 restore 会静默失败）
# 方式一：写入文件（推荐，容器重启后不丢失）
echo "YOUR_TOKEN" > /tmp/github_token.txt
# 方式二：环境变量
export GITHUB_TOKEN="YOUR_TOKEN"
# 方式三：home 目录文件
echo "YOUR_TOKEN" > ~/.git_token

# 一键设置（首次备份 + 启动守护进程 + 配置 .bashrc + 开启免确认）
/root/chat-backup.sh setup
```

> ⚠️ **请将 `YOUR_TOKEN`、`YOUR_USER`、`YOUR_REPO` 替换为你自己的值！**

### 3. 配置一键自动恢复

```bash
# 将 auto-restore.sh 加入 .bashrc，容器重启自动恢复
echo '' >> /root/.bashrc
echo '# 容器重启自动恢复' >> /root/.bashrc
echo 'bash /root/auto-restore.sh 2>/dev/null' >> /root/.bashrc
```

### 4. 容器重建后恢复

**方式一：自动恢复**（推荐）
容器重启后 `.bashrc` 自动执行 `auto-restore.sh`，无需手动操作。

**方式二：手动恢复**
```bash
bash /root/auto-restore.sh
```

> auto-restore.sh 会依次恢复：聊天数据 → GLM Proxy → 保活守护进程 → 备份守护进程

## 核心功能

### 聊天备份 + GLM Proxy 备份

| 命令 | 说明 |
|------|------|
| `chat-backup.sh setup` | 首次设置：自动批准 + 备份 + 启动守护进程 + 配置 .bashrc |
| `chat-backup.sh backup` | 立即备份当前数据到 Git（聊天数据 + GLM Proxy 配置） |
| `chat-backup.sh restore` | 从 Git 恢复最新数据（安全合并 + GLM Proxy 恢复） |
| `chat-backup.sh daemon` | 启动后台守护进程（每120秒备份） |
| `chat-backup.sh status` | 查看备份状态 |
| `chat-backup.sh auto-approve` | 开启自动批准（免确认，修改 settings.json） |
| `chat-backup.sh fix-visibility` | 修复会话可见性（清除 metadata.source="acp"） |
| `chat-backup.sh prune` | 清理多余会话（交互式确认，保留消息最多的最近 N 个） |
| `chat-backup.sh delete` | 交互式删除会话（支持关键词/日期/空会话筛选） |

### 一键自动恢复 🆕

| 命令 | 说明 |
|------|------|
| `auto-restore.sh` | 一键恢复全部服务（聊天数据 + GLM Proxy + 保活 + 备份守护） |

auto-restore.sh 执行流程：
1. 检测并恢复聊天数据（chat-backup.sh restore）
2. 检测并启动 GLM Proxy 服务
3. 启动保活守护进程（keepalive.sh setup）
4. 启动备份守护进程（chat-backup.sh daemon）
5. 配置 .bashrc 自动恢复

### 防断开保活

| 命令 | 说明 |
|------|------|
| `keepalive.sh setup` | 防断开保活设置（tmux + 心跳 + .bashrc + 进程守护） |
| `keepalive.sh status` | 查看保活状态 |
| `keepalive.sh log` | 查看断开/恢复记录 |
| `keepalive.sh attach` | 进入 tmux 会话 |

### GitHub 加速（镜像回退）

| 命令 | 说明 |
|------|------|
| `gclone <url> [dir]` | git clone 带镜像回退 |
| `gpull [remote] [branch]` | git pull 带镜像回退 |
| `gfetch [remote] [branch]` | git fetch 带镜像回退 |
| `gpush [remote] [branch]` | git push 带重试（镜像不支持 push） |
| `graw <url> [-o file]` | 下载 raw 文件带镜像回退 |
| `ggit <subcmd> ...` | 通用 git 加速器（自动选择上述函数） |

## 备份内容

| 文件 | 说明 |
|------|------|
| `sessions/*.jsonl` | 聊天会话记录（保留原始时间戳） |
| `sessions-index.md` | 可读会话索引：ID → 中文标题 → 日期 → 消息数 |
| `sessions-index.json` | 程序可读的会话索引（JSON 格式） |
| `memory.db` | 语义记忆数据库（sessions + messages 表） |
| `audit.db` | 审计日志数据库 |
| `settings.json` | 用户设置 |
| `SOUL.md` | Agent 人格配置 |
| `user_info.json` | 用户信息 |
| `scripts/glm-proxy/` | 🆕 GLM Proxy 服务脚本备份 |
| `tmp-data/*.txt` | 🆕 GLM Proxy 密钥/Token 备份 |

## 脚本清单

| 脚本 | 行数 | 说明 |
|------|------|------|
| `chat-backup.sh` | 284 | 聊天数据 + GLM Proxy 备份/恢复核心 |
| `keepalive.sh` | 85 | 容器保活 + 进程守护 |
| `github-accel.sh` | 152 | GitHub 加速（镜像 + 代理回退） |
| `auto-restore.sh` | 132 | 🆕 容器重启一键恢复全部服务 |

## 关键经验与避坑指南

> ⚠️ 以下经验全部来自实际踩坑，详见 [references/pitfalls.md](references/pitfalls.md)

1. **私有仓库 clone 无认证** → 必须配置 `GITHUB_TOKEN`（环境变量 / `/tmp/github_token.txt` / `~/.git_token`），否则 restore 静默失败（坑 20）
2. **rsync 不可用** → 用 `cp -rf` 替代（DevEnv 精简环境无 rsync）
2. **git 命令无超时会卡死** → 所有 git 命令加 `timeout 30s`
3. **守护进程 CWD 会丢失** → 启动时 `cd /root`
4. **crontab 不可用** → 用 `setsid + nohup + while 循环` 替代
5. **curl 被 DNS 限制** → 恢复命令必须用 `git clone`，不能用 curl
6. **.bashrc 在 overlay 层** → 容器重建后 .bashrc 丢失，需手动执行一次恢复命令
7. **GIT_TERMINAL_PROMPT=0** → 防止 git 等待输入导致守护进程卡死
8. **僵尸 git 进程堆积** → timeout 防止 + 手动清理 index.lock
9. **.bashrc 自动 restore 损坏数据** → .bashrc 只放 daemon，restore 改手动（坑 11）
10. **restore 跳过数据库导致标题丢失** → 改用 SQLite ATTACH 安全合并，不再跳过（坑 15）
11. **sessions.title 有标题但界面仍显示 ID** → messages 表为空，从 .jsonl 补充（坑 16）
12. **exec tmux attach 断开连接** → 改为提示，不替换 shell 进程（坑 12）
13. **metadata.source="acp" 导致会话不可见** → 清除 metadata 为 `{}`（坑 17）
14. **DevEnv UI 最多显示10个会话** → 自动 prune 消息少的旧会话（坑 18）
15. **GLM Proxy 服务重启丢失** → auto-restore.sh 自动恢复（坑 19）

## References

| 文档 | 说明 |
|------|------|
| [pitfalls.md](references/pitfalls.md) | 所有踩过的坑和解决方案 |
| [architecture.md](references/architecture.md) | 方案架构和设计决策详解 |
| [recovery-guide.md](references/recovery-guide.md) | 容器重建后恢复步骤 |
