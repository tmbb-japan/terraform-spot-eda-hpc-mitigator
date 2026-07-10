#!/bin/bash

# ==========================================
# 설정 변수
# ==========================================
PROGRESS_FILE="progress.txt"
BACKUP_DIR="/mnt/efs/backup"
CURRENT_SUM=0
CURRENT_NUM=1

# ==========================================
# SIGTERM 핸들러 (백업 및 종료 로직)
# ==========================================
handle_sigterm() {
    echo ""
    echo "[WARN] SIGTERM 신호를 수신했습니다. 연산을 중지합니다..."
    
    # 백업 디렉토리가 존재하지 않으면 생성
    mkdir -p "${BACKUP_DIR}"
    
    # 타임스탬프 생성
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="${BACKUP_DIR}/progress_${TIMESTAMP}.txt"
    
    # EFS 마운트 경로로 progress.txt 및 타임스탬프 덤프(Dump)
    {
        echo "=== 스팟 인스턴스 중단에 의한 백업 ==="
        echo "백업 시간: $(date)"
        echo "마지막 상태:"
        cat "${PROGRESS_FILE}"
    } > "${BACKUP_FILE}"
    
    echo "[INFO] 상태 및 타임스탬프가 안전하게 저장되었습니다: ${BACKUP_FILE}"
    echo "[INFO] 프로세스를 종료합니다."
    exit 0
}

# 에이전트로부터 SIGTERM(15) 수신 시 handle_sigterm 함수 실행
trap 'handle_sigterm' SIGTERM

# ==========================================
# 메인 시뮬레이션 루프
# ==========================================
echo "[INFO] 시뮬레이션을 시작합니다. (PID: $$)"
echo "Current Number: 0 | Current Sum: 0" > "${PROGRESS_FILE}"

while true; do
    CURRENT_SUM=$((CURRENT_SUM + CURRENT_NUM))
    
    # 디스크 I/O 병목 현상을 방지하기 위해 10만 번 연산마다 파일에 기록
    if (( CURRENT_NUM % 100000 == 0 )); then
        echo "Current Number: ${CURRENT_NUM} | Current Sum: ${CURRENT_SUM}" > "${PROGRESS_FILE}"
    fi
    
    CURRENT_NUM=$((CURRENT_NUM + 1))
done