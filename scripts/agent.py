#!/usr/bin/env python3
"""
AWS EC2 Spot Interruption Mitigation Agent

IMDSv2를 통해 스팟 중단 알림을 감지하고,
실행 중인 시뮬레이션 프로세스를 Graceful Drain 처리합니다.

환경 변수:
  TARGET_PROCESS  - 종료 대상 프로세스 식별자 (기본: simulate.sh)
  POLL_INTERVAL   - 폴링 주기 초 (기본: 5)
  BACKUP_DIR      - 백업 확인 경로 (기본: /mnt/efs/backup)
  DRAIN_TIMEOUT   - 드레인 대기 최대 초 (기본: 90)
"""

import os
import sys
import time
import signal
import logging
import subprocess
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from pathlib import Path

# ==============================================================================
# Configuration (환경 변수 기반 설정)
# ==============================================================================
TARGET_PROCESS = os.environ.get("TARGET_PROCESS", "simulate.sh")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))
BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", "/mnt/efs/backup"))
DRAIN_TIMEOUT = int(os.environ.get("DRAIN_TIMEOUT", "90"))

# ==============================================================================
# Logging
# ==============================================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("spot-agent")


class SpotInterruptionAgent:
    """IMDSv2 기반 스팟 중단 감지 및 Graceful Drain 에이전트."""

    IMDS_BASE = "http://169.254.169.254/latest"
    TOKEN_URL = f"{IMDS_BASE}/api/token"
    ACTION_URL = f"{IMDS_BASE}/meta-data/spot/instance-action"
    TOKEN_TTL = 21600  # 6시간

    def __init__(self):
        self._token: str | None = None
        self._token_expiry: datetime = datetime.min
        self._running = True

        # 에이전트 자체 시그널 핸들링
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

    def _handle_shutdown(self, signum, frame):
        """에이전트 자체의 정상 종료 처리."""
        sig_name = signal.Signals(signum).name
        logger.info(f"에이전트가 {sig_name} 시그널을 수신하여 종료합니다.")
        self._running = False

    # --------------------------------------------------------------------------
    # IMDSv2 Token Management
    # --------------------------------------------------------------------------
    def _refresh_token(self) -> bool:
        """만료 1분 전 선제적으로 IMDSv2 세션 토큰을 갱신합니다."""
        if datetime.now() < self._token_expiry - timedelta(minutes=1):
            return True

        req = urllib.request.Request(self.TOKEN_URL, method="PUT")
        req.add_header("X-aws-ec2-metadata-token-ttl-seconds", str(self.TOKEN_TTL))

        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                self._token = resp.read().decode("utf-8")
                self._token_expiry = datetime.now() + timedelta(seconds=self.TOKEN_TTL)
                return True
        except Exception as e:
            logger.error(f"IMDSv2 토큰 갱신 실패: {e}")
            return False

    # --------------------------------------------------------------------------
    # Process Signal Dispatch
    # --------------------------------------------------------------------------
    def _send_sigterm(self) -> list[int]:
        """타겟 프로세스를 찾아 SIGTERM을 전송합니다. 시그널을 보낸 PID 목록을 반환."""
        signaled: list[int] = []
        try:
            result = subprocess.run(
                ["pgrep", "-f", TARGET_PROCESS],
                capture_output=True, text=True, check=True
            )
            pids = [int(p) for p in result.stdout.strip().split("\n") if p]
        except subprocess.CalledProcessError:
            logger.warning(f"활성 프로세스 없음: {TARGET_PROCESS}")
            return signaled

        my_pid = os.getpid()
        for pid in pids:
            if pid == my_pid:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
                logger.info(f"SIGTERM → PID {pid}")
                signaled.append(pid)
            except ProcessLookupError:
                pass
            except PermissionError:
                logger.error(f"PID {pid} 시그널 권한 없음")

        return signaled

    def _wait_for_drain(self, pids: list[int]) -> bool:
        """대상 프로세스가 종료될 때까지 최대 DRAIN_TIMEOUT초 대기합니다."""
        deadline = time.time() + DRAIN_TIMEOUT
        remaining = set(pids)

        while remaining and time.time() < deadline:
            for pid in list(remaining):
                try:
                    os.kill(pid, 0)  # 프로세스 존재 확인 (시그널 전송 안 함)
                except ProcessLookupError:
                    remaining.discard(pid)
                    logger.info(f"PID {pid} 정상 종료 확인")
            if remaining:
                time.sleep(1)

        if remaining:
            logger.warning(f"드레인 타임아웃 — 미종료 PID: {remaining}")
            return False
        return True

    # --------------------------------------------------------------------------
    # Main Polling Loop
    # --------------------------------------------------------------------------
    def run(self):
        """메인 이벤트 루프: IMDSv2 폴링 → 중단 감지 → Graceful Drain."""
        logger.info(
            f"스팟 에이전트 시작 | target={TARGET_PROCESS} "
            f"interval={POLL_INTERVAL}s drain_timeout={DRAIN_TIMEOUT}s"
        )

        while self._running:
            if not self._refresh_token():
                time.sleep(POLL_INTERVAL)
                continue

            req = urllib.request.Request(self.ACTION_URL)
            req.add_header("X-aws-ec2-metadata-token", self._token)

            try:
                with urllib.request.urlopen(req, timeout=3) as resp:
                    if resp.status == 200:
                        body = resp.read().decode("utf-8")
                        logger.critical(f"[SPOT INTERRUPTION] 회수 알림 수신: {body}")

                        # Phase 1: 시뮬레이션 프로세스 종료 요청
                        pids = self._send_sigterm()

                        # Phase 2: 프로세스 종료 대기 (백업 완료 보장)
                        if pids:
                            self._wait_for_drain(pids)

                        # Phase 3: 백업 파일 존재 확인
                        if BACKUP_DIR.exists() and any(BACKUP_DIR.iterdir()):
                            logger.info(f"백업 확인 완료: {BACKUP_DIR}")
                        else:
                            logger.warning(f"백업 디렉토리 비어있음: {BACKUP_DIR}")

                        logger.info("드레인 시퀀스 완료. 에이전트 종료.")
                        return

            except urllib.error.HTTPError as e:
                if e.code == 404:
                    pass  # 정상: 중단 알림 없음
                elif e.code == 401:
                    logger.warning("토큰 만료 감지 — 다음 루프에서 갱신")
                    self._token_expiry = datetime.min
                else:
                    logger.error(f"IMDS HTTP 에러: {e.code}")
            except urllib.error.URLError as e:
                logger.error(f"IMDS 연결 불가: {e.reason}")
            except Exception as e:
                logger.error(f"예외 발생: {e}")

            time.sleep(POLL_INTERVAL)

        logger.info("에이전트 정상 종료.")


if __name__ == "__main__":
    agent = SpotInterruptionAgent()
    agent.run()
