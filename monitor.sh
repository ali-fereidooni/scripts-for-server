#!/usr/bin/env bash

SESSION="server-monitor"

# Check dependencies
if ! command -v tmux >/dev/null 2>&1; then
    echo "Error: tmux is not installed."
    exit 1
fi

# If session already exists, attach to it
if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach-session -t "$SESSION"
    exit 0
fi

# Create session
tmux new-session -d -s "$SESSION" -n "Overview"

# Helper function to execute commands in panes
run() {
    tmux send-keys -t "$1" "$2" C-m
}

# ==========================================
# WINDOW 1: OVERVIEW
# ==========================================

tmux split-window -h -t "$SESSION:Overview"
tmux split-window -v -t "$SESSION:Overview.0"
tmux split-window -v -t "$SESSION:Overview.2"

tmux select-layout -t "$SESSION:Overview" tiled

run "$SESSION:Overview.0" \
"watch -n 2 'uptime; echo; cat /proc/loadavg'"

run "$SESSION:Overview.1" \
"watch -n 2 'top -b -n1 | head -20'"

run "$SESSION:Overview.2" \
"watch -n 2 'free -h; echo; cat /proc/meminfo | head -10'"

run "$SESSION:Overview.3" \
"watch -n 10 'df -hT'"

# ==========================================
# WINDOW 2: CPU
# ==========================================

tmux new-window -t "$SESSION" -n "CPU"

tmux split-window -h -t "$SESSION:CPU"

tmux select-layout -t "$SESSION:CPU" tiled

run "$SESSION:CPU.0" \
"top -d 2"

run "$SESSION:CPU.1" \
"vmstat 2"

# ==========================================
# WINDOW 3: MEMORY
# ==========================================

tmux new-window -t "$SESSION" -n "Memory"

tmux split-window -h -t "$SESSION:Memory"

tmux select-layout -t "$SESSION:Memory" tiled

run "$SESSION:Memory.0" \
"watch -n 2 'free -h'"

run "$SESSION:Memory.1" \
"watch -n 2 'cat /proc/meminfo | head -20'"

# ==========================================
# WINDOW 4: DISK
# ==========================================

tmux new-window -t "$SESSION" -n "Disk"

tmux split-window -h -t "$SESSION:Disk"

tmux select-layout -t "$SESSION:Disk" tiled

run "$SESSION:Disk.0" \
"watch -n 5 'df -hT; echo; lsblk'"

run "$SESSION:Disk.1" \
"if command -v iostat >/dev/null 2>&1; then iostat -xz 2; else vmstat 2; fi"

# ==========================================
# WINDOW 5: NETWORK
# ==========================================

tmux new-window -t "$SESSION" -n "Network"

tmux split-window -h -t "$SESSION:Network"

tmux select-layout -t "$SESSION:Network" tiled

run "$SESSION:Network.0" \
"watch -n 2 'ip -s link'"

run "$SESSION:Network.1" \
"watch -n 2 'ss -s; echo; ss -tuna | head -30'"

# ==========================================
# WINDOW 6: PROCESSES
# ==========================================

tmux new-window -t "$SESSION" -n "Processes"

run "$SESSION:Processes.0" \
"if command -v htop >/dev/null 2>&1; then htop; else top; fi"

# ==========================================
# FINISH
# ==========================================

tmux select-window -t "$SESSION:Overview"

tmux attach-session -t "$SESSION"
