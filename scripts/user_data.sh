#!/bin/bash
set -euo pipefail

# ==============================================================================
# EC2 Spot Instance Bootstrap Script (templatefile로 렌더링됨)
# - EFS 마운트
# - 스크립트 배포 및 실행
# ==============================================================================

LOG_TAG="${project_name}-bootstrap"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LOG_TAG] $*"; }

log "부트스트랩 시작"

# ------------------------------------------------------------------------------
# 1. 패키지 설치
# ------------------------------------------------------------------------------
dnf install -y amazon-efs-utils python3 git

# ------------------------------------------------------------------------------
# 2. EFS 마운트
# ------------------------------------------------------------------------------
EFS_MOUNT="/mnt/efs"
mkdir -p "$EFS_MOUNT"

# EFS mount target DNS 전파 대기 (최대 90초)
RETRY=0
until mount -t efs -o tls,iam ${efs_id}:/ "$EFS_MOUNT" 2>/dev/null; do
  RETRY=$((RETRY + 1))
  if [ "$RETRY" -ge 18 ]; then
    log "ERROR: EFS 마운트 실패 (timeout)"
    exit 1
  fi
  log "EFS 마운트 대기 중... (시도 $RETRY/18)"
  sleep 5
done

chown ec2-user:ec2-user "$EFS_MOUNT"
log "EFS 마운트 완료: ${efs_id} → $EFS_MOUNT"

# fstab 등록 (재부팅 시 자동 마운트)
echo "${efs_id}:/ $EFS_MOUNT efs _netdev,tls,iam 0 0" >> /etc/fstab

# ------------------------------------------------------------------------------
# 3. 워커 스크립트 배포
# ------------------------------------------------------------------------------
WORK_DIR="/opt/eda-hpc"
mkdir -p "$WORK_DIR"

# 현재 인스턴스에 내장된 스크립트를 작업 디렉토리에 복사
# (AMI 빌드 또는 S3 배포 파이프라인으로 대체 가능)
cat > "$WORK_DIR/simulate.sh" << 'SIMULATE_EOF'
${simulate_script}
SIMULATE_EOF

cat > "$WORK_DIR/agent.py" << 'AGENT_EOF'
${agent_script}
AGENT_EOF

cat > "$WORK_DIR/manual_drain.sh" << 'DRAIN_EOF'
${manual_drain_script}
DRAIN_EOF

chmod +x "$WORK_DIR/simulate.sh" "$WORK_DIR/manual_drain.sh"
chown -R ec2-user:ec2-user "$WORK_DIR"

# ------------------------------------------------------------------------------
# 4. 시뮬레이션 및 에이전트 실행
# ------------------------------------------------------------------------------
su - ec2-user -c "
  cd $WORK_DIR
  nohup bash simulate.sh >> /var/log/eda-simulate.log 2>&1 &
  nohup python3 agent.py >> /var/log/eda-agent.log 2>&1 &
"

log "부트스트랩 완료 — 시뮬레이션 및 에이전트 데몬 기동됨"
