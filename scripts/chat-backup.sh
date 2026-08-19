#!/bin/bash
# chat-backup.sh — AI Shell 聊天历史 + GLM Proxy 自动备份/恢复脚本
REPO_URL="https://github.com/88lin/ai-shell-backup.git"
REPO_MIRROR="https://ghfast.top/${REPO_URL}"
REPO_DIR="/tmp/ai-shell-backup"
LOCAL_DIR="/root/.huawei/hwcloud"
SCRIPT_PATH="/root/chat-backup.sh"
BACKUP_LOG="/var/log/chat-backup.log"
PID_FILE="/var/run/chat-backup.pid"
BACKUP_INTERVAL=3600
GIT_TIMEOUT=30
LOCK_DIR="/var/run/chat-backup.lock"
STALE_LOCK_SEC=300
MAX_SESSIONS=10
AUTO_PRUNE=false
GLM_PROXY_DIR="/root/glm-proxy"
GLM_PROXY_PORT=9997
RUNTIME_DB_DIR="/root/.hwcloud/memory"
RUNTIME_DB="$RUNTIME_DB_DIR/memory.db"
GLM_PROXY_PID_FILE="/tmp/glm_proxy.pid"
CF_TUNNEL_PID_FILE="/tmp/cloudflared.pid"
export GIT_TERMINAL_PROMPT=0

# --- GitHub token resolution (fixes silent failure on private repos) ---
# Token is read from: env var GITHUB_TOKEN -> /tmp/github_token.txt -> ~/.git_token
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
[ -z "$GITHUB_TOKEN" ] && [ -f /tmp/github_token.txt ] && GITHUB_TOKEN=$(cat /tmp/github_token.txt 2>/dev/null)
[ -z "$GITHUB_TOKEN" ] && [ -f "$HOME/.git_token" ] && GITHUB_TOKEN=$(cat "$HOME/.git_token" 2>/dev/null)

# Inject token into a GitHub URL for private repo auth.
auth_url() {
    local url="$1"
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "$url"
    elif echo "$url" | grep -q 'ghfast.top'; then
        # Mirror: use username:token format (x-access-token returns 403 on mirror)
        local user; user=$(echo "$url" | sed -n 's|.*/github.com/\([^/]*\)/.*|\1|p')
        echo "$url" | sed "s|https://ghfast.top/|https://${user}:${GITHUB_TOKEN}@ghfast.top/|"
    elif echo "$url" | grep -q 'https://github.com'; then
        # Direct: use x-access-token format
        echo "$url" | sed "s|https://github.com|https://x-access-token:${GITHUB_TOKEN}@github.com|"
    else
        echo "$url"
    fi
}

# Clone the backup repo with auth + error logging (no more silent 2>/dev/null).
# Tries: auth mirror -> auth direct -> no-auth mirror -> no-auth direct.
git_sync_repo() {
    local auth_mirror auth_direct
    auth_mirror=$(auth_url "$REPO_MIRROR")
    auth_direct=$(auth_url "$REPO_URL")
    cd /tmp 2>/dev/null || cd /  # leave REPO_DIR before rm -rf
    rm -rf "$REPO_DIR"
    local err
    for url in "$auth_mirror" "$auth_direct" "$REPO_MIRROR" "$REPO_URL"; do
        err=$(timeout "$GIT_TIMEOUT" git clone --depth 1 "$url" "$REPO_DIR" 2>&1)
        if [ -d "$REPO_DIR/.git" ]; then
            cd "$REPO_DIR" && git remote set-url origin "$REPO_URL" 2>/dev/null
            log "GIT: clone ok ($url)"
            return 0
        fi
        log "GIT: clone failed ($url): $(echo "$err" | tail -1)"
    done
    log "GIT: all clone methods failed"
    return 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$BACKUP_LOG" 2>/dev/null; }

acquire_lock() {
    if [ -d "$LOCK_DIR" ]; then
        local lock_age; lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
        [ "$lock_age" -gt "$STALE_LOCK_SEC" ] && rmdir "$LOCK_DIR" 2>/dev/null
    fi
    mkdir "$LOCK_DIR" 2>/dev/null || { log "LOCK: busy, skip"; return 1; }
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }

sqlite_backup() {
    local src="$1" dst="$2"
    if [ -f "$src" ] && command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$src" ".backup '$dst'" 2>/dev/null
    elif [ -f "$src" ]; then cp -f "$src" "$dst"; fi
}

generate_session_index() {
    local sessions_dir="$LOCAL_DIR/sessions"
    [ -d "$sessions_dir" ] || return 0
    local index_md="$REPO_DIR/hwcloud-data/sessions-index.md"
    local index_json="$REPO_DIR/hwcloud-data/sessions-index.json"
    local db_path="$LOCAL_DIR/memory.db"
    python3 - "$sessions_dir" "$index_md" "$index_json" "$db_path" << 'PYEOF' 2>>/var/log/chat-backup.log
import json, os, glob, sys, sqlite3
from datetime import datetime
sessions_dir, index_md, index_json, db_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
db_times = {}
try:
    conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=3)
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(sessions)")
    col_names = [r[1] for r in cur.fetchall()]
    if "id" in col_names and "session_id" not in col_names:
        sid_col, ts_col = "id", "created_at"
    else:
        sid_col, ts_col = "session_id", "start_timestamp"
    cur.execute("SELECT %s, %s FROM sessions" % (sid_col, ts_col))
    for row in cur.fetchall():
        sid, ts = row[0], row[1]
        if ts:
            if isinstance(ts, (int, float)):
                db_times[sid] = datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
            else:
                db_times[sid] = str(ts)[:16]
    conn.close()
except Exception as e:
    sys.stderr.write("INDEX: db query failed: %s\n" % e)
files = sorted(glob.glob(os.path.join(sessions_dir, "*.jsonl")), key=lambda f: os.path.getmtime(f))
entries = []
for f in files:
    sid = os.path.basename(f).replace('.jsonl', '')
    time_str = db_times.get(sid, datetime.fromtimestamp(os.path.getmtime(f)).strftime('%Y-%m-%d %H:%M'))
    size = os.path.getsize(f)
    title = "(空会话)"; msg_count = 0; first_user_msg = ""
    with open(f, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line); msg_count += 1
                if d.get("Role") == 0 and d.get("Content") and not first_user_msg:
                    first_user_msg = d["Content"][:80].replace('\n', ' ').strip()
            except: continue
    if first_user_msg: title = first_user_msg
    entries.append({"id": sid, "title": title, "date": time_str, "messages": msg_count, "size": size})
entries.sort(key=lambda e: e["date"])
with open(index_md, 'w', encoding='utf-8') as f:
    f.write("# 会话索引（共 %d 个会话）\n\n生成时间：%s\n\n" % (len(entries), datetime.now().strftime('%Y-%m-%d %H:%M:%S')))
    f.write("| 序号 | 日期 | 消息数 | 标题 | 会话ID |\n|------|------|--------|------|--------|\n")
    for i, e in enumerate(entries, 1):
        f.write("| %d | %s | %d | %s | `%s` |\n" % (i, e['date'], e['messages'], e['title'], e['id']))
with open(index_json, 'w', encoding='utf-8') as f: json.dump(entries, f, ensure_ascii=False, indent=2)
PYEOF
    log "INDEX: generated"
}

sync_to_repo() {
    [ ! -d "$LOCAL_DIR" ] && return 0
    mkdir -p "$REPO_DIR/hwcloud-data/sessions" "$REPO_DIR/scripts/glm-proxy" "$REPO_DIR/config" "$REPO_DIR/tmp-data"
    if [ -d "$LOCAL_DIR/sessions" ]; then
        cp -rfp "$LOCAL_DIR/sessions/"* "$REPO_DIR/hwcloud-data/sessions/" 2>/dev/null
        for repo_file in "$REPO_DIR/hwcloud-data/sessions/"*; do
            [ -f "$repo_file" ] || continue
            local base; base=$(basename "$repo_file")
            [ -f "$LOCAL_DIR/sessions/$base" ] || rm -f "$repo_file"
        done
    fi
    generate_session_index
    sqlite_backup "$LOCAL_DIR/memory.db" "$REPO_DIR/hwcloud-data/memory.db"
    sqlite_backup "$LOCAL_DIR/audit.db" "$REPO_DIR/hwcloud-data/audit.db"
    sqlite_backup "$RUNTIME_DB" "$REPO_DIR/hwcloud-data/runtime-memory.db"
    for f in settings.json SOUL.md user_info.json sessions-index.json sessions-index.md; do
        [ -f "$LOCAL_DIR/$f" ] && cp -f "$LOCAL_DIR/$f" "$REPO_DIR/hwcloud-data/$f"
    done
    if [ -d "$GLM_PROXY_DIR" ]; then cp -rf "$GLM_PROXY_DIR/"* "$REPO_DIR/scripts/glm-proxy/" 2>/dev/null; fi
    for f in /tmp/working_api_key.txt /tmp/proxy_api_key.txt /tmp/cf_tunnel_token.txt; do
        [ -f "$f" ] && cp -f "$f" "$REPO_DIR/tmp-data/$(basename $f)"
    done
    for f in /root/chat-backup.sh /root/keepalive.sh /root/github-accel.sh /root/auto-restore.sh; do
        [ -f "$f" ] && cp -f "$f" "$REPO_DIR/scripts/$(basename $f)"
    done
    [ -d /root/.agents/skills ] && ls /root/.agents/skills/ > "$REPO_DIR/config/installed-skills.txt" 2>/dev/null
    { echo "=== AI Shell Backup Snapshot ==="; echo "Date: $(date)"; echo "Hostname: $(hostname)"
      echo "OS: $(cat /etc/os-release 2>/dev/null | head -1)"
      echo "Sessions: $(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)"
      echo "GLM Proxy PID: $(cat "$GLM_PROXY_PID_FILE" 2>/dev/null || echo 'N/A')"
      echo "CF Tunnel PID: $(cat "$CF_TUNNEL_PID_FILE" 2>/dev/null || echo 'N/A')"
    } > "$REPO_DIR/config/env-info.txt"
}

merge_session_db() {
    local backup_db="$1" live_db="$2"
    [ -f "$backup_db" ] || return 0; [ -f "$live_db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local tmp_db="/tmp/backup_merge_$$.db"
    cp -f "$backup_db" "$tmp_db" 2>/dev/null
    local merge_err
    merge_err=$(sqlite3 "$live_db" "$(printf "ATTACH DATABASE '%s' AS bk;\nINSERT OR REPLACE INTO sessions SELECT * FROM bk.sessions;\nINSERT OR IGNORE INTO messages (message_uid, session_id, role, content_json, search_text, tool_name, tool_call_id, tool_calls, finish_reason, reasoning, timestamp, token_count) SELECT message_uid, session_id, role, content_json, search_text, tool_name, tool_call_id, tool_calls, finish_reason, reasoning, timestamp, token_count FROM bk.messages;\nDETACH DATABASE bk;\n" "$tmp_db")" 2>&1)
    local rc=$?; if [ $rc -ne 0 ]; then log "SESSION_MERGE: error: $merge_err"; fi; rm -f "$tmp_db"; return $rc
}

merge_runtime_db() {
    local backup_db="$1" live_db="$2"
    [ -f "$backup_db" ] || return 0; [ -f "$live_db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local tmp_db="/tmp/runtime_merge_$$.db"
    cp -f "$backup_db" "$tmp_db" 2>/dev/null
    # runtime DB schema: sessions(id TEXT PK), messages(id INTEGER PK, session_id TEXT)
    # Merge: bring in sessions and messages from backup that are missing in live DB
    local err
    err=$(sqlite3 "$live_db" "$(printf "ATTACH DATABASE '%s' AS bk;\nINSERT OR REPLACE INTO sessions SELECT * FROM bk.sessions;\nINSERT OR IGNORE INTO messages SELECT * FROM bk.messages;\nDETACH DATABASE bk;\n" "$tmp_db")" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then log "RUNTIME_MERGE: error: $err"; fi
    rm -f "$tmp_db"; return $rc
}

import_messages_from_jsonl() {
    [ -d "$LOCAL_DIR/sessions" ] || return 0; [ -f "$LOCAL_DIR/memory.db" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$LOCAL_DIR" "$BACKUP_LOG" <<'PYEOF' 2>>"$BACKUP_LOG"
import json, os, sqlite3, time, uuid, sys, traceback
local_dir = sys.argv[1]
log_path = sys.argv[2] if len(sys.argv) > 2 else "/var/log/chat-backup.log"
def log_err(msg):
    with open(log_path, "a") as lf:
        lf.write("[%s] JSONL_IMPORT: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
try:
    sessions_dir = os.path.join(local_dir, "sessions"); db_path = os.path.join(local_dir, "memory.db")
    ROLE_MAP = {0: "user", 1: "assistant", 2: "tool", 3: "assistant"}
    def gen_uid(): return "01" + uuid.uuid4().hex.upper()[:24]
    conn = sqlite3.connect(db_path); conn.execute("PRAGMA journal_mode=WAL"); cur = conn.cursor()
    cur.execute("PRAGMA table_info(sessions)")
    col_names = [r[1] for r in cur.fetchall()]
    use_new_schema = "id" in col_names and "session_id" not in col_names
    if use_new_schema:
        sid_col, ts_col = "id", "created_at"
        log_err("detected new schema (id, created_at)")
    else:
        sid_col, ts_col = "session_id", "start_timestamp"
        log_err("detected old schema (session_id, start_timestamp)")
    cur.execute("SELECT %s, %s FROM sessions" % (sid_col, ts_col))
    imported_total = 0
    for row in cur.fetchall():
        session_id, start_ts = row[0], row[1]
        cur.execute("SELECT COUNT(*) FROM messages WHERE session_id=?", (session_id,))
        if cur.fetchone()[0] > 0: continue
        jsonl_path = os.path.join(sessions_dir, "%s.jsonl" % session_id)
        if not os.path.exists(jsonl_path): continue
        rows = []
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line: continue
                try: data = json.loads(line)
                except: continue
                role_str = ROLE_MAP.get(data.get("Role", -1), "assistant"); content = data.get("Content", "")
                if not content: continue
                ts = (start_ts if start_ts else time.time()) + i * 0.001; msg_uid = gen_uid()
                content_json = json.dumps({"ID": msg_uid, "SessionID": session_id, "Role": role_str,
                    "Parts": [{"Type": "text", "Text": {"Text": content}, "File": None, "Image": None, "Audio": None, "ToolCall": None, "Reasoning": None}],
                    "Metadata": {"acp_message_id": None, "acp_meta": {}, "source": "local"},
                    "CreatedAt": time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime(ts)), "TokenCount": 0}, ensure_ascii=False)
                rows.append((msg_uid, session_id, role_str, content_json, content[:200], "", "", "", "", "", ts, 0))
        if rows:
            cur.executemany("INSERT OR IGNORE INTO messages (message_uid, session_id, role, content_json, search_text, tool_name, tool_call_id, tool_calls, finish_reason, reasoning, timestamp, token_count) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)
            if not use_new_schema:
                cur.execute("UPDATE sessions SET message_count=? WHERE session_id=?", (len(rows), session_id))
            imported_total += len(rows)
            log_err("imported %d messages for session %s" % (len(rows), session_id))
    conn.commit(); conn.close()
    log_err("done, total imported=%d" % imported_total)
except Exception as e:
    log_err("FAILED: %s" % e)
    traceback.print_exc(file=open(log_path, "a"))
PYEOF
    log "JSONL_IMPORT: done"
}

fix_session_visibility() {
    local db="$LOCAL_DIR/memory.db"; [ -f "$db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local has_metadata; has_metadata=$(sqlite3 "$db" "PRAGMA table_info(sessions);" 2>/dev/null | grep -c "metadata")
    [ "$has_metadata" -eq 0 ] && return 0
    local hidden_count; hidden_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM sessions WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';" 2>/dev/null || echo 0)
    [ "$hidden_count" -eq 0 ] && return 0
    sqlite3 "$db" "UPDATE sessions SET metadata='{}' WHERE metadata LIKE '%\"source\"%' AND metadata != '{}';" 2>/dev/null
    log "FIX_VIS: fixed $hidden_count sessions"; echo "FIX_VIS: fixed $hidden_count sessions"
}

do_backup() {
    acquire_lock || return 0; log "BACKUP: start"
    if [ ! -d "$REPO_DIR/.git" ]; then
        if ! git_sync_repo clone; then
            log "BACKUP: clone failed, initializing local-only repo"
            mkdir -p "$REPO_DIR"; git init "$REPO_DIR" 2>/dev/null; cd "$REPO_DIR" && git remote add origin "$REPO_URL" 2>/dev/null
        fi
    fi
    cd "$REPO_DIR" || { release_lock; return 1; }
    git config user.email >/dev/null 2>&1 || git config user.email "${GIT_AUTHOR_EMAIL:-backup@localhost}" 2>/dev/null
    git config user.name >/dev/null 2>&1 || git config user.name "${GIT_AUTHOR_NAME:-backup}" 2>/dev/null
    git remote set-url origin "$REPO_URL" 2>/dev/null
    # Use auth URL for pull if token available
    local pull_url; pull_url=$(auth_url "$REPO_URL")
    git remote set-url origin "$pull_url" 2>/dev/null
    timeout "$GIT_TIMEOUT" git pull --depth 1 origin main 2>>"$BACKUP_LOG" || log "BACKUP: pull failed (non-fatal)"
    git remote set-url origin "$REPO_URL" 2>/dev/null  # restore clean URL
    sync_to_repo
    timeout "$GIT_TIMEOUT" git add -A 2>/dev/null
    local changes; changes=$(git diff --cached --stat 2>/dev/null)
    if [ -z "$changes" ]; then log "BACKUP: no changes"; release_lock; return 0; fi
    timeout "$GIT_TIMEOUT" git commit -m "backup: $(date '+%Y-%m-%d %H:%M:%S') - $(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l) sessions" 2>/dev/null
    # Use auth URL for push
    git remote set-url origin "$pull_url" 2>/dev/null
    local push_rc; timeout "$GIT_TIMEOUT" git push origin HEAD:main --force 2>>"$BACKUP_LOG" && push_rc=0 || push_rc=1
    git remote set-url origin "$REPO_URL" 2>/dev/null  # restore clean URL
    log "BACKUP: push $([ $push_rc -eq 0 ] && echo ok || echo fail)"; release_lock; return $push_rc
}

do_restore() {
    log "RESTORE: start"
    if [ ! -d "$REPO_DIR/.git" ]; then
        if ! git_sync_repo clone; then
            log "RESTORE: clone failed"
        fi
    else
        cd "$REPO_DIR" || true
        local pull_url; pull_url=$(auth_url "$REPO_URL")
        git remote set-url origin "$pull_url" 2>/dev/null
        if ! timeout "$GIT_TIMEOUT" git pull --depth 1 origin main 2>>"$BACKUP_LOG"; then
            log "RESTORE: pull failed, re-cloning"
            git remote set-url origin "$REPO_URL" 2>/dev/null
            git_sync_repo clone || log "RESTORE: re-clone also failed"
        else
            git remote set-url origin "$REPO_URL" 2>/dev/null
        fi
    fi
    [ -d "$REPO_DIR/hwcloud-data" ] || { log "RESTORE: no data (clone/pull failed or repo empty)"; return 1; }
    mkdir -p "$LOCAL_DIR/sessions"
    [ -d "$REPO_DIR/hwcloud-data/sessions" ] && cp -rfp "$REPO_DIR/hwcloud-data/sessions/"* "$LOCAL_DIR/sessions/" 2>/dev/null
    if [ -f "$REPO_DIR/hwcloud-data/memory.db" ]; then
        if [ -f "$LOCAL_DIR/memory.db" ]; then merge_session_db "$REPO_DIR/hwcloud-data/memory.db" "$LOCAL_DIR/memory.db"
        else cp -f "$REPO_DIR/hwcloud-data/memory.db" "$LOCAL_DIR/memory.db"; fi
    fi
    [ -f "$REPO_DIR/hwcloud-data/audit.db" ] && [ ! -f "$LOCAL_DIR/audit.db" ] && cp -f "$REPO_DIR/hwcloud-data/audit.db" "$LOCAL_DIR/audit.db"
    # Restore agent runtime DB (the one the agent actually uses)
    if [ -f "$REPO_DIR/hwcloud-data/runtime-memory.db" ]; then
        mkdir -p "$RUNTIME_DB_DIR"
        if [ -f "$RUNTIME_DB" ]; then
            merge_runtime_db "$REPO_DIR/hwcloud-data/runtime-memory.db" "$RUNTIME_DB"
            log "RUNTIME_DB: merged backup into live runtime DB"
        else
            cp -f "$REPO_DIR/hwcloud-data/runtime-memory.db" "$RUNTIME_DB"
            log "RUNTIME_DB: restored from backup (fresh copy)"
        fi
    else
        log "RUNTIME_DB: no backup found in repo, skip"
    fi
    # Migrate old-schema sessions into runtime DB if they're missing
    if [ -f "$LOCAL_DIR/memory.db" ] && [ -f "$RUNTIME_DB" ]; then
        python3 - "$LOCAL_DIR/memory.db" "$RUNTIME_DB" "$BACKUP_LOG" <<'MIGRATE_EOF' 2>>"$BACKUP_LOG"
import sqlite3, json, sys, time, traceback
from datetime import datetime
old_db_path, new_db_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
def log_err(msg):
    with open(log_path, "a") as lf:
        lf.write("[%s] MIGRATE: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
def ts_to_iso(ts):
    if not ts: return datetime.now().strftime("%Y-%m-%dT%H:%M:%S+08:00")
    if ts > 1e17: ts = ts / 1e9
    elif ts > 1e14: ts = ts / 1e6
    elif ts > 1e11: ts = ts / 1e3
    try: return datetime.fromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%S+08:00")
    except: return datetime.now().strftime("%Y-%m-%dT%H:%M:%S+08:00")
def extract_content(cj):
    if not cj: return "", ""
    try: data = json.loads(cj)
    except: return str(cj)[:5000], ""
    parts = data.get("Parts", [])
    tp = []; rs = ""
    for p in parts:
        if not isinstance(p, dict): continue
        t = p.get("Type", "")
        if t == "text":
            x = p.get("Text")
            if isinstance(x, dict): tp.append(x.get("Text", ""))
            elif isinstance(x, str): tp.append(x)
        elif t == "reasoning":
            r = p.get("Reasoning")
            if r and isinstance(r, str): rs = r
        elif t == "tool_call":
            tc = p.get("ToolCall")
            if tc:
                try: tp.append(json.dumps(tc, ensure_ascii=False)[:2000])
                except: pass
    return "\n".join(tp) if tp else "", rs
try:
    old = sqlite3.connect(old_db_path)
    new = sqlite3.connect(new_db_path)
    co = old.cursor(); cn = new.cursor()
    cn.execute("SELECT id FROM sessions")
    existing = set(r[0] for r in cn.fetchall())
    co.execute("SELECT session_id, title, start_timestamp, updated_at, workdir FROM sessions")
    total = 0
    for sid, title, sts, uat, wd in co.fetchall():
        if sid in existing:
            cn.execute("SELECT COUNT(*) FROM messages WHERE session_id=?", (sid,))
            if cn.fetchone()[0] > 0: continue
        if not title:
            co.execute("SELECT content_json FROM messages WHERE session_id=? AND role='user' LIMIT 1", (sid,))
            r = co.fetchone()
            if r:
                t, _ = extract_content(r[0])
                title = t[:100] if t else "(no title)"
        cn.execute("INSERT OR IGNORE INTO sessions (id, cwd, title, created_at, updated_at, additional_directories, meta) VALUES (?,?,?,?,?,?,?)",
            (sid, wd or "/root/workspace", title, ts_to_iso(sts), ts_to_iso(uat) if uat else ts_to_iso(sts), "[]", '{"_clientMode":"ai","_hasPrompted":true,"config":{"mode":"auto","model":"hwdevspace/glm-5.2","thought_level":"medium"},"kind":"acp","mode":"auto","previous_mode":"","total_tokens":0}'))
        co.execute("SELECT message_id, role, content_json, tool_name, tool_call_id, reasoning FROM messages WHERE session_id=? ORDER BY message_id", (sid,))
        cnt = 0
        for mid, role, cj, tn, tcid, rsn in co.fetchall():
            try: content, ext_r = extract_content(cj)
            except: content, ext_r = "(decode error)", ""
            if not content and not (rsn or ext_r) and not tcid: continue
            cn.execute("INSERT INTO messages (session_id, role, name, content, content_parts, tool_calls, tool_call_id, reasoning_content) VALUES (?,?,?,?,?,?,?,?)",
                (sid, role or "assistant", tn or "", content, "", "[]", tcid or "", rsn or ext_r or ""))
            cnt += 1
        total += cnt
        log_err("session %s: %d messages" % (sid, cnt))
    new.commit()
    log_err("done, total=%d" % total)
    old.close(); new.close()
except Exception as e:
    log_err("FAILED: %s" % e)
    traceback.print_exc(file=open(log_path, "a"))
MIGRATE_EOF
        log "MIGRATE: old sessions -> runtime DB"
    fi
    import_messages_from_jsonl
    for f in settings.json SOUL.md user_info.json sessions-index.json sessions-index.md; do [ -f "$REPO_DIR/hwcloud-data/$f" ] && cp -f "$REPO_DIR/hwcloud-data/$f" "$LOCAL_DIR/$f"; done
    for f in working_api_key.txt proxy_api_key.txt cf_tunnel_token.txt; do [ -f "$REPO_DIR/tmp-data/$f" ] && cp -f "$REPO_DIR/tmp-data/$f" "/tmp/$f"; done
    [ -d "$REPO_DIR/scripts/glm-proxy" ] && mkdir -p "$GLM_PROXY_DIR" && cp -rf "$REPO_DIR/scripts/glm-proxy/"* "$GLM_PROXY_DIR/" 2>/dev/null
    for f in chat-backup.sh keepalive.sh github-accel.sh auto-restore.sh; do [ -f "$REPO_DIR/scripts/$f" ] && cp -f "$REPO_DIR/scripts/$f" "/root/$f" && chmod +x "/root/$f"; done
    fix_session_visibility; log "RESTORE: done"; echo "RESTORE: done! sessions=$(find "$LOCAL_DIR/sessions" -name "*.jsonl" | wc -l)"
}

start_glm_proxy() {
    if [ -f "$GLM_PROXY_PID_FILE" ] && kill -0 "$(cat "$GLM_PROXY_PID_FILE")" 2>/dev/null; then
        log "GLM_PROXY: already running"; return 0
    fi
    [ -f "$GLM_PROXY_DIR/glm_proxy.py" ] || { log "GLM_PROXY: not found"; return 1; }
    [ -f /tmp/working_api_key.txt ] || { log "GLM_PROXY: no API key"; return 1; }
    cd "$GLM_PROXY_DIR"
    nohup python3 glm_proxy.py --port "$GLM_PROXY_PORT" > /tmp/glm_proxy.log 2>&1 &
    echo $! > "$GLM_PROXY_PID_FILE"
    sleep 2
    if kill -0 "$(cat "$GLM_PROXY_PID_FILE")" 2>/dev/null; then log "GLM_PROXY: started PID $(cat "$GLM_PROXY_PID_FILE")"
    else log "GLM_PROXY: failed to start"; return 1; fi
}

start_cf_tunnel() {
    if [ -f "$CF_TUNNEL_PID_FILE" ] && kill -0 "$(cat "$CF_TUNNEL_PID_FILE")" 2>/dev/null; then
        log "CF_TUNNEL: already running"; return 0
    fi
    [ -f /tmp/cf_tunnel_token.txt ] || { log "CF_TUNNEL: no token"; return 0; }
    command -v cloudflared >/dev/null 2>&1 || { log "CF_TUNNEL: cloudflared not found"; return 0; }
    local cf_token; cf_token=$(cat /tmp/cf_tunnel_token.txt 2>/dev/null)
    if [ -n "$cf_token" ]; then
        nohup cloudflared tunnel --no-autoupdate run --token "$cf_token" > /tmp/cloudflared.log 2>&1 &
    else
        nohup cloudflared tunnel --url http://localhost:"$GLM_PROXY_PORT" run glm-proxy > /tmp/cloudflared.log 2>&1 &
    fi
    echo $! > "$CF_TUNNEL_PID_FILE"
    sleep 2; log "CF_TUNNEL: started PID $(cat "$CF_TUNNEL_PID_FILE")"
}

do_full_restore() {
    do_restore
    start_glm_proxy
    start_cf_tunnel
    echo "Full restore complete!"
}

show_status() {
    echo "=== AI Shell Backup Status ==="
    echo "Date: $(date)"
    echo "Sessions: $(find "$LOCAL_DIR/sessions" -name "*.jsonl" 2>/dev/null | wc -l)"
    echo "GLM Proxy: $([ -f "$GLM_PROXY_PID_FILE" ] && kill -0 "$(cat "$GLM_PROXY_PID_FILE")" 2>/dev/null && echo "running (PID $(cat "$GLM_PROXY_PID_FILE"))" || echo "stopped")"
    echo "CF Tunnel: $([ -f "$CF_TUNNEL_PID_FILE" ] && kill -0 "$(cat "$CF_TUNNEL_PID_FILE")" 2>/dev/null && echo "running (PID $(cat "$CF_TUNNEL_PID_FILE"))" || echo "stopped")"
    echo "Last backup: $(tail -1 "$BACKUP_LOG" 2>/dev/null || echo 'N/A')"
}

run_daemon() {
    echo $$ > "$PID_FILE"
    log "DAEMON: started (PID $$)"
    trap 'log "DAEMON: stopping"; rm -f "$PID_FILE"; release_lock; exit 0' SIGTERM SIGINT
    while true; do
        do_backup
        sleep "$BACKUP_INTERVAL"
    done
}

case "${1:-daemon}" in
    backup) do_backup ;;
    restore) do_restore ;;
    full-restore) do_full_restore ;;
    status) show_status ;;
    daemon) run_daemon ;;
    start-glm) start_glm_proxy ;;
    start-cf) start_cf_tunnel ;;
    *) echo "Usage: $0 {backup|restore|full-restore|status|daemon|start-glm|start-cf}"
       echo "  backup        - 立即备份一次"
       echo "  restore       - 从 GitHub 恢复数据"
       echo "  full-restore  - 恢复数据 + 启动 GLM Proxy + CF Tunnel"
       echo "  status        - 查看状态"
       echo "  daemon        - 后台守护进程（默认，每 ${BACKUP_INTERVAL}s 备份一次）"
       echo "  start-glm     - 启动 GLM Proxy"
       echo "  start-cf      - 启动 Cloudflare Tunnel"
       ;;
esac
