# terraform-spot-eda-hpc-mitigator

반도체 EDA(설계) 및 HPC(고성능 연산) 환경의 비용 최적화를 위한 **AWS 스팟 인스턴스 자동 중단 완화(Mitigation) 인프라 템플릿**입니다. 

AWS의 스팟 회수 경고(2분 전 알림)를 감지하여 실행 중인 시뮬레이션의 상태(State)를 네트워크 스토리지(EFS)에 안전하게 백업하고, 작업 유실을 최소화하는 CLI 기반의 IaC 패키지입니다.

---

## 🏗️ 시스템 아키텍처 (Architecture)

1. **IaC (Terraform):** VPC, Security Group, EFS(Amazon Elastic File System), EC2 스팟 인스턴스를 코드 한 줄로 프로비저닝합니다.
2. **Simulation Worker:** 인스턴스 생성 시 `user_data`를 통해 가상의 대용량 시뮬레이션 파이프라인(Bash 루프)이 백그라운드에서 자동 실행됩니다.
3. **Mitigation Agent (Python):** IMDSv2(인스턴스 메타데이터 서비스)를 5초 주기로 폴링하며 스팟 회수 경고(`instance-action`)를 감시합니다.
4. **Backup & Drain:** 경고 감시 즉시 시뮬레이션 프로세스에 종료 시그널을 보내 작업을 안전하게 안전 자산(EFS 마운트 경로)으로 백업(Dump)하고 프로세스를 종료합니다.

---

## 🚀 빠른 시작 (Quick Start)

### 1. 사전 요구사항
* AWS CLI 자격 증명(Credentials) 설정 완료
* Terraform CLI 설치 완료

### 2. 인프라 배포 및 실행
```bash
git clone https://github.com/YOUR_ACCOUNT/terraform-spot-eda-hpc-mitigator.git
cd terraform-spot-eda-hpc-mitigator
terraform init
terraform apply -auto-approve
```

---

## ⚠️ 현업 적용 시 고려사항 (Production Considerations for Semiconductor Enterprise)

본 저장소는 스팟 중단 대응 흐름을 설명하기 위한 MVP로, 경량 워크로드 기준에서는 2분 내 상태 백업이 가능합니다. 다만 기업의 실제 EDA 결과물(수십~수백 GB)은 같은 방식으로는 2분 안에 EFS로 완전 전송하기 어렵기 때문에, 아래와 같은 프로덕션 확장이 필요합니다.

### 1) 2분의 벽: 백업 중심에서 체크포인트 중심으로

* **한계:** 스팟 중단 알림 후 남은 2분은 대용량 산출물 전체를 네트워크 스토리지로 이동하기에 물리적으로 부족할 수 있습니다.
* **권장 전략:** 인프라 레이어와 애플리케이션 레이어에서 **주기적 체크포인팅(Checkpointing) + 스냅샷**을 병행합니다.
* **운영 방식:** 중단 알림 시점에는 전체 덤프가 아니라 마지막 체크포인트 메타데이터 동기화와 작업 안전 종료(Graceful Shutdown)에 집중합니다.

### 2) HPC 스케줄러 연동: 단일 노드 감지에서 클러스터 오케스트레이션으로

* **한계:** 단일 스크립트 기반 감지는 대규모 HPC 운영(예: 키옥시아급 반도체 환경)에 충분하지 않습니다.
* **권장 전략:** IBM LSF 또는 Slurm과 연동하여 스팟 중단 이벤트를 **클러스터 단위 제어 신호**로 처리합니다.
* **확장 시나리오:**
	1. 중단 알림 수신
	2. 스케줄러 API로 해당 노드를 즉시 Drain 처리
	3. 대기/실행 중 작업을 On-Demand 또는 가용 Spot 노드로 Re-queue
	4. 체크포인트 기준으로 작업 재개