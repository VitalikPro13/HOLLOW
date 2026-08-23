#!/usr/bin/env bash
# Linux counterpart to perf_threads.ps1 + perf_memory.ps1.
#
# Reports what a running Hollow actually costs on Linux: resident and
# proportional memory, CPU over a sampling window, and the per-thread CPU
# split by thread NAME (Flutter, tokio and libwebrtc all name their threads),
# so "is it Rust or is it the renderer" is answerable here too.
#
# RSS double-counts shared pages across processes; PSS divides them by the
# number of sharers and is the honest per-process number on Linux.
#
# Usage: bash scripts/perf_linux.sh [process_name] [seconds]

set -u
NAME="${1:-hollow}"
SECS="${2:-20}"

PID="$(pgrep -x "$NAME" | head -1)"
if [ -z "$PID" ]; then
  echo "no process named '$NAME' is running"
  exit 1
fi

HZ="$(getconf CLK_TCK)"
NCPU="$(nproc)"

read_proc_cpu() {
  # utime + stime of the whole process, in clock ticks
  awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null
}

echo "=== $NAME (pid $PID) ==="
echo "uptime: $(ps -o etime= -p "$PID" | tr -d ' ')   cores: $NCPU"
echo

# ---- memory ----
echo "--- memory ---"
if [ -r "/proc/$PID/smaps_rollup" ]; then
  awk '
    /^Rss:/            { rss = $2 }
    /^Pss:/            { pss = $2 }
    /^Private_Clean:/  { pc  = $2 }
    /^Private_Dirty:/  { pd  = $2 }
    /^Shared_Clean:/   { sc  = $2 }
    /^Shared_Dirty:/   { sd  = $2 }
    /^Swap:/           { sw  = $2 }
    END {
      printf "  RSS (resident)        %8.1f MB   what top/System Monitor show\n", rss/1024
      printf "  PSS (proportional)    %8.1f MB   <- the honest per-process number\n", pss/1024
      printf "  private (clean+dirty) %8.1f MB   cannot be shared with anything\n", (pc+pd)/1024
      printf "  shared                %8.1f MB\n", (sc+sd)/1024
      printf "  swap                  %8.1f MB\n", sw/1024
    }' "/proc/$PID/smaps_rollup"
else
  awk '/^VmRSS:/ { printf "  RSS %8.1f MB\n", $2/1024 }' "/proc/$PID/status"
fi
awk '/^VmSize:/ { printf "  VmSize (address space)%8.1f MB   reserved, not charged\n", $2/1024 }' "/proc/$PID/status"
echo "  threads: $(awk '/^Threads:/ {print $2}' "/proc/$PID/status")   fds: $(ls "/proc/$PID/fd" 2>/dev/null | wc -l)"
echo

# ---- cpu over the window ----
echo "--- cpu over ${SECS}s ---"
declare -A T0
for t in /proc/$PID/task/*; do
  tid="${t##*/}"
  T0["$tid"]="$(awk '{print $14 + $15}' "$t/stat" 2>/dev/null)"
done
P0="$(read_proc_cpu "$PID")"

sleep "$SECS"

P1="$(read_proc_cpu "$PID")"
if [ -z "$P1" ]; then echo "  process exited during sampling"; exit 1; fi
TOTAL_MS=$(( (P1 - P0) * 1000 / HZ ))
WALL_MS=$(( SECS * 1000 ))
echo "  process total: ${TOTAL_MS} ms CPU over ${WALL_MS} ms wall = $(awk -v a="$TOTAL_MS" -v b="$WALL_MS" 'BEGIN{printf "%.1f", 100*a/b}')% of one core"
echo

printf "  %8s %8s %6s  %s\n" "TID" "CPU_MS" "PCT" "THREAD NAME"
for t in /proc/$PID/task/*; do
  tid="${t##*/}"
  c1="$(awk '{print $14 + $15}' "$t/stat" 2>/dev/null)"
  c0="${T0[$tid]:-}"
  [ -z "$c1" ] && continue
  [ -z "$c0" ] && c0=0
  ms=$(( (c1 - c0) * 1000 / HZ ))
  [ "$ms" -le 0 ] && continue
  nm="$(cat "$t/comm" 2>/dev/null)"
  printf "  %8s %8s %6s  %s\n" "$tid" "$ms" "$(awk -v a="$ms" -v b="$WALL_MS" 'BEGIN{printf "%.2f", 100*a/b}')" "$nm"
done | sort -k2 -rn | head -20
echo
echo "  (threads with 0 ms omitted; a Rust runtime at 0 ms is the point)"
