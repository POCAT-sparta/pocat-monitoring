# POCAT 모니터링 운영 가이드

전체 모니터링 시스템의 구성 요소별 역할, 동작 방식, 설정 방법을 정리한 문서입니다.

---

## 전체 흐름 한눈에 보기

```
백엔드 로그/메트릭 발생
        │
        ├─ 메트릭 ──→ Prometheus (수집) ──→ Grafana 대시보드 (시각화)
        │
        └─ 로그 ───→ Loki (저장)
                          │
                     Grafana Alert Rule (1분마다 감지)
                          │
                     Contact Point (n8n 웹훅 호출)
                          │
                     n8n Workflow
                       ├─ Loki에서 실제 로그 재조회
                       ├─ 태그별로 그룹핑
                       ├─ Gemini AI 분석
                       └─ Slack 채널별 전송
```

---

## 1. Prometheus — 메트릭 수집

### 역할
백엔드 서버에서 주기적으로 메트릭 데이터를 수집(스크래핑)합니다.

### 동작 방식
- 15초마다 `http://pocat-backend:8080/actuator/prometheus` 에 HTTP GET 요청
- 응답받은 메트릭을 시계열 데이터로 저장
- Grafana가 이 데이터를 쿼리해 대시보드에 표시

### 설정 파일 (`prometheus/prometheus.yml`)

```yaml
scrape_configs:
  - job_name: "pocat-backend"
    metrics_path: /actuator/prometheus   # ← 반드시 명시 (기본값 /metrics 아님)
    static_configs:
      - targets: ["pocat-backend:8080"]
```

> **주의**: `metrics_path`를 빠뜨리면 403 또는 404 오류 발생

### 백엔드 설정 요구사항

```yaml
# docker-compose.yml (백엔드)
environment:
  MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE: "health,info,prometheus,metrics"
```

```java
// SecurityConfig.java — actuator 엔드포인트 허용
.requestMatchers("/actuator/health", "/actuator/prometheus").permitAll()
```

---

## 2. Loki — 로그 수집

### 역할
백엔드가 직접 Push하는 로그를 받아 저장합니다. Promtail 없이 백엔드 → Loki 직접 전송 구조입니다.

### 동작 방식
- 백엔드의 Loki4j Appender가 `POST /loki/api/v1/push`로 로그 전송
- 로그에 라벨 태그를 붙여 저장 → 나중에 조건 검색 가능

### 라벨 구조 (백엔드 logback 설정 기준)

| 라벨 | 값 | 설명 |
|---|---|---|
| `service` | `backend` | 하드코딩 |
| `app` | `${spring.application.name}` | 앱 이름 |
| `host` | `${HOSTNAME}` | 서버 호스트 |
| `level` | `ERROR` / `WARN` / `INFO` | 로그 레벨 (대문자) |

### 주요 설정 (`loki/loki-config.yml`)

```yaml
limits_config:
  retention_period: 7d     # 7일 보관 후 자동 삭제

server:
  http_listen_port: 3100   # Push/Query 포트
  grpc_listen_port: 0      # 단일 노드라 비활성화
```

### LogQL 필터 문법

```logql
# ERROR 로그 중 [PAYMENT_ESCALATION] 태그 포함
{service="backend", level="ERROR"} |= "[PAYMENT_ESCALATION]"

# 여러 태그 중 하나 포함 (정규식)
{service="backend", level="ERROR"} |~ "\[EMBEDDING_FAIL\]|\[FAKFA_FAIL\]"

# 특정 태그 제외
{service="backend", level="ERROR"} !~ "\[EMBEDDING_FAIL\]|\[FAKFA_FAIL\]"
```

---

## 3. Grafana 대시보드 — 메트릭 시각화

### 역할
Prometheus에서 수집한 메트릭을 실시간 그래프로 시각화합니다.

### 코드베이스 관리 방식

```
grafana/
├── dashboards/
│   └── pocat-overview.json          ← 대시보드 정의 (JSON)
└── provisioning/
    └── dashboards/
        └── dashboard.yml            ← 대시보드 파일 경로 지정
```

컨테이너 시작 시 자동으로 대시보드가 적용됩니다. UI에서 직접 수정하면 재시작 시 초기화되므로 반드시 JSON 파일을 수정하세요.

### 대시보드 패널 구성

| 섹션 | 주요 패널 |
|---|---|
| 🏷 경매 | 등록 수 / 종료 현황(낙찰·유찰) / 낙찰률 |
| 💰 입찰/주문 | 입찰 수 / 주문 생성(경매·즉시구매) / 취소 수 |
| 💳 결제 | 자동/직접결제 성공·실패 / 실패율 / 소요시간(p50·p95·p99) |
| 🔔 결제 웹훅 | 웹훅 처리 현황 / 금액 불일치 |
| 🖥 시스템 | JVM Heap / HTTP 요청률 / 5xx 에러율 / 응답시간 p99 |
| 🤖 AI 사용량 | 토큰 사용량 / 응답시간 / 에러 수 |

### 멀티 인스턴스 환경 주의사항

`histogram_quantile`은 반드시 `sum(...) by (le)` 로 집계해야 합니다.

```promql
# 잘못된 방식 (인스턴스별 각각 계산)
histogram_quantile(0.99, rate(metric_bucket[1m]))

# 올바른 방식 (전체 합산 후 계산)
histogram_quantile(0.99, sum(rate(metric_bucket[1m])) by (le))
```

---

## 4. Grafana Alert Rule — 에러 감지

### 역할
Loki에 쌓인 로그를 주기적으로 쿼리해 조건을 만족하면 알림을 발동합니다.

### 동작 방식

```
1분마다 Loki에 LogQL 쿼리 실행
→ 결과값 > 0 이면 Alert 발동
→ 설정된 Contact Point로 알림 전송
```

### Alert Rule 구성 요소

| 항목 | 설명 |
|---|---|
| `interval` | 평가 주기 (현재 1분) |
| `expr` | LogQL 쿼리 — 로그 건수를 숫자로 변환 |
| `condition` | 임계값 조건 (결과 > 0이면 발동) |
| `for` | Pending Period — 조건이 지속되어야 하는 시간 (`0s` = 즉시) |
| `labels` | 라우팅 키 — Notification Policy가 이 라벨을 보고 분기 |
| `noDataState` | 데이터 없을 때 상태 (`NoData` = 조용히 대기) |

### 현재 Alert Rule (3개)

```
alert-rule-error.yml  →  level="ERROR" 전체 로그 감지  →  label: level=error
alert-rule-warn.yml   →  level="WARN"  전체 로그 감지  →  label: level=warn
alert-rule-info.yml   →  특정 INFO 태그 로그 감지      →  label: level=info
```

INFO는 모든 로그가 아닌 주요 배치 작업 태그만 감지합니다:
`[CARD_SYNC]`, `[ES_MIGRATION]`, `[RAG_REINDEX]`, `[PAYMENT_ESCALATION]`

### 설정 예시

```yaml
# grafana/provisioning/alerting/alert-rule-error.yml
rules:
  - uid: pocat-level-error          # 고유 ID (변경 금지)
    title: "Backend ERROR 로그 감지"
    condition: C
    data:
      - refId: A
        datasourceUid: loki         # Loki 데이터소스 UID
        model:
          expr: 'sum(count_over_time({service="backend", level="ERROR"}[5m]))'
      - refId: C                    # 임계값 조건 (A > 0)
        datasourceUid: __expr__
        model:
          type: threshold
    for: 0s                         # 즉시 발동
    labels:
      level: error                  # 라우팅 키
```

> **datasourceUid** 값은 `grafana/provisioning/datasources/loki.yml`의 `uid`와 반드시 일치해야 합니다.

---

## 5. Notification Policy — 라우팅 정책

### 역할
Alert Rule의 라벨을 보고 어떤 Contact Point로 보낼지 결정합니다.

### 동작 방식

```
Alert 발동
→ labels 확인 (level=error / level=warn / level=info)
→ matchers와 매칭되는 Contact Point 선택
→ 해당 Contact Point로 알림 전송
```

### 현재 설정

```yaml
# grafana/provisioning/alerting/notification-policy.yml
policies:
  - orgId: 1
    receiver: n8n-webhook-error      # 기본 (매칭 안 되면 여기로)
    routes:
      - receiver: n8n-webhook-warn
        matchers:
          - name: level
            value: warn
            matchType: =
      - receiver: n8n-webhook-info
        matchers:
          - name: level
            value: info
            matchType: =
```

---

## 6. Contact Point — 알림 수신처

### 역할
Grafana가 알림을 보낼 실제 주소(URL)를 정의합니다.

### 현재 설정

```yaml
# grafana/provisioning/alerting/contact-points.yml
contactPoints:
  - name: n8n-webhook-error   →  http://n8n:5678/webhook/grafana-alert-error
  - name: n8n-webhook-warn    →  http://n8n:5678/webhook/grafana-alert-warn
  - name: n8n-webhook-info    →  http://n8n:5678/webhook/grafana-alert-info
```

> Grafana와 n8n이 같은 Docker 네트워크(`pocat-net`)에 있어서 내부 URL로 직접 통신합니다.

---

## 7. n8n Workflow — AI 분석 및 Slack 전송

### 역할
Grafana 알림을 받아 → Loki에서 실제 로그를 조회 → AI 분석 → Slack 전송합니다.

### 워크플로우 구성 (3개)

| 파일 | 웹훅 경로 | 처리 레벨 |
|---|---|---|
| `error-analyzer.json` | `/webhook/grafana-alert-error` | ERROR |
| `warn-analyzer.json` | `/webhook/grafana-alert-warn` | WARN |
| `info-analyzer.json` | `/webhook/grafana-alert-info` | INFO (선택 태그) |

### 처리 흐름

```
① Grafana Webhook 수신
② Parse Alert — alertStatus, 시간 범위(KST) 추출
③ Is Firing? — resolved 알림이면 스킵
④ Query Loki — 해당 레벨의 실제 로그 50건 조회
⑤ Has Logs? — 로그가 없으면 스킵 (NoData 오탐 방지)
⑥ Group by Tag — [TAG] 추출 → 태그별 그룹핑 → 여러 아이템 반환
⑦ Gemini 분석 — 각 아이템(태그 그룹)마다 개별 AI 분석
⑧ Format Slack Message — mrkdwn 형식 후처리
⑨ Send to Slack — 태그별 Slack 채널로 각각 전송
```

### Group by Tag — 핵심 로직

모든 태그 → Slack 채널 라우팅이 이 노드 한 곳에서 관리됩니다.

```javascript
const tagChannelMap = {
  RAG_REINDEX:        $vars.SLACK_WEBHOOK_AI_ALERT,
  EMBEDDING_FAIL:     $vars.SLACK_WEBHOOK_AI_ALERT,
  AUCTION_ANOMALY:    $vars.SLACK_WEBHOOK_ADMIN_ALERT,
  PAYMENT_ESCALATION: $vars.SLACK_WEBHOOK_ADMIN_ALERT,
  CACHE:              $vars.SLACK_WEBHOOK_BACKEND,
  RATE_LIMIT:         $vars.SLACK_WEBHOOK_BACKEND,
  ES_INDEXING:        $vars.SLACK_WEBHOOK_BACKEND,
  CARD_SYNC:          $vars.SLACK_WEBHOOK_BACKEND,
  FAKFA_FAIL:         $vars.SLACK_WEBHOOK_BACKEND,
  SLOW_QUERY:         $vars.SLACK_WEBHOOK_BACKEND,
};
```

**새 태그 추가 방법:** 위 맵에 한 줄만 추가하면 됩니다.

### 워크플로우 활성화

n8n UI에서 Import 후 반드시 **Active** 상태로 변경해야 합니다.

| 상태 | 웹훅 경로 |
|---|---|
| Inactive | `/webhook-test/grafana-alert-error` |
| **Active** | `/webhook/grafana-alert-error` ← 이것만 동작 |

### n8n Variables 설정 필요

n8n UI → Settings → Variables에서 아래 값을 설정합니다.

| 변수명 | 설명 |
|---|---|
| `GEMINI_BASE_URL` | Gemini API 엔드포인트 |
| `GEMINI_API_KEY` | Gemini API 키 |
| `SLACK_WEBHOOK_AI_ALERT` | #ai-alert 채널 Incoming Webhook URL |
| `SLACK_WEBHOOK_ADMIN_ALERT` | #admin-alert 채널 Incoming Webhook URL |
| `SLACK_WEBHOOK_BACKEND` | #backend 채널 Incoming Webhook URL |
| `SLACK_WEBHOOK_ERROR` | #error 채널 Incoming Webhook URL (기본) |

> Slack Incoming Webhook은 OAuth 토큰 없이 채널별 URL 하나로 동작합니다. Slack App 설정에서 채널마다 Incoming Webhook을 활성화해 URL을 발급받으세요.

---

## 8. 전체 파일 구조

```
pocat-monitoring/
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml                    ← 스크래핑 대상 설정
├── loki/
│   └── loki-config.yml                   ← 로그 보관 기간, 포트 설정
├── grafana/
│   ├── dashboards/
│   │   └── pocat-overview.json           ← 대시보드 패널 정의
│   └── provisioning/
│       ├── datasources/
│       │   ├── prometheus.yml            ← Prometheus 데이터소스
│       │   └── loki.yml                  ← Loki 데이터소스 (uid: loki)
│       ├── dashboards/
│       │   └── dashboard.yml             ← 대시보드 경로 지정
│       └── alerting/
│           ├── alert-rule-error.yml      ← ERROR 감지 룰
│           ├── alert-rule-warn.yml       ← WARN 감지 룰
│           ├── alert-rule-info.yml       ← 주요 INFO 감지 룰
│           ├── contact-points.yml        ← n8n 웹훅 주소 정의
│           └── notification-policy.yml   ← 레벨별 라우팅 정책
└── n8n/
    ├── error-analyzer.json               ← ERROR 분석 워크플로우
    ├── warn-analyzer.json                ← WARN 분석 워크플로우
    └── info-analyzer.json                ← INFO 분석 워크플로우
```

---

## 9. 설정 변경 가이드

### 새 로그 태그 추가 시

1. 각 워크플로우 JSON의 `Group by Tag` 노드 `tagChannelMap`에 태그 추가
2. 태그별 AI 역할 프롬프트(`sysPrompts`)에 항목 추가
3. n8n UI에서 워크플로우 재Import

### Alert 민감도 조정 시

```yaml
# alert-rule-*.yml
for: 0s    # 즉시 발동 (기본)
for: 5m    # 5분 지속될 때만 발동 (오탐 감소)
```

```yaml
# notification-policy.yml
repeat_interval: 1h    # 동일 알림 재전송 간격
```

### Grafana 대시보드 수정 시

`grafana/dashboards/pocat-overview.json`을 직접 수정하거나, Grafana UI에서 수정 후 JSON을 Export해서 파일을 덮어씁니다.
