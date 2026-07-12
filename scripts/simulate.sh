#!/bin/bash
set -uo pipefail
# ==============================================================================
# EDA HPC Simulation Worker
# - 무한 루프 연산을 수행하며 주기적으로 진행 상태를 기록
# - SIGTERM 수신 시 현재 상태를 EFS로 백업하고 정상 종료
# ==============================================================================

# Configuration
readonly WORK_DIR="/opt/eda-hpc"
readonly PROGRESS_FILE="${WORK_DIR}/progress.txt"
readonly BACKUP_DIR="/mnt/efs/backup"
readonly PID_FILE="${WORK_DIR}/simulate.pid"

CURRENT_SUM=0
CURRENT_NUM=1

# ==============================================================================
# Checkpoint Restore: EFS 백업에서 마지막 상태 복원
# ==============================================================================
restore_checkpoint() {
    local latest
    latest=$(ls -t "${BACKUP_DIR}"/progress_*.txt 2>/dev/null | head -1)

    if [[ -z "$latest" ]]; then
        echo "[$(date '+%F %T')] [RESTORE] 복원할 체크포인트 없음 — 처음부터 시작"
        return
    fi

    local saved_num saved_sum
    saved_num=$(grep '^current_number=' "$latest" | cut -d= -f2)
    saved_sum=$(grep '^current_sum=' "$latest" | cut -d= -f2)

    if [[ -n "$saved_num" && -n "$saved_sum" ]]; then
        CURRENT_NUM=$((saved_num + 1))
        CURRENT_SUM=$saved_sum
        echo "[$(date '+%F %T')] [RESTORE] 체크포인트 복원 완료: num=${CURRENT_NUM} sum=${CURRENT_SUM} (from: $latest)"
    else
        echo "[$(date '+%F %T')] [RESTORE] 체크포인트 파싱 실패 — 처음부터 시작"
    fi
}

# ==============================================================================
# SIGTERM Handler: 상태 백업 후 정상 종료
# ==============================================================================
handle_sigterm() {
    echo "[$(date '+%F %T')] [DRAIN] SIGTERM 수신 — 백업 시작"

    mkdir -p "${BACKUP_DIR}"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${BACKUP_DIR}/progress_${timestamp}.txt"

    {
        echo "backup_time=$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
        echo "reason=spot_interruption"
        echo "current_number=${CURRENT_NUM}"
        echo "current_sum=${CURRENT_SUM}"
        echo "pid=$$"
        echo "hostname=$(hostname)"
    } > "${backup_file}"

    # 마지막 progress 파일도 백업
    if [[ -f "${PROGRESS_FILE}" ]]; then
        cp "${PROGRESS_FILE}" "${BACKUP_DIR}/last_progress.txt"
    fi

    # 최근 2개를 제외한 오래된 백업 파일 정리
    ls -t "${BACKUP_DIR}"/progress_*.txt 2>/dev/null | tail -n +3 | xargs -r rm -f

    echo "[$(date '+%F %T')] [DRAIN] 백업 완료: ${backup_file}"
    rm -f "${PID_FILE}"
    exit 0
}

trap 'handle_sigterm' SIGTERM

# ==============================================================================
# 초기화
# ==============================================================================
mkdir -p "${WORK_DIR}"
echo $$ > "${PID_FILE}"
restore_checkpoint
echo "[$(date '+%F %T')] [START] 시뮬레이션 시작 (PID: $$, num=${CURRENT_NUM}, sum=${CURRENT_SUM})"
echo "num=${CURRENT_NUM} sum=${CURRENT_SUM}" > "${PROGRESS_FILE}"

# ==============================================================================
# Main Loop: 누적합 연산 시뮬레이션
# ==============================================================================
while true; do
    CURRENT_SUM=$((CURRENT_SUM + CURRENT_NUM))

    # 디스크 I/O 부하 방지: 10만 반복마다 상태 기록
    if (( CURRENT_NUM % 100000 == 0 )); then
        echo "num=${CURRENT_NUM} sum=${CURRENT_SUM}" > "${PROGRESS_FILE}"
    fi

    CURRENT_NUM=$((CURRENT_NUM + 1))
done