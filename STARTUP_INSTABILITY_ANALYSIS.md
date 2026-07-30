# build_and_verify.sh × ローカル compose 環境 起動不安定問題 調査報告

対象:

| プロジェクト | パス | 役割 |
| --- | --- | --- |
| Container_Compose_Build_Push_v2_from_Codex | `build_and_verify.sh` ほか | ビルド・起動確認・調査スクリプト |
| Container_Compose_file | `compose.yaml` ほか | 検証対象のローカル compose 環境 (17 サービス) |

事象: フロントコンテナ (`app-front`) を検証対象に指定し、バック / MySQL / ecs-mock などを
同時に起動対象とすると、**MySQL のデータベースホストが見つからずバックコンテナが異常終了**したり、
**ecs-mock から ECS タスク ID を取得できずフロントコンテナが起動しなかったり**する。
すべて成功することもある。

---

## 1. 結論 (先に要点)

不安定さの正体は **「依存ゲートが開く時刻」と「モックが listen を開始する時刻」の競合**である。

```
mysql がウォーム   → 依存ゲートが t≈15s で開く → WireMock がまだ listen していない
                                                 → ECS タスク ID 取得失敗   [症状B]

mysql がコールド   → 依存ゲートが t≈60s で開く → WireMock は listen 済み
                                                 → 全て成功

mysql が超コールド → 130s 以内に healthy にならない
                    → compose が dependency failed to start で中断        [症状A]
```

**起動が速い回ほど症状 B、遅い回ほど症状 A、その中間で全て成功する**という逆相関が生じている。

根本原因は 3 つ。

1. `ecs-metadata-mock` / `svf-mock` / `valkey` に **healthcheck が無く**、依存側は
   `condition: service_started` (= コンテナが起動しただけ) で待っている。
   WireMock は JVM 起動なので listen まで 4〜30 秒かかる。
2. `mysql` の healthcheck が `mysqladmin ping` で、**「サーバが応答すること」しか検証していない**
   (認証エラーでも exit 0 を返す仕様)。かつ猶予が約 130 秒しかなく、コールド初期化時に
   compose 側がタイムアウトする。
3. `build_and_verify.sh` が **`base` サービスまで起動対象に含めており**、待機処理 (`--wait`) を
   持たず、**起動対象サービスの異常終了を検知できない**。

---

## 2. compose 環境構成 (Container_Compose_file)

### 2.1 目的

プロジェクト名 `eap-adot-local`。**AWS に一切接続せず**、ECS/Fargate 本番構成をローカルで
等価検証するための 17 サービス構成。

ECS 本番との最大の差異は**ネットワーク名前空間**。ECS では front / back / adot-collector /
cwagent が 1 タスク内 (awsvpc) で `localhost` 通信するが、compose では各サービスが別コンテナに
なるため、宛先を環境変数 (`OTEL_EXPORTER_OTLP_ENDPOINT`, `BACK_BASE_URL`,
`ECS_CONTAINER_METADATA_URI_V4` 等) でサービス名 DNS に差し替えて等価性を担保している。
back が `port-offset=100` (8180) で動くのも、ECS で front と同一名前空間に同居する設計を
そのまま持ち込んでいるため。

### 2.2 サービス一覧

> 以下の 2.2 / 2.3 と第 3〜4 章は、**パッチ適用前**の状態を記録したもの。
> 適用後の内容は第 8 章を参照。

| サービス | 代替対象 | イメージ | ホストポート | healthcheck |
| --- | --- | --- | --- | --- |
| **app-front** | ECS front コンテナ | 自前ビルド (EAP 8.1/UBI9/JDK21) | 8080 | `curl 127.0.0.1:8080/` — 30s/5s/retries 3/**start_period 120s** |
| **app-back** | ECS back コンテナ | 自前ビルド (同一ベース) | 8180 | `curl 127.0.0.1:8180/` — 同上 |
| **adot-collector** | ADOT サイドカー | aws-otel-collector v0.43.3 | 4318 | `CMD /healthcheck` — 10s/5s/5/10s |
| **jaeger** | X-Ray コンソール | jaeger 2.4.0 | 16686 | **なし** |
| **mysql** | Aurora MySQL 8.4 + RDS Proxy | mysql:8.4.7 | 3306 | `mysqladmin ping` — 10s/5s/10/**start_period 30s** |
| **valkey** | ElastiCache for Valkey | valkey 8.0 | 6379 | **なし** |
| **svf-mock** | SVF 帳票サーバ | WireMock 3.13.0 | 8280→8080 | **なし** |
| **ecs-metadata-mock** | ECS Task Metadata v4 | WireMock 3.13.0 | 8380→8080 | **なし** |
| **efs-mock** | EFS (アクセスポイント不使用) | alpine 3.21 | — | 初期化マーカー + `stat` 検証 — 5s/3s/5/3s |
| **cwagent** | CW Agent サイドカー | cloudwatch-agent:latest | — | なし |
| **cloudwatch-logs-mock** | CloudWatch Logs API | WireMock 3.13.0 | 8480→8080 | **なし** |
| **sqs** | Amazon SQS | ElasticMQ 1.6.11 | 9324/9325 | なし |
| **lambda** | Lambda ランタイム | lambda/python:3.12 (RIE) | 9000→8080 | なし |
| **lambda-esm** | SQS イベントソースマッピング | 自前ビルド (poller.py) | — | なし |
| **alb** | ALB | nginx 1.27-alpine | 9080→80 | `wget /healthz` — 10s/5s/5/5s |
| **maintenance-lambda** | メンテ画面 Lambda | lambda/python:3.12 | 9001→8080 | なし |
| **alb-lambda-adapter** | ALB の Lambda ターゲット統合 | python:3.12-slim | 9081→8080 | なし |

全サービスに `container_name` が固定で付いている。

### 2.3 依存グラフ

`(H)` = `condition: service_healthy` / `(S)` = `condition: service_started`

```
jaeger(S) ────────┐
ecs-metadata-mock(S) ─┴→ adot-collector
                              │(H)
mysql(H) ───────────┬─────────┤
valkey(S) ──────────┤         │
efs-mock(H) ────────┤         │
svf-mock(S) ────────┤         │
ecs-metadata-mock(S)┴─────────┴→ app-back ──┬→ app-front   (app-back は S 判定)
                                             └→ alb ──→ lambda
alb-lambda-adapter(S) ←─ maintenance-lambda(S)
sqs(S) ──────────────────────────────────────→ lambda-esm
efs-mock(H) ─┬→ cwagent
cloudwatch-logs-mock(S) ─┘
```

起動段階:

| 段 | サービス |
| --- | --- |
| 0 | jaeger / mysql / valkey / svf-mock / **ecs-metadata-mock** / efs-mock / cloudwatch-logs-mock / sqs / maintenance-lambda |
| 1 | adot-collector / cwagent / alb-lambda-adapter |
| 2 | **app-back** |
| 3 | **app-front** / alb |
| 4 | lambda |
| 5 | lambda-esm |

### 2.4 front / back の中身

ビルド (`docker/front/Dockerfile`, `docker/back/Dockerfile`, コンテキストは `docker/`):

1. ADOT Java Agent v2.11.5 を公式配布イメージから `/opt/adot/aws-opentelemetry-agent.jar` へ COPY
2. Connector/J 9.7.0 を Maven Central から取得し `modules/com/mysql/main/` へ**静的モジュール**として配置
3. `docker/cli/mysql-xa-datasource.cli` を `jboss-cli.sh --file` (embed-server) で適用
4. `front/app/` `back/app/` の WAR を deployments へ (back はさらに Maven ステージで
   `async-receiver.war` をビルドして同梱)
5. `USER 185` (jboss) で `entrypoint.sh` を ENTRYPOINT に

XA データソース (`mysql-xa-datasource.cli`):

```
xa-data-source=AppXADS (java:jboss/datasources/AppXADS)
  user-name=${env.DB_USER}  password=${env.DB_PASSWORD}
  min-pool-size=5  max-pool-size=20  pool-prefill=false
  validate-on-match=true  background-validation=false
  ServerName=${env.DB_HOST}  PortNumber=${env.DB_PORT}  DatabaseName=${env.DB_NAME}
  PinGlobalTxToPhysicalConnection=true   # MySQL の XA 制約対策
transactions node-identifier=${jboss.tx.node.id:changeme}
```

`pool-prefill=false` なのでプールの事前充填はしないが、**XA データソースとして deploy・検証される
時点で DB へ到達できる必要がある**。到達できないと
`WFLYJCA0031: unable to validate and deploy ds or xads` → `WFLYSRV0026` 系の起動失敗になる
(これは `build_and_verify.sh` のテスト fixture にある失敗パターンと同型)。

entrypoint (front/back でほぼ同一):

- `DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD` 未設定なら fail-fast
- OTEL_* の既定補完、`JAVA_TOOL_OPTIONS` へ `-javaagent` を二重登録防止付きで追加
- `umask 0002` を設定し `/mnt/logs/{front,back}/logs`・`/mnt/data/{front,back}` を
  mode 2775 (setgid) で冪等作成
- `/mnt/logs/app-front.log` (back は `app-back.log`) へ起動マーカーを追記
  ← **cwagent のファイル検知トリガーを兼ねる**
- `exec standalone.sh -b 0.0.0.0 -bmanagement 127.0.0.1 -Djboss.tx.node.id=…`
  (back はさらに `-Djboss.socket.binding.port-offset=100`)

**重要**: entrypoint は ECS メタデータを一切叩かない。`ECS_CONTAINER_METADATA_URI_V4` を参照するのは
**ADOT Java Agent の ECS リソース検出器**と、アプリ WAR (`front/app/` は git 管理外 = 実アプリ)。

### 2.5 偽装 EFS

`efs-mock` (alpine) が named volume `efs-logs` / `efs-data` を **UID 6301 / GID 6302 / mode 2775
(setgid)** で `chown`+`chmod` し、`touch /tmp/efs-initialized` してから `tail -f /dev/null` で常駐。
healthcheck はマーカーと `stat -c %u:%g` の両方を検証するため、**初期化完了を正しく表現できている
数少ないサービス**。front/back は `group_add: 6302` で書き込み権限を得る。

### 2.6 可観測性の 2 経路

**トレース**: app-front/app-back (ADOT Java Agent) → `http://adot-collector:4318` (OTLP http/protobuf)
→ Collector パイプライン `otlp → memory_limiter → resourcedetection/ecs(detectors:[env,ecs],
timeout 2s, override false) → resource → batch` → `debug` (コレクタログ) + `otlphttp/jaeger`
(`http://jaeger:4318`)。Jaeger の OTLP ポートは非公開で内部通信のみ、UI だけ 16686 で公開。

**ログ**: front/back が `/mnt/logs/app-*.log` へ書く → cwagent が `collect_list` で tail →
`logs.endpoint_override: http://cloudwatch-logs-mock:8080` により WireMock へ `PutLogEvents`
(`force_flush_interval: 5`)。ロググループは `/local/myapp/efs/app-front`・`/local/myapp/efs/app-back`、
ストリームは `front-local`・`back-local`。

この構成は `build_and_verify.sh` の可観測性ヘルパーが前提にしているもの (サービス名
`cwagent`/`cloudwatch-logs-mock`/`adot-collector`/`jaeger`、cwagent 設定パス
`/etc/cwagentconfig/cwagent-config.json`、mock のコンテナ側ポート 8080、Jaeger 16686、
Collector の `/healthcheck` バイナリ) と**完全に一致している**。

### 2.7 非同期チェーン

`app-front`/`app-back` → SQS(ElasticMQ) `app-async-queue` → `lambda-esm` (poller が 20 秒
ロングポーリング、BATCH_SIZE 10) → `lambda` (RIE の
`/2015-03-31/functions/function/invocations`) → `alb`(nginx) の `/async/*` ルール →
`app-back:8180/async/receive` (`AsyncReceiverServlet`)。
ALB のリスナールールは `compose/alb/rules/*.conf` に分離され、`alb-maintenance.sh on|off` で
`variants/` を差し替えて全面メンテナンス (`maintenance-lambda` が 503 + HTML) へ切り替えられる。

### 2.8 データ永続化

named volume は `mysql-data` / `efs-logs` / `efs-data` の 3 つ。`compose down` では残るが、
`down -v` および `docker volume prune --all` で消える。消えると **MySQL は initdb +
`10-init.sql` (XA_RECOVER_ADMIN 付与、`appdb.tx_check` 作成) + `20-init-infdb.sh`
(infdb/infuser 作成) のコールド初期化**、efs-mock は再初期化からやり直しになる。

---

## 3. 実行コマンドから生成される実際の Docker 操作

実際の指定:

```
--compose-service base,app-front,app-back,mysql,ecs-metadata-mock,valkey,adot-collector,efs-mock,cwagent,cloudwatch-logs-mock
--startup-service app-front
```

`COMPOSE_SERVICES` が 10 個なので `build_and_verify.sh` は**複数サービス分岐** (`:4450`) に入る。

```bash
# ① COMPOSE_PARALLEL_OPTS=(--parallel 10) が組み立てられる (:632)
# ② 第1フェーズ: base を単独ビルド (:4455)
docker compose --parallel 10 -f compose.yaml build base
docker image inspect j1/base.local          # verify_local_image (:4435)

# ③ 第2フェーズ: base を除いた9サービスをまとめてビルド (:4475)
docker compose --parallel 10 -f compose.yaml build \
    app-front app-back mysql ecs-metadata-mock valkey \
    adot-collector efs-mock cwagent cloudwatch-logs-mock

# ④ 起動: COMPOSE_SERVICES をそのまま渡す (:1772-1774)  ← base が入ったまま
docker compose --parallel 10 -f compose.yaml up -d --no-build \
    base app-front app-back mysql ecs-metadata-mock valkey \
    adot-collector efs-mock cwagent cloudwatch-logs-mock
```

④ は `--no-deps` を付けていないので未指定の依存も起動される。依存閉包を取ると実際に立つのは
**12 コンテナ**。

| 段 | 起動されるコンテナ | 備考 |
| --- | --- | --- |
| **0** | `base` / `mysql` / `valkey` / `svf-mock`✚ / `ecs-metadata-mock` / `efs-mock` / `cloudwatch-logs-mock` / `jaeger`✚ | **8 個が同時**。うち WireMock×3 + Jaeger = **JVM 4 本 + MySQL initdb** |
| 1 | `adot-collector` / `cwagent` | |
| 2 | `app-back` | EAP JVM |
| 3 | `app-front` | EAP JVM |

✚ = `--compose-service` に無いが依存として自動起動 (`svf-mock` は app-back の、
`jaeger` は adot-collector の依存)

---

## 4. 原因分析

### 4.1 不具合①: `base` が起動対象に入っている

`build_and_verify.sh` は第 2 フェーズのビルドからは base を除外する (`:4468-4471`) が、
**`start_container()` は `COMPOSE_SERVICES` をそのまま `up` に渡す** (`:1773`)。

```bash
REMAINING_SERVICES=()
for _service in "${COMPOSE_SERVICES[@]}"; do
  [ "$_service" = "$BASE_SERVICE" ] || REMAINING_SERVICES+=("$_service")   # ← build 用だけ
done
...
up_args+=(${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"})                  # ← up には base 込み
```

README の「base が指定に含まれていない場合は…**起動対象には追加しません**」という記述は、
base を明示指定した場合には適用されない。移植した base は `CMD ["/bin/sh"]` 相当なので、
TTY 無しの `up -d` では**起動直後に exit 0** する。

実害:

- `docker compose ps --services` から消えるため `compose_started_services()` の一覧が実行のたびに
  揺れる (`--keep-container-mode logs` のメニュー番号も揺れる)
- 毎回 exited コンテナが残り、次回 `up` で再作成される
- レベル 0 の同時起動数を 1 つ増やし、初期の CPU 競合を悪化させる

### 4.2 核心: 依存ゲートが開く時刻の計算

app-back / app-front が起動を開始できる時刻は、`depends_on` の各条件が揃った時刻の **max**。

| 依存 | 条件 | 満たされる時刻 |
| --- | --- | --- |
| `efs-mock` | **healthy** | start_period 3s / interval 5s → 約 5s |
| `adot-collector` | **healthy** | start_period 10s / interval 10s → 約 10〜20s |
| `mysql` | **healthy** | interval 10s → **ウォーム 10〜20s / コールド 40〜130s** |
| `valkey` | started | ≈ 0s |
| `svf-mock` | started | ≈ 0s |
| **`ecs-metadata-mock`** | **started** | **≈ 0s (listen 完了は待たない)** |
| `app-back` (front のみ) | started | app-back のコンテナ起動と同時 |

一方 **WireMock 3.13.0 (JVM) がコンテナ起動から HTTP を listen するまでは通常 4〜8 秒、
レベル 0 で JVM 4 本 + MySQL initdb が同時に走る負荷下では 10〜30 秒**かかる。

`mysql` の healthcheck は `interval: 10s` で **`start_period` 中でも成功した瞬間に healthy になる**
ため、ウォーム時は 10 秒程度でゲートが開いてしまう。これが第 1 節の逆相関を生む。

`--cleanup-all-docker-data` を使った回は `docker volume prune --all` で `mysql-data` が消えるため
**必ずコールド**になり症状 A に倒れる。使わなければウォームで症状 B に倒れる。
**2 種類の症状が交互に出るのは、この運用差が効いているため。**

### 4.3 症状 B: ecs-mock から ECS タスク ID を取得できない

**確定。** `ecs-metadata-mock` には healthcheck が無く、`app-front` / `app-back` /
`adot-collector` の 3 つとも `condition: service_started` で待っている。`service_started` は
**コンテナが起動したこと**しか保証しないため、WireMock が listen する前に EAP と
ADOT Java Agent が動き出す。

- front の `entrypoint.sh` は ECS メタデータを叩かないので、失敗しているのは
  **`front/app/` の WAR (実アプリ)** か ADOT Java Agent の ECS リソース検出器。
- アプリがデプロイ時にタスク ID を必須にしている場合、デプロイ失敗 → `WFLYSRV0026` →
  `build_and_verify.sh` が `STARTUP_FAILURE_LOG_PATTERN` で検知して即失敗、という流れになる。
- **`svf-mock` (app-back の依存) と `valkey` も同じ穴**。

### 4.4 症状 A: MySQL のホストが見つからず back が異常終了

`mysql` は `condition: service_healthy` なので依存待ちは効いているはず。考えられる機序は 2 つ。

**機序 A-1 (有力): compose の依存待ちがタイムアウトしている**

`interval 10s × retries 10` (start_period 30s は失敗を数えないだけ) ≒ **約 130 秒**で
`unhealthy` 確定。MySQL 8.4 のコールド初期化 (initdb → `10-init.sql` → `20-init-infdb.sh`) が、
JVM 4 本と EAP ビルド/起動の裏で 130 秒を超えると、compose が

```
dependency failed to start: container mysql is unhealthy
```

で `up` 全体を中断する。`start_container()` はこれを検知して
`err "コンテナの起動に失敗しました (compose up)"` → exit 1。**この場合 back は起動していない。**

**機序 A-2: healthy 判定が「使える」ことを保証していない**

```yaml
test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} --silent"]
```

`mysqladmin ping` は**サーバが応答すれば認証エラー (ER_ACCESS_DENIED) でも exit 0 を返す**仕様。
「`appuser` で `appdb` に接続できる」ことは一切検証していない。

**切り分け方法**: 失敗回の `docker compose logs app-back` で

- `UnknownHostException: mysql` / `Name or service not known` → DNS。mysql コンテナが存在しない = 機序 A-1
- `Connection refused` / `Communications link failure` / `Access denied for user 'appuser'` → 機序 A-2

### 4.5 スクリプト側の増幅要因

| # | 箇所 | 内容 |
| --- | --- | --- |
| ① | `start_container:1773` | **base を `up` に渡す** (4.1) |
| ② | `start_container:1772` | **`--wait` を使っていない**。`up -d` の戻りで「起動した」とみなす |
| ③ | `:632` | `--parallel 10` は build 用に作った値が `up` にもかかる。Compose v2 の既定は無制限なので**直列化の手段が無い** |
| ④ | `containers_all_running:1749` | `docker compose ps -q` (**停止済みを返さない**) ベース。ループが 0 回なら `return 0` = 「全部 running」。しかも `--startup-service app-front` なので**検査対象は front のみ**。**back の異常終了を検知できず、front が 120 秒タイムアウトするまで待ち続ける** |
| ⑤ | `STARTUP_TIMEOUT` 既定 120s | DESIGN.md 自身が front の EAP 起動は「60〜90s かかることがある」と明記。EAP 単体で 120s を超えると失敗 |
| ⑥ | `verify_local_image:4435` | 検査対象は `j1/base.local` のみ。**app-front / app-back のイメージ生成は未検証** |
| ⑦ | 第 2 フェーズ build | `mysql` `valkey` `ecs-metadata-mock` `adot-collector` `efs-mock` `cwagent` `cloudwatch-logs-mock` は **`build:` セクションを持たない**サービス。`docker compose build` に渡した際の挙動は Compose のバージョン依存。要確認 |

---

## 5. 対応策

### 5.1 起動コマンドの修正 (即効)

```bash
./build_and_verify.sh \
    --compose-file compose.yaml \
    --local-image j1/base.local \
    --compose-service app-front,app-back,mysql,ecs-metadata-mock,valkey,adot-collector,efs-mock,cwagent,cloudwatch-logs-mock \
    --startup-service app-front \
    --startup-timeout 300 \
    --wait-healthy \
    --keep-container-mode logs
```

- **`base` を外す** (先行ビルドは自動で走る)
- `--startup-timeout 300` で EAP 起動の余裕を確保
- `--wait-healthy` で compose 側に healthy 待ちを任せる (5.3 で追加)

### 5.2 compose.yaml の修正 (本命)

- `ecs-metadata-mock` / `svf-mock` / `cloudwatch-logs-mock` に **TCP listen を条件とする
  healthcheck** を追加し、依存側を `service_healthy` へ変更
- `valkey` に `valkey-cli ping` の healthcheck を追加し、依存側を `service_healthy` へ変更
- `mysql` の healthcheck を **`appuser` で `appdb` に `SELECT 1` する実クエリ**へ変更し、
  猶予を約 130 秒から約 320 秒へ拡大

### 5.3 build_and_verify.sh の修正

1. `base` (= `--compose-service` の `BASE_SERVICE`) を**起動・ログ・監視の対象から除外**
2. `--wait-healthy` / `--wait-timeout` を追加し、`compose up --wait --wait-timeout` を発行
3. `containers_all_running` を `docker compose ps -aq` ベースへ変更し、**1 件も返らない場合を
   異常として扱う**
4. `--compose-service` で指定した全サービスの生存を監視し、**起動確認中に停止したサービスを
   即座に失敗として報告**する (`--allow-service-exit` で除外可)

### 5.4 アプリケーション側 (恒久対策)

`depends_on` は**起動時点しか守らない**。

- front アプリの ECS タスク ID 取得にリトライ + バックオフ (例: 1 秒間隔 × 30 回) を入れる
- XA データソースを `background-validation=true` + `background-validation-millis` へ切り替え、
  `validate-on-match` によるブート時検証依存を減らす

---

## 6. 確認手順

```bash
# A. ゲートが開く時刻と WireMock の listen 時刻を突き合わせる
docker compose -f compose.yaml up -d 2>&1 | ts
docker inspect -f '{{.State.StartedAt}} {{.State.Health.Status}}' mysql ecs-metadata-mock
docker compose -f compose.yaml logs ecs-metadata-mock | head

# B. ウォーム/コールドで挙動が変わることを確認する
docker compose -f compose.yaml down            # volume は残る → ウォーム
docker compose -f compose.yaml down -v         # volume 削除 → コールド

# C. 失敗回の切り分け
docker compose -f compose.yaml logs app-back \
  | grep -E 'UnknownHost|Connection refused|WFLYJCA0031|Access denied'
```

`build_and_verify.sh` の `--keep-container-mode logs` で `mysql` → `3) healthcheck 設定・実行履歴・
通信を確認` を選ぶと、Docker が保持する healthcheck 履歴 (開始/終了時刻・終了コード) が出るため、
**healthy になった正確な時刻**を確認できる。

---

## 7. 適用したパッチ

### 7.1 `build_and_verify.sh`

| # | 変更 | 内容 |
| --- | --- | --- |
| 1 | `COMPOSE_TARGET_SERVICES` を新設 | `--compose-service` から `BASE_SERVICE` (`base`) を除いた配列。**起動 (`up`) / ログ取得 / コンテナ列挙 / 生存監視**はこちらを使う。ビルドは従来どおり `COMPOSE_SERVICES` (base 込み)。`base` だけを指定して起動確認を要求した場合は exit 2 |
| 2 | `--wait-healthy` / `--wait-timeout SEC` を追加 | `compose up` に `--wait --wait-timeout` を付与。既定 600 秒。`--wait-timeout` 指定で `--wait-healthy` も暗黙有効 |
| 3 | `compose_container_ids_all()` を新設し `containers_all_running()` を変更 | 一覧を `ps -q` → **`ps -aq`** へ。異常終了したコンテナが一覧から消えて「停止を検知できないまま成功」と誤判定する穴を塞ぐ。**1 件も返らない場合も異常**として扱う |
| 4 | `target_services_all_running()` を新設し `wait_for_startup()` へ組み込み | 起動確認のポーリングごとに `--compose-service` 指定の全サービス (base 除く) の生存を確認し、停止したサービス名とそのログを出して即失敗。`--allow-service-exit NAME` (繰り返し / カンマ区切り) で除外可 |
| 5 | 全量レポートのヘッダー | `対象サービス` を `ビルド対象` / `起動対象` の 2 行へ分離 |
| 6 | `--help` / `README.md` | 新オプションと `base` の扱いを追記 |

主要な差分:

```bash
# 起動対象から base を除外
COMPOSE_TARGET_SERVICES=()
for _cs in ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; do
  [ "$_cs" = "$BASE_SERVICE" ] || COMPOSE_TARGET_SERVICES+=("$_cs")
done

# compose 側で healthy 待ちをさせる
if [ "$STARTUP_WAIT" = "true" ]; then
  up_args+=(--wait --wait-timeout "$STARTUP_WAIT_TIMEOUT")
fi

# 異常終了の検知漏れを塞ぐ (ps -aq + 0 件を異常扱い)
containers_all_running() {
  local cid running found="false"
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found="true"
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)"
    [ "$running" = "true" ] || return 1
  done < <(compose_container_ids_all "$@")
  [ "$found" = "true" ] || return 1
}

# 起動対象サービス全体の生存監視 (wait_for_startup のポーリング内)
if ! target_services_all_running; then
  err "起動対象の Compose サービスが停止しました: ${STOPPED_TARGET_SERVICES[*]}"
  dump_startup_logs "${STOPPED_TARGET_SERVICES[@]}"
  return 1
fi
```

### 7.2 `Container_Compose_file/compose.yaml`

| サービス | 変更 |
| --- | --- |
| `ecs-metadata-mock` | **healthcheck 新設** (TCP listen 確認, 3s/3s/40/start_period 5s) |
| `svf-mock` | **healthcheck 新設** (同上) |
| `cloudwatch-logs-mock` | **healthcheck 新設** (同上) |
| `valkey` | **healthcheck 新設** (`valkey-cli ping`, 3s/3s/20/3s) |
| `mysql` | healthcheck を `mysqladmin ping` → **`appuser` で `appdb` へ `SELECT 1`** に変更。猶予を 130s → **約 320s** (5s/5s/retries 60/start_period 20s) |
| `app-front` | `depends_on`: `ecs-metadata-mock` / `valkey` を `service_started` → **`service_healthy`** |
| `app-back` | `depends_on`: `ecs-metadata-mock` / `svf-mock` / `valkey` を `service_started` → **`service_healthy`** |
| `adot-collector` | `depends_on`: `ecs-metadata-mock` を **`service_healthy`** |
| `cwagent` | `depends_on`: `cloudwatch-logs-mock` を **`service_healthy`** |

適用後の依存条件:

```
service                healthcheck  depends_on
app-front              YES          adot-collector:healthy, mysql:healthy, valkey:healthy,
                                    app-back:started, ecs-metadata-mock:healthy, efs-mock:healthy
app-back               YES          adot-collector:healthy, mysql:healthy, valkey:healthy,
                                    svf-mock:healthy, ecs-metadata-mock:healthy, efs-mock:healthy
adot-collector         YES          jaeger:started, ecs-metadata-mock:healthy
cwagent                -            efs-mock:healthy, cloudwatch-logs-mock:healthy
mysql / valkey / svf-mock / ecs-metadata-mock / cloudwatch-logs-mock / efs-mock : healthcheck あり
```

`app-front` → `app-back` は `service_started` のまま残した。`service_healthy` にすると
back の `start_period: 120s` により front の起動開始が 2〜3 分遅れるため、必要になったら
切り替える方針をコメントで残している。

`jaeger` は公式イメージにシェルが無い可能性があるため healthcheck を追加していない。
Collector の exporter はリトライするうえ、front/back は Collector の healthy を待つため
実害は無い。

### 7.3 適用前に確認が必要な前提

WireMock 3 系のイメージに `bash` と `timeout` があることを前提に、次の healthcheck を使っている。

```yaml
test: ["CMD-SHELL", "timeout 2 bash -c '</dev/tcp/127.0.0.1/8080' || exit 1"]
```

**初回適用時に必ず次を実行して確認すること。** 存在しない場合は healthcheck が常に失敗し、
`up` 全体が止まるため、コメントに記載した `curl` 版へ差し替える。

```bash
docker compose -f compose.yaml up -d ecs-metadata-mock
docker exec ecs-metadata-mock sh -c 'command -v bash timeout curl wget'
# curl があれば下記へ差し替え可
#   test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8080/__admin/health >/dev/null || exit 1"]
```

### 7.4 推奨する起動コマンド

```bash
./build_and_verify.sh \
    --compose-file compose.yaml \
    --local-image j1/base.local \
    --compose-service app-front,app-back,mysql,ecs-metadata-mock,valkey,adot-collector,efs-mock,cwagent,cloudwatch-logs-mock \
    --startup-service app-front \
    --startup-timeout 300 \
    --wait-healthy \
    --keep-container-mode logs
```

`base` は `--compose-service` に含めても除外されるようになったが、
ビルド専用であることを明示するため指定から外しておくのが分かりやすい
(複数サービス指定時は `base` が自動で先行ビルドされる)。

### 7.5 検証結果

- `bash -n build_and_verify.sh` … 構文 OK
- `--compose-service base` + `--verify-startup` … 起動対象なしを検出して exit 2
- `--compose-service base,app` … ビルドは `base` → `app`、`up` は `app` のみ。
  「ベースサービス 'base' はビルド専用のため起動対象から除外しました」を出力
- `--wait-healthy` … `docker compose --parallel 2 -f compose.yml up -d --no-build --wait --wait-timeout 600 app` を生成
- `tests/build_and_verify_test.sh` … 第 8 章の環境制約 2 件を除き全シナリオ PASS
  (パッチ前後で失敗箇所に変化なし)

---

## 8. 既知の制約 (テスト実行環境)

Windows + Git Bash で `tests/build_and_verify_test.sh` を実行する場合、次の 2 点で
**コード変更とは無関係に**失敗する。

1. `assert_occurrences "$success_output" "old.war" 1` 等、ANSI エスケープを含む出力に対する
   出現回数アサーション。作者環境の grep はこのファイルをバイナリ扱いして
   `Binary file ... matches` の 1 行を返すが、GNU grep 3.0 (Git Bash) はテキストとして
   実際の 2 件を返す。
2. 可観測性ヘルパー (cwagent / OTel) のシナリオ。`render_cloudwatch_delivery_report` などが
   `os.fdopen(3)` でプロセス置換の fd を受け取るが、Windows の Python では fd 継承が
   同じようには機能しない。

上記 2 点を除いた全シナリオは Git Bash 上でも PASS することを確認済み (パッチ前後で結果に変化なし)。
