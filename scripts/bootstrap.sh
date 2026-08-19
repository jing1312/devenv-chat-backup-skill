#!/bin/bash
# bootstrap.sh — 容器重建后一键引导恢复
# 用法:
#   curl -sL https://raw.githubusercontent.com/jing1312/devenv-chat-backup-skill/main/scripts/bootstrap.sh | bash -s YOUR_TOKEN
#   或:
#   bash bootstrap.sh YOUR_TOKEN

set -e

TOKEN="${1:-}"
SKILL_REPO="https://github.com/jing1312/devenv-chat-backup-skill.git"
DATA_REPO="https://github.com/jing1312/devenv-chat-backup.git"

echo "╔══════════════════════════════════════════╗"
echo "║   DevEnv Chat Backup — Bootstrap & Restore ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. 检查 token ──
if [ -z "$TOKEN" ]; then
    echo "❌ 缺少 GitHub Token 参数"
    echo ""
    echo "用法:"
    echo "  bash bootstrap.sh <YOUR_GITHUB_TOKEN>"
    echo ""
    echo "或一行命令:"
    echo "  curl -sL https://raw.githubusercontent.com/jing1312/devenv-chat-backup-skill/main/scripts/bootstrap.sh | bash -s <YOUR_TOKEN>"
    exit 1
fi

echo "✅ Token 已接收 (${#TOKEN} 字符)"

# ── 2. 从 public 仓库拉取脚本 (不需要 token) ──
echo ""
echo "📥 Step 1/4: 从公开仓库拉取脚本..."
rm -rf /tmp/bootstrap-scripts
git clone --depth 1 "$SKILL_REPO" /tmp/bootstrap-scripts 2>&1 | tail -1

# ── 3. 部署脚本到 /root/ ──
echo "📦 Step 2/4: 部署脚本到 /root/..."
cp /tmp/bootstrap-scripts/scripts/*.sh /root/
chmod +x /root/*.sh

# 修改 chat-backup.sh 中的 REPO_URL 指向你的私有仓库
sed -i 's|REPO_URL="https://github.com/88lin/ai-shell-backup.git"|REPO_URL="https://github.com/jing1312/devenv-chat-backup.git"|' /root/chat-backup.sh

# 设置 120 秒备份间隔
sed -i 's/BACKUP_INTERVAL=3600/BACKUP_INTERVAL=120/' /root/chat-backup.sh

# 设置 120 秒 git 超时 (5MB runtime-memory.db push 需要更长时间)
sed -i 's/GIT_TIMEOUT=30/GIT_TIMEOUT=120/' /root/chat-backup.sh

echo "   ✅ 脚本已部署: $(ls /root/*.sh | xargs -n1 basename | tr '\n' ' ')"

# ── 4. 配置 token ──
echo "🔑 Step 3/4: 配置 GitHub Token..."
echo -n "$TOKEN" > /tmp/github_token.txt
chmod 600 /tmp/github_token.txt
echo "   ✅ Token 已写入 /tmp/github_token.txt"

# 创建旧版 LOCAL_DIR (脚本需要)
mkdir -p /root/.huawei/hwcloud/sessions

# ── 5. 执行恢复 ──
echo "🔄 Step 4/4: 从私有仓库恢复数据..."
echo ""
bash /root/auto-restore.sh 2>&1

# ── 6. 配置 .bashrc 自动恢复 (下次重启 overlay 没清时生效) ──
if ! grep -q 'auto-restore' /root/.bashrc 2>/dev/null; then
    echo '' >> /root/.bashrc
    echo '# 容器重启自动恢复' >> /root/.bashrc
    echo 'bash /root/auto-restore.sh 2>/dev/null' >> /root/.bashrc
    echo "   ✅ .bashrc 已配置自动恢复"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          Bootstrap Complete!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "备份守护进程已启动，每 120 秒自动备份一次"
echo ""
echo "常用命令:"
echo "  bash /root/chat-backup.sh status        # 查看状态"
echo "  bash /root/chat-backup.sh list-dates     # 列出备份日期"
echo "  bash /root/chat-backup.sh restore-date today  # 只恢复今天"
echo "  bash /root/chat-backup.sh backup         # 立即备份"
