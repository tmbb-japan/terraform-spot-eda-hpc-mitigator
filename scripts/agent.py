#!/usr/bin/env python3
"""
AWS EC2 Spot Interruption Mitigation Agent
Description: Automatically detects Spot instance termination via IMDSv2 
             and gracefully drains running simulation processes.
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

# 로깅 설정 (Standard Output으로 구조화된 로그 출력)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("SpotDetector")

class SpotInterruptionDetector:
    IMDS_BASE_URL = "http://169.254.169.254/latest"
    TOKEN_URL = f"{IMDS_BASE_URL}/api/token"
    ACTION_URL = f"{IMDS_BASE_URL}/meta-data/spot/instance-action"
    
    def __init__(self, target_process="simulate.sh", interval=5, token_ttl=21600):
        self.target_process = target_process
        self.interval = interval
        self.token_ttl = token_ttl
        
        self.token = None
        self.token_expiry = datetime.min

    def _refresh_token(self):
        """IMDSv2 보안 세션 토큰을 선제적으로 발급 및 갱신합니다."""
        if datetime.now() < self.token_expiry - timedelta(minutes=1):
            return True

        logger.debug("IMDSv2 세션 토큰 갱신 시도 중...")
        req = urllib.request.Request(self.TOKEN_URL, method="PUT")
        req.add_header("X-aws-ec2-metadata-token-ttl-seconds", str(self.token_ttl))
        
        try:
            with urllib.request.urlopen(req, timeout=2) as response:
                self.token = response.read().decode('utf-8')
                self.token_expiry = datetime.now() + timedelta(seconds=self.token_ttl)
                logger.debug("IMDSv2 세션 토큰이 성공적으로 발급되었습니다.")
                return True
        except Exception as e:
            logger.error(f"IMDSv2 토큰 발급 실패 (네트워크 또는 IMDS 미활성화 상태): {e}")
            return False

    def send_sigterm_to_target(self):
        """프로덕션 환경에서 오탐 없이 타겟 프로세스를 정확히 찾아 SIGTERM을 전송합니다."""
        try:
            cmd = ["pgrep", "-f", f"([^/ ]*/)?{self.target_process}"]
            pid_bytes = subprocess.check_output(cmd)
            pids = [int(pid) for pid in pid_bytes.decode('utf-8').strip().split('\n') if pid]
            
            my_pid = os.getpid()
            signaled_count = 0

            for pid in pids:
                if pid == my_pid:
                    continue  # 에이전트 자신은 제외
                
                logger.info(f"종료 대상 프로세스 포착 -> {self.target_process} (PID: {pid})")
                os.kill(pid, signal.SIGTERM)
                logger.info(f"PID [{pid}]번에 SIGTERM(종료 및 드레인) 신호를 전달했습니다.")
                signaled_count += 1
                
            if signaled_count == 0:
                logger.warning(f"종료 대상 프로세스 목록에는 있었으나 신호를 보낼 실제 프로세스가 없습니다.")
                
        except subprocess.CalledProcessError:
            logger.warning(f"현재 인스턴스 내에서 활성화된 '{self.target_process}' 프로세스를 찾을 수 없습니다.")
        except Exception as e:
            logger.error(f"프로세스 시그널 전송 중 예기치 못한 실패 발생: {e}")

    def start_polling(self):
        """5초 주기로 IMDSv2 엔드포인트를 감시하는 메인 루프입니다."""
        logger.info(f"스팟 알림 데몬이 시작되었습니다. (대상: {self.target_process}, 주기: {self.interval}s)")
        
        while True:
            if not self._refresh_token():
                # 토큰 갱신 실패 시 다음 루프에서 재시도
                time.sleep(self.interval)
                continue

            req = urllib.request.Request(self.ACTION_URL)
            req.add_header("X-aws-ec2-metadata-token", self.token)

            try:
                with urllib.request.urlopen(req, timeout=2) as response:
                    if response.status == 200:
                        meta_data = response.read().decode('utf-8')
                        
                        logger.critical("🚨 [SPOT INTERRUPTION DETECTED] AWS로부터 스팟 회수 알림을 수신했습니다!")
                        logger.critical(f"상세 메타데이터 원본: {meta_data}")
                        logger.info("▶️ [Graceful Drain] 인프라 대피 작업을 가동합니다. 시뮬레이션 강제 정지 시퀀스 진입.")
                        
                        # 시뮬레이션 프로세스 중단 처리
                        self.send_sigterm_to_target()
                        
                        logger.info("에이전트 임무 완료. 모니터링 데몬을 종료합니다.")
                        sys.exit(0)

            except urllib.error.HTTPError as e:
                if e.code == 404:
                    # 평상시 상태: 중단 알림이 없는 경우 AWS가 404를 반환하는 것이 정상 스펙
                    pass
                elif e.code == 401:
                    logger.warning("인증 토큰이 만료되었거나 무효화되었습니다. 다음 루프에서 즉시 갱신합니다.")
                    self.token_expiry = datetime.min
                else:
                    logger.error(f"IMDSv2 통신 중 예외적 HTTP 에러 발생 (Status Code: {e.code})")
            except urllib.error.URLError as e:
                logger.error(f"IMDSv2 서버와 통신할 수 없습니다 (네트워크 타임아웃 또는 미연결): {e.reason}")
            except Exception as e:
                logger.error(f"시스템 예외 발생: {e}")

            time.sleep(self.interval)

if __name__ == "__main__":
    try:
        detector = SpotInterruptionDetector(target_process="simulate.sh", interval=5)
        detector.start_polling()
    except KeyboardInterrupt:
        logger.info("사용자 요청(SIGINT)에 의해 모니터 데몬이 안전하게 정지되었습니다.")
        sys.exit(0)
    except Exception as fatal_err:
        logger.critical(f"에이전트가 예기치 못한 치명적 오류로 다운되었습니다: {fatal_err}")
        sys.exit(1)