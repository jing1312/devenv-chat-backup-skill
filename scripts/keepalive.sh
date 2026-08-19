#!/bin/bash
# keepalive.sh — AI Shell 容器保活脚本
KEEPALIVE_LOG="/var/log/keepalive.log"
KEEPALIVE_INTERVAL=60
KEEPALIVE_PID_FILE="/var/run/keepalive.pid"
BACKUP_SCRIPT="/root/chat-backup.sh"
BACKUP_PID_FILE="/var/run/chat-backup.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$KEEPALIVE_LOG" 2>/dev/null; }

ensure_backup_running() {
    if [ -f "$BACKUP_PID_FILE" ] && kill -0 "$(cat "$BACKUP_PID_FILE")" 2>/dev/null; then
        return 0
    fi
    log "BACKUP: not running, restarting..."
    nohup bash "$BACKUP_SCRIPT" daemon >> /var/log/chat-backup.log 2>&1 &
    log "BACKUP: restarted PID $!"
}

ensure_glm_proxy() {
    local pid_file="/tmp/glm_proxy.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        return 0
    fi
    log "GLM_PROXY: not running, restarting..."
    if [ -f /root/glm-proxy/glm_proxy.py ] && [ -f /tmp/working_api_key.txt ]; then
        cd /root/glm-proxy
        nohup python3 glm_proxy.py --port 9997 > /tmp/glm_proxy.log 2>&1 &
        echo $! > "$pid_file"
        log "GLM_PROXY: restarted PID $!"
    else
        log "GLM_PROXY: missing files, skip"
    fi
}

ensure_cf_tunnel() {
    local pid_file="/tmp/cloudflared.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        return 0
    fi
    log "CF_TUNNEL: not running, restarting..."
    if command -v cloudflared >/dev/null 2>&1 && [ -f /tmp/cf_tunnel_token.txt ]; then
        local token; token=$(cat /tmp/cf_tunnel_token.txt 2>/dev/null)
        if [ -n "$token" ]; then
            nohup cloudflared tunnel --no-autoupdate run --token "$token" > /tmp/cloudflared.log 2>&1 &
            echo $! > "$pid_file"
            log "CF_TUNNEL: restarted PID $!"
        else
            log "CF_TUNNEL: token empty, skip"
        fi
    else
        log "CF_TUNNEL: cloudflared or token not found, skip"
    fi
}

touch_keepalive() {
    touch /tmp/.keepalive_marker
    # Write current timestamp to prevent idle detection
    date +%s > /tmp/.keepalive_ts
}

run_keepalive() {
    echo $$ > "$KEEPALIVE_PID_FILE"
    log "KEEPALIVE: started (PID $$)"
    trap 'log "KEEPALIVE: stopping"; rm -f "$KEEPALIVE_PID_FILE"; exit 0' SIGTERM SIGINT
    
    while true; do
        touch_keepalive
        ensure_backup_running
        ensure_glm_proxy
        ensure_cf_tunnel
        sleep "$KEEPALIVE_INTERVAL"
    done
}

case "${1:-start}" in
    start) run_keepalive ;;
    status)
        echo "=== Keepalive Status ==="
        echo "Keepalive: $([ -f "$KEEPALIVE_PID_FILE" ] && kill -0 "$(cat "$KEEPALIVE_PID_FILE")" 2>/dev/null && echo "running" || echo "stopped")"
        echo "Backup daemon: $([ -f "$BACKUP_PID_FILE" ] && kill -0 "$(cat "$BACKUP_PID_FILE")" 2>/dev/null && echo "running" || echo "stopped")"
        echo "GLM Proxy: $([ -f /tmp/glm_proxy.pid ] && kill -0 "$(cat /tmp/glm_proxy.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        echo "CF Tunnel: $([ -f /tmp/cloudflared.pid ] && kill -0 "$(cat /tmp/cloudflared.pid)" 2>/dev/null && echo "running" || echo "stopped")"
        ;;
    stop)
        [ -f "$KEEPALIVE_PID_FILE" ] && kill "$(cat "$KEEPALIVE_PID_FILE")" 2>/dev/null && log "KEEPALIVE: stopped"
        rm -f "$KEEPALIVE_PID_FILE"
        ;;
    *) echo "Usage: $0 {start|status|stop}" ;;
esac
