# 踩坑经验汇总

在实际 DevEnv 环境中部署聊天备份方案时踩过的所有坑，以及对应的解决方案。

---

## 坑 1：rsync 不可用

**现象**：脚本中使用 `rsync` 同步文件，报错 `rsync: command not found`

**原因**：DevEnv 是精简容器环境，没有安装 rsync

**解决**：用 `cp -rf` 替代 rsync

```bash
# ❌ 不可用
rsync -av --delete "$LOCAL_DIR/sessions/" "$REPO_DIR/sessions/"

# ✅ 替代方案
cp -rf "$LOCAL_DIR/sessions/"* "$REPO_DIR/sessions/"
# 清理过期文件需要手动遍历删除
for repo_file in "$REPO_DIR/sessions/"*; do
    [ -f "$repo_file" ] || continue
    base=$(basename "$repo_file")
    [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
done
```

---

## 坑 2：git 命令无超时会卡死

**现象**：守护进程运行一段时间后停止工作，`ps` 显示 git 进程处于 `D` 状态（不可中断睡眠）

**原因**：网络抖动时 `git push` / `git pull` 会无限等待，没有超时机制

**解决**：所有 git 命令用 `timeout` 包裹

```bash
GIT_TIMEOUT=30

# ❌ 危险：网络问题会无限卡死
git pull origin main
git push origin main

# ✅ 安全：30秒超时
timeout $GIT_TIMEOUT git pull origin main
timeout $GIT_TIMEOUT git push origin main
```

---

## 坑 3：守护进程 CWD（工作目录）丢失

**现象**：守护进程运行一段时间后报 `fatal: not a git repository`

**原因**：守护进程的工作目录（CWD）可能被删除或重建，导致 git 命令找不到仓库

**解决**：守护进程启动时先 `cd /root`，每次 backup 时也确保 cd 到仓库目录

```bash
# ❌ 依赖当前目录
nohup bash -c "while true; do ./chat-backup.sh backup; sleep 120; done" &

# ✅ 显式 cd 到稳定目录
nohup setsid bash -c "cd /root; while true; do /root/chat-backup.sh backup; sleep 120; done" &
```

---

## 坑 4：crontab 不可用

**现象**：`crontab -e` 报错，无法设置定时任务

**原因**：DevEnv 精简环境没有 cron 服务

**解决**：用 `setsid + nohup + while 循环` 替代 crontab

```bash
# ❌ 不可用
crontab -e
# */2 * * * * /root/chat-backup.sh backup

# ✅ 替代方案：后台守护进程
nohup setsid bash -c "
    cd /root
    echo \$\$ > /var/run/chat-backup.pid
    while true; do
        /root/chat-backup.sh backup
        sleep 120
    done
" >/dev/null 2>&1 &
```

---

## 坑 5：curl 被 DNS 限制

**现象**：`curl https://raw.githubusercontent.com/...` 超时，但 `git clone` 正常

**原因**：DevEnv 网络环境对 `raw.githubusercontent.com` 域名有 DNS 限制

**解决**：恢复命令必须用 `git clone`，不能用 curl 下载单文件

```bash
# ❌ 不可用：DNS 解析超时
curl -o chat-backup.sh https://raw.githubusercontent.com/user/repo/main/chat-backup.sh

# ✅ 可用：git clone 不受影响
git clone https://TOKEN@github.com/user/repo.git /root/chat-backup-new
cp /root/chat-backup-new/chat-backup.sh /root/chat-backup.sh
```

---

## 坑 6：.bashrc 在 overlay 层，容器重建后丢失

**现象**：容器重建后 `.bashrc` 中的自动恢复配置消失，需要重新配置

**原因**：`.bashrc` 修改写入 overlay 层，容器重建时 overlay 层被清除

**解决**：这是 overlay FS 的设计特性，无法避免。方案是将恢复命令保存到 GitHub 仓库的 README 中，容器重建后手动执行一次即可

```bash
# ⚠️ 以下为旧版配置，已废弃！restore 在 .bashrc 中会导致数据损坏（见坑 11）
# .bashrc 中添加的自动恢复逻辑（容器重建后会丢失）
# >>> chat-backup auto-restore >>>
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh restore 2>/dev/null  # ← 危险！见坑 11
    /root/chat-backup.sh daemon 2>/dev/null
fi
# <<< chat-backup auto-restore <<<
# ✅ 新版 .bashrc 只保留 daemon，不放 restore（见坑 11 的解决方案）

# 容器重建后手动执行一次恢复命令（从 GitHub 仓库 README 复制）
git config --global credential.helper store
echo "https://YOUR_TOKEN@github.com" > ~/.git-credentials
git clone https://YOUR_TOKEN@github.com/YOUR_USER/YOUR_REPO.git /root/chat-backup-new
cp /root/chat-backup-new/chat-backup.sh /root/chat-backup.sh
chmod +x /root/chat-backup.sh
/root/chat-backup.sh setup
```

---

## 坑 7：git 等待输入导致守护进程卡死

**现象**：守护进程静默停止，没有错误日志

**原因**：git 在某些情况下会等待用户输入（如认证失败时提示输入密码），守护进程没有 TTY，会无限等待

**解决**：设置 `GIT_TERMINAL_PROMPT=0`，git 遇到需要输入时直接报错退出而不是等待

```bash
# ✅ 在脚本开头设置
export GIT_TERMINAL_PROMPT=0
```

---

## 坑 8：僵尸 git 进程堆积 + index.lock 冲突

**现象**：系统出现大量 `D` 状态的 git 进程，新备份报 `index.lock exists` 错误

**原因**：
1. 网络问题导致 git 进程卡在 `D` 状态（不可中断睡眠）
2. 卡死的 git 进程持有 `index.lock`，新 git 命令无法执行
3. 守护进程不断启动新 git 命令，进程越积越多

**解决**：
1. 用 `timeout` 防止 git 无限等待（见坑 2）
2. 如果已经出现僵尸进程，手动清理：

```bash
# 杀掉所有 git 进程
pkill -9 git 2>/dev/null

# 清理 index.lock
find /root -name ".git" -type d -exec rm -f {}/index.lock \; 2>/dev/null

# 重启守护进程
/root/chat-backup.sh daemon
```

---

## 坑 9：GitHub 直连慢或打不开

**现象**：`git clone` / `git pull` / `curl raw.githubusercontent.com` 经常超时或极慢

**原因**：DevEnv 网络环境访问 GitHub 不稳定，`raw.githubusercontent.com` 被 DNS 限制，`github.com` 时好时坏

**解决**：使用 `tvv.tw` 镜像加速，直连失败时自动回退

```bash
# 加载加速脚本
source /root/github-accel.sh

# ❌ 直连可能超时
git clone https://github.com/user/repo.git
curl -o file.sh https://raw.githubusercontent.com/user/repo/main/file.sh

# ✅ 自动回退：先直连 15s，失败后切换镜像
gclone https://github.com/user/repo.git
graw https://raw.githubusercontent.com/user/repo/main/file.sh -o file.sh
```

**镜像原理**：在 GitHub URL 前加 `https://tvv.tw/` 即可加速：
- `git clone https://tvv.tw/https://github.com/user/repo.git`
- `https://tvv.tw/https://raw.githubusercontent.com/user/repo/main/file.sh`
- `https://tvv.tw/https://github.com/.../releases/download/...`

**注意**：
- 镜像仅支持读操作（clone/fetch/pull），**不支持 push**
- `gpush` 采用重试策略（3 次，每次 60s 超时）
- 镜像克隆后自动修复 remote URL，确保后续 push 走直连

---

## 坑 10：SQLite WAL 库裸拷 = 备份无效 + 恢复即损坏

**现象**：聊天记录数据库报 `database disk image is malformed (11)`，整库损坏打开即崩

**原因**：`memory.db` 是 WAL 模式数据库，数据分布在主库文件 + `memory.db-wal`（+ `memory.db-shm`）三份文件里。旧版脚本用 `cp -f memory.db` 备份：
1. 裸拷得到的是**撕裂的不一致快照**（主库和 WAL 帧处于任意中间状态），这份"备份"本身就不能用；更糟的是 `.bashrc` 在每次打开终端时自动 `restore`，把这份坏快照**覆盖回正在运行的库**，主库与 WAL 帧错位 → 整库损坏
2. 运行中覆盖库文件 = 制造损坏的最快方式

**解决**：
1. 备份 SQLite 必须用一致性快照：
```bash
# ✅ 一致性快照（推荐）
sqlite3 "$LOCAL_DIR/memory.db" ".backup '$REPO_DIR/hwcloud-data/memory.db'"

# ❌ 禁止裸拷 WAL 库
cp -f "$LOCAL_DIR/memory.db" "$REPO_DIR/hwcloud-data/memory.db"
```
2. 恢复前先确认聊天进程已退出，覆盖后清除本地 `-wal`/`-shm` 让其重建：
```bash
pgrep -f hwcloud && echo "先退出聊天再恢复！"
rm -f "$LOCAL_DIR/memory.db-wal" "$LOCAL_DIR/memory.db-shm"
```
3. 覆盖前把现场 `memory.db` 留一份快照到 `restore-points/`，出错可回滚

---

## 坑 11：.bashrc 自动 restore 导致 AI 数据损坏/连接断开

**现象**：按 setup 部署后，出现以下问题：
- "用不了 AI" — AI 启动报数据库损坏
- "数据没有" — 聊天历史全部消失
- "连接直接断开" — 终端连上就断

**原因**：`do_setup()` 在 `.bashrc` 中加入了 `restore` + `daemon`。每次开新终端都会触发 `restore`，而 `restore` 会覆盖 `memory.db`/`audit.db`/`settings.json` 并删除 WAL 文件。在以下时机，AI 进程（`hwcloud`）可能还没启动：
- 容器刚启动时
- AI 重启的间隙
- `refresh.sh` 执行时（它 `source ~/.bashrc`）

此时 `pgrep -f hwcloud` 检测不到进程 → restore 直接执行 → 用旧备份覆盖新数据 + 删 WAL → 数据库损坏或数据丢失。

**解决**：
1. **`.bashrc` 中只放 `daemon`，不放 `restore`**。restore 改为手动执行（容器重建后跑一次）
2. **`sync_from_repo()` 增加 WAL 活跃度检测**：即使进程未检测到，如果 WAL 文件在 120 秒内被修改过，也跳过 restore
3. **`enable_auto_approve()` 加原子锁**：用 `mkdir` 原子操作防止并发写坏 `settings.json`
4. **`do_backup()` 加备份锁**：防止守护进程与手动 backup 并发导致 `index.lock` 冲突

```bash
# ❌ 危险：.bashrc 里放 restore
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh restore 2>/dev/null   # ← 每次开终端都执行，时机不可控
    /root/chat-backup.sh daemon 2>/dev/null
fi

# ✅ 安全：.bashrc 里只放 daemon
if [ -f /root/chat-backup.sh ]; then
    /root/chat-backup.sh daemon 2>/dev/null     # ← 只启动备份，不覆盖数据
fi
# restore 改为手动：容器重建后执行 /root/chat-backup.sh restore
```

---

## 坑 12：keepalive.sh 的 exec tmux attach 导致 DevEnv 连接断开

**现象**：部署 `keepalive.sh setup` 后，终端连上就断开，无法使用

**原因**：`setup_bashrc()` 在 `.bashrc` 中加入 `exec tmux attach -t devenv`。`exec` 会用 tmux 进程替换当前 bash shell 进程。但 DevEnv 的终端管理（`devenvd`）通过 WebSocket 与 bash shell 通信，shell 进程被 `exec` 掉后，`devenvd` 认为终端已死 → 连接断开。

**解决**：不自动 `exec tmux attach`，改为打印提示信息，用户按需手动 `tmux attach`。

```bash
# ❌ 危险：exec 替换 shell 进程，DevEnv 终端协议断裂
exec tmux attach -t devenv

# ✅ 安全：只提示，不替换 shell
echo "💡 tmux 会话 'devenv' 正在运行，输入 tmux attach -t devenv 可进入"
```

---

## 坑 13：cp -rf 不保留时间戳，备份文件全显示同一个日期

**现象**：在 GitHub 仓库中查看备份的会话文件，所有文件的日期都是同一个（备份执行时间），无法分辨会话的实际创建/修改时间。

**原因**：`cp -rf` 默认不保留源文件的修改时间（mtime），复制后文件的 mtime 变成当前时间。

**解决**：加 `-p`（preserve）标志保留原始时间戳。

```bash
# ❌ 所有文件变成备份时间
cp -rf "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/"

# ✅ 保留原始修改时间
cp -rfp "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/"
```

---

## 坑 14：会话文件只有 ID 文件名，无法分辨哪个是哪个

**现象**：备份仓库中会话文件名为 `01KZY1TGE2HW8Q2N51FHJT966W.jsonl`，全是数字和英文 ID。用户打开仓库后完全不知道哪个文件对应哪个对话。DevEnv UI 上显示的是中文标题（首条用户消息），但备份没有保留这个映射关系。

**原因**：备份脚本只做了文件复制，没有生成任何可读的索引或映射。

**解决**：新增 `generate_session_index()` 函数，扫描所有会话文件，提取首条用户消息（Role=0）作为标题，生成 `sessions-index.md`（人类可读）和 `sessions-index.json`（程序可读）。

```bash
# 生成的 sessions-index.md 示例：
# | 序号 | 日期       | 消息数 | 标题                     | 会话ID      |
# |------|------------|--------|--------------------------|------------|
# | 1    | 2026-08-15 | 40     | 帮我看看登录模块...       | 01KZYF7R6...|
```

在 `sync_to_repo()` 中，sessions 同步完成后自动调用 `generate_session_index`。

---

## 坑 16：messages 表为空 → DevEnv 界面只显示 session ID 而非中文标题

### 现象

容器重建后执行 `restore`，`sessions` 表已合并（`sessions.title` 有中文标题），
但 DevEnv 界面仍然只显示 session ID（如 `01KZYF7R6...`），看不到任何中文。

### 根因

DevEnv 界面**不从 `sessions.title` 读取会话显示名**，而是从 `messages` 表中
提取每个会话的**第一条用户消息**作为显示名。

容器重建后 `messages` 表只有少量数据（新建的 2 个会话），其他 10 个会话的消息
只存在于 `.jsonl` 文件中，没有被导入 `messages` 表。

### 解决方案

在 `chat-backup.sh` 中新增 `import_messages_from_jsonl()` 函数：

1. 遍历 `sessions/*.jsonl` 文件
2. 逐行解析 JSON，提取 `sessionId`、`role`、`content`、`timestamp` 等字段
3. 用 `INSERT OR REPLACE` 写入 `messages` 表
4. 跳过已存在的记录（避免重复导入）

`restore` 函数在合并 `sessions` 表后自动调用 `import_messages_from_jsonl`，
确保 `messages` 表包含所有历史消息。

### 验证

```bash
sqlite3 /root/.ai/memory.db "SELECT COUNT(*) FROM messages;"
# 应显示与 .jsonl 总消息数一致的数字（如 1279）
```

---

## 坑 17：metadata.source="acp" 导致会话在 DevEnv UI 中不可见

### 现象

备份了14个会话到 GitHub，restore 后数据库中有14条 session 记录，但 DevEnv UI 只显示10个会话。
检查数据库发现4个会话的 `metadata` 字段为 `{"source":"acp",...}`，而可见的10个会话 `metadata` 为 `{}`。

### 根因

通过 ACP（Agent Communication Protocol）创建的会话，`metadata` 字段会自动写入 `{"source":"acp",...}`。
DevEnv UI 的会话列表查询会**隐式过滤**掉 `metadata` 含 `source` 字段的记录，只显示 `metadata={}` 的会话。

这是一个 UI 层面的过滤行为，不是数据库问题——数据都在，只是 UI 不显示。

### 解决方案

在 `chat-backup.sh` 中新增 `fix_session_visibility()` 函数：

```bash
# 清除 metadata 中的 source 字段，使会话在 UI 中可见
sqlite3 "$db" "UPDATE sessions SET metadata='{}' WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';"
```

在 `backup` 和 `restore` 时自动调用。也可手动执行：

```bash
/root/chat-backup.sh fix-visibility
```

### 验证

```bash
# 检查是否有隐藏会话
sqlite3 /root/.huawei/hwcloud/memory.db \
  "SELECT COUNT(*) FROM sessions WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';"
# 应返回 0

# 查看总会话数
sqlite3 /root/.huawei/hwcloud/memory.db "SELECT COUNT(*) FROM sessions;"
```

---

## 坑 18：DevEnv UI 最多只显示10个会话

### 现象

即使所有会话的 `metadata` 都已修复为 `{}`，DevEnv UI 仍然最多只显示10个会话。
数据库中有超过10个会话记录，但 UI 列表只展示前10个。

### 根因

DevEnv UI 的会话列表查询有硬编码的 `LIMIT 10`，这是平台层面的限制，无法通过用户配置修改。
这不是 bug，是 DevEnv 产品设计上的约束。

### 解决方案

默认**不自动删除**，只警告提示。需要用户手动确认后才删除：

```bash
# 手动执行（交互式确认）
/root/chat-backup.sh prune
# 会列出候选会话，显示标题/消息数/日期，要求 y/N 确认后才删除

# backup/restore 时默认只警告（AUTO_PRUNE=false）
# 如需开启自动删除，编辑脚本顶部：
# AUTO_PRUNE=true
```

`prune_sessions()` 函数支持两种模式：
- **auto 模式**（backup/restore 调用）：`AUTO_PRUNE=false` 时只列出建议清理的会话但不删除；`true` 时自动删除
- **interactive 模式**（手动 `prune` 命令）：列出候选会话，要求 `y/N` 确认后才删除

### 策略说明

prune 的删除策略是**保留对话最丰富、最近的会话**：
1. 按 `message_count` 升序排序（消息少的先删）
2. 同等消息数按 `start_timestamp` 升序排序（时间早的先删）
3. 只删除超出 `MAX_SESSIONS` 的部分

> ⚠️ **重要**：默认 `AUTO_PRUNE=false`，不会自动删除任何会话。
> 手动 `prune` 时会显示候选列表并要求确认，防止误删重要会话。
> 被删除的会话在 GitHub 仓库的历史提交中仍可找回（git 版本控制）。

### 验证

```bash
# 查看当前会话数
sqlite3 /root/.huawei/hwcloud/memory.db "SELECT COUNT(*) FROM sessions;"
# 应 ≤ 10

# 查看会话列表（按消息数降序）
sqlite3 /root/.huawei/hwcloud/memory.db \
  "SELECT message_count, substr(title,1,40) FROM sessions ORDER BY message_count DESC;"
```


## 坑 21：cloudflared 下载不完整 = 损坏二进制 + SIGSEGV + 隧道起不来

**现象**：`auto-restore.sh` STEP 3 报 `Failed to start`，`/tmp/cloudflared.log` 显示 `Permission denied` 或进程秒退。手动跑 `cloudflared --version` 返回 exit 139（SIGSEGV）。

**根因**：`curl` 下载 cloudflared 二进制时网络中断或 GitHub 直连太慢，只下了一部分（实测 1.06MB / 完整 37.4MB）。旧代码只检查 `[ -s file ]`（文件非空），1MB 的半截文件通过了检查，`chmod +x` 后一执行就段错误。

更隐蔽的是：**如果损坏的二进制已经在 PATH 里**，`command -v cloudflared` 返回成功，脚本根本不会重新下载，每次恢复都失败且无提示。

**解决**：三层校验：
1. 下载前先检测现有二进制能否 `--version`，不能跑就标记重新下载
2. 下载后检查文件大小 > 10MB（cloudflared 完整约 35-40MB）
3. `chmod +x` 后再跑一次 `--version` 验证能执行
4. 直连失败自动回退 ghfast.top 镜像

```bash
# 修复后的下载逻辑（摘自 auto-restore.sh start_cf_tunnel）
local cf_ok=false
for url in "$cf_url" "https://ghfast.top/${cf_url}"; do
    curl -fSL -o /usr/local/bin/cloudflared "$url" 2>/dev/null
    local sz=0; [ -f /usr/local/bin/cloudflared ] && sz=$(stat -c %s /usr/local/bin/cloudflared 2>/dev/null || echo 0)
    if [ "$sz" -gt 10485760 ]; then
        chmod +x /usr/local/bin/cloudflared
        if /usr/local/bin/cloudflared --version >/dev/null 2>&1; then
            cf_ok=true; break
        fi
    fi
done
```

### 验证

```bash
# 模拟损坏：截断 cloudflared
head -c 1000000 /usr/local/bin/cloudflared > /tmp/bad_cf && cp /tmp/bad_cf /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
# 跑恢复，应自动检测损坏并重新下载
bash /root/auto-restore.sh
# 日志应显示 "existing cloudflared binary is broken" + "cloudflared ok"
tail -20 /var/log/auto-restore.log
```

---

## 经验总结

1. **容器环境 ≠ 完整 Linux**：很多常用工具（rsync、crontab、curl 某些域名）可能不可用，要有替代方案
2. **网络不可靠**：所有网络操作必须加超时，否则守护进程会卡死
3. **overlay 层是临时的**：任何写入 overlay 层的配置（.bashrc 等）都可能在容器重建后丢失
4. **守护进程要自防御**：CWD 丢失、TTY 缺失、进程堆积等问题都要预防
5. **恢复命令要外部保存**：恢复命令本身也在 overlay 层，容器重建后一起丢失，必须保存到外部（如 GitHub 仓库 README）
6. **界面显示名来源**：DevEnv 界面从 `messages` 表第一条用户消息提取显示名，不是 `sessions.title`。restore 必须同时恢复 `sessions` 和 `messages` 表
7. **metadata.source 过滤**：DevEnv UI 隐式过滤 `metadata` 含 `source` 字段的会话，ACP 创建的会话需清除 metadata 才能可见
8. **UI 会话数上限**：DevEnv UI 硬编码 `LIMIT 10`，超过10个会话需自动 prune，优先保留消息多且最近的
