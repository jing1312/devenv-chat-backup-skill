#!/bin/bash
# github-accel.sh — GitHub 加速脚本（镜像 + 代理）
# 参考 devenv-chat-backup-skill 的 github-accel.sh

GHACCEL_LOG="/var/log/github-accel.log"
GHACCEL_PID_FILE="/var/run/github-accel.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$GHACCEL_LOG" 2>/dev/null; }

# GitHub 镜像源列表
MIRRORS=(
    "https://ghfast.top/"
    "https://ghproxy.com/"
    "https://gh-proxy.com/"
    "https://ghps.cc/"
    "https://mirror.ghproxy.com/"
)

# 测试哪个镜像最快
test_mirror() {
    local mirror="$1"
    local start_time end_time duration
    start_time=$(date +%s%N)
    if curl -sL -o /dev/null --connect-timeout 3 --max-time 5 "${mirror}https://github.com/git/git/raw/refs/heads/master/README.md" 2>/dev/null; then
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))
        echo "$duration"
        return 0
    fi
    echo "999999"
    return 1
}

# 找到最快的镜像
find_fastest_mirror() {
    local fastest="" fastest_time=999999
    for mirror in "${MIRRORS[@]}"; do
        local time; time=$(test_mirror "$mirror")
        log "MIRROR: $mirror -> ${time}ms"
        if [ "$time" -lt "$fastest_time" ]; then
            fastest_time=$time
            fastest="$mirror"
        fi
    done
    if [ -n "$fastest" ] && [ "$fastest_time" -lt 999999 ]; then
        echo "$fastest"
        log "MIRROR: fastest = $fastest (${fastest_time}ms)"
        return 0
    fi
    log "MIRROR: all mirrors failed"
    return 1
}

# 加速 git clone
accel_clone() {
    local url="$1"
    local target="${2:-$(basename "$url" .git)}"
    
    if [ -z "$url" ]; then
        echo "Usage: $0 clone <url> [target]"
        return 1
    fi
    
    # 尝试直接 clone（可能已经够快）
    local clone_err
    log "CLONE: trying direct: $url"
    clone_err=$(timeout 10 git clone --depth 1 "$url" "$target" 2>&1)
    if [ $? -eq 0 ] && [ -d "$target/.git" ]; then
        log "CLONE: direct success"
        echo "Clone success (direct)"
        return 0
    fi
    log "CLONE: direct failed: $(echo "$clone_err" | tail -1)"
    
    # 尝试镜像加速
    local mirror; mirror=$(find_fastest_mirror)
    if [ -n "$mirror" ]; then
        local accel_url="${mirror}${url}"
        log "CLONE: trying mirror: $accel_url"
        clone_err=$(timeout 30 git clone --depth 1 "$accel_url" "$target" 2>&1)
        if [ $? -eq 0 ] && [ -d "$target/.git" ]; then
            log "CLONE: mirror success"
            # 修正 remote URL
            cd "$target" 2>/dev/null && git remote set-url origin "$url" 2>/dev/null
            echo "Clone success (via $mirror)"
            return 0
        fi
        log "CLONE: mirror failed: $(echo "$clone_err" | tail -1)"
    fi
    
    log "CLONE: all methods failed"
    echo "Clone failed: $(echo "$clone_err" | tail -1)"
    return 1
}

# 加速 git pull
accel_pull() {
    local remote="${1:-origin}"
    local branch="${2:-main}"
    
    # 获取当前 remote URL
    local url; url=$(git remote get-url "$remote" 2>/dev/null)
    if [ -z "$url" ]; then
        echo "No remote '$remote' found"
        return 1
    fi
    
    local pull_err
    log "PULL: trying direct: $url"
    pull_err=$(timeout 15 git pull --depth 1 "$remote" "$branch" 2>&1)
    if [ $? -eq 0 ]; then
        log "PULL: direct success"
        echo "Pull success (direct)"
        return 0
    fi
    log "PULL: direct failed: $(echo "$pull_err" | tail -1)"
    
    # 尝试镜像
    local mirror; mirror=$(find_fastest_mirror)
    if [ -n "$mirror" ]; then
        local accel_url="${mirror}${url}"
        log "PULL: trying mirror: $accel_url"
        pull_err=$(timeout 30 git pull --depth 1 "$accel_url" "$branch" 2>&1)
        if [ $? -eq 0 ]; then
            log "PULL: mirror success"
            echo "Pull success (via $mirror)"
            return 0
        fi
        log "PULL: mirror failed: $(echo "$pull_err" | tail -1)"
    fi
    
    log "PULL: all methods failed"
    echo "Pull failed: $(echo "$pull_err" | tail -1)"
    return 1
}

# 配置 git 全局加速
setup_git_config() {
    # 设置 git 超时
    git config --global http.lowSpeedLimit 1000 2>/dev/null
    git config --global http.lowSpeedTime 10 2>/dev/null
    git config --global http.postBuffer 524288000 2>/dev/null
    
    # 并发传输
    git config --global http.maxRequests 5 2>/dev/null
    
    log "GIT_CONFIG: configured"
    echo "Git config updated"
}

case "${1:-}" in
    clone) shift; accel_clone "$@" ;;
    pull) shift; accel_pull "$@" ;;
    config) setup_git_config ;;
    test) find_fastest_mirror ;;
    *)
        echo "Usage: $0 {clone <url> [target]|pull [remote] [branch]|config|test}"
        echo "  clone  - 加速 git clone（自动选最快镜像）"
        echo "  pull   - 加速 git pull（自动选最快镜像）"
        echo "  config - 配置 git 全局加速参数"
        echo "  test   - 测试所有镜像速度"
        ;;
esac
