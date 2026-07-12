#!/bin/bash
set -euo pipefail
# ==============================================================================
# Manual Drain Trigger — Spot Interruption Simulation & Backup Verification
#
# 스팟 회수 없이 수동으로 Graceful Drain → Backup → (선택) Restart 사이클을
# 실행하여 전체 파이프라인의 정상 동작을 E2E 검증합니다.
#
# Usage:
#   manual_drain.sh [OPTIONS]
#
# Options:
#   -t, --timeout SEC    드레인 대기 시간 (기본: 30)
#   -r, --restart        드레인 후 simulate.sh를 자동 재시작
#   -d, --dry-run        실제 SIGTERM 없이 프리플라이트 체크만 수행
#   -f, --force          확인 프롬프트 건너뛰기
#   -h, --help           도움말
# ==============================================================================

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly WORK_DIR="/opt/eda-hpc"
readonly BACKUP_DIR="/mnt/efs/backup"
readonly PID_FILE="${WORK_DIR}/simulate.pid"
readonly PROGRESS_FILE="${WORK_DIR}/progress.txt"
readonly SIMULATE_SCRIPT="${WORK_DIR}/simulate.sh"
readonly SIMULATE_LOG="/var/log/eda-simulate.log"

# ------------------------------------------------------------------------------
# Defaults (overridable via flags)
# ------------------------------------------------------------------------------
DRAIN_TIMEOUT=30
OPT_RESTART=false
OPT_DRY_RUN=false
OPT_FORCE=false

# ------------------------------------------------------------------------------
# Colors & Logging
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

_ts() { date '+%F %T'; }
log_info()  { echo -e "${CYAN}[$(_ts)] [INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[$(_ts)] [  OK]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[$(_ts)] [WARN]${RESET}  $*"; }
log_fail()  { echo -e "${RED}[$(_ts)] [FAIL]${RESET}  $*"; }
log_step()  { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,2\}//p }' "$0"
    exit 0
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--timeout)  DRAIN_TIMEOUT="${2:?timeout 값이 필요합니다}"; shift 2 ;;
        -r|--restart)  OPT_RESTART=true;  shift ;;
        -d|--dry-run)  OPT_DRY_RUN=true;  shift ;;
        -f|--force)    OPT_FORCE=true;    shift ;;
        -h|--help)     usage ;;
        *)             log_fail "알 수 없는 옵션: $1"; usage ;;
    esac
done

# ------------------------------------------------------------------------------
# Helper: 파일 개수 카운트
# ------------------------------------------------------------------------------
count_files() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# ==============================================================================
# Phase 0: Pre-flight Checks
# ==============================================================================
log_step "Phase 0 — Pre-flight Checks"

CHECKS_PASSED=0
CHECKS_TOTAL=0

preflight() {
    local label="$1" result="$2"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    if [[ "$result" == "ok" ]]; then
        log_ok "$label"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "$label"
    fi
}

# PID 파일 존재
[[ -f "$PID_FILE" ]] && pf_pid="ok" || pf_pid="fail"
preflight "PID 파일 존재 ($PID_FILE)" "$pf_pid"

# PID 파일에서 프로세스 확인
SIM_PID=""
if [[ -f "$PID_FILE" ]]; then
    SIM_PID=$(cat "$PID_FILE")
    if kill -0 "$SIM_PID" 2>/dev/null; then
        preflight "프로세스 활성 (PID $SIM_PID)" "ok"
    else
        preflight "프로세스 활성 (PID $SIM_PID)" "fail"
    fi
else
    preflight "프로세스 활성" "fail"
fi

# 백업 디렉토리 쓰기 가능 여부
if [[ -d "$BACKUP_DIR" ]] && [[ -w "$BACKUP_DIR" ]]; then
    preflight "백업 디렉토리 쓰기 가능 ($BACKUP_DIR)" "ok"
elif mkdir -p "$BACKUP_DIR" 2>/dev/null && [[ -w "$BACKUP_DIR" ]]; then
    preflight "백업 디렉토리 생성 후 쓰기 가능 ($BACKUP_DIR)" "ok"
else
    preflight "백업 디렉토리 쓰기 가능 ($BACKUP_DIR)" "fail"
fi

# EFS 마운트 확인
if mountpoint -q /mnt/efs 2>/dev/null; then
    preflight "EFS 마운트 (/mnt/efs)" "ok"
else
    log_warn "EFS 마운트 확인 불가 — 로컬 환경에서는 무시 가능"
fi

# 결과 요약
log_info "프리플라이트: ${CHECKS_PASSED}/${CHECKS_TOTAL} 통과"

if (( CHECKS_PASSED < CHECKS_TOTAL )); then
    log_fail "필수 조건 미충족 — 중단합니다."
    exit 1
fi

if $OPT_DRY_RUN; then
    log_info "드라이런 모드 — 실제 드레인을 수행하지 않습니다."
    exit 0
fi

# ==============================================================================
# Phase 1: Confirmation
# ==============================================================================
if ! $OPT_FORCE; then
    log_step "Phase 1 — Confirmation"

    # 현재 진행 상태 미리보기
    if [[ -f "$PROGRESS_FILE" ]]; then
        log_info "현재 시뮬레이션 상태: $(cat "$PROGRESS_FILE")"
    fi

    echo ""
    read -rp "  PID $SIM_PID 에 SIGTERM을 보내시겠습니까? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "사용자 취소."
        exit 0
    fi
fi

# ==============================================================================
# Phase 2: SIGTERM & Drain
# ==============================================================================
log_step "Phase 2 — SIGTERM & Drain (timeout: ${DRAIN_TIMEOUT}s)"

BEFORE_COUNT=$(count_files "$BACKUP_DIR")
DRAIN_START=$(date +%s)

log_info "SIGTERM → PID $SIM_PID"
kill -TERM "$SIM_PID"

ELAPSED=0
SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
while kill -0 "$SIM_PID" 2>/dev/null; do
    if (( ELAPSED >= DRAIN_TIMEOUT )); then
        echo ""
        log_fail "드레인 타임아웃 (${DRAIN_TIMEOUT}초) — PID $SIM_PID 미종료"
        log_warn "강제 종료가 필요하면: kill -9 $SIM_PID"
        exit 1
    fi
    # 스피너 표시
    i=$(( ELAPSED % ${#SPIN} ))
    printf "\r  ${CYAN}${SPIN:$i:1}${RESET} 대기 중... %ds / %ds" "$ELAPSED" "$DRAIN_TIMEOUT"
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

DRAIN_END=$(date +%s)
DRAIN_DURATION=$((DRAIN_END - DRAIN_START))
echo ""
log_ok "프로세스 종료 확인 (${DRAIN_DURATION}초 소요)"

# ==============================================================================
# Phase 3: Backup Verification
# ==============================================================================
log_step "Phase 3 — Backup Verification"

AFTER_COUNT=$(count_files "$BACKUP_DIR")

if (( AFTER_COUNT > BEFORE_COUNT )); then
    log_ok "백업 파일 생성 확인 (${BEFORE_COUNT} → ${AFTER_COUNT}개)"
else
    log_fail "새 백업 파일이 생성되지 않았습니다"
    exit 1
fi

# 최신 백업 파일 내용 출력
LATEST=$(find "$BACKUP_DIR" -maxdepth 1 -name 'progress_*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -1 | cut -d' ' -f2-)

# GNU find -printf 미지원 시 fallback
if [[ -z "$LATEST" ]]; then
    LATEST=$(ls -t "$BACKUP_DIR"/progress_*.txt 2>/dev/null | head -1)
fi

if [[ -n "$LATEST" ]]; then
    log_info "최신 백업: $LATEST"
    echo -e "${CYAN}  ┌──────────────────────────────────────${RESET}"
    while IFS= read -r line; do
        echo -e "${CYAN}  │${RESET} $line"
    done < "$LATEST"
    echo -e "${CYAN}  └──────────────────────────────────────${RESET}"
fi

# last_progress.txt 확인
if [[ -f "${BACKUP_DIR}/last_progress.txt" ]]; then
    log_ok "last_progress.txt 백업 확인"
else
    log_warn "last_progress.txt 없음 (progress 기록 전 종료된 경우 정상)"
fi

# ==============================================================================
# Phase 4: (Optional) Restart
# ==============================================================================
if $OPT_RESTART; then
    log_step "Phase 4 — Restart"

    if [[ ! -x "$SIMULATE_SCRIPT" ]]; then
        log_fail "simulate.sh를 찾을 수 없거나 실행 권한이 없습니다: $SIMULATE_SCRIPT"
        exit 1
    fi

    nohup bash "$SIMULATE_SCRIPT" >> "$SIMULATE_LOG" 2>&1 &
    NEW_PID=$!
    sleep 1

    if kill -0 "$NEW_PID" 2>/dev/null; then
        log_ok "시뮬레이션 재시작 (PID $NEW_PID)"
    else
        log_fail "시뮬레이션 재시작 실패"
        exit 1
    fi
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BOLD}━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  드레인 대상     PID $SIM_PID"
echo -e "  드레인 소요     ${DRAIN_DURATION}초"
echo -e "  백업 파일       ${BEFORE_COUNT} → ${AFTER_COUNT}개"
[[ -n "${LATEST:-}" ]] && echo -e "  최신 백업       $LATEST"
$OPT_RESTART && echo -e "  재시작 PID      ${NEW_PID:-N/A}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
log_ok "수동 드레인 검증 완료 ✓"
