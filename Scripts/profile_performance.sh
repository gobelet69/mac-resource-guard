#!/usr/bin/env zsh
set -euo pipefail

APP_BIN="${1:-/Users/theodeville/Documents/Mac Ressource Guard/dist/MacResourceGuard.app/Contents/MacOS/MacResourceGuard}"
REPORT_OUT="${2:-/Users/theodeville/Documents/Mac Ressource Guard/PERFORMANCE_AUDIT.md}"

if [[ ! -x "$APP_BIN" ]]; then
  echo "Error: Executable not found at $APP_BIN"
  exit 1
fi

echo "==> Launching MacResourceGuard for performance profiling..."
"$APP_BIN" >/dev/null 2>&1 &
APP_PID=$!
trap "kill $APP_PID >/dev/null 2>&1 || true" EXIT

sleep 3

echo "==> Measuring initial startup RSS and physical footprint (PID $APP_PID)..."
STARTUP_PS=$(ps -p "$APP_PID" -o pid,rss,%cpu,vsz)
VMMAP_SUMMARY=$(vmmap -summary "$APP_PID" 2>/dev/null | grep -E "Physical footprint|Physical footprint \(peak\)|dirty" | head -n 6 || true)

echo "==> Sampling 22 seconds of idle operation (low-frequency 10s interval)..."
TOP_IDLE=$(top -l 12 -s 2 -pid "$APP_PID" -stats pid,cpu,mem,idlew | grep -E "^[[:space:]]*${APP_PID}[[:space:]]" || true)

echo "==> Running Controlled Reversible CPU Load Validation..."
python3 -c "import time; end = time.time() + 8; 
while time.time() < end: _ = sum(i*i for i in range(10000))" &
LOAD_PID=$!

sleep 2
# Trigger detailed sampling via popover while load is active
"$APP_BIN" --open-popover >/dev/null 2>&1 &
POPOVER_PID=$!
sleep 3
TOP_DETAILED=$(top -l 3 -s 1 -pid "$POPOVER_PID" -stats pid,cpu,mem,idlew | grep -E "^[[:space:]]*${POPOVER_PID}[[:space:]]" || true)
kill "$POPOVER_PID" >/dev/null 2>&1 || true
wait "$LOAD_PID" >/dev/null 2>&1 || true

echo "==> Checking for memory leaks via macOS leaks tool..."
LEAKS_OUT=$(leaks "$APP_PID" 2>&1 | grep -E "Process $APP_PID:|leaks for|0 leaks" || true)

echo "==> Sampling call stack for main-thread responsiveness..."
SAMPLE_OUT=$(sample "$APP_PID" 2 2>&1 | grep -A 12 "Call graph:" || true)

cat <<EOF > "$REPORT_OUT"
# Mac Resource Guard — Empirical Performance Audit

- **Hardware**: $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) logical cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM)
- **OS**: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))
- **Build Configuration**: Release (\`-O -whole-module-optimization\`, stripped)

## 1. Memory Footprint (Target: < 40 MB)

\`\`\`
PS (PID, RSS_KB, %CPU, VSZ_KB):
$STARTUP_PS

vmmap -summary:
$VMMAP_SUMMARY
\`\`\`

## 2. Idle CPU & Wakeups Over 22s Window (Target: < 0.2% Avg Idle CPU)

\`\`\`
PID    %CPU   MEM      PURG   IDLEW  THREADS
$TOP_IDLE
\`\`\`

## 3. Detailed Sampling Under Controlled CPU Load

\`\`\`
PID    %CPU   MEM      IDLEW  THREADS
$TOP_DETAILED
\`\`\`

## 4. Memory Leak Verification (\`leaks\`)

\`\`\`
$LEAKS_OUT
\`\`\`

## 5. Call Graph & Main Thread Responsiveness (\`sample\`)

\`\`\`
$SAMPLE_OUT
\`\`\`
EOF

echo "==> Audit written to $REPORT_OUT"
