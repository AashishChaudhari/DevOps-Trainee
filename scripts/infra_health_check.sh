#!/bin/bash
# infra_health_check.sh
# Checks system resources and Docker container health.
# Logs a [WARNING] if disk usage > 85% or any monitored container is not running.

LOG_FILE="/var/log/infra_health.log"
DISK_THRESHOLD=85
CONTAINERS=("flask_app" "nginx_proxy" "postgres_db")

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# --- Resource checks ---
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
MEM_USAGE=$(free | awk '/Mem:/ {printf "%.2f", $3/$2 * 100}')
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

echo "===== Infra Health Check: $TIMESTAMP ====="
echo "CPU Usage: ${CPU_USAGE}%"
echo "RAM Usage: ${MEM_USAGE}%"
echo "Disk Usage (/): ${DISK_USAGE}%"

WARNING_TRIGGERED=false

# --- Disk threshold check ---
if [ "$DISK_USAGE" -ge "$DISK_THRESHOLD" ]; then
    echo "[WARNING] Disk usage is at ${DISK_USAGE}%, exceeding ${DISK_THRESHOLD}% threshold."
    echo "$TIMESTAMP [WARNING] Disk usage at ${DISK_USAGE}% (threshold: ${DISK_THRESHOLD}%)" >> "$LOG_FILE"
    WARNING_TRIGGERED=true
fi

# --- Docker daemon check ---
if ! systemctl is-active --quiet docker; then
    echo "[WARNING] Docker service is not running."
    echo "$TIMESTAMP [WARNING] Docker service is not running." >> "$LOG_FILE"
    WARNING_TRIGGERED=true
else
    echo "Docker service: running"

    # --- Container status checks ---
    for CONTAINER in "${CONTAINERS[@]}"; do
        STATUS=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)

        if [ "$STATUS" == "true" ]; then
            echo "Container '$CONTAINER': running"
        else
            echo "[WARNING] Container '$CONTAINER' is stopped or not found."
            echo "$TIMESTAMP [WARNING] Container '$CONTAINER' is stopped or not found." >> "$LOG_FILE"
            WARNING_TRIGGERED=true
        fi
    done
fi

if [ "$WARNING_TRIGGERED" = false ]; then
    echo "All checks passed. No issues detected."
fi

echo "==========================================="
exit 0
