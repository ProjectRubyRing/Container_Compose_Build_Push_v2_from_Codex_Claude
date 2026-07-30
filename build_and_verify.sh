#!/usr/bin/env bash
#
# build_and_verify.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# build_and_push.sh の「ビルドのみ実行する処理」を切り出した専用スクリプト。
# compose.yml で定義したローカルベースイメージ (既定: j1/base.local) を
# docker compose build でビルドする。ECR ログイン/タグ付け/プッシュ/
# imagedefinition.json の出力は一切行わない。
#
# ビルドに加えて、以下の確認・診断を任意で行える:
#   (1) --verify-startup : ビルドしたイメージをコンテナとして起動し、
#                          jbosseap (WildFly/JBoss EAP) サーバーの起動完了を
#                          ログから確認し、起動ログと重要ログの色分けを表示する。
#   (2) --verify-url URL : 起動確認後、指定 URL へ HTTP リクエストを送り、
#                          その応答 (ステータスコード/本文) を確認する。
#   (3) Compose サービスログ: 起動確認対象と同時に起動した他サービスのログを、
#                          起動ログの直後へサービス単位で順次表示する。
#   (4) ディレクトリツリー表示: 動作確認したコンテナのディレクトリを階層表示する。
#                          通常ファイルはオプション指定時のみ出力する。
#   (5) デプロイ構造表示    : JBoss デプロイ先、Web ルート、Java クラスパスルート、
#                          指定環境変数のディレクトリを検出して階層表示する。
#   (6) JVM パラメータ表示  : コンテナ内の Java プロセスを検出し、起動時の JVM
#                          パラメータをヒープ・GC・エージェント・システム
#                          プロパティ等へ分類して表示する。
#   (7) OpenTelemetry 表示  : OTEL_* をはじめとする OpenTelemetry 関連の環境変数と
#                          JVM パラメータを 1 つの一覧にまとめて表示する。
#   (8) 全量レポート        : ビルド結果と全量の環境変数・ツリー・デプロイ構造・
#                          JVM パラメータ・OpenTelemetry 設定を日時付きテキスト
#                          ファイルへ保存する。
#   (9) --keep-container-mode: 起動確認後もコンテナを残し、検証対象へ直接
#                          bash 接続するか、対話式の HTTP リクエスト、または
#                          起動中 Compose サービスのログ閲覧・bash / MySQL 接続、
#                          healthcheck 設定・実行履歴・HTTP 通信、および
#                          cwagent / OTel のローカル送達診断を実行する。
#  (10) 終了 (SIGTERM) ログ : エラー終了時は、ECS のタスク停止と同じく SIGTERM で
#                          コンテナを終了させてから最終ログを取得する。これにより
#                          adot collector などサイドカーの graceful shutdown ログ
#                          (シグナル受信 → パイプライン停止 → 終了) まで、画面と
#                          全量レポートの双方へ残る。
#
# --verify-startup / --verify-url いずれも指定しなければ、純粋にビルドのみを
# 行って終了する (従来の build_and_push.sh --build-only 相当)。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - ビルド前に、パラメータストアの指定キー (--jboss-password-param) から
#     JBoss のマスターパスワードを取得できる (直接指定 --jboss-password も可)。
#   - 取得した値は環境変数 (--jboss-password-env, 既定: JBOSS_MASTER_PASSWORD)
#     へ export し、compose.yml の environment 型シークレット定義を通じて
#     BuildKit シークレットとして安全にビルドへ注入する。
#   - パラメータストアを使う場合のみ AWS 認証 (aws login --remote 実施済み) が
#     必要で、未認証の場合は認証を促す警告を表示して終了する。
#
# 使い方:
#   # ビルドのみ
#   ./build_and_verify.sh
#
#   # ビルド + jbosseap 起動確認
#   ./build_and_verify.sh --verify-startup
#
#   # ビルド + 起動確認 + URL 応答確認 (例: ヘルスチェックエンドポイント)
#   ./build_and_verify.sh --verify-startup \
#       --verify-url http://localhost:8080/health --expect-status 200
#
#   # base を先行ビルド後、複数サービスを同時にビルド・起動し、
#   # app サービスのみ起動確認する
#   ./build_and_verify.sh --compose-service app --compose-service db \
#       --startup-service app
#   # (カンマ区切りでも指定可: --compose-service app,db)
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 表示タイムゾーン (JST 固定) --------------------------------------------
# ホストや CI が UTC でも、このスクリプトが表示・保存する時刻はすべて JST に揃える。
# tzdata を持たない環境でも +09:00 になるよう、Asia/Tokyo が使えない場合は tzdata
# 不要の POSIX 形式 (JST-9) へフォールバックする。日本標準時は夏時間を持たないため
# 固定オフセットでも Asia/Tokyo と同じ結果になる。
# 時刻表示へ付ける名前は %Z が空になる環境があるため、この変数から明示的に付ける。
DISPLAY_TZ_LABEL='JST'
setup_display_timezone() {
  local tz_candidate
  for tz_candidate in 'Asia/Tokyo' 'JST-9'; do
    if [ "$(TZ="$tz_candidate" date '+%z' 2>/dev/null)" = "+0900" ]; then
      export TZ="$tz_candidate"
      return 0
    fi
  done
  DISPLAY_TZ_LABEL="$(date '+%Z' 2>/dev/null)"
  [ -n "$DISPLAY_TZ_LABEL" ] || DISPLAY_TZ_LABEL="ローカル時刻"
  return 1
}
if ! setup_display_timezone; then
  # ログ用ヘルパはまだ定義前のため、ここだけ printf で警告する。
  printf '[%s %s] [WARN] JST へ切り替えられないため、ホストのタイムゾーンで表示します。\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL" >&2
fi

# ---- 既定値 -----------------------------------------------------------------
RUN_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S') ${DISPLAY_TZ_LABEL}"
RUN_TIMESTAMP="$(date '+%Y%m%d%H%M%S')"
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICES=()               # 指定時はそのサービスのみビルド/起動 (複数指定可、空なら全サービス)
BASE_SERVICE="base"              # 複数サービス指定時に必ず先行ビルドするベースサービス名
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
CLEANUP_ALL_DOCKER_DATA="false"   # true: 終了時に確認後、現在の Docker context の全データを削除
DOCKER_CLEANUP_CONFIRM_PHRASE="DELETE ALL DOCKER DATA"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"  # パラメータストア参照時に使用

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか
JBOSS_PASSWORD_SHOW_VALUES="false" # true: 明示指定時だけ設定値・比較対象文字列を診断へ表示
JBOSS_SECRET_ID="jboss_master_password"     # compose.yml / Dockerfile 間で使う既定の secret id
JBOSS_PASSWORD_SOURCE="未設定"
JBOSS_PASSWORD_EXPECTED=""        # 照合用。既定では非表示、明示指定時だけ診断へ表示
JBOSS_PASSWORD_EXPECTED_FILE=""   # XML 照合用の権限 600 一時ファイル
JBOSS_PASSWORD_REDACTION_FILE=""  # ビルドログマスク用の権限 600 一時ファイル
JBOSS_PASSWORD_COMPOSE_STATUS="未確認"
JBOSS_PASSWORD_DOCKERFILE_STATUS="未確認"
JBOSS_PASSWORD_XML_STATUS="未確認"
JBOSS_DIAGNOSTIC_CONTAINER_ID=""
JBOSS_DIAGNOSTIC_TMP_DIR=""
JBOSS_BUILD_LOG_FILES=()
JBOSS_PASSWORD_DIAGNOSTIC_LINES=()

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
COPY_SPECS=()
COPIED_FILES=()

# ---- 起動確認 (jbosseap) 関連 ----------------------------------------------
VERIFY_STARTUP="false"            # true: ビルド後にコンテナを起動し起動完了を確認
STARTUP_SERVICES=()               # 起動完了チェックの対象サービス (複数指定可)。
                                  # 空なら対象サービス全体のログをまとめて確認する。
# 起動完了とみなすログのパターン (拡張正規表現)。
# JBoss EAP 8.1 では WFLYSRV0025 が正常起動、WFLYSRV0026 はエラー付き起動を表す。
# 両者を成功扱いしないよう、正常系と異常系を明確に分離する。
STARTUP_LOG_PATTERN='WFLYSRV0025:'
STARTUP_FAILURE_LOG_PATTERN='WFLYSRV0026:|WFLYSRV0056:'
STARTUP_TIMEOUT="120"             # 起動完了を待つ最大秒数
STARTUP_INTERVAL="3"              # 起動確認ポーリング間隔 (秒)
# compose up に --wait を付け、依存サービスが healthy (healthcheck 未定義なら running)
# になるまで compose 側で待機させる。compose.yml の healthcheck 整備が前提。
STARTUP_WAIT="false"
STARTUP_WAIT_TIMEOUT="600"        # --wait の最大待機秒数
# 起動確認中に停止していても失敗扱いにしないサービス (初期化専用の短命サービス等)
ALLOW_SERVICE_EXIT=()
KEEP_CONTAINER="false"            # true: 確認後もコンテナを停止・削除せずに残す
KEEP_CONTAINER_MODE=""            # bash/http/logs: 確認後に実行する対話操作 (指定時はコンテナを残す)
SUPPRESS_REMOVED_LOGS="false"     # true: compose down の Removed ログ等を抑制する
SUPPRESS_STARTUP_LOGS="false"     # true: 起動確認対象と同時起動サービスのログ表示を抑制する
STARTUP_LOG_LINES="50"            # all: 全行表示 / 数値: 末尾からの最大表示行数
# エラー終了時に、削除 (compose down) の前へ SIGTERM による停止 (compose stop) を
# 挟み、コンテナの終了処理が出すログまで取得するか。ECS はタスク停止時に各
# コンテナへ SIGTERM を送るため、ローカル検証でも同じ終了ログを残せるようにする。
CAPTURE_SHUTDOWN_LOGS="true"
SHUTDOWN_LOG_TIMEOUT="30"         # SIGTERM 後に SIGKILL するまでの猶予秒数 (ECS 既定と同じ)
SHUTDOWN_LOGS_CAPTURED="false"    # 終了ログの取得を試行済みか (二重実行の防止)
SHUTDOWN_STOP_EXECUTED="false"    # 実際に SIGTERM で停止したか (レポートの記載条件)
# EAP 8.1 の起動、ドライバー、データソース、リスナー、デプロイ、終了状態を
# 重要ログとして色分けする。
STARTUP_IMPORTANT_LOG_PATTERN='WFLYSRV0049|WFLYJCA0009|WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYDS0013|WFLYSRV0027|WFLYSRV0207|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0051|WFLYSRV0060|WFLYSRV0025|WFLYSRV0026|WFLYSRV0056'
# 起動完了、ドライバー、データソース、HTTP リスナー、デプロイ完了は成功色で表示する。
STARTUP_SUCCESS_LOG_PATTERN='WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0025'

# ---- URL 応答確認 関連 ------------------------------------------------------
VERIFY_URL=""                     # 空でなければ起動確認後にこの URL を呼び出して確認
EXPECT_STATUS="200"               # 期待する HTTP ステータスコード
URL_METHOD="GET"                  # HTTP メソッド
URL_CONTENT_TYPE=""               # Content-Type ヘッダ値 (未指定時は curl 既定)
URL_BODY_JSON=""                  # JSON 文字列をリクエストボディとして送る
URL_BODY_FORM=""                  # form 文字列 (key=value&...) をリクエストボディとして送る
URL_TIMEOUT="60"                  # URL 応答待機と HTTP / healthcheck 診断の最大秒数
URL_INTERVAL="3"                  # URL 呼び出しリトライ間隔 (秒)
URL_INSECURE="false"             # true: TLS 証明書検証を無効化して呼び出す (curl -k)

# ---- 起動維持後の対話操作 関連 ----------------------------------------------
JBOSS_CONTEXT_ROOT=""             # HTTP モードで使うコンテキストルート (空ならログから検出)
JBOSS_HTTP_PORT=""                # JBoss EAP のコンテナ側 HTTP ポート (空ならログから検出)
INTERACTION_CONTAINER_ID=""
INTERACTION_SERVICE_NAME=""
INTERACTION_CONTAINER_NAME=""
INTERACTION_CONTEXT_ROOT=""
INTERACTION_CONTAINER_PORT=""
INTERACTION_HTTP_HOST=""
INTERACTION_HTTP_PORT=""
INTERACTIVE_HTTP_BODY_FILE=""
HEALTHCHECK_DIAGNOSTIC_FILE=""
HTTP_REQUEST_METHOD=""
HTTP_REQUEST_PATH=""
HTTP_REQUEST_BODY=""
HTTP_REQUEST_CONTENT_TYPE=""
OBSERVABILITY_HTTP_HOST=""
OBSERVABILITY_HTTP_PORT=""
OBSERVABILITY_HTTP_BASE_URL=""
OBSERVABILITY_CONTAINER_NAME=""
OBSERVABILITY_PYTHON=""
OBSERVABILITY_WIREMOCK_REQUEST_LIMIT="100"
OBSERVABILITY_EVENT_DISPLAY_LIMIT="20"
OBSERVABILITY_TRACE_LIMIT="5"
# OTel Collector の health_check 拡張が待ち受ける既定ポート。コンテナ内で
# healthcheck コマンドを実行できない場合の代替確認先として使う。
OTEL_HEALTH_CHECK_PORT="13133"

# BuildKit の tty 表示はログ保存時に途中経過が上書きされるため、未指定時は
# plain を使用して各ビルドステップの出力を確実に残す。利用者が環境変数を
# 明示している場合はその値を尊重する。
BUILD_PROGRESS="${BUILDKIT_PROGRESS:-plain}"

# ---- 環境変数一覧出力 --------------------------------------------------------
ENV_LIST_LIMIT="all"              # all: 全件表示 / 数値: 各コンテナごとの最大表示件数
ENV_LIST_FILE=""                  # 指定時は環境変数一覧をファイルにも出力
BUILD_ARG_ENV_NAMES_LOADED="false"
declare -A BUILD_ARG_ENV_NAME_SET=()

# ---- コンテナ内ディレクトリツリー出力 -----------------------------------------
DIRECTORY_TREE_DEPTH="all"        # all: 最下層まで / 数値: / 直下を 1 とする最大ディレクトリ深さ
DIRECTORY_TREE_DEPTH_SET="false"  # 深さが明示指定されたか (ビルドのみ実行時の警告用)
DIRECTORY_FILE_LIMIT="none"       # none: ファイル非表示 / all・数値: ファイル表示を有効化
DIRECTORY_FILE_LIMIT_SET="false"  # 表示上限が明示指定されたか (ビルドのみ実行時の警告用)
DEPLOYMENT_DIR_ENVS=()            # ディレクトリパスを値に持つ環境変数名 (複数指定可)
# コンテナ全体ツリーでは、巨大・仮想・実行基盤固有の各ディレクトリ配下を
# 探索しない。通常はディレクトリ自体を 1 ノードとして表示するが、
# DIRECTORY_TREE_HIDDEN_PATHS に含まれるパスはそのノードも表示しない。
# 個別のデプロイ構造表示には適用しない。
DIRECTORY_TREE_PRUNE_PATHS=(
  /afs
  /aws
  /etc
  /local/aws-cli
  /opt/jboss-eap/.galleon
  /opt/jboss-eap/modules/system/layers/base
  /proc
  /usr/share
  /usr/share/X11
  /usr/share/doc
  /usr/share/icons
  /usr/share/licenses
  /usr/share/man
  /usr/share/osinfo
  /usr/share/zoneinfo
  /sys
  /usr/lib
  /usr/lib64
  /usr/local
)
# RHEL 9 / UBI 9 の /usr/share 配下にある実行基盤固有ディレクトリは、
# 枝刈りするだけでなく画面と全量レポートの双方からディレクトリ自体も除外する。
DIRECTORY_TREE_HIDDEN_PATHS=(
  /usr/share/X11
  /usr/share/doc
  /usr/share/icons
  /usr/share/licenses
  /usr/share/man
  /usr/share/osinfo
  /usr/share/zoneinfo
)

# ---- Java JVM パラメータ / OpenTelemetry 設定出力 -----------------------------
# /proc/<pid>/cmdline は NUL 区切りのため、コンテナ内で US (0x1f) へ置き換えてから
# ホスト側の Bash で分解する。JVM パラメータに 0x1f が現れることはない。
JVM_FIELD_SEPARATOR=$'\037'
# 名前と値を桁揃えして表示する際の名前欄の幅 (半角換算)。
JVM_PARAM_NAME_WIDTH="44"
# JVM オプションを渡す代表的な環境変数。ここで指定した内容は起動コマンドラインへ
# 現れないため、/proc/<pid>/cmdline とは別に収集して表示する。
JVM_OPTION_ENV_NAMES=(
  JAVA_OPTS
  JAVA_OPTS_APPEND
  JAVA_TOOL_OPTIONS
  JDK_JAVA_OPTIONS
  _JAVA_OPTIONS
  JBOSS_JAVA_OPTS
  JBOSS_JAVA_SIZING
  JAVA_ARGS
)
# OpenTelemetry の標準環境変数は接頭辞 OTEL_ で始まる (OpenTelemetry 仕様
# "General SDK Configuration" / Java エージェントの設定名)。接頭辞で判定するため、
# OTEL_SERVICE_NAME・OTEL_EXPORTER_OTLP_*・OTEL_INSTRUMENTATION_* などは
# 個別に列挙しなくても検出できる。
OTEL_ENV_NAME_PREFIX="OTEL_"
# 接頭辞 OTEL_ を持たないが OpenTelemetry の構成に使われる環境変数。
# 設定されていれば常に OpenTelemetry 関連として一覧へ出す。
# OTEL_ で始まる名前は上の接頭辞判定で拾えるため、ここには入れない (二重表示になる)。
OTEL_RELATED_ENV_NAMES=(
  AWS_XRAY_DAEMON_ADDRESS       # ADOT / X-Ray デーモンの送信先
  AWS_XRAY_CONTEXT_MISSING      # X-Ray のコンテキスト欠落時の挙動
  AWS_XRAY_TRACING_NAME         # X-Ray のセグメント名
  AWS_LAMBDA_EXEC_WRAPPER       # ADOT Lambda レイヤーの計装ラッパー
  AOT_CONFIG_CONTENT            # ADOT Collector の設定内容 (YAML)
)
# JVM オプション用の環境変数は、値が OpenTelemetry を参照している場合のみ
# OpenTelemetry 関連として扱う (JAVA_TOOL_OPTIONS で javaagent を注入する構成)。
OTEL_JVM_OPTION_ENV_NAMES=(
  JAVA_TOOL_OPTIONS
  JDK_JAVA_OPTIONS
  _JAVA_OPTIONS
  JAVA_OPTS
  JAVA_OPTS_APPEND
  JBOSS_JAVA_OPTS
)
# 送達不良の切り分けでまず確認する主要設定。環境変数と、それに対応する
# システムプロパティ (OTEL_SERVICE_NAME → -Dotel.service.name) の
# どちらも無い場合に「未設定」として表示する。
OTEL_KEY_ENV_NAMES=(
  OTEL_SERVICE_NAME
  OTEL_RESOURCE_ATTRIBUTES
  OTEL_TRACES_EXPORTER
  OTEL_METRICS_EXPORTER
  OTEL_LOGS_EXPORTER
  OTEL_EXPORTER_OTLP_ENDPOINT
  OTEL_EXPORTER_OTLP_PROTOCOL
  OTEL_PROPAGATORS
  OTEL_TRACES_SAMPLER
  OTEL_SDK_DISABLED
)

# ---- 全量ビルドレポート出力 --------------------------------------------------
BUILD_REPORT_DIR=""               # 指定時は日時付きテキストレポートをこの配下へ出力
BUILD_REPORT_DIR_SET="false"
BUILD_REPORT_FILE=""
BUILD_RESULT_STATUS="未実行"
BUILD_RESULT_DETAIL=""
BUILD_IMAGE_INFO=""

# ---- ログ用ヘルパ -----------------------------------------------------------
# 表示する時刻はすべて JST。UTC と読み違えないよう、必ずタイムゾーン名を併記する。
now_display_time() { printf '%s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL"; }
log()  { printf '[%s] %s\n'  "$(now_display_time)" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(now_display_time)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(now_display_time)" "$*" >&2; }
# 診断ガイド等の整形出力用 (タイムスタンプ等の接頭辞を付けず、そのまま表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(now_display_time)" "$*"
    return 0
  fi
  "$@"
}

# docker inspect や docker image inspect が返す時刻は、TZ 設定によらず RFC3339 の
# UTC 表記になる。表示前にこのヘルパで JST へ変換し、スクリプト全体の時刻表記を
# 揃える。date -d を持たない環境や解釈できない値は、元の文字列をそのまま返す。
DATE_PARSE_SUPPORTED=""
date_parse_supported() {
  if [ -z "$DATE_PARSE_SUPPORTED" ]; then
    if date -d '2000-01-02T03:04:05Z' '+%s' >/dev/null 2>&1; then
      DATE_PARSE_SUPPORTED="true"
    else
      DATE_PARSE_SUPPORTED="false"
    fi
  fi
  [ "$DATE_PARSE_SUPPORTED" = "true" ]
}

to_jst_display_time() {
  local value="$1" converted
  case "$value" in
    ''|0001-01-01T00:00:00Z)  # Docker が「未設定」を表すゼロ値はそのまま扱う
      printf '%s' "$value"
      return 0
      ;;
  esac
  if ! date_parse_supported; then
    printf '%s' "$value"
    return 0
  fi
  if converted="$(date -d "$value" '+%Y-%m-%d %H:%M:%S.%3N' 2>/dev/null)" \
      && [ -n "$converted" ]; then
    printf '%s %s' "$converted" "$DISPLAY_TZ_LABEL"
  else
    printf '%s' "$value"
  fi
}

# 「開始: <RFC3339>」「終了: <RFC3339>」形式の行だけを JST 表記へ書き換える。
# healthcheck 履歴の出力本文 (任意のテキスト) は変換対象にしない。
rewrite_health_history_time() {
  local line prefix value
  while IFS= read -r line; do
    case "$line" in
      '開始: '[0-9][0-9][0-9][0-9]-[0-9][0-9]-*|'終了: '[0-9][0-9][0-9][0-9]-[0-9][0-9]-*)
        prefix="${line%%: *}"
        value="${line#*: }"
        printf '%s: %s\n' "$prefix" "$(to_jst_display_time "$value")"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: build_and_verify.sh [OPTIONS]

build_and_push.sh の「ビルドのみ」処理を切り出した専用スクリプト。
compose build でローカルイメージをビルドし、必要に応じて起動確認・URL 応答確認を行う。
ECR ログイン/タグ付け/プッシュ/imagedefinition.json の出力は行わない。

ビルド関連:
  --local-image NAME       compose build で生成されるローカルイメージ名 (既定: j1/base.local)
  --compose-file FILE      compose ファイル (既定: compose.yml)
  --compose-service NAME   ビルド/起動対象サービス名 (未指定なら全サービス)。
                           繰り返し指定またはカンマ区切りで複数指定できる。
                           複数指定時は base サービスを必ず単独で先行ビルドし、
                           ベースイメージの生成確認後、base を除く指定サービスを
                           まとめて並列ビルドする。base を除く指定サービスは同時に起動する。
                           base はビルド専用のため、指定に含めても起動対象にはしない。
                           例: --compose-service app --compose-service db
                               --compose-service app,db
  --no-cache               キャッシュを破棄して compose build する
  --dry-run                実際のビルド/起動/URL 呼び出し/ファイル操作は行わず、
                           実行される内容のプレビューのみ表示する

終了時の Docker 完全クリーンアップ:
  --cleanup-all-docker-data
                           処理終了時 (成功・失敗を問わず)、現在の Docker context にある
                           全コンテナ (Compose を含む。一時停止中は解除) を通常停止した後、
                           停止済みを含む全コンテナ、
                           全ローカルイメージ、全ローカルボリューム、未使用の
                           ユーザー定義ネットワーク、削除可能な全ビルドキャッシュを
                           削除する。
                           実行直前に削除対象と件数を表示し、確認フレーズの入力を
                           必須とする。確認できない場合は Docker 全体クリーンアップを
                           実行せず、終了コード 1 とする。
                           Docker daemon / Docker Desktop、標準ネットワーク、context、
                           認証情報、daemon 設定は削除・停止しない。
                           --keep-container とは同時に指定できない。

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           処理終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc:./app --copy-file cert.pem:./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は事故防止のため中止する

JBoss マスターパスワード (BuildKit シークレット):
  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           compose.yml の environment 型シークレット定義を通じて
                           BuildKit シークレットとしてビルドに注入される。
                           このオプション使用時は aws コマンドと AWS 認証
                           (aws login --remote 実施済み) が必要で、未認証の場合は
                           認証を促す警告を表示して終了する (exit 1)。
  --jboss-password VALUE   JBoss のマスターパスワードを直接指定する
                           (パラメータストアから取得しない場合)。
                           --jboss-password-param とは同時に指定できない。
                           ※ コマンドライン (ps / シェル履歴) に平文が残るため、
                             可能なら --jboss-password-param か、事前 export +
                             --jboss-password-env の利用を推奨。
  --jboss-password-env NAME
                           シークレットの受け渡しに使う環境変数名
                           (既定: JBOSS_MASTER_PASSWORD)。compose.yml の
                           secrets の environment: と一致させること。
                           このオプションのみを指定した場合は、事前に export
                           済みの環境変数の値をそのままパスワードとして使う。
                           指定時は取得元 → export → Compose secret →
                           Dockerfile mount → standalone.xml の 5 段階を、
                           平文・ハッシュを出さずに自動照合する。
                           $ / # / ! / " / バッククォートは出現回数も記録する。
  --show-jboss-password-values
                           マスターパスワードの入力側設定値と standalone.xml 側の
                           不一致・直接照合不能文字列を、表現種別 (平文候補 /
                           ハッシュ形式候補 / 保護値等) と一緒にエスケープして
                           診断へ表示する。
                           指定しない場合も表現種別は表示するが、値は伏せる。
                           ※ 秘密値が画面、--report-dir の全量レポート、および呼出元の
                             --log-dir に残り得るため、隔離した調査時だけ使用すること。
                             ビルドログ本文のマスクは、この指定時も解除しない。
  --region REGION          パラメータストア参照時の AWS リージョン
                           (既定: ap-northeast-1 / env: AWS_REGION)

起動確認 (jbosseap / WildFly):
  --verify-startup         ビルド後にコンテナを起動し、jbosseap サーバーの起動完了を
                           ログから確認する。確認後はコンテナを停止・削除する
                           (--keep-container 指定時は残す)。
  --startup-service NAME   起動完了チェックを行うサービス名。繰り返し指定または
                           カンマ区切りで複数指定でき、指定した全サービスの起動完了を
                           それぞれのログから個別に確認する。指定時は --verify-startup
                           を暗黙に有効化する。未指定なら対象サービス全体のログを
                           まとめて確認する (従来動作)。
                           例: --compose-service app,db --startup-service app
  --startup-log-pattern P  起動完了とみなすログのパターン (拡張正規表現)。
                           既定: 'WFLYSRV0025:' (WFLYSRV0026 は失敗扱い)
  --startup-timeout SEC    起動完了を待つ最大秒数 (既定: 120)
  --startup-interval SEC   起動確認のポーリング間隔・秒 (既定: 3)
  --startup-log-lines N|all
                           起動確認対象と、同時に起動した他 Compose サービスの
                           ログ、および logs モードで選択したサービスの画面表示行数。
                           N は各サービスの末尾 N 行、all は全行を表示する (既定: 50)
  --wait-healthy           compose up に --wait を付け、起動対象サービスが healthy
                           (healthcheck 未定義なら running) になるまで compose 側で
                           待ってから起動確認へ進む。依存サービスの準備完了を待たずに
                           アプリが起動して失敗するのを防ぐ。compose.yml 側で依存
                           サービスに healthcheck と depends_on の condition:
                           service_healthy を定義しておくこと。
  --wait-timeout SEC       --wait の最大待機秒数 (既定: 600)。指定すると
                           --wait-healthy も暗黙に有効化する
  --allow-service-exit NAME
                           起動確認中に停止していても失敗扱いにしないサービス名。
                           繰り返し指定またはカンマ区切りで複数指定できる。
                           既定では --compose-service で指定した全サービス
                           (base を除く) の停止を失敗として即座に報告する
  --suppress-startup-logs  起動確認対象と同時起動サービスのログ表示を抑制する
                           (起動判定は継続)
  --shutdown-timeout SEC   エラー終了時に SIGTERM でコンテナを終了させる際、
                           SIGKILL へ切り替えるまでの猶予秒数 (既定: 30 /
                           ECS の StopTimeout 既定と同じ)。この停止を挟むことで、
                           adot collector などサイドカーの終了処理ログまで
                           画面・全量レポートへ残す
  --no-shutdown-logs       エラー終了時の SIGTERM 停止と終了ログ取得を行わない。
                           コンテナは従来どおり compose down でまとめて削除する
  --keep-container         確認後もコンテナを停止・削除せずに残す (調査用)
  --keep-container-mode MODE
                           起動確認後もコンテナを残し、検証対象コンテナで MODE の
                           対話操作を実行する。指定時は --verify-startup と
                           --keep-container を暗黙に有効化する。
                           MODE:
                             bash  docker exec で /bin/bash へ直接接続する
                             http  JBoss EAP へ対話式の HTTP リクエストを送る
                              logs  起動中 Compose サービスを番号で選択後、
                                    ログ表示、対話式 bash 接続、healthcheck の
                                    設定・実行履歴・通信確認を繰り返す。
                                    MySQL サーバーでは SQL の対話実行も選択できる。
                                    cwagent / cloudwatch-logs-mock では CloudWatch
                                    Logs 偽装送達、otel / adot-collector / jaeger
                                    では X-Ray 偽装トレースも確認できる
                                    (bash 接続先には /bin/bash が必要)
                           bash/http で対象が複数ある場合と、logs のサービス選択では
                           番号選択ダイアログを表示する。
                           送達診断の JSON 整形には curl と Python 3 が必要。
  --jboss-context-root ROOT
                           http モードで使う JBoss EAP のコンテキストルート。
                           未指定時は WFLYUT0021 ログから検出し、複数なら選択する。
  --jboss-http-port PORT   http モードで使うコンテナ側 HTTP リスナーポート。
                           未指定時は WFLYUT0006 ログから検出する (検出不能時: 8080)。
                           Docker の公開ポートがあれば接続先ポートへ自動変換する。
  --suppress-removed-logs  compose down 実行時の "Container ... Removed" 等の
                           出力を抑制する (ログが煩雑な場合に使用)
  --env-list-limit N|all   動作確認成功時に表示する環境変数一覧の件数。
                           各対象コンテナごとに先頭 N 件を表示する。
                           既定: all (全件表示)
  --env-list-file FILE     動作確認成功時の環境変数一覧を FILE にも出力する。
                           画面表示は従来どおり継続する
  --directory-tree-depth N|all
                           環境変数一覧の後に表示するコンテナ内ディレクトリツリーの
                           最大深さ。/ 直下を深さ 1 とし、既定の all は最下層まで表示する。
                           JBoss EAP のデプロイ構造にも同じ深さを適用する
  --directory-file-limit N|all
                           通常ファイルの画面表示を有効にする。各ディレクトリ直下が
                           N 件以下なら全ファイル名、超過時は拡張子別件数を表示する。
                           all は件数にかかわらず全ファイル名を表示する。
                           未指定時はディレクトリのみを表示する
  --deployment-dir-env NAME
                           ディレクトリパスを値に持つコンテナ環境変数名。
                           JBoss デプロイ先、Web アプリケーションルート、
                           WEB-INF/classes と併せて、そのディレクトリ構造を表示する。
                           繰り返し指定またはカンマ区切りで複数指定できる
  --report-dir DIR         ビルド結果、環境変数一覧、コンテナ内ツリー、JBoss EAP
                           デプロイ構造、JVM パラメータ、OpenTelemetry 設定を
                           DIR/build_and_verify_<日時>.txt へ保存する。
                           保存内容は画面の制限にかかわらず全深度・全ファイル名となる

  (オプション指定不要の自動表示)
  Java JVM パラメータ一覧  動作確認したコンテナ内の Java プロセスを /proc から検出し、
                           起動時の JVM パラメータをヒープ・メモリ / GC /
                           Java エージェント / OpenTelemetry / JBoss /
                           システムプロパティ / クラスパス・モジュール / その他へ
                           分類して表示する。JAVA_OPTS・JAVA_TOOL_OPTIONS など、
                           コマンドラインに現れない環境変数経由の指定も併記する。
  OpenTelemetry 設定一覧   OTEL_ で始まる標準環境変数、AWS_XRAY_* などの関連環境変数、
                           -Dotel.* や OpenTelemetry の -javaagent といった JVM
                           パラメータを 1 つの一覧にまとめて表示する。
                           主要設定が環境変数・システムプロパティのどちらにも
                           無い場合は「未設定」として併せて表示する。
                           ※ 値に認証情報を含みやすい名前 (PASSWORD / TOKEN /
                             SECRET / HEADERS 等) は [REDACTED] で表示する

URL 応答確認:
  --verify-url URL         起動確認後、この URL へ HTTP リクエストを送り応答を確認する。
                           (単独指定でもコンテナを起動して確認する)
  --expect-status CODE     期待する HTTP ステータスコード (既定: 200)
  --url-method METHOD      HTTP メソッド (既定: GET)
  --url-content-type TYPE  verify-url 時の Content-Type ヘッダ値
  --url-body-json JSON     verify-url 時のリクエストボディに JSON を設定する。
                           Content-Type 未指定時は application/json を自動設定する。
  --url-body-form DATA     verify-url 時のリクエストボディに form データ
                           (key=value&...) を設定する。Content-Type 未指定時は
                           application/x-www-form-urlencoded を自動設定する。
  --url-timeout SEC        期待する応答を得るまで待つ最大秒数・リトライ、および
                           HTTP / healthcheck 診断の 1 回あたりの最大秒数。
                           対話式 http モードでは 1 リクエストの最大秒数 (既定: 60)
  --url-interval SEC       URL 呼び出しのリトライ間隔・秒 (既定: 3)
  --url-insecure           TLS 証明書検証を無効化して呼び出す (curl -k)

  -h, --help               このヘルプを表示
EOF
}

# ---- 引数パース -------------------------------------------------------------
# カンマ区切りの値を分割して配列変数 (名前を $1 で受ける) に追加する。
# 例: append_services COMPOSE_SERVICES "app,db"
append_services() {
  local _var="$1" _value="$2" _s
  local -a _parts=()
  IFS=',' read -r -a _parts <<< "$_value"
  for _s in "${_parts[@]}"; do
    [ -n "$_s" ] && eval "$_var+=(\"\$_s\")"
  done
}

# 値を取るオプションで値が省略されると "$2" の参照が set -u の unbound variable
# となり、原因の分からないエラーになる。各 case の先頭で残り引数数を検証する。
need_value() {
  if [ "$2" -lt 2 ]; then
    err "オプションに値が指定されていません: $1"
    err "  使い方は --help を参照してください。"
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local-image)         need_value "$1" $#; LOCAL_IMAGE="$2"; shift 2 ;;
    --compose-file)        need_value "$1" $#; COMPOSE_FILE="$2"; shift 2 ;;
    --compose-service)     need_value "$1" $#; append_services COMPOSE_SERVICES "$2"; shift 2 ;;
    --no-cache)            NO_CACHE="true"; shift ;;
    --dry-run)             DRY_RUN="true"; shift ;;
    --cleanup-all-docker-data) CLEANUP_ALL_DOCKER_DATA="true"; shift ;;
    --copy-file)           need_value "$1" $#; COPY_SPECS+=("$2"); shift 2 ;;
    --region)              need_value "$1" $#; REGION="$2"; shift 2 ;;
    --jboss-password-param) need_value "$1" $#; JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       need_value "$1" $#; JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   need_value "$1" $#; JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --show-jboss-password-values) JBOSS_PASSWORD_SHOW_VALUES="true"; shift ;;
    --verify-startup)      VERIFY_STARTUP="true"; shift ;;
    --startup-service)     need_value "$1" $#; append_services STARTUP_SERVICES "$2"; VERIFY_STARTUP="true"; shift 2 ;;
    --startup-log-pattern) need_value "$1" $#; STARTUP_LOG_PATTERN="$2"; shift 2 ;;
    --startup-timeout)     need_value "$1" $#; STARTUP_TIMEOUT="$2"; shift 2 ;;
    --startup-interval)    need_value "$1" $#; STARTUP_INTERVAL="$2"; shift 2 ;;
    --startup-log-lines)   need_value "$1" $#; STARTUP_LOG_LINES="$2"; shift 2 ;;
    --wait-healthy)        STARTUP_WAIT="true"; shift ;;
    --wait-timeout)        need_value "$1" $#; STARTUP_WAIT_TIMEOUT="$2"; STARTUP_WAIT="true"; shift 2 ;;
    --allow-service-exit)  need_value "$1" $#; append_services ALLOW_SERVICE_EXIT "$2"; shift 2 ;;
    --suppress-startup-logs) SUPPRESS_STARTUP_LOGS="true"; shift ;;
    --shutdown-timeout)    need_value "$1" $#; SHUTDOWN_LOG_TIMEOUT="$2"; shift 2 ;;
    --no-shutdown-logs)    CAPTURE_SHUTDOWN_LOGS="false"; shift ;;
    --keep-container)      KEEP_CONTAINER="true"; shift ;;
    --keep-container-mode) need_value "$1" $#; KEEP_CONTAINER_MODE="$2"; shift 2 ;;
    --jboss-context-root)  need_value "$1" $#; JBOSS_CONTEXT_ROOT="$2"; shift 2 ;;
    --jboss-http-port)     need_value "$1" $#; JBOSS_HTTP_PORT="$2"; shift 2 ;;
    --suppress-removed-logs) SUPPRESS_REMOVED_LOGS="true"; shift ;;
    --env-list-limit)      need_value "$1" $#; ENV_LIST_LIMIT="$2"; shift 2 ;;
    --env-list-file)       need_value "$1" $#; ENV_LIST_FILE="$2"; shift 2 ;;
    --directory-tree-depth) need_value "$1" $#; DIRECTORY_TREE_DEPTH="$2"; DIRECTORY_TREE_DEPTH_SET="true"; shift 2 ;;
    --directory-file-limit) need_value "$1" $#; DIRECTORY_FILE_LIMIT="$2"; DIRECTORY_FILE_LIMIT_SET="true"; shift 2 ;;
    --deployment-dir-env) need_value "$1" $#; append_services DEPLOYMENT_DIR_ENVS "$2"; shift 2 ;;
    --report-dir)          need_value "$1" $#; BUILD_REPORT_DIR="$2"; BUILD_REPORT_DIR_SET="true"; shift 2 ;;
    --verify-url)          need_value "$1" $#; VERIFY_URL="$2"; shift 2 ;;
    --expect-status)       need_value "$1" $#; EXPECT_STATUS="$2"; shift 2 ;;
    --url-method)          need_value "$1" $#; URL_METHOD="$2"; shift 2 ;;
    --url-content-type)    need_value "$1" $#; URL_CONTENT_TYPE="$2"; shift 2 ;;
    --url-body-json)       need_value "$1" $#; URL_BODY_JSON="$2"; shift 2 ;;
    --url-body-form)       need_value "$1" $#; URL_BODY_FORM="$2"; shift 2 ;;
    --url-timeout)         need_value "$1" $#; URL_TIMEOUT="$2"; shift 2 ;;
    --url-interval)        need_value "$1" $#; URL_INTERVAL="$2"; shift 2 ;;
    --url-insecure)        URL_INSECURE="true"; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# 表示件数・階層深さは、何も表示されない指定を避けるため 1 以上に制限する。
validate_positive_integer() {
  local value="$1" opt_name="$2"
  case "$value" in
    ''|*[!0-9]*|0)
      err "${opt_name} には 1 以上の整数を指定してください: ${value}"
      return 1
    ;;
  esac
  return 0
}

if [ "$STARTUP_LOG_LINES" != "all" ]; then
  validate_positive_integer "$STARTUP_LOG_LINES" "--startup-log-lines" || exit 2
fi
validate_positive_integer "$STARTUP_TIMEOUT" "--startup-timeout" || exit 2
validate_positive_integer "$STARTUP_WAIT_TIMEOUT" "--wait-timeout" || exit 2
# 0 を許すと SIGTERM 直後に SIGKILL となり、終了処理のログが残らないため 1 以上とする。
validate_positive_integer "$SHUTDOWN_LOG_TIMEOUT" "--shutdown-timeout" || exit 2
validate_positive_integer "$URL_TIMEOUT" "--url-timeout" || exit 2
if [ "$ENV_LIST_LIMIT" != "all" ]; then
  validate_positive_integer "$ENV_LIST_LIMIT" "--env-list-limit" || exit 2
fi
if [ "$DIRECTORY_TREE_DEPTH" != "all" ]; then
  validate_positive_integer "$DIRECTORY_TREE_DEPTH" "--directory-tree-depth" || exit 2
fi
if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] && [ "$DIRECTORY_FILE_LIMIT" != "all" ]; then
  validate_positive_integer "$DIRECTORY_FILE_LIMIT" "--directory-file-limit" || exit 2
fi
for _deployment_env in "${DEPLOYMENT_DIR_ENVS[@]}"; do
  if ! printf '%s' "$_deployment_env" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
    err "--deployment-dir-env に不正な環境変数名が指定されました: $_deployment_env"
    exit 2
  fi
done
if [ "$BUILD_REPORT_DIR_SET" = "true" ] && { [ -z "$BUILD_REPORT_DIR" ] || [ "$BUILD_REPORT_DIR" = "-" ]; }; then
  err "--report-dir にはディレクトリパスを指定してください: $BUILD_REPORT_DIR"
  exit 2
fi

case "$KEEP_CONTAINER_MODE" in
  "") ;;
  bash|http|logs)
    KEEP_CONTAINER="true"
    VERIFY_STARTUP="true"
    ;;
  *)
    err "--keep-container-mode には bash、http または logs を指定してください: ${KEEP_CONTAINER_MODE}"
    exit 2
    ;;
esac

if [ -n "$JBOSS_HTTP_PORT" ]; then
  case "$JBOSS_HTTP_PORT" in
    *[!0-9]*)
      err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
      exit 2
      ;;
  esac
  if [ "${#JBOSS_HTTP_PORT}" -gt 5 ] \
      || (( 10#$JBOSS_HTTP_PORT < 1 || 10#$JBOSS_HTTP_PORT > 65535 )); then
    err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
    exit 2
  fi
fi

if { [ -n "$JBOSS_CONTEXT_ROOT" ] || [ -n "$JBOSS_HTTP_PORT" ]; } \
    && [ "$KEEP_CONTAINER_MODE" != "http" ]; then
  err "--jboss-context-root / --jboss-http-port は --keep-container-mode http と併用してください"
  exit 2
fi

if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
  case "$JBOSS_CONTEXT_ROOT" in
    *://*|*\?*|*\#*|*[[:space:]]*)
      err "--jboss-context-root には URL ではなくコンテキストルートのパスだけを指定してください: ${JBOSS_CONTEXT_ROOT}"
      exit 2
      ;;
  esac
fi

if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] && [ "$KEEP_CONTAINER" = "true" ]; then
  err "--cleanup-all-docker-data と --keep-container は同時に指定できません"
  exit 2
fi

# --startup-service が --compose-service の対象に含まれているか検証する。
# (--compose-service 未指定 = 全サービス対象なので、その場合は検証不要)
if [ ${#STARTUP_SERVICES[@]} -gt 0 ] && [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
  for _ss in "${STARTUP_SERVICES[@]}"; do
    _found="false"
    for _cs in "${COMPOSE_SERVICES[@]}"; do
      [ "$_ss" = "$_cs" ] && _found="true"
    done
    if [ "$_found" != "true" ]; then
      err "--startup-service '$_ss' が --compose-service で指定した対象 (${COMPOSE_SERVICES[*]}) に含まれていません"
      exit 2
    fi
  done
fi

# base はベースイメージを提供するビルド専用サービスであり、起動しても即終了するだけで
# 検証の役に立たない。--compose-service に明示指定されていてもビルドのみに使い、
# 起動・ログ収集・生存監視の対象からは除外する (README の仕様と実装を一致させる)。
COMPOSE_TARGET_SERVICES=()
for _cs in ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; do
  [ "$_cs" = "$BASE_SERVICE" ] || COMPOSE_TARGET_SERVICES+=("$_cs")
done
if [ ${#COMPOSE_SERVICES[@]} -gt 0 ] && [ ${#COMPOSE_TARGET_SERVICES[@]} -eq 0 ]; then
  if [ "$VERIFY_STARTUP" = "true" ] || [ -n "$VERIFY_URL" ]; then
    err "--compose-service にベースサービス '${BASE_SERVICE}' しか指定されていないため、起動対象がありません"
    err "  起動確認を行う場合は、起動したいサービスも --compose-service に指定してください。"
    exit 2
  fi
fi

# --verify-url が指定されている場合、コンテナ起動が前提となる。
# 明示的に --verify-startup が付いていなくてもコンテナは起動する
# (起動完了のログ確認を行うかどうかは VERIFY_STARTUP で制御)。
NEED_CONTAINER="false"
if [ "$VERIFY_STARTUP" = "true" ] || [ -n "$VERIFY_URL" ]; then
  NEED_CONTAINER="true"
fi

# URL ボディ指定は JSON / form のどちらか一方のみ許可する。
if [ -n "$URL_BODY_JSON" ] && [ -n "$URL_BODY_FORM" ]; then
  err "--url-body-json と --url-body-form は同時に指定できません (リクエストボディは一つのみ指定できます)"
  exit 2
fi

# verify-url 用の追加指定は --verify-url と組み合わせて使う。
HAS_URL_REQUEST_OPTIONS="false"
if [ -n "$URL_CONTENT_TYPE" ] || [ -n "$URL_BODY_JSON" ] || [ -n "$URL_BODY_FORM" ]; then
  HAS_URL_REQUEST_OPTIONS="true"
fi
if [ -z "$VERIFY_URL" ] && [ "$HAS_URL_REQUEST_OPTIONS" = "true" ]; then
  err "--url-content-type / --url-body-json / --url-body-form は --verify-url と併用してください"
  exit 2
fi

# ボディ形式に応じて Content-Type の既定値を補う。
if [ -z "$URL_CONTENT_TYPE" ]; then
  if [ -n "$URL_BODY_JSON" ]; then
    URL_CONTENT_TYPE="application/json"
  elif [ -n "$URL_BODY_FORM" ]; then
    URL_CONTENT_TYPE="application/x-www-form-urlencoded"
  fi
fi

# ---- JBoss マスターパスワード関連オプションの検証 ----------------------------
# 取得元はパラメータストア (--jboss-password-param) / 直接指定 (--jboss-password) /
# 事前 export 済み環境変数 (--jboss-password-env のみ指定) のいずれか 1 つ。
if [ -n "$JBOSS_PASSWORD_PARAM" ] && [ -n "$JBOSS_PASSWORD_VALUE" ]; then
  err "--jboss-password-param と --jboss-password は同時に指定できません (どちらか一方を指定してください)"
  exit 2
fi
if [ -n "$JBOSS_PASSWORD_PARAM" ] || [ -n "$JBOSS_PASSWORD_VALUE" ] || [ "$JBOSS_PASSWORD_ENV_SET" = "true" ]; then
  JBOSS_SECRET_ENABLED="true"
fi
if [ "$JBOSS_PASSWORD_SHOW_VALUES" = "true" ] && [ "$JBOSS_SECRET_ENABLED" != "true" ]; then
  err "--show-jboss-password-values は --jboss-password-param / --jboss-password / --jboss-password-env のいずれかと併用してください"
  exit 2
fi
if ! printf '%s' "$JBOSS_PASSWORD_ENV" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
  err "--jboss-password-env に不正な環境変数名が指定されました: $JBOSS_PASSWORD_ENV"
  exit 2
fi

# ---- 依存コマンド確認 -------------------------------------------------------
# ビルドには docker が必須。URL 応答確認または対話式 HTTP 通信では curl も必須。
# logs モードの可観測性ヘルパーは、選択時に curl と Python 3 を確認する。
# パラメータストアからパスワードを取得する場合は aws も必須。
REQUIRED_CMDS=(docker)
if [ -n "$VERIFY_URL" ] || [ "$KEEP_CONTAINER_MODE" = "http" ]; then
  REQUIRED_CMDS+=(curl)
fi
[ -n "$JBOSS_PASSWORD_PARAM" ] && REQUIRED_CMDS+=(aws)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# このスクリプトは通常 AWS を操作しないが、パラメータストアからパスワードを
# 取得する場合のみ AWS 認証が必要になる。事前に aws login --remote による認証
# 操作が実行されているかを sts get-caller-identity で確認し、未認証なら
# 認証を促して終了する。
if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
  log "AWS 認証状態を確認します (aws login --remote 実施済みか) ..."
  if aws sts get-caller-identity >/dev/null 2>&1; then
    log "AWS 認証を確認しました。"
  elif [ "$DRY_RUN" = "true" ]; then
    warn "AWS 認証が確認できませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合は、事前に 'aws login --remote' で認証してください。"
  else
    err "AWS 認証が確認できません (aws sts get-caller-identity に失敗)。未認証の状態です。"
    err "  事前に 'aws login --remote' を実行して認証してから、再実行してください。"
    exit 1
  fi
fi

# docker compose (v2) / docker-compose (v1) の判定。
# 複数サービス指定時は Compose の並列実行オプションも準備する。v2 はグローバルの
# --parallel N、v1 は build サブコマンドの --parallel を使用する。
COMPOSE_PARALLEL_OPTS=()
COMPOSE_BUILD_PARALLEL_OPTS=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    COMPOSE_PARALLEL_OPTS=(--parallel "${#COMPOSE_SERVICES[@]}")
  fi
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    if docker-compose build --help 2>&1 | grep -q -- '--parallel'; then
      COMPOSE_BUILD_PARALLEL_OPTS=(--parallel)
    else
      err "複数サービスの並列ビルドには --parallel 対応の docker-compose が必要です"
      exit 1
    fi
  fi
else
  err "docker compose / docker-compose が見つかりません"
  exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/起動/URL 呼び出し/ファイル操作は行いません。 ***"
fi

# JBoss パスワード診断は既定で平文やハッシュ文字列を保存せず、照合結果・表現種別・
# 文字種情報だけを画面および全量レポートへ残す。--show-jboss-password-values が
# 明示された場合に限り、調査対象の値を一行エスケープ形式で診断へ含める。
record_jboss_password_diagnostic() {
  local level="$1" message
  shift
  message="$*"
  JBOSS_PASSWORD_DIAGNOSTIC_LINES+=("${level}: ${message}")
  case "$level" in
    INFO)   log "$message" ;;
    WARN)   warn "$message" ;;
    ERROR)  err "$message" ;;
    DETAIL) diag "$message" ;;
    *)      log "$message" ;;
  esac
}

# 値を開示せずに、特殊文字が受け渡し途中で欠落していないか確認するための属性を返す。
# 順序や値は出さず、文字数・UTF-8 バイト数・指定文字の出現回数だけを表示する。
count_jboss_password_character() {
  local remainder="$1" character="$2" count=0
  while [[ "$remainder" == *"$character"* ]]; do
    remainder="${remainder#*"$character"}"
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# 文字列だけから平文かハッシュかを断定することはできないため、自己記述形式や
# 代表的なダイジェスト長に一致する場合だけ「候補」として分類する。
jboss_password_representation() {
  local value="$1" digest_name=""
  case "$value" in
    MASK-*)
      printf 'JBoss/WildFly MASK- 保護値（平文ではない）'
      return 0
      ;;
    '${'*)
      if [[ "$value" == *'}' ]]; then
        printf '式参照（実値ではない）'
        return 0
      fi
      ;;
    '$2a$'*|'$2b$'*|'$2y$'*)
      printf 'ハッシュ形式候補（bcrypt）'
      return 0
      ;;
    '$argon2i$'*|'$argon2d$'*|'$argon2id$'*)
      printf 'ハッシュ形式候補（Argon2）'
      return 0
      ;;
    '$pbkdf2-'*|'$scrypt$'*)
      printf 'ハッシュ形式候補（PBKDF2 / scrypt）'
      return 0
      ;;
    '$1$'*)
      printf 'ハッシュ形式候補（md5-crypt）'
      return 0
      ;;
    '$5$'*)
      printf 'ハッシュ形式候補（sha256-crypt）'
      return 0
      ;;
    '$6$'*)
      printf 'ハッシュ形式候補（sha512-crypt）'
      return 0
      ;;
  esac
  if [[ "$value" =~ ^\{([Ss][Hh][Aa]|[Ss][Ss][Hh][Aa]|[Mm][Dd]5|[Ss][Mm][Dd]5|[Pp][Bb][Kk][Dd][Ff]2)\} ]]; then
    printf 'ハッシュ形式候補（LDAP 接頭辞形式）'
    return 0
  fi
  if [[ "$value" =~ ^[[:xdigit:]]+$ ]]; then
    case "${#value}" in
      32)  digest_name="MD5 相当の32桁16進" ;;
      40)  digest_name="SHA-1 相当の40桁16進" ;;
      56)  digest_name="SHA-224 相当の56桁16進" ;;
      64)  digest_name="SHA-256 相当の64桁16進" ;;
      96)  digest_name="SHA-384 相当の96桁16進" ;;
      128) digest_name="SHA-512 相当の128桁16進" ;;
    esac
  fi
  if [ -n "$digest_name" ]; then
    printf 'ハッシュ形式候補（%s）' "$digest_name"
  else
    printf '平文候補（既知のハッシュ・保護値形式には非該当）'
  fi
}

jboss_password_profile() {
  local value="$1" byte_length character_length item joined=""
  local -a special_characters=()
  byte_length="$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d '[:space:]')"
  character_length="${#value}"
  case "$value" in *'$'*) special_characters+=("ドル記号($):$(count_jboss_password_character "$value" '$')") ;; esac
  case "$value" in *'#'*) special_characters+=("番号記号(#):$(count_jboss_password_character "$value" '#')") ;; esac
  case "$value" in *'!'*) special_characters+=("感嘆符(!):$(count_jboss_password_character "$value" '!')") ;; esac
  case "$value" in *'"'*) special_characters+=("二重引用符(\"):$(count_jboss_password_character "$value" '"')") ;; esac
  case "$value" in *'`'*) special_characters+=("バッククォート(\`):$(count_jboss_password_character "$value" '`')") ;; esac
  if [ ${#special_characters[@]} -eq 0 ]; then
    joined="なし"
  else
    for item in "${special_characters[@]}"; do
      [ -n "$joined" ] && joined="${joined}, "
      joined="${joined}${item}"
    done
  fi
  printf '表現種別=%s, 文字数=%s, UTF-8バイト数=%s, 対象特殊文字={%s}' \
    "$(jboss_password_representation "$value")" \
    "$character_length" "$byte_length" "$joined"
}

create_jboss_secure_temp_file() {
  local purpose="$1" old_umask temp_file status
  old_umask="$(umask)"
  umask 077
  temp_file="$(mktemp "${TMPDIR:-/tmp}/build-and-verify-jboss-${purpose}.XXXXXX" 2>/dev/null)"
  status=$?
  umask "$old_umask"
  if [ "$status" -ne 0 ] || [ -z "$temp_file" ]; then
    err "JBoss パスワード診断用の一時ファイルを作成できませんでした (${purpose})"
    return 1
  fi
  printf '%s' "$temp_file"
}

# ビルドツールや CLI が値をそのまま、シェル引用、CLI 引用、XML エスケープの
# いずれで表示してもマスクできるよう、既知の表現だけを権限 600 の一時ファイルへ
# 保存する。改行を含む値は行指向マスクで安全に扱えないため明示的に拒否する。
prepare_jboss_password_redaction() {
  local raw="$JBOSS_PASSWORD_EXPECTED" shell_quoted cli_escaped xml_escaped
  if [[ "$raw" == *$'\n'* ]] || [[ "$raw" == *$'\r'* ]]; then
    err "JBoss マスターパスワードに改行 (LF/CR) は使用できません。"
    err "  ビルドログの行単位マスクと JBoss CLI 式の境界が曖昧になり、値を安全に診断できないためです。"
    return 1
  fi
  if ! JBOSS_PASSWORD_EXPECTED_FILE="$(create_jboss_secure_temp_file expected)"; then
    return 1
  fi
  if ! printf '%s' "$raw" > "$JBOSS_PASSWORD_EXPECTED_FILE"; then
    err "JBoss パスワード照合用の一時ファイルへ書き込めませんでした。"
    return 1
  fi
  if ! JBOSS_PASSWORD_REDACTION_FILE="$(create_jboss_secure_temp_file redaction)"; then
    return 1
  fi

  printf -v shell_quoted '%q' "$raw"
  cli_escaped="${raw//\\/\\\\}"
  cli_escaped="${cli_escaped//\"/\\\"}"
  xml_escaped="${raw//&/\&amp;}"
  xml_escaped="${xml_escaped//</\&lt;}"
  xml_escaped="${xml_escaped//>/\&gt;}"
  xml_escaped="${xml_escaped//\"/\&quot;}"
  xml_escaped="${xml_escaped//\'/\&apos;}"
  if ! printf '%s\n' "$raw" "$shell_quoted" "$cli_escaped" "$xml_escaped" \
      > "$JBOSS_PASSWORD_REDACTION_FILE"; then
    err "JBoss パスワードのビルドログマスク情報を作成できませんでした。"
    return 1
  fi
}

# 権限 600 の候補ファイルを読むため、パスワード自体は awk の引数や環境変数へ
# 新たに載せない。空文字候補は全行置換を避けるため無視する。
redact_jboss_password_stream() {
  if [ "$JBOSS_SECRET_ENABLED" != "true" ] || [ -z "$JBOSS_PASSWORD_REDACTION_FILE" ]; then
    cat
    return
  fi
  awk -v variants_file="$JBOSS_PASSWORD_REDACTION_FILE" '
    BEGIN {
      count = 0
      while ((getline value < variants_file) > 0) {
        if (length(value) > 0) {
          variants[++count] = value
        }
      }
      close(variants_file)
    }
    {
      line = $0
      for (i = 1; i <= count; i++) {
        while ((position = index(line, variants[i])) > 0) {
          line = substr(line, 1, position - 1) \
                 "[REDACTED:JBOSS_MASTER_PASSWORD]" \
                 substr(line, position + length(variants[i]))
        }
      }
      print line
      fflush()
    }
  '
}

JBOSS_PASSWORD_FAILURE_PATTERN='WFLYELY[0-9]+|ELY[0-9]{5}|CredentialStoreException|UnrecoverableKeyException|BadPaddingException|AEADBadTagException|org\.jboss\.as\.cli\.[A-Za-z]*Exception|CommandFormatException|keystore[^[:cntrl:]]*(password|tampered)|password[^[:cntrl:]]*(incorrect|invalid|mismatch|does not match|failed)|credential[- ]?store[^[:cntrl:]]*(failed|failure|error|exception|unable|cannot)|jboss-cli[^[:cntrl:]]*(failed|failure|error|unexpected|parse)|WFLYCTL[^[:cntrl:]]*(credential|elytron|password)|パスワード[^[:cntrl:]]*(不一致|誤り|失敗)'

diagnose_jboss_password_build_failure() {
  local phase="$1" build_log="$2" exported_value evidence_line
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  if ! grep -Eiq -- "$JBOSS_PASSWORD_FAILURE_PATTERN" "$build_log"; then
    record_jboss_password_diagnostic INFO \
      "ビルド失敗ログに JBoss CLI / Elytron / credential-store のパスワード関連エラーパターンは見つかりませんでした (フェーズ=${phase})。"
    return 0
  fi

  record_jboss_password_diagnostic ERROR \
    "ビルド失敗は JBoss マスターパスワード、JBoss CLI、または Elytron credential-store に関連している可能性が高いです (フェーズ=${phase})。"
  exported_value="${!JBOSS_PASSWORD_ENV:-}"
  if [ "$exported_value" = "$JBOSS_PASSWORD_EXPECTED" ]; then
    record_jboss_password_diagnostic INFO \
      "照合済み: 取得元 (${JBOSS_PASSWORD_SOURCE}) とホスト環境変数 ${JBOSS_PASSWORD_ENV} はバイト列として完全一致しています。"
  else
    record_jboss_password_diagnostic ERROR \
      "不一致箇所: 取得元 (${JBOSS_PASSWORD_SOURCE}) とホスト環境変数 ${JBOSS_PASSWORD_ENV} が一致しません。"
  fi
  record_jboss_password_diagnostic INFO \
    "Compose secret 照合: ${JBOSS_PASSWORD_COMPOSE_STATUS}; Dockerfile mount 確認: ${JBOSS_PASSWORD_DOCKERFILE_STATUS}"
  record_jboss_password_diagnostic WARN \
    "ビルド失敗時は最終イメージが確定しないため、JBoss CLI が解釈した clear-text 値と standalone.xml は直接取得できません。"

  if grep -Eiq -- 'UnrecoverableKeyException|BadPaddingException|AEADBadTagException|keystore[^[:cntrl:]]*(password|tampered)|password[^[:cntrl:]]*(incorrect|mismatch|does not match)' "$build_log"; then
    record_jboss_password_diagnostic ERROR \
      "エラーが示す照合点: JBoss CLI / standalone.xml の credential-store マスターパスワードと、既存 credential-store ファイルを暗号化したパスワードとの照合です。"
  elif grep -Eiq -- 'jboss-cli[^[:cntrl:]]*(unexpected|parse)|org\.jboss\.as\.cli\.[A-Za-z]*Exception|CommandFormatException|WFLYCTL[^[:cntrl:]]*(credential|password)' "$build_log"; then
    record_jboss_password_diagnostic ERROR \
      "エラーが示す照合点: BuildKit secret の元バイト列と、JBoss CLI の引用・エスケープ後に解釈された clear-text 値との照合です。"
  else
    record_jboss_password_diagnostic WARN \
      "不一致候補は (1) BuildKit secret と JBoss CLI 解釈値、または (2) CLI 設定値と既存 credential-store ファイルの暗号化パスワードです。"
  fi

  record_jboss_password_diagnostic DETAIL \
    "---- パスワード関連と判定したビルドログ抜粋 (マスターパスワードはマスク済み、最大60行) ----"
  while IFS= read -r evidence_line; do
    record_jboss_password_diagnostic DETAIL "  ${evidence_line}"
  done < <({ grep -Ein -C 2 -- "$JBOSS_PASSWORD_FAILURE_PATTERN" "$build_log" || true; } | sed -n '1,60p')
  record_jboss_password_diagnostic DETAIL \
    "---- パスワード関連ビルドログ抜粋ここまで ----"
}

# JBoss secret が有効な場合だけビルド出力をマスク後に保存し、失敗時の根拠を
# その場で分析する。PIPESTATUS[0] により tee ではなく compose build の終了値を返す。
execute_compose_build() {
  local phase="$1" build_log command_status
  local -a pipeline_status=()
  shift
  if [ "$DRY_RUN" = "true" ]; then
    run "$@"
    return $?
  fi
  if [ "$JBOSS_SECRET_ENABLED" != "true" ]; then
    "$@"
    return $?
  fi
  if ! build_log="$(create_jboss_secure_temp_file build-log)"; then
    return 1
  fi
  JBOSS_BUILD_LOG_FILES+=("$build_log")
  record_jboss_password_diagnostic INFO \
    "ビルド出力を逐次マスクしながら診断用に一時保存します (フェーズ=${phase}、終了時に削除)。"
  "$@" 2>&1 | redact_jboss_password_stream | tee "$build_log"
  pipeline_status=("${PIPESTATUS[@]}")
  command_status="${pipeline_status[0]:-1}"
  if [ "${pipeline_status[1]:-1}" -ne 0 ] || [ "${pipeline_status[2]:-1}" -ne 0 ]; then
    record_jboss_password_diagnostic ERROR \
      "ビルドログのマスクまたは一時保存に失敗したため、検証を安全に継続できません。"
    return 1
  fi
  if [ "$command_status" -ne 0 ]; then
    diagnose_jboss_password_build_failure "$phase" "$build_log"
  fi
  return "$command_status"
}

# ---- JBoss マスターパスワードの取得 / BuildKit シークレット注入準備 ----------
# --jboss-password-param / --jboss-password / --jboss-password-env のいずれかが
# 指定された場合に、マスターパスワードを取得して環境変数へ export する。
# compose.yml 側で secrets の environment: に同じ環境変数名を定義しておくことで、
# BuildKit シークレット (RUN --mount=type=secret) としてビルドから参照できる。
# 値は既定でログへ出さず、明示的な診断オプションがある場合だけ診断行へ出す。
prepare_jboss_password() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local password="" exported_value escaped_value
  if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
    JBOSS_PASSWORD_SOURCE="SSM Parameter Store (${JBOSS_PASSWORD_PARAM})"
    log "パラメータストアから JBoss マスターパスワードを取得します: ${JBOSS_PASSWORD_PARAM} (region=${REGION}) ..."
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] aws ssm get-parameter --name ${JBOSS_PASSWORD_PARAM} --with-decryption --region ${REGION} (値の取得・表示は行いません)"
    else
      local ssm_errfile
      ssm_errfile="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ssm_err.$$")"
      if ! password="$(aws ssm get-parameter --name "$JBOSS_PASSWORD_PARAM" \
            --with-decryption --region "$REGION" \
            --query 'Parameter.Value' --output text 2>"$ssm_errfile")"; then
        err "パラメータストアからの取得に失敗しました: ${JBOSS_PASSWORD_PARAM}"
        sed 's/^/  /' "$ssm_errfile" >&2
        rm -f "$ssm_errfile"
        err "  パラメータ名 / リージョン (${REGION}) / ssm:GetParameter 権限を確認してください。"
        exit 1
      fi
      rm -f "$ssm_errfile"
      if [ -z "$password" ] || [ "$password" = "None" ]; then
        err "パラメータストアから取得した値が空です: ${JBOSS_PASSWORD_PARAM}"
        exit 1
      fi
      log "パラメータストアから JBoss マスターパスワードを取得しました。"
    fi
  elif [ -n "$JBOSS_PASSWORD_VALUE" ]; then
    JBOSS_PASSWORD_SOURCE="直接指定 (--jboss-password)"
    log "直接指定された JBoss マスターパスワードを使用します。"
    password="$JBOSS_PASSWORD_VALUE"
  else
    JBOSS_PASSWORD_SOURCE="既存環境変数 (${JBOSS_PASSWORD_ENV})"
    # --jboss-password-env のみ指定: 事前に export 済みの環境変数の値をそのまま使う
    password="${!JBOSS_PASSWORD_ENV:-}"
    if [ -z "$password" ] && [ "$DRY_RUN" != "true" ]; then
      err "環境変数 ${JBOSS_PASSWORD_ENV} が未設定または空です。"
      err "  --jboss-password-param / --jboss-password で渡すか、事前に export してから再実行してください。"
      exit 1
    fi
    log "既存の環境変数 ${JBOSS_PASSWORD_ENV} の値を JBoss マスターパスワードとして使用します。"
  fi
  JBOSS_PASSWORD_EXPECTED="$password"
  if [ "$DRY_RUN" != "true" ]; then
    if ! prepare_jboss_password_redaction; then
      exit 1
    fi
    record_jboss_password_diagnostic INFO \
      "パスワード推移[1/5] 取得元=${JBOSS_PASSWORD_SOURCE}; $(jboss_password_profile "$JBOSS_PASSWORD_EXPECTED")。"
    if [ "$JBOSS_PASSWORD_SHOW_VALUES" = "true" ]; then
      printf -v escaped_value '%q' "$JBOSS_PASSWORD_EXPECTED"
      record_jboss_password_diagnostic WARN \
        "--show-jboss-password-values が有効です。秘密値が画面・全量レポート・呼出元ログへ残る可能性があります (ビルドログ本文は引き続きマスクします)。"
      record_jboss_password_diagnostic DETAIL \
        "パスワード推移[1/5] 入力側設定値: 取得元=${JBOSS_PASSWORD_SOURCE}; 表現種別=$(jboss_password_representation "$JBOSS_PASSWORD_EXPECTED"); 値(shell %q)=${escaped_value}"
    fi
  else
    record_jboss_password_diagnostic INFO \
      "パスワード推移[1/5] DRY-RUN のため実値取得・文字列照合を行いません (取得元=${JBOSS_PASSWORD_SOURCE})。"
  fi
  export "${JBOSS_PASSWORD_ENV}=${password}"
  exported_value="${!JBOSS_PASSWORD_ENV:-}"
  if [ "$DRY_RUN" != "true" ] && [ "$exported_value" != "$JBOSS_PASSWORD_EXPECTED" ]; then
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[2/5] 取得元と環境変数 ${JBOSS_PASSWORD_ENV} の完全一致照合に失敗しました。"
    exit 1
  fi
  record_jboss_password_diagnostic INFO \
    "パスワード推移[2/5] 取得元から環境変数 ${JBOSS_PASSWORD_ENV} への設定は完全一致です。"
  log "JBoss マスターパスワードを環境変数 ${JBOSS_PASSWORD_ENV} 経由で BuildKit シークレットとして注入します。"
  log "  (compose.yml の secrets で environment: ${JBOSS_PASSWORD_ENV} を定義しておくこと)"
}

# Compose の正規化済み設定を使い、入力元の環境変数名と build secret の source を
# ビルド開始前に照合する。値そのものは Compose 設定へ展開されず、ログにも出さない。
verify_jboss_compose_secret_mapping() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local config_file config_error_file configured_env="" matching_secret_id=""
  local config_error_line dockerfile
  local active_mount_count=0
  local -a dockerfiles=()
  if [ "$DRY_RUN" = "true" ]; then
    JBOSS_PASSWORD_COMPOSE_STATUS="DRY-RUN のため未確認"
    JBOSS_PASSWORD_DOCKERFILE_STATUS="DRY-RUN のため未確認"
    record_jboss_password_diagnostic INFO \
      "パスワード推移[3/5] DRY-RUN のため Compose secret の environment/source 照合を行いません。"
    return 0
  fi
  if ! config_file="$(create_jboss_secure_temp_file compose-config)" \
      || ! config_error_file="$(create_jboss_secure_temp_file compose-config-error)"; then
    return 1
  fi
  if ! "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" config >"$config_file" 2>"$config_error_file"; then
    JBOSS_PASSWORD_COMPOSE_STATUS="Compose 設定の正規化に失敗"
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[3/5] Compose 設定を正規化できず、secret の対応関係を確認できませんでした。"
    while IFS= read -r config_error_line; do
      record_jboss_password_diagnostic DETAIL "  compose config: ${config_error_line}"
    done < <(redact_jboss_password_stream < "$config_error_file")
    rm -f -- "$config_file" "$config_error_file"
    return 1
  fi

  configured_env="$(awk -v secret="$JBOSS_SECRET_ID" '
    index($0, "  " secret ":") == 1 {
      in_target_secret = 1
      next
    }
    in_target_secret && /^  [^ ]/ {
      exit
    }
    in_target_secret && /^[[:space:]]+environment:[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]+environment:[[:space:]]+/, "", line)
      print line
      exit
    }
  ' "$config_file")"
  configured_env="${configured_env%$'\r'}"
  configured_env="${configured_env#\"}"
  configured_env="${configured_env%\"}"
  configured_env="${configured_env#\'}"
  configured_env="${configured_env%\'}"

  # compose 版には secret id の CLI オプションがないため、既定 id だけに固定せず、
  # 正規化済み secrets セクションから environment が一致する id を逆引きする。
  matching_secret_id="$(awk -v expected="$JBOSS_PASSWORD_ENV" '
    /^secrets:[[:space:]]*$/ {
      in_secrets = 1
      next
    }
    in_secrets && /^[^ ]/ {
      exit
    }
    in_secrets && /^  [^ ]/ {
      current = $0
      sub(/^  /, "", current)
      sub(/:[[:space:]]*$/, "", current)
      gsub(/^"|"$/, "", current)
      next
    }
    in_secrets && /^[[:space:]]+environment:[[:space:]]+/ {
      value = $0
      sub(/^[[:space:]]+environment:[[:space:]]+/, "", value)
      gsub(/^"|"$/, "", value)
      if (value == expected) {
        print current
        exit
      }
    }
  ' "$config_file")"
  matching_secret_id="${matching_secret_id%$'\r'}"

  if [ -z "$matching_secret_id" ] && [ -z "$configured_env" ]; then
    JBOSS_PASSWORD_COMPOSE_STATUS="environment=${JBOSS_PASSWORD_ENV} を参照する build secret が未定義"
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[3/5] Compose に environment=${JBOSS_PASSWORD_ENV} を参照する secret が定義されていません。"
    rm -f -- "$config_file" "$config_error_file"
    return 1
  fi
  if [ -z "$matching_secret_id" ]; then
    JBOSS_PASSWORD_COMPOSE_STATUS="不一致 (入力=${JBOSS_PASSWORD_ENV}, Compose=${configured_env})"
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[3/5] 環境変数名が不一致です: 入力・export 先=${JBOSS_PASSWORD_ENV}, Compose secret '${JBOSS_SECRET_ID}' の参照先=${configured_env}。"
    record_jboss_password_diagnostic ERROR \
      "この状態では Compose が別のパスワード設定を読むため、JBoss CLI へ渡る値との照合前に経路が分岐します。"
    rm -f -- "$config_file" "$config_error_file"
    return 1
  fi
  JBOSS_SECRET_ID="$matching_secret_id"
  if ! awk -v secret="$JBOSS_SECRET_ID" '
      $1 == "-" && $2 == "source:" {
        source = $3
        gsub(/^"|"$/, "", source)
        if (source == secret) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    ' "$config_file"; then
    JBOSS_PASSWORD_COMPOSE_STATUS="environment は一致したが build.secrets の source が未接続"
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[3/5] Compose secret '${JBOSS_SECRET_ID}' は定義されていますが、サービスの build.secrets から参照されていません。"
    rm -f -- "$config_file" "$config_error_file"
    return 1
  fi
  rm -f -- "$config_file" "$config_error_file"
  JBOSS_PASSWORD_COMPOSE_STATUS="完全一致 (${JBOSS_PASSWORD_ENV} -> ${JBOSS_SECRET_ID})"
  record_jboss_password_diagnostic INFO \
    "パスワード推移[3/5] Compose の environment=${JBOSS_PASSWORD_ENV} と build secret source=${JBOSS_SECRET_ID} の対応は一致しています。"

  mapfile -t dockerfiles < <(compose_dockerfiles)
  for dockerfile in "${dockerfiles[@]}"; do
    [ -f "$dockerfile" ] || continue
    if awk '
        /^[[:space:]]*#/ { next }
        { print }
      ' "$dockerfile" \
        | grep -Eq -- "(id[[:space:]]*=[[:space:]]*${JBOSS_SECRET_ID}|/run/secrets/${JBOSS_SECRET_ID}([^A-Za-z0-9_]|$))"; then
      active_mount_count=$((active_mount_count + 1))
    fi
  done
  if [ "$active_mount_count" -gt 0 ]; then
    JBOSS_PASSWORD_DOCKERFILE_STATUS="有効な secret mount/read を ${active_mount_count} Dockerfile で検出"
    record_jboss_password_diagnostic INFO \
      "パスワード推移[4/5] Dockerfile の有効行で secret id=${JBOSS_SECRET_ID} の mount/read を検出しました (${active_mount_count} ファイル)。"
    record_jboss_password_diagnostic INFO \
      "BuildKit へ渡る元値は推移[2/5]の環境変数と同一です。mount 内の再展開結果は平文を出さず、推移[5/5]の standalone.xml で照合します。"
  else
    JBOSS_PASSWORD_DOCKERFILE_STATUS="有効な secret mount/read を未検出"
    record_jboss_password_diagnostic WARN \
      "パスワード推移[4/5] Compose は secret を提供しますが、Dockerfile の有効行に id=${JBOSS_SECRET_ID} の mount/read を検出できませんでした。"
    record_jboss_password_diagnostic WARN \
      "コメント行だけの例示、外部スクリプト内での参照、または未使用の可能性があります。"
  fi
  return 0
}

find_jboss_diagnostic_python() {
  local candidate
  for candidate in python3 python /usr/libexec/platform-python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
          >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

cleanup_jboss_xml_temp_artifacts() {
  if [ -n "$JBOSS_DIAGNOSTIC_TMP_DIR" ] && [ -d "$JBOSS_DIAGNOSTIC_TMP_DIR" ]; then
    rm -f -- \
      "$JBOSS_DIAGNOSTIC_TMP_DIR/standalone.xml" \
      "$JBOSS_DIAGNOSTIC_TMP_DIR/parser.out"
    if ! rmdir -- "$JBOSS_DIAGNOSTIC_TMP_DIR" 2>/dev/null; then
      warn "JBoss XML 診断用一時ディレクトリを削除できませんでした: $JBOSS_DIAGNOSTIC_TMP_DIR"
    fi
  fi
  JBOSS_DIAGNOSTIC_TMP_DIR=""
}

cleanup_jboss_password_diagnostics() {
  local temp_file
  if [ -n "$JBOSS_DIAGNOSTIC_CONTAINER_ID" ]; then
    docker rm -f "$JBOSS_DIAGNOSTIC_CONTAINER_ID" >/dev/null 2>&1 || true
    JBOSS_DIAGNOSTIC_CONTAINER_ID=""
  fi
  cleanup_jboss_xml_temp_artifacts
  for temp_file in "${JBOSS_BUILD_LOG_FILES[@]}"; do
    [ -n "$temp_file" ] && rm -f -- "$temp_file"
  done
  JBOSS_BUILD_LOG_FILES=()
  [ -n "$JBOSS_PASSWORD_EXPECTED_FILE" ] && rm -f -- "$JBOSS_PASSWORD_EXPECTED_FILE"
  [ -n "$JBOSS_PASSWORD_REDACTION_FILE" ] && rm -f -- "$JBOSS_PASSWORD_REDACTION_FILE"
  JBOSS_PASSWORD_EXPECTED_FILE=""
  JBOSS_PASSWORD_REDACTION_FILE=""
}

# 最終イメージを起動せず docker create/docker cp だけで standalone.xml を取得する。
# ElementTree に XML エンティティを復元させた後、credential-store の clear-text と
# 入力値をバイト単位で比較する。既定では値を出さず、明示指定時だけ不一致値を出す。
verify_jboss_standalone_password() {
  local image="$1" python_command image_env home candidate found_path=""
  local xml_file parser_output parser_status parser_level parser_line old_umask create_status
  local -a candidate_paths=(
    "/opt/eap/standalone/configuration/standalone.xml"
    "/opt/jboss-eap/standalone/configuration/standalone.xml"
    "/opt/jboss/wildfly/standalone/configuration/standalone.xml"
    "/opt/wildfly/standalone/configuration/standalone.xml"
  )
  local -a checked_candidates=()
  local checked_candidate duplicate_candidate
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    JBOSS_PASSWORD_XML_STATUS="DRY-RUN のため未確認"
    record_jboss_password_diagnostic INFO \
      "パスワード推移[5/5] DRY-RUN のため standalone.xml の照合を行いません。"
    return 0
  fi
  image_env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" 2>/dev/null || true)"
  while IFS= read -r candidate; do
    case "$candidate" in
      EAP_HOME=*|JBOSS_HOME=*|JBOSS_EAP_HOME=*|WILDFLY_HOME=*)
        home="${candidate#*=}"
        home="${home%/}"
        if printf '%s' "$home" | grep -Eq '^/[A-Za-z0-9._/-]+$' \
            && [[ "/${home#/}/" != *"/../"* ]]; then
          candidate_paths+=("${home}/standalone/configuration/standalone.xml")
        fi
        ;;
    esac
  done <<< "$image_env"

  old_umask="$(umask)"
  umask 077
  JBOSS_DIAGNOSTIC_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-and-verify-jboss-xml.XXXXXX" 2>/dev/null)"
  create_status=$?
  umask "$old_umask"
  if [ "$create_status" -ne 0 ] || [ -z "$JBOSS_DIAGNOSTIC_TMP_DIR" ]; then
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[5/5] standalone.xml 取得用の一時ディレクトリを作成できませんでした。"
    return 1
  fi
  xml_file="${JBOSS_DIAGNOSTIC_TMP_DIR}/standalone.xml"
  parser_output="${JBOSS_DIAGNOSTIC_TMP_DIR}/parser.out"

  if ! JBOSS_DIAGNOSTIC_CONTAINER_ID="$(docker create "$image" 2>/dev/null)"; then
    JBOSS_PASSWORD_XML_STATUS="診断用コンテナを作成できず未確認"
    record_jboss_password_diagnostic WARN \
      "パスワード推移[5/5] 最終イメージから standalone.xml を読むための停止コンテナを作成できませんでした: ${image}"
    cleanup_jboss_xml_temp_artifacts
    return 0
  fi
  for candidate in "${candidate_paths[@]}"; do
    duplicate_candidate="false"
    for checked_candidate in "${checked_candidates[@]}"; do
      if [ "$checked_candidate" = "$candidate" ]; then
        duplicate_candidate="true"
        break
      fi
    done
    [ "$duplicate_candidate" = "true" ] && continue
    checked_candidates+=("$candidate")
    rm -f -- "$xml_file"
    if docker cp "${JBOSS_DIAGNOSTIC_CONTAINER_ID}:${candidate}" "$xml_file" \
        >/dev/null 2>&1 && [ -s "$xml_file" ]; then
      found_path="$candidate"
      break
    fi
  done
  if docker rm -f "$JBOSS_DIAGNOSTIC_CONTAINER_ID" >/dev/null 2>&1; then
    JBOSS_DIAGNOSTIC_CONTAINER_ID=""
  fi
  if [ -z "$found_path" ]; then
    JBOSS_PASSWORD_XML_STATUS="standalone.xml が最終イメージに見つからず未確認"
    record_jboss_password_diagnostic WARN \
      "パスワード推移[5/5] 最終イメージ ${image} の標準 EAP_HOME 候補に standalone.xml はありませんでした。"
    record_jboss_password_diagnostic WARN \
      "このサンプルのような非 JBoss イメージ、別パス、またはビルド途中でのみ CLI を実行する構成では直接照合できません。"
    cleanup_jboss_xml_temp_artifacts
    return 0
  fi

  if ! python_command="$(find_jboss_diagnostic_python)"; then
    JBOSS_PASSWORD_XML_STATUS="Python 3 がなく standalone.xml を照合不能 (${found_path})"
    record_jboss_password_diagnostic ERROR \
      "パスワード推移[5/5] standalone.xml は見つかりましたが、Python 3 がないため XML エンティティ復元後の完全一致照合を実行できません。"
    cleanup_jboss_xml_temp_artifacts
    return 1
  fi

  "$python_command" - "$xml_file" "$JBOSS_PASSWORD_EXPECTED_FILE" "$JBOSS_PASSWORD_ENV" \
      "$JBOSS_PASSWORD_SOURCE" "$JBOSS_PASSWORD_SHOW_VALUES" \
      >"$parser_output" 2>&1 <<'PY'
import hmac
import json
import re
import sys
import xml.etree.ElementTree as ET

xml_path, expected_path, expected_env, expected_source, show_values_text = sys.argv[1:6]
show_values = show_values_text == "true"

def local_name(tag):
    return tag.rsplit("}", 1)[-1]

def label(value):
    return json.dumps(str(value), ensure_ascii=False)

def representation(value):
    if value.startswith("MASK-"):
        return "JBoss/WildFly MASK- 保護値（平文ではない）"
    if value.startswith("${") and value.endswith("}"):
        return "式参照（実値ではない）"
    if re.match(r"^\$2[aby]\$", value):
        return "ハッシュ形式候補（bcrypt）"
    if re.match(r"^\$argon2(?:i|d|id)\$", value):
        return "ハッシュ形式候補（Argon2）"
    if re.match(r"^\$(?:pbkdf2-[^$]+|scrypt)\$", value):
        return "ハッシュ形式候補（PBKDF2 / scrypt）"
    if value.startswith("$1$"):
        return "ハッシュ形式候補（md5-crypt）"
    if value.startswith("$5$"):
        return "ハッシュ形式候補（sha256-crypt）"
    if value.startswith("$6$"):
        return "ハッシュ形式候補（sha512-crypt）"
    if re.match(r"^\{(?:S?SHA|S?MD5|PBKDF2)\}", value, re.IGNORECASE):
        return "ハッシュ形式候補（LDAP 接頭辞形式）"
    digest_names = {
        32: "MD5 相当の32桁16進",
        40: "SHA-1 相当の40桁16進",
        56: "SHA-224 相当の56桁16進",
        64: "SHA-256 相当の64桁16進",
        96: "SHA-384 相当の96桁16進",
        128: "SHA-512 相当の128桁16進",
    }
    if re.fullmatch(r"[0-9A-Fa-f]+", value) and len(value) in digest_names:
        return f"ハッシュ形式候補（{digest_names[len(value)]}）"
    return "平文候補（既知のハッシュ・保護値形式には非該当）"

def profile(value):
    special = [
        ("$", "ドル記号($)"),
        ("#", "番号記号(#)"),
        ("!", "感嘆符(!)"),
        ('"', '二重引用符(")'),
        ("`", "バッククォート(`)"),
    ]
    details = ", ".join(
        f"{description}:{value.count(character)}"
        for character, description in special
        if character in value
    ) or "なし"
    return (
        f"表現種別={representation(value)}, 文字数={len(value)}, "
        f"UTF-8バイト数={len(value.encode('utf-8'))}, "
        f"対象特殊文字={{{details}}}"
    )

try:
    with open(expected_path, "rb") as expected_file:
        expected = expected_file.read()
    root = ET.parse(xml_path).getroot()
except Exception as exc:
    print(f"XML解析エラー: {type(exc).__name__}: {exc}")
    raise SystemExit(23)

try:
    expected_text = expected.decode("utf-8")
except UnicodeDecodeError:
    expected_text = None

expected_representation = (
    representation(expected_text)
    if expected_text is not None
    else "非UTF-8バイト列（XMLのUTF-8文字列とは一致不能）"
)

stores = [element for element in root.iter() if local_name(element.tag) == "credential-store"]
if not stores:
    print("Elytron credential-store 要素はありません。")
    raise SystemExit(22)

literal_count = 0
match_count = 0
indirect_count = 0
mismatches = []
for store in stores:
    name = store.attrib.get("name", "(name なし)")
    path = store.attrib.get("path", "(path なし)")
    references = [
        element for element in store.iter()
        if element is not store and local_name(element.tag) == "credential-reference"
    ]
    if not references:
        print(
            f"credential-store name={label(name)}, path={label(path)}: "
            "credential-reference がなく直接照合不能"
        )
        indirect_count += 1
        continue
    for reference in references:
        clear_text = reference.attrib.get("clear-text")
        if clear_text is None:
            store_name = reference.attrib.get("store", "(なし)")
            alias = reference.attrib.get("alias", "(なし)")
            print(
                f"credential-store name={label(name)}, path={label(path)}: "
                f"間接参照 (store={label(store_name)}, alias={label(alias)}) のため直接照合不能"
            )
            indirect_count += 1
            continue
        env_expression = re.fullmatch(
            r"\$\{env\.([A-Za-z_][A-Za-z0-9_]*)(?::.*)?\}", clear_text
        )
        if env_expression:
            actual_env = env_expression.group(1)
            relation = "一致" if actual_env == expected_env else "不一致"
            print(
                f"credential-store name={label(name)}, path={label(path)}: "
                f"環境変数式参照 env={label(actual_env)} (入力経路={label(expected_env)}; "
                f"変数名照合={relation})。実値は最終 XML だけでは直接照合不能; "
                f"XML側 表現種別={representation(clear_text)}"
            )
            if show_values:
                print(
                    f"standalone.xml側直接照合不能文字列: credential-store "
                    f"name={label(name)}, path={label(path)}; "
                    f"値(JSON)={label(clear_text)}"
                )
            indirect_count += 1
            continue
        if clear_text.startswith("MASK-") or (
            clear_text.startswith("${") and clear_text.endswith("}")
        ):
            print(
                f"credential-store name={label(name)}, path={label(path)}: "
                "保護値または式参照のため直接照合不能; "
                f"XML側 表現種別={representation(clear_text)}"
            )
            if show_values:
                print(
                    f"standalone.xml側直接照合不能文字列: credential-store "
                    f"name={label(name)}, path={label(path)}; "
                    f"値(JSON)={label(clear_text)}"
                )
            indirect_count += 1
            continue

        literal_count += 1
        actual = clear_text.encode("utf-8")
        matched = hmac.compare_digest(actual, expected)
        if matched:
            match_count += 1
        else:
            mismatches.append((name, path, clear_text))
        result = "完全一致" if matched else "不一致"
        print(
            f"credential-store name={label(name)}, path={label(path)}: "
            f"literal clear-text の照合結果={result}; "
            f"入力側 表現種別={expected_representation}; XML側 {profile(clear_text)}"
        )

if show_values and mismatches:
    print("--show-jboss-password-values による不一致実値比較（秘密情報）:")
    if expected_text is None:
        expected_display = f"値(hex)={expected.hex()}"
    else:
        expected_display = f"値(JSON)={label(expected_text)}"
    print(
        f"入力側設定値: 取得元={label(expected_source)}; "
        f"表現種別={expected_representation}; {expected_display}"
    )
    for index, (name, path, clear_text) in enumerate(mismatches, start=1):
        print(
            f"standalone.xml側不一致文字列[{index}]: credential-store "
            f"name={label(name)}, path={label(path)}; "
            'XML属性="credential-reference@clear-text"; '
            f"表現種別={representation(clear_text)}; 値(JSON)={label(clear_text)}"
        )

print(
    f"credential-store 集計: stores={len(stores)}, literal={literal_count}, "
    f"match={match_count}, mismatch={len(mismatches)}, indirect={indirect_count}"
)
if match_count:
    raise SystemExit(0)
if literal_count:
    raise SystemExit(20)
raise SystemExit(21)
PY
  parser_status=$?
  while IFS= read -r parser_line; do
    case "$parser_status:$parser_line" in
      *:*--show-jboss-password-values*|*:*入力側設定値:*|*:*standalone.xml側不一致文字列*|*:*standalone.xml側直接照合不能文字列*)
        parser_level="DETAIL"
        ;;
      20:*|23:*) parser_level="ERROR" ;;
      *:*照合結果=不一致*|*:*変数名照合=不一致*|*:*直接照合不能*)
        parser_level="WARN"
        ;;
      0:*) parser_level="INFO" ;;
      *) parser_level="WARN" ;;
    esac
    record_jboss_password_diagnostic "$parser_level" "  ${parser_line}"
  done < <(
    if [ "$JBOSS_PASSWORD_SHOW_VALUES" = "true" ]; then
      cat "$parser_output"
    else
      redact_jboss_password_stream < "$parser_output"
    fi
  )

  case "$parser_status" in
    0)
      JBOSS_PASSWORD_XML_STATUS="standalone.xml の literal clear-text と完全一致 (${found_path})"
      record_jboss_password_diagnostic INFO \
        "パスワード推移[5/5] JBoss CLI が standalone.xml に生成した credential-store のうち、少なくとも1件の literal clear-text は入力値と完全一致しています: ${found_path}"
      cleanup_jboss_xml_temp_artifacts
      return 0
      ;;
    20)
      JBOSS_PASSWORD_XML_STATUS="standalone.xml の literal clear-text と不一致 (${found_path})"
      record_jboss_password_diagnostic ERROR \
        "パスワード推移[5/5] standalone.xml 側の credential-store マスターパスワードと入力値が一致しません: ${found_path}"
      record_jboss_password_diagnostic ERROR \
        "不一致箇所は、推移[4/5]の BuildKit secret 以降から JBoss CLI の引用・エスケープを経て XML に保存されるまでの区間です。"
      if [ "$JBOSS_PASSWORD_SHOW_VALUES" != "true" ]; then
        record_jboss_password_diagnostic INFO \
          "双方の実値が必要な場合は、出力を安全に管理できる隔離環境で --show-jboss-password-values を付けて再実行してください。"
      fi
      cleanup_jboss_xml_temp_artifacts
      return 1
      ;;
    21)
      JBOSS_PASSWORD_XML_STATUS="credential-reference が式/間接参照のため実値照合不能 (${found_path})"
      record_jboss_password_diagnostic WARN \
        "パスワード推移[5/5] standalone.xml は生成されていますが、credential-reference が式または間接参照のため実値を直接照合できません。"
      if [ "$JBOSS_PASSWORD_SHOW_VALUES" != "true" ]; then
        record_jboss_password_diagnostic INFO \
          "XML に記録された文字列が必要な場合は、出力を安全に管理できる隔離環境で --show-jboss-password-values を付けて再実行してください。"
      fi
      cleanup_jboss_xml_temp_artifacts
      return 0
      ;;
    22)
      JBOSS_PASSWORD_XML_STATUS="credential-store 要素がなく照合対象なし (${found_path})"
      record_jboss_password_diagnostic WARN \
        "パスワード推移[5/5] standalone.xml に Elytron credential-store 要素がないため、照合対象がありません。"
      cleanup_jboss_xml_temp_artifacts
      return 0
      ;;
    *)
      JBOSS_PASSWORD_XML_STATUS="standalone.xml の解析に失敗 (${found_path})"
      record_jboss_password_diagnostic ERROR \
        "パスワード推移[5/5] standalone.xml を安全に解析できず、設定値を確認できませんでした。"
      cleanup_jboss_xml_temp_artifacts
      return 1
      ;;
  esac
}

# ---- ビルド前後の一時ファイルコピー / 自動削除 ------------------------------
# --copy-file で指定した SRC:DEST_DIR を検証し、SRC を DEST_DIR へコピーする。
# コピーしたコピー先パスは COPIED_FILES に記録し、EXIT トラップで自動削除する。
prepare_copy_files() {
  [ ${#COPY_SPECS[@]} -eq 0 ] && return 0
  log "ビルド前の一時ファイルコピーを実行します (${#COPY_SPECS[@]} 件) ..."
  local spec src dest_dir dest
  for spec in "${COPY_SPECS[@]}"; do
    # 最初の ':' で SRC と DEST_DIR に分割する (':' が無ければ書式エラー)
    if [ "${spec%%:*}" = "$spec" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC:DEST_DIR 形式で指定してください)"
      exit 2
    fi
    src="${spec%%:*}"
    dest_dir="${spec#*:}"
    if [ -z "$src" ] || [ -z "$dest_dir" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC / DEST_DIR が空です)"
      exit 2
    fi
    if [ ! -f "$src" ]; then
      err "コピー元ファイルが見つかりません: $src"
      exit 1
    fi
    if [ ! -d "$dest_dir" ]; then
      err "コピー先ディレクトリが存在しません: $dest_dir"
      exit 1
    fi
    dest="${dest_dir%/}/$(basename "$src")"
    # 既存ファイルを上書き→後で削除すると元ファイルを消してしまうため中止する
    if [ -e "$dest" ]; then
      err "コピー先に同名ファイルが既に存在します: $dest (自動削除による事故防止のため中止します)"
      exit 1
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] cp $src -> $dest (処理後に自動削除)"
    else
      if ! cp "$src" "$dest"; then
        err "ファイルのコピーに失敗しました: $src -> $dest"
        exit 1
      fi
      log "コピーしました: $src -> $dest"
    fi
    # dry-run でも記録し、削除プレビューを表示できるようにする
    COPIED_FILES+=("$dest")
  done
}

# コピーしたファイルのみ削除する (EXIT トラップから呼び出す)。
cleanup_copied_files() {
  [ ${#COPIED_FILES[@]} -eq 0 ] && return 0
  log "コピーした一時ファイルを削除します (${#COPIED_FILES[@]} 件) ..."
  local f
  for f in "${COPIED_FILES[@]}"; do
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] rm -f $f"
    elif rm -f "$f"; then
      log "削除しました: $f"
    else
      warn "一時ファイルの削除に失敗しました: $f (手動で削除してください)"
    fi
  done
  COPIED_FILES=()
}

# ---- 起動確認 / URL 確認 用ヘルパ -------------------------------------------
STARTED_CONTAINER="false"          # コンテナを起動したか (teardown 判定用)
# compose up を実行したか。up に失敗してもコンテナは作られているため、今回の実行が
# 触れたコンテナかどうかの判定にはこちらを使う (終了ログ取得の対象判定)。
COMPOSE_UP_ATTEMPTED="false"
CONTAINER_LOG_SINCE=""             # 今回の起動より前のコンテナログを除外する基準時刻

# 対象コンテナの ID を取得する (引数でサービスを指定、未指定なら対象サービス全体)。
# ps -q は実行中のコンテナのみを返す。
compose_container_ids() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>/dev/null
  fi
}

# 停止済みを含む対象コンテナの ID を取得する。異常終了の検知には ps -q ではなく
# こちらを使う (ps -q は終了したコンテナを返さないため、消えた = 正常と誤判定する)。
compose_container_ids_all() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -aq "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -aq ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>/dev/null
  fi
}

# 環境変数一覧とディレクトリツリーで共通して使う対象コンテナ ID を取得する。
# 起動確認サービスが明示されている場合はその対象を優先し、それ以外はビルド・起動
# 対象の Compose サービス (未指定なら全サービス) を対象とする。
verification_target_container_ids() {
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${STARTUP_SERVICES[@]}"
  elif [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${COMPOSE_TARGET_SERVICES[@]}"
  else
    compose_container_ids
  fi
}

# ログを取得する (スナップショット)。引数でサービスを指定、未指定なら対象サービス全体。
compose_logs() {
  local -a log_args=(-f "$COMPOSE_FILE" logs --no-color)
  if [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_args+=(--since "$CONTAINER_LOG_SINCE")
  fi
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" "${log_args[@]}" "$@" 2>&1
  else
    "${COMPOSE_CMD[@]}" "${log_args[@]}" ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>&1
  fi
}

# JBoss のコンソールカラーは compose logs --no-color では除去されないため、
# EAP のメッセージ解析前に ANSI SGR シーケンスを取り除く。
strip_ansi_codes() {
  LC_ALL=C sed $'s/\033\[[0-9;]*m//g'
}

# ログ文字列の行数を数える。空文字列は「1 行 (空行)」ではなく 0 行として扱う。
count_log_lines() {
  local logs="$1"
  if [ -z "$logs" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$logs" | awk 'END { print NR }'
}

# 端末への直接表示時だけ色を付ける。NO_COLOR を優先し、リダイレクトされたログへ
# ANSI シーケンスを混入させない。CLICOLOR_FORCE はテストや明示的な強制表示に使える。
startup_log_color_enabled() {
  [ -z "${NO_COLOR+x}" ] || return 1
  case "${CLICOLOR_FORCE:-0}" in
    0) ;;
    *) return 0 ;;
  esac
  [ -t 2 ] && [ "${TERM:-}" != "dumb" ]
}

# JBoss EAP の重要行を意味別に色分けし、その他の行はそのまま表示する。
print_startup_logs_with_highlights() {
  local logs="$1" line color
  local use_color="false"
  local error_level_pattern='[[:space:]](ERROR|FATAL)[[:space:]]'
  local warning_level_pattern='[[:space:]]WARN(ING)?[[:space:]]'
  local color_red=$'\033[1;31m' color_yellow=$'\033[1;33m'
  local color_green=$'\033[1;32m' color_cyan=$'\033[1;36m' color_reset=$'\033[0m'

  startup_log_color_enabled && use_color="true"
  while IFS= read -r line || [ -n "$line" ]; do
    color=""
    if [ "$use_color" = "true" ]; then
      if [[ "$line" =~ $error_level_pattern ]] || [[ "$line" =~ $STARTUP_FAILURE_LOG_PATTERN ]]; then
        color="$color_red"
      elif [[ "$line" =~ $warning_level_pattern ]]; then
        color="$color_yellow"
      elif [[ "$line" =~ $STARTUP_SUCCESS_LOG_PATTERN ]] || [[ "$line" =~ $STARTUP_LOG_PATTERN ]]; then
        color="$color_green"
      elif [[ "$line" =~ $STARTUP_IMPORTANT_LOG_PATTERN ]]; then
        color="$color_cyan"
      fi
    fi
    if [ -n "$color" ]; then
      printf '%s%s%s\n' "$color" "$line" "$color_reset" >&2
    else
      printf '%s\n' "$line" >&2
    fi
  done <<< "$logs"
}

show_startup_logs() {
  local logs="$1" target_desc="$2" allow_suppression="${3:-true}"
  local log_title="${4:-コンテナ起動ログ}"
  local selected normalized_logs total_count shown_count display_range

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    log "コンテナ起動ログの表示を抑制しました (--suppress-startup-logs)。"
    return 0
  fi

  normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
  if [ -n "$normalized_logs" ]; then
    total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
  else
    total_count=0
  fi

  if [ "$STARTUP_LOG_LINES" = "all" ]; then
    selected="$normalized_logs"
    shown_count="$total_count"
    display_range="全 ${total_count} 行"
  else
    selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
    if [ -n "$selected" ]; then
      shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
    else
      shown_count=0
    fi
    display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
  fi

  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "${log_title} (${target_desc}, ${display_range}):"
  diag "───────────────────────────────────────────────────────────────────"
  if [ -n "$selected" ]; then
    if startup_log_color_enabled; then
      printf '色分け: \033[1;32m成功\033[0m / \033[1;36m重要\033[0m / \033[1;33m警告\033[0m / \033[1;31mエラー\033[0m\n' >&2
    fi
    print_startup_logs_with_highlights "$selected"
  else
    diag "表示対象のコンテナ起動ログはありません。"
  fi
  diag "───────────────────────────────────────────────────────────────────"
}

# 現在起動している Compose サービス名を、Compose が返す順序を保って列挙する。
# ps --services を利用できない旧実装では、明示された起動対象またはコンテナラベルへ
# フォールバックする。
compose_started_services() {
  local services cid service_name
  services="$("${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps --services 2>/dev/null || true)"
  if [ -n "$services" ]; then
    printf '%s\n' "$services" | awk 'NF && !seen[$0]++'
    return 0
  fi
  if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    printf '%s\n' "${COMPOSE_TARGET_SERVICES[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] && printf '%s\n' "$service_name"
  done < <(compose_container_ids) | awk 'NF && !seen[$0]++'
}

# 起動確認対象以外で、同じ compose up により現在起動しているサービスのログを、
# 起動確認ログと同じ行数設定でサービス単位に順次表示する。
show_companion_service_logs() {
  local allow_suppression="${1:-true}"
  local svc logs normalized_logs selected total_count shown_count display_range
  local -a started_services=()
  local -A verification_services=()

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    return 0
  fi

  mapfile -t started_services < <(compose_started_services)
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    for svc in "${STARTUP_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  elif [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    for svc in "${COMPOSE_TARGET_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  else
    # 起動対象を限定していない場合、起動確認ログには全サービスが含まれている。
    for svc in "${started_services[@]}"; do
      verification_services["$svc"]=1
    done
  fi

  for svc in "${started_services[@]}"; do
    [ -n "$svc" ] || continue
    [ -z "${verification_services[$svc]+_}" ] || continue
    logs="$(compose_logs "$svc")"
    normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
    if [ -n "$normalized_logs" ]; then
      total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
    else
      total_count=0
    fi
    if [ "$STARTUP_LOG_LINES" = "all" ]; then
      selected="$normalized_logs"
      shown_count="$total_count"
      display_range="全 ${total_count} 行"
    else
      selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
      if [ -n "$selected" ]; then
        shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
      else
        shown_count=0
      fi
      display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
    fi

    diag ""
    diag "───────────────────────────────────────────────────────────────────"
    diag "同時起動 Compose サービスログ (サービス: ${svc}, ${display_range}):"
    diag "───────────────────────────────────────────────────────────────────"
    if [ -n "$selected" ]; then
      printf '%s\n' "$selected" >&2
    else
      diag "表示対象のサービスログはありません。"
    fi
    diag "───────────────────────────────────────────────────────────────────"
  done
}

# compose.yml に定義された全サービスと、停止済みを含むコンテナを持つ全サービスを
# 重複なく列挙する。失敗レポートへログを書き出す対象を決めるために使うので、
# 起動確認対象かどうか、サイドカー (adot collector 等) かどうかで絞り込まない。
# 定義順を優先し、profiles などで定義側に現れないサービスは ps の結果で補う。
compose_all_service_names() {
  {
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" config --services 2>/dev/null || true
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -a --services 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

# レポートのサービス見出しへ添えるコンテナ名と状態を組み立てる。停止済みも対象に
# するため ps -aq を使い、サイドカーの異常終了をログ本文より先に示す。
compose_service_container_summary() {
  local service_name="$1" cid name state status exit_code entry summary=""
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    state="$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}' "$cid" 2>/dev/null || printf '|')"
    status="${state%%|*}"
    exit_code="${state##*|}"
    case "$status" in
      running) entry="${name} (状態: running)" ;;
      "")      entry="${name} (状態: 不明)" ;;
      *)       entry="${name} (状態: ${status}, 終了コード: ${exit_code:-不明})" ;;
    esac
    if [ -n "$summary" ]; then
      summary="${summary}, ${entry}"
    else
      summary="$entry"
    fi
  done < <(compose_container_ids_all "$service_name")
  [ -n "$summary" ] || summary="(コンテナなし)"
  printf '%s\n' "$summary"
}

normalize_container_name() {
  local name="$1"
  printf '%s\n' "${name#/}"
}

compose_file_dir() {
  local compose_dir
  compose_dir="$(cd "$(dirname "$COMPOSE_FILE")" 2>/dev/null && pwd -P)" || return 1
  printf '%s\n' "$compose_dir"
}

compose_dockerfiles() {
  local compose_dir dockerfile_path cleaned found="false"
  compose_dir="$(compose_file_dir)" || return 0
  while IFS= read -r dockerfile_path; do
    [ -n "$dockerfile_path" ] || continue
    cleaned="${dockerfile_path#\"}"
    cleaned="${cleaned%\"}"
    cleaned="${cleaned#\'}"
    cleaned="${cleaned%\'}"
    if [ "${cleaned#/}" = "$cleaned" ]; then
      cleaned="${compose_dir}/${cleaned}"
    fi
    printf '%s\n' "$cleaned"
    found="true"
  done < <(sed -n 's/^[[:space:]]*dockerfile:[[:space:]]*//p' "$COMPOSE_FILE")
  if [ "$found" != "true" ] && [ -f "${compose_dir}/Dockerfile" ]; then
    printf '%s\n' "${compose_dir}/Dockerfile"
  fi
}

collect_build_arg_env_names_from_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0
  local physical_line logical_line="" trimmed env_body key value arg_name
  local -a env_tokens=()
  local -a arg_names=()
  local -A arg_name_set=()
  local -A env_name_set=()

  while IFS= read -r physical_line || [ -n "$physical_line" ]; do
    if [ -n "$logical_line" ]; then
      logical_line="${logical_line}${physical_line}"
    else
      logical_line="$physical_line"
    fi
    if [[ "$logical_line" == *\\ ]]; then
      logical_line="${logical_line%\\} "
      continue
    fi

    trimmed="${logical_line#"${logical_line%%[![:space:]]*}"}"
    logical_line=""
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      \#*) continue ;;
    esac

    if [[ "$trimmed" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
      arg_name="${BASH_REMATCH[1]}"
      arg_name_set["$arg_name"]=1
      continue
    fi

    if [[ "$trimmed" =~ ^ENV[[:space:]]+(.+)$ ]]; then
      env_body="${BASH_REMATCH[1]}"
      env_tokens=()
      read -r -a env_tokens <<< "$env_body"
      if [ ${#env_tokens[@]} -ge 2 ] && [[ "${env_tokens[0]}" != *=* ]]; then
        key="${env_tokens[0]}"
        value="${env_tokens[1]}"
        for arg_name in "${!arg_name_set[@]}"; do
          case "$value" in
            *"\${${arg_name}}"*|*"\$${arg_name}"*)
              env_name_set["$key"]=1
              break
            ;;
          esac
        done
      fi
      for value in "${env_tokens[@]}"; do
        case "$value" in
          *=*)
            key="${value%%=*}"
            value="${value#*=}"
            for arg_name in "${!arg_name_set[@]}"; do
              case "$value" in
                *"\${${arg_name}}"*|*"\$${arg_name}"*)
                  env_name_set["$key"]=1
                  break
                ;;
              esac
            done
          ;;
        esac
      done
    fi
  done < "$dockerfile"

  for key in "${!env_name_set[@]}"; do
    printf '%s\n' "$key"
  done | sort
}

load_build_arg_env_name_set() {
  [ "$BUILD_ARG_ENV_NAMES_LOADED" = "true" ] && return 0
  local dockerfile env_name
  while IFS= read -r dockerfile; do
    [ -f "$dockerfile" ] || continue
    while IFS= read -r env_name; do
      [ -n "$env_name" ] || continue
      BUILD_ARG_ENV_NAME_SET["$env_name"]=1
    done < <(collect_build_arg_env_names_from_dockerfile "$dockerfile")
  done < <(compose_dockerfiles)
  BUILD_ARG_ENV_NAMES_LOADED="true"
}

collect_container_pid1_env() {
  local cid="$1"
  if docker exec "$cid" /bin/sh -lc "tr '\\0' '\\n' </proc/1/environ" 2>/dev/null; then
    return 0
  fi
  docker exec "$cid" env 2>/dev/null || true
}

collect_container_config_env() {
  local cid="$1"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null || true
}

collect_container_image_env() {
  local cid="$1" image_id
  image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" || return 0
  [ -n "$image_id" ] || return 0
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image_id" 2>/dev/null || true
}

# 画面表示と全量レポートへ認証情報を平文で残さないための判定。名前だけは分類・
# 設定漏れの確認に必要なため維持し、値の側を [REDACTED] へ置き換える。
# 環境変数名にも JVM パラメータ名 (-Dxxx.password 等) にも同じ規則を適用する。
# OTLP の *_HEADERS は認証ヘッダを載せる用途が多いため対象に含める。
is_sensitive_setting_name() {
  local upper="${1^^}"
  case "$upper" in
    *PASSWORD*|*PASSWD*|*TOKEN*|*SECRET*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*|*CREDENTIAL*|*HEADERS*)
      return 0
      ;;
  esac
  return 1
}

append_env_names_by_type() {
  local report_file="$1" type_label="$2"
  shift 2
  local -a names=("$@")
  printf '[%s] %s 件\n' "$type_label" "${#names[@]}" >> "$report_file"
  if [ ${#names[@]} -eq 0 ]; then
    printf '  (なし)\n' >> "$report_file"
    return 0
  fi
  printf '%s\n' "${names[@]}" | sed 's/^/  /' >> "$report_file"
}

append_container_env_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local env_limit="${5:-$ENV_LIST_LIMIT}"
  local line key value kv type_label shown_count total_count
  local -a sorted_names=()
  local -a compose_names=() build_arg_names=() internal_names=() other_names=()
  declare -A process_env_values=()
  declare -A container_env_values=()
  declare -A image_env_values=()
  declare -A compose_runtime_name_set=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    container_env_values["$key"]="$value"
  done < <(collect_container_config_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    image_env_values["$key"]="$value"
  done < <(collect_container_image_env "$cid")

  for key in "${!container_env_values[@]}"; do
    if [ -z "${image_env_values[$key]+_}" ] || [ "${container_env_values[$key]}" != "${image_env_values[$key]}" ]; then
      compose_runtime_name_set["$key"]=1
    fi
  done

  mapfile -t sorted_names < <(printf '%s\n' "${!process_env_values[@]}" | sort)
  total_count="${#sorted_names[@]}"
  shown_count="$total_count"
  if [ "$env_limit" != "all" ] && [ "$env_limit" -lt "$shown_count" ]; then
    shown_count="$env_limit"
  fi

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  printf '環境変数一覧 (サービス: %s, コンテナ: %s, 表示件数: %s/%s)\n' "$service_name" "$container_name" "$shown_count" "$total_count" >> "$report_file"
  printf '種別: compose.yml environment / build引数 / コンテナ内部処理 / イメージ既定・その他\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"

  shown_count=0
  for key in "${sorted_names[@]}"; do
    if [ "$env_limit" != "all" ] && [ "$shown_count" -ge "$env_limit" ]; then
      break
    fi
    value="${process_env_values[$key]}"
    if is_sensitive_setting_name "$key" || [ "$key" = "$JBOSS_PASSWORD_ENV" ]; then
      value="[REDACTED]"
    fi
    kv="${key}=${value}"
    if [ -z "${container_env_values[$key]+_}" ]; then
      internal_names+=("$kv")
    elif [ -n "${compose_runtime_name_set[$key]+_}" ]; then
      compose_names+=("$kv")
    elif [ -n "${BUILD_ARG_ENV_NAME_SET[$key]+_}" ]; then
      build_arg_names+=("$kv")
    else
      other_names+=("$kv")
    fi
    shown_count=$((shown_count + 1))
  done

  append_env_names_by_type "$report_file" "compose.yml environment" "${compose_names[@]}"
  append_env_names_by_type "$report_file" "build引数" "${build_arg_names[@]}"
  append_env_names_by_type "$report_file" "コンテナ内部処理" "${internal_names[@]}"
  append_env_names_by_type "$report_file" "イメージ既定・その他" "${other_names[@]}"
}

show_verified_container_envs() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] 動作確認成功後の環境変数一覧出力をプレビューします。"
    return 0
  }

  local report_file cid service_name container_name env_report_tmp
  local -a target_container_ids=()

  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "環境変数一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  load_build_arg_env_name_set
  env_report_tmp="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/env_report.$$")"
  : > "$env_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_env_report "$cid" "$service_name" "$container_name" "$env_report_tmp"
  done

  diag ""
  while IFS= read -r report_file; do
    diag "$report_file"
  done < "$env_report_tmp"

  if [ -n "$ENV_LIST_FILE" ]; then
    mkdir -p "$(dirname "$ENV_LIST_FILE")" 2>/dev/null || true
    if cp "$env_report_tmp" "$ENV_LIST_FILE" 2>/dev/null; then
      log "環境変数一覧をファイルへ出力しました: $ENV_LIST_FILE"
    else
      warn "環境変数一覧のファイル出力に失敗しました: $ENV_LIST_FILE"
    fi
  fi

  rm -f "$env_report_tmp"
}

# 1 コンテナ内の指定ルートを report_file へ追記する。コンテナ内に追加の
# スクリプトや tree コマンドを要求しないよう、find の NUL 区切り出力をホスト側の
# Bash で集計し、tree コマンドと同じ罫線記号で表示する。file_limit が none の
# 場合はディレクトリだけを取得する。
# それ以外は、直下のファイル数が file_limit 以下なら名前を、超える場合は
# 最終拡張子 (例: archive.tar.gz は .gz) ごとの件数を出力する。
append_container_directory_tree_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local root_path="${5:-/}" report_title="${6:-コンテナ内ディレクトリツリー}"
  local tree_depth="${7:-$DIRECTORY_TREE_DEPTH}" file_limit="${8:-$DIRECTORY_FILE_LIMIT}"
  local directory_list_tmp file_list_tmp directory_find_status=0 file_find_status=0
  local file_max_depth directory file_path parent filename suffix extension key count file_count
  local failure_message
  local display_name extension_list filename_list ancestor prefix connector is_last index
  local hidden_path hide_directory
  local -a directory_find_args=()
  local -a file_find_args=()
  local -a directory_paths=()
  local -a visible_directory_paths=()
  local -a ancestor_chain=()
  local -a leaf_entries=()
  local -A extension_counts=()
  local -A directory_extension_lists=()
  local -A directory_file_counts=()
  local -A directory_filename_lists=()
  local -A directory_child_counts=()
  local -A last_child_directory=()
  local -A directory_is_last=()

  # / 以外は末尾のスラッシュを除き、find の出力と親パスの比較を安定させる。
  if [ "$root_path" != "/" ]; then
    root_path="${root_path%/}"
  fi
  directory_find_args=(find "$root_path")
  if [ "$file_limit" != "none" ]; then
    file_find_args=(find "$root_path")
  fi

  if ! directory_list_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  if ! file_list_tmp="$(mktemp 2>/dev/null)"; then
    rm -f -- "$directory_list_tmp"
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi

  if [ "$tree_depth" != "all" ]; then
    directory_find_args+=(-maxdepth "$tree_depth")
    if [ "$file_limit" != "none" ]; then
      file_max_depth="$((10#$tree_depth + 1))"
      file_find_args+=(-maxdepth "$file_max_depth")
    fi
  fi

  # コンテナ全体のツリーでは、巨大な仮想ファイルシステム等を find 自体で枝刈り
  # する。対象ディレクトリは 1 ノードとして出力し、その配下だけを探索しない。
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    directory_find_args+=("(")
    if [ "$file_limit" != "none" ]; then
      file_find_args+=("(")
    fi
    for index in "${!DIRECTORY_TREE_PRUNE_PATHS[@]}"; do
      if [ "$index" -gt 0 ]; then
        directory_find_args+=(-o)
        if [ "$file_limit" != "none" ]; then
          file_find_args+=(-o)
        fi
      fi
      directory_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      if [ "$file_limit" != "none" ]; then
        file_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      fi
    done
    directory_find_args+=(")" -prune -print0 -o)
    if [ "$file_limit" != "none" ]; then
      file_find_args+=(")" -prune -o)
    fi
  fi
  directory_find_args+=(-type d -print0)
  if [ "$file_limit" != "none" ]; then
    file_find_args+=(-type f -print0)
  fi

  docker exec "$cid" "${directory_find_args[@]}" > "$directory_list_tmp" 2>/dev/null || directory_find_status=$?
  if [ "$file_limit" != "none" ]; then
    docker exec "$cid" "${file_find_args[@]}" > "$file_list_tmp" 2>/dev/null || file_find_status=$?
  fi

  if [ ! -s "$directory_list_tmp" ]; then
    failure_message="${report_title}を取得できませんでした (サービス: ${service_name}, コンテナ: ${container_name}, ルート: ${root_path})。コンテナ内のパスと find コマンドを確認してください。"
    printf '\n[WARN] %s\n' "$failure_message" >> "$report_file"
    rm -f -- "$directory_list_tmp" "$file_list_tmp"
    return 0
  fi

  while IFS= read -r -d '' file_path; do
    parent="${file_path%/*}"
    [ -n "$parent" ] || parent="/"
    filename="${file_path##*/}"
    extension="(拡張子なし)"
    if [ -z "${directory_file_counts[$parent]+_}" ]; then
      directory_file_counts["$parent"]=1
      directory_filename_lists["$parent"]="$filename"
    else
      file_count="${directory_file_counts[$parent]}"
      directory_file_counts["$parent"]=$((file_count + 1))
      directory_filename_lists["$parent"]+=$'\n'"$filename"
    fi

    # 先頭のドットだけを持つファイル (.env など) と末尾がドットのファイルは
    # 拡張子なしとして扱う。.env.local のように後続のドットがあれば .local とする。
    case "$filename" in
      .*)
        suffix="${filename#.}"
        case "$suffix" in
          *.*)
            suffix="${filename##*.}"
            [ -n "$suffix" ] && extension=".${suffix}"
          ;;
        esac
      ;;
      *.*)
        suffix="${filename##*.}"
        [ -n "$suffix" ] && extension=".${suffix}"
      ;;
    esac

    key="${parent}"$'\x1f'"${extension}"
    if [ -z "${extension_counts[$key]+_}" ]; then
      extension_counts["$key"]=1
      if [ -z "${directory_extension_lists[$parent]+_}" ]; then
        directory_extension_lists["$parent"]="$extension"
      else
        directory_extension_lists["$parent"]+=$'\n'"$extension"
      fi
    else
      count="${extension_counts[$key]}"
      extension_counts["$key"]=$((count + 1))
    fi
  done < "$file_list_tmp"

  # 親ごとの最後の子ディレクトリを先に確定し、├── / └── と祖先の │ を
  # 正しく選択できるようにする。ファイル行は各親の先頭、ディレクトリ行は
  # その後に出すため、最後の子ディレクトリが親全体の最後のノードになる。
  mapfile -d '' -t directory_paths < <(LC_ALL=C sort -z "$directory_list_tmp")
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    for directory in "${directory_paths[@]}"; do
      hide_directory="false"
      for hidden_path in "${DIRECTORY_TREE_HIDDEN_PATHS[@]}"; do
        if [ "$directory" = "$hidden_path" ]; then
          hide_directory="true"
          break
        fi
      done
      [ "$hide_directory" = "true" ] || visible_directory_paths+=("$directory")
    done
    directory_paths=("${visible_directory_paths[@]}")
  fi
  for directory in "${directory_paths[@]}"; do
    [ "$directory" = "$root_path" ] && continue
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    directory_child_counts["$parent"]=$((${directory_child_counts[$parent]:-0} + 1))
    last_child_directory["$parent"]="$directory"
  done
  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      directory_is_last["$directory"]="true"
      continue
    fi
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    if [ "${last_child_directory[$parent]:-}" = "$directory" ]; then
      directory_is_last["$directory"]="true"
    else
      directory_is_last["$directory"]="false"
    fi
  done

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    printf '%s (サービス: %s, コンテナ: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '%s (サービス: %s, コンテナ: %s, ルート: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$root_path" "$tree_depth" >> "$report_file"
  fi
  if [ "$file_limit" = "none" ]; then
    printf '通常ファイル: 表示しない\n' >> "$report_file"
  elif [ "$file_limit" = "all" ]; then
    printf '通常ファイル: 件数にかかわらず全ファイル名を表示\n' >> "$report_file"
  else
    printf '通常ファイル: 直下 %s 件以下は全ファイル名、超過時は拡張子別件数\n' \
        "$file_limit" >> "$report_file"
  fi
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$directory_find_status" -ne 0 ] || [ "$file_find_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能または実行中に消滅したパスを除く、取得可能な範囲を表示します。\n' >> "$report_file"
  fi

  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      if [ "$root_path" = "/" ]; then
        display_name="/"
      else
        display_name="${root_path##*/}/"
      fi
      printf '%s\n' "$display_name" >> "$report_file"
    else
      display_name="${directory##*/}/"
      parent="${directory%/*}"
      [ -n "$parent" ] || parent="/"
      ancestor_chain=()
      ancestor="$parent"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      is_last="${directory_is_last[$directory]:-false}"
      if [ "$is_last" = "true" ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "$display_name" >> "$report_file"
    fi

    leaf_entries=()
    file_count="${directory_file_counts[$directory]:-0}"
    if [ "$file_count" -gt 0 ] \
        && { [ "$file_limit" = "all" ] || [ "$file_count" -le "$file_limit" ]; }; then
      filename_list="${directory_filename_lists[$directory]}"
      while IFS= read -r filename; do
        leaf_entries+=("[ファイル] ${filename}")
      done < <(printf '%s\n' "$filename_list" | LC_ALL=C sort)
    elif [ "$file_count" -gt 0 ] && [ -n "${directory_extension_lists[$directory]+_}" ]; then
      extension_list="${directory_extension_lists[$directory]}"
      while IFS= read -r extension; do
        [ -n "$extension" ] || continue
        key="${directory}"$'\x1f'"${extension}"
        leaf_entries+=("[ファイル] ${extension}: ${extension_counts[$key]} 件")
      done < <(printf '%s\n' "$extension_list" | LC_ALL=C sort)
    fi

    for index in "${!leaf_entries[@]}"; do
      ancestor_chain=()
      ancestor="$directory"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      if [ "$index" -eq "$((${#leaf_entries[@]} - 1))" ] \
          && [ "${directory_child_counts[$directory]:-0}" -eq 0 ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "${leaf_entries[$index]}" >> "$report_file"
    done
  done

  rm -f -- "$directory_list_tmp" "$file_list_tmp"
}

show_verified_container_directory_trees() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name tree_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "コンテナ内ディレクトリツリーを出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  if ! tree_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$tree_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_directory_tree_report "$cid" "$service_name" "$container_name" "$tree_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$tree_report_tmp"

  rm -f -- "$tree_report_tmp"
}

# JBoss EAP のデプロイ先、展開済み Web ルート、Java クラスパスルート
# (WEB-INF/classes)、および指定環境変数のディレクトリを検出して表示する。
append_container_deployment_structure_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local tree_depth="${5:-$DIRECTORY_TREE_DEPTH}" file_limit="${6:-$DIRECTORY_FILE_LIMIT}"
  local scan_tmp scan_status=0 directory label root_path key entry line env_name value
  local deployment_found="false" web_root_found="false" class_root_found="false"
  local -a root_entries=() notices=()
  local -A seen_roots=() process_env_values=()

  if ! scan_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造の検出用一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  docker exec "$cid" find / -type d -print0 > "$scan_tmp" 2>/dev/null || scan_status=$?

  while IFS= read -r -d '' directory; do
    label=""
    root_path="$directory"
    case "$directory" in
      */standalone/deployments)
        label="JBoss EAP デプロイ先"
        deployment_found="true"
        ;;
      */WEB-INF/classes)
        label="Java クラスパスルート"
        class_root_found="true"
        ;;
      */WEB-INF)
        label="Web アプリケーションルート"
        root_path="${directory%/WEB-INF}"
        [ -n "$root_path" ] || root_path="/"
        web_root_found="true"
        ;;
    esac
    [ -n "$label" ] || continue
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done < "$scan_tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  for env_name in "${DEPLOYMENT_DIR_ENVS[@]}"; do
    if [ -z "${process_env_values[$env_name]+_}" ] || [ -z "${process_env_values[$env_name]}" ]; then
      notices+=("環境変数 ${env_name} は未設定または空です。")
      continue
    fi
    root_path="${process_env_values[$env_name]}"
    case "$root_path" in
      /*) ;;
      *)
        notices+=("環境変数 ${env_name} の値は絶対パスではありません: ${root_path}")
        continue
        ;;
    esac
    [ "$root_path" = "/" ] || root_path="${root_path%/}"
    label="環境変数 ${env_name}"
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造\n' >> "$report_file"
  if [ "$file_limit" = "none" ]; then
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, 通常ファイル: 表示しない)\n' \
        "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, ファイル表示上限: %s)\n' \
        "$service_name" "$container_name" "$tree_depth" "$file_limit" >> "$report_file"
  fi
  printf '===================================================================\n' >> "$report_file"
  if [ "$scan_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能なパスを除く、検出可能な範囲を表示します。\n' >> "$report_file"
  fi
  [ "$deployment_found" = "true" ] || notices+=("JBoss EAP の standalone/deployments を検出できませんでした。")
  [ "$web_root_found" = "true" ] || notices+=("展開済み Web アプリケーションルート (WEB-INF の親) を検出できませんでした。")
  [ "$class_root_found" = "true" ] || notices+=("Java クラスパスルート (WEB-INF/classes) を検出できませんでした。")
  for line in "${notices[@]}"; do
    printf '[WARN] %s\n' "$line" >> "$report_file"
  done

  if [ ${#root_entries[@]} -eq 0 ]; then
    printf '表示対象のディレクトリはありません。\n' >> "$report_file"
  else
    for entry in "${root_entries[@]}"; do
      IFS=$'\x1f' read -r label root_path <<< "$entry"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_file" "$root_path" "[${label}]" "$tree_depth" "$file_limit"
    done
  fi

  rm -f -- "$scan_tmp"
}

show_verified_container_deployment_structures() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name deployment_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "JBoss EAP デプロイ構造を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! deployment_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$deployment_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
        "$deployment_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$deployment_report_tmp"
  rm -f -- "$deployment_report_tmp"
}

# ---- Java JVM パラメータ / OpenTelemetry 設定の収集 ---------------------------
# コンテナ内の全プロセスのコマンドラインを "PID<US>arg0<US>arg1<US>..." で返す。
# ps / jcmd / jinfo をコンテナへ要求しないよう /proc/<pid>/cmdline を直接読み、
# NUL 区切りを US (0x1f) へ置き換えてホスト側の Bash で分解する。
# 引数中の空白をそのまま保てるため、-Dkey=値 に空白があっても壊れない。
collect_container_process_cmdlines() {
  local cid="$1"
  docker exec "$cid" /bin/sh -c '
for proc_dir in /proc/[0-9]*; do
  [ -r "$proc_dir/cmdline" ] || continue
  proc_cmdline=$(tr "\0" "\037" < "$proc_dir/cmdline" 2>/dev/null)
  [ -n "$proc_cmdline" ] || continue
  printf "%s\037%s\n" "${proc_dir#/proc/}" "$proc_cmdline"
done
' 2>/dev/null || true
}

# 上記のうち実行ファイル名が java のプロセス行だけを返す。
collect_container_java_processes() {
  local cid="$1" line rest first_arg
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest="${line#*"$JVM_FIELD_SEPARATOR"}"
    [ "$rest" != "$line" ] || continue
    first_arg="${rest%%"$JVM_FIELD_SEPARATOR"*}"
    case "${first_arg##*/}" in
      java) printf '%s\n' "$line" ;;
    esac
  done < <(collect_container_process_cmdlines "$cid")
}

# java -version の出力 (stderr) を取得する。取得できない場合は空を返す。
container_java_version_text() {
  local cid="$1" java_bin="$2" version_output
  case "$java_bin" in
    /*|java) ;;
    *) return 0 ;;
  esac
  if ! version_output="$(docker exec "$cid" "$java_bin" -version 2>&1)"; then
    return 0
  fi
  printf '%s\n' "$version_output"
}

# JVM オプションを「名前」と「値」に分ける。-Dkey=value / -XX:key=value /
# -javaagent:path のように区切り文字が異なるため、書式ごとに分解する。
# 戻り値は関数呼び出しごとのフォークを避けるためグローバル変数へ格納する。
JVM_OPTION_NAME=""
JVM_OPTION_VALUE=""
JVM_OPTION_HAS_VALUE="false"
split_jvm_option_name_value() {
  local option="$1"
  JVM_OPTION_NAME="$option"
  JVM_OPTION_VALUE=""
  JVM_OPTION_HAS_VALUE="false"
  case "$option" in
    -javaagent:*|-agentlib:*|-agentpath:*|-Xbootclasspath*:*|-splash:*|-Xlog:*|-Xloggc:*)
      JVM_OPTION_NAME="${option%%:*}"
      JVM_OPTION_VALUE="${option#*:}"
      JVM_OPTION_HAS_VALUE="true"
      ;;
    -D*=*|-XX:*=*|--*=*)
      JVM_OPTION_NAME="${option%%=*}"
      JVM_OPTION_VALUE="${option#*=}"
      JVM_OPTION_HAS_VALUE="true"
      ;;
  esac
}

# JVM オプションを表示用の分類へ割り当てる。上から順に判定するため、
# 複数に当てはまるオプション (例: -javaagent の OpenTelemetry エージェント) は
# 先に一致した分類へ入る。OpenTelemetry の一覧は別途、全引数を横断して集める。
JVM_OPTION_CATEGORY=""
classify_jvm_option() {
  local option="$1"
  case "$option" in
    -javaagent:*|-agentlib:*|-agentpath:*)
      JVM_OPTION_CATEGORY="agent"; return 0 ;;
    -Dotel.*|-Dio.opentelemetry.*)
      JVM_OPTION_CATEGORY="otel"; return 0 ;;
    -cp|-classpath|--class-path*|-p|--module-path*|--add-opens*|--add-exports*|--add-modules*|--add-reads*|--patch-module*|--upgrade-module-path*|--limit-modules*|-Djava.class.path=*|-Djava.library.path=*|-Xbootclasspath*)
      JVM_OPTION_CATEGORY="module"; return 0 ;;
    -Xms*|-Xmx*|-Xss*|-Xmn*|-XX:*Metaspace*|-XX:*Heap*|-XX:*RAM*|-XX:MaxDirectMemorySize*|-XX:*CodeCache*|-XX:*ThreadStackSize*|-XX:*CompressedOops*|-XX:*CompressedClassSpaceSize*)
      JVM_OPTION_CATEGORY="memory"; return 0 ;;
    -Xlog:gc*|-Xloggc:*|-XX:*GC*|-XX:*SurvivorRatio*|-XX:*NewRatio*|-XX:*Tenuring*)
      JVM_OPTION_CATEGORY="gc"; return 0 ;;
    -Djboss.*|-Dorg.jboss.*|-Dwildfly.*|-Dorg.wildfly.*|-Dlogging.configuration=*|-Dmodule.path=*)
      JVM_OPTION_CATEGORY="jboss"; return 0 ;;
    -D*)
      JVM_OPTION_CATEGORY="sysprop"; return 0 ;;
    -*)
      JVM_OPTION_CATEGORY="other"; return 0 ;;
  esac
  JVM_OPTION_CATEGORY="other"
  return 0
}

# JVM オプションが OpenTelemetry の設定かどうかを判定する。
# 分類 (classify_jvm_option) と異なり、-javaagent の OpenTelemetry エージェントや
# 起動対象へ渡される引数側の -Dotel.* も対象にする。
is_otel_jvm_option() {
  local lower="${1,,}"
  case "$lower" in
    -dotel.*|-dio.opentelemetry.*) return 0 ;;
    *opentelemetry*) return 0 ;;
    -javaagent:*otel*|-agentpath:*otel*|-agentlib:*otel*) return 0 ;;
  esac
  return 1
}

# 環境変数名から OpenTelemetry Java エージェントが参照するシステムプロパティ名を
# 求める (OTEL_SERVICE_NAME → otel.service.name)。設定漏れ判定に使う。
otel_env_name_to_property() {
  local lower="${1,,}"
  printf '%s\n' "${lower//_/.}"
}

# 分類ごとの JVM パラメータを report_file へ追記する。件数 0 の分類は
# 読みにくくなるだけなので出力しない (OpenTelemetry 一覧側は未設定も表示する)。
# 字下げは append_env_names_by_type と同じく、この関数側で付ける。
append_jvm_option_entries() {
  local report_file="$1" label="$2"
  shift 2
  [ $# -gt 0 ] || return 0
  printf '[%s] %s 件\n' "$label" "$#" >> "$report_file"
  printf '%s\n' "$@" | sed 's/^/  /' >> "$report_file"
}

# 名前と値を桁揃えした 1 行を JVM_PARAM_ENTRY へ格納する。値を持たない
# オプション (-server, -XX:+UseG1GC 等) は名前だけを出力する。
JVM_PARAM_ENTRY=""
format_jvm_param_entry() {
  local name="$1" value="$2" has_value="$3"
  if is_sensitive_setting_name "$name"; then
    value="[REDACTED]"
  fi
  if [ "$has_value" = "true" ]; then
    printf -v JVM_PARAM_ENTRY '%-*s = %s' "$JVM_PARAM_NAME_WIDTH" "$name" "$value"
  else
    printf -v JVM_PARAM_ENTRY '%s' "$name"
  fi
}

# 1 コンテナ内の Java プロセスごとに、JVM パラメータを分類して report_file へ
# 追記する。JVM オプションは起動対象 (-jar / 主クラス / --module) の手前までで、
# それ以降は起動対象へ渡される引数として分けて表示する。
append_container_jvm_parameter_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local line option value name has_value pid java_bin main_target
  local version_text version_line version_printed process_index=0 option_total app_arg_total
  local arg_index arg_count parsing_jvm_options env_name env_value
  local -a process_lines=() args=() app_args=() jvm_env_entries=()
  local -a memory_entries=() gc_entries=() agent_entries=() otel_entries=()
  local -a jboss_entries=() sysprop_entries=() module_entries=() other_entries=()
  local -A process_env_values=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"
    [ -n "$name" ] || continue
    value=""
    [ "$name" != "$line" ] && value="${line#*=}"
    process_env_values["$name"]="$value"
  done < <(collect_container_pid1_env "$cid")

  mapfile -t process_lines < <(collect_container_java_processes "$cid")

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'Java JVM パラメータ (サービス: %s, コンテナ: %s, Java プロセス: %s)\n' \
      "$service_name" "$container_name" "${#process_lines[@]}" >> "$report_file"
  printf '分類: ヒープ・メモリ / GC / Java エージェント / OpenTelemetry / JBoss / システムプロパティ / クラスパス・モジュール / その他\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"

  if [ ${#process_lines[@]} -eq 0 ]; then
    printf 'Java プロセスを検出できませんでした。\n' >> "$report_file"
    printf '  (このコンテナが JVM を実行していないか、/proc または /bin/sh を読み取れません)\n' >> "$report_file"
  fi

  for line in "${process_lines[@]}"; do
    process_index=$((process_index + 1))
    # コマンドライン末尾の NUL 由来の空フィールドを落としてから分解する。
    while [ "${line: -1}" = "$JVM_FIELD_SEPARATOR" ]; do
      line="${line%"$JVM_FIELD_SEPARATOR"}"
    done
    args=()
    IFS="$JVM_FIELD_SEPARATOR" read -r -a args <<< "$line"

    pid="${args[0]:-(不明)}"
    java_bin="${args[1]:-(不明)}"
    main_target=""
    app_args=()
    memory_entries=(); gc_entries=(); agent_entries=(); otel_entries=()
    jboss_entries=(); sysprop_entries=(); module_entries=(); other_entries=()
    option_total=0
    arg_count=${#args[@]}
    arg_index=2
    parsing_jvm_options="true"

    while [ "$arg_index" -lt "$arg_count" ]; do
      option="${args[$arg_index]}"
      arg_index=$((arg_index + 1))
      [ -n "$option" ] || continue

      if [ "$parsing_jvm_options" != "true" ]; then
        app_args+=("$option")
        continue
      fi

      has_value="false"
      value=""
      name="$option"
      case "$option" in
        -jar)
          main_target="-jar ${args[$arg_index]:-(不明)}"
          arg_index=$((arg_index + 1))
          parsing_jvm_options="false"
          continue
          ;;
        -m|--module)
          main_target="--module ${args[$arg_index]:-(不明)}"
          arg_index=$((arg_index + 1))
          parsing_jvm_options="false"
          continue
          ;;
        -cp|-classpath|--class-path|-p|--module-path|--add-opens|--add-exports|--add-modules|--add-reads|--patch-module|--upgrade-module-path|--limit-modules)
          # これらは次の引数を値として取る書式。値を巻き込んで表示する。
          value="${args[$arg_index]:-}"
          arg_index=$((arg_index + 1))
          has_value="true"
          ;;
        -*)
          split_jvm_option_name_value "$option"
          name="$JVM_OPTION_NAME"
          value="$JVM_OPTION_VALUE"
          has_value="$JVM_OPTION_HAS_VALUE"
          ;;
        *)
          # オプションでない最初の引数が起動する主クラス。以降は起動対象への引数。
          main_target="$option"
          parsing_jvm_options="false"
          continue
          ;;
      esac

      format_jvm_param_entry "$name" "$value" "$has_value"
      classify_jvm_option "$option"
      case "$JVM_OPTION_CATEGORY" in
        memory)  memory_entries+=("$JVM_PARAM_ENTRY") ;;
        gc)      gc_entries+=("$JVM_PARAM_ENTRY") ;;
        agent)   agent_entries+=("$JVM_PARAM_ENTRY") ;;
        otel)    otel_entries+=("$JVM_PARAM_ENTRY") ;;
        jboss)   jboss_entries+=("$JVM_PARAM_ENTRY") ;;
        module)  module_entries+=("$JVM_PARAM_ENTRY") ;;
        sysprop) sysprop_entries+=("$JVM_PARAM_ENTRY") ;;
        *)       other_entries+=("$JVM_PARAM_ENTRY") ;;
      esac
      option_total=$((option_total + 1))
    done

    app_arg_total=${#app_args[@]}
    printf '\n' >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    printf '[Java プロセス %s] PID: %s\n' "$process_index" "$pid" >> "$report_file"
    printf '実行ファイル     : %s\n' "$java_bin" >> "$report_file"
    version_text="$(container_java_version_text "$cid" "$java_bin")"
    if [ -n "$version_text" ]; then
      # java -version は複数行を返す。2 行目以降は見出しの幅だけ字下げして続ける。
      version_printed="false"
      while IFS= read -r version_line; do
        [ -n "$version_line" ] || continue
        if [ "$version_printed" = "true" ]; then
          printf '                   %s\n' "$version_line" >> "$report_file"
        else
          printf 'バージョン       : %s\n' "$version_line" >> "$report_file"
          version_printed="true"
        fi
      done <<< "$version_text"
    else
      printf 'バージョン       : (取得できませんでした)\n' >> "$report_file"
    fi
    printf '起動対象         : %s\n' "${main_target:-(検出できませんでした)}" >> "$report_file"
    printf 'JVM パラメータ数 : %s 件\n' "$option_total" >> "$report_file"
    printf '起動対象への引数 : %s 件\n' "$app_arg_total" >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"

    if [ "$option_total" -eq 0 ]; then
      printf 'JVM パラメータの指定はありません。\n' >> "$report_file"
    else
      append_jvm_option_entries "$report_file" "ヒープ・メモリ" ${memory_entries[@]+"${memory_entries[@]}"}
      append_jvm_option_entries "$report_file" "GC (ガベージコレクション)" ${gc_entries[@]+"${gc_entries[@]}"}
      append_jvm_option_entries "$report_file" "Java エージェント" ${agent_entries[@]+"${agent_entries[@]}"}
      append_jvm_option_entries "$report_file" "OpenTelemetry" ${otel_entries[@]+"${otel_entries[@]}"}
      append_jvm_option_entries "$report_file" "JBoss / WildFly" ${jboss_entries[@]+"${jboss_entries[@]}"}
      append_jvm_option_entries "$report_file" "システムプロパティ (-D)" ${sysprop_entries[@]+"${sysprop_entries[@]}"}
      append_jvm_option_entries "$report_file" "クラスパス・モジュール" ${module_entries[@]+"${module_entries[@]}"}
      append_jvm_option_entries "$report_file" "その他 JVM オプション" ${other_entries[@]+"${other_entries[@]}"}
    fi
    append_jvm_option_entries "$report_file" "起動対象へ渡される引数" ${app_args[@]+"${app_args[@]}"}
  done

  # JAVA_OPTS などで渡した指定は JVM 起動時に追加されるため、
  # /proc/<pid>/cmdline には現れない。取りこぼさないよう別枠で表示する。
  for env_name in "${JVM_OPTION_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    env_value="${process_env_values[$env_name]}"
    [ -n "$env_value" ] || continue
    format_jvm_param_entry "$env_name" "$env_value" "true"
    jvm_env_entries+=("$JVM_PARAM_ENTRY")
  done

  printf '\n' >> "$report_file"
  if [ ${#jvm_env_entries[@]} -eq 0 ]; then
    printf '[JVM オプションを渡す環境変数] 0 件\n' >> "$report_file"
    printf '  (なし)\n' >> "$report_file"
  else
    append_jvm_option_entries "$report_file" "JVM オプションを渡す環境変数" "${jvm_env_entries[@]}"
    printf '※ 環境変数経由の指定は JVM 起動時に追加されるため、上記のコマンドライン一覧には現れません。\n' >> "$report_file"
  fi
}

# 1 コンテナの OpenTelemetry 関連設定を、環境変数と JVM パラメータの双方から
# 集めて report_file へ追記する。Java を実行しないコンテナ (Collector 等) でも
# 環境変数側は同じ形式で確認できる。
append_container_otel_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local line key value env_name property_name option token otel_token_found total_found=0
  local -a process_lines=() args=() tokens=()
  local -a standard_entries=() related_entries=() cmdline_entries=()
  local -a env_option_entries=() missing_entries=()
  local -A process_env_values=() defined_properties=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  # (1) 接頭辞 OTEL_ を持つ標準環境変数
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      "$OTEL_ENV_NAME_PREFIX"*) ;;
      *) continue ;;
    esac
    format_jvm_param_entry "$key" "${process_env_values[$key]}" "true"
    standard_entries+=("$JVM_PARAM_ENTRY")
  done < <(printf '%s\n' "${!process_env_values[@]}" | sort)

  # (2) 接頭辞を持たない関連環境変数
  for env_name in "${OTEL_RELATED_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    format_jvm_param_entry "$env_name" "${process_env_values[$env_name]}" "true"
    related_entries+=("$JVM_PARAM_ENTRY")
  done
  # JVM オプション用の環境変数は、OpenTelemetry を参照している場合だけ関連とみなす。
  # 値には複数のオプションが空白区切りで並ぶため、個々のオプションごとに判定する。
  for env_name in "${OTEL_JVM_OPTION_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    value="${process_env_values[$env_name]}"
    [ -n "$value" ] || continue
    tokens=()
    read -r -a tokens <<< "$value"
    otel_token_found="false"
    for token in ${tokens[@]+"${tokens[@]}"}; do
      is_otel_jvm_option "$token" || continue
      otel_token_found="true"
      split_jvm_option_name_value "$token"
      format_jvm_param_entry "${env_name}: ${JVM_OPTION_NAME}" "$JVM_OPTION_VALUE" "$JVM_OPTION_HAS_VALUE"
      env_option_entries+=("$JVM_PARAM_ENTRY")
      case "$JVM_OPTION_NAME" in
        -D*) defined_properties["${JVM_OPTION_NAME#-D}"]=1 ;;
      esac
    done
    [ "$otel_token_found" = "true" ] || continue
    format_jvm_param_entry "$env_name" "$value" "true"
    related_entries+=("$JVM_PARAM_ENTRY")
  done

  # (3) Java プロセスのコマンドライン全体 (起動対象への引数も含む)
  mapfile -t process_lines < <(collect_container_java_processes "$cid")
  for line in "${process_lines[@]}"; do
    while [ "${line: -1}" = "$JVM_FIELD_SEPARATOR" ]; do
      line="${line%"$JVM_FIELD_SEPARATOR"}"
    done
    args=()
    IFS="$JVM_FIELD_SEPARATOR" read -r -a args <<< "$line"
    for option in "${args[@]:2}"; do
      [ -n "$option" ] || continue
      is_otel_jvm_option "$option" || continue
      split_jvm_option_name_value "$option"
      format_jvm_param_entry "$JVM_OPTION_NAME" "$JVM_OPTION_VALUE" "$JVM_OPTION_HAS_VALUE"
      cmdline_entries+=("$JVM_PARAM_ENTRY")
      case "$JVM_OPTION_NAME" in
        -D*) defined_properties["${JVM_OPTION_NAME#-D}"]=1 ;;
      esac
    done
  done

  total_found=$(( ${#standard_entries[@]} + ${#related_entries[@]} \
      + ${#cmdline_entries[@]} + ${#env_option_entries[@]} ))

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: %s, コンテナ: %s)\n' \
      "$service_name" "$container_name" >> "$report_file"
  printf '種別: OTEL_ 標準環境変数 / 関連環境変数 / JVM パラメータ (コマンドライン・環境変数由来)\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"

  if [ "$total_found" -eq 0 ]; then
    printf 'OpenTelemetry 関連の環境変数・JVM パラメータは検出されませんでした。\n' >> "$report_file"
    return 0
  fi

  append_env_names_by_type "$report_file" "OpenTelemetry 標準環境変数 (${OTEL_ENV_NAME_PREFIX}*)" \
      ${standard_entries[@]+"${standard_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連環境変数" \
      ${related_entries[@]+"${related_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連 JVM パラメータ (コマンドライン)" \
      ${cmdline_entries[@]+"${cmdline_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連 JVM パラメータ (環境変数由来)" \
      ${env_option_entries[@]+"${env_option_entries[@]}"}

  # 環境変数とシステムプロパティのどちらでも指定されていない主要設定を挙げ、
  # 送達不良時に「そもそも設定されていない」ケースを切り分けやすくする。
  for env_name in "${OTEL_KEY_ENV_NAMES[@]}"; do
    [ -z "${process_env_values[$env_name]+_}" ] || continue
    property_name="$(otel_env_name_to_property "$env_name")"
    [ -z "${defined_properties[$property_name]+_}" ] || continue
    missing_entries+=("${env_name} (システムプロパティ -D${property_name} も未設定)")
  done
  append_env_names_by_type "$report_file" "未設定の主要 OpenTelemetry 設定" \
      ${missing_entries[@]+"${missing_entries[@]}"}
}

# append_env_names_by_type / append_jvm_option_entries は既に整形済みの行を
# 受け取るため、画面表示用のラッパーは環境変数一覧・ツリーと同じ流れで書ける。
show_verified_container_jvm_parameters() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] JBoss EAP デプロイ構造の後に Java JVM パラメータ一覧をプレビューします。"
    return 0
  }

  local report_line cid service_name container_name jvm_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "Java JVM パラメータ一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! jvm_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "Java JVM パラメータ一覧出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$jvm_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_jvm_parameter_report "$cid" "$service_name" "$container_name" "$jvm_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$jvm_report_tmp"
  rm -f -- "$jvm_report_tmp"
}

show_verified_container_otel_settings() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] JVM パラメータの後に OpenTelemetry 環境変数・JVM パラメータ一覧をプレビューします。"
    return 0
  }

  local report_line cid service_name container_name otel_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "OpenTelemetry 設定一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! otel_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "OpenTelemetry 設定一覧出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$otel_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_otel_report "$cid" "$service_name" "$container_name" "$otel_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$otel_report_tmp"
  rm -f -- "$otel_report_tmp"
}

# 対象コンテナがすべて実行中か確認する (途中停止 = 起動失敗の早期検知用)。
# 停止しているコンテナがあれば 1 を返す。
# 一覧には ps -aq を使う。ps -q だと異常終了したコンテナが一覧から消えてループが
# 一度も回らず、「停止を検知できないまま成功」と誤判定してしまうため。
# 同じ理由で、1 件も返らない場合 (コンテナが作られていない / 削除された) も異常とする。
containers_all_running() {
  local cid running found="false"
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found="true"
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)"
    if [ "$running" != "true" ]; then
      return 1
    fi
  done < <(compose_container_ids_all "$@")
  [ "$found" = "true" ] || return 1
  return 0
}

# 起動確認中に停止した「起動対象サービス」を検出する。
# --startup-service で検証対象を絞っていると、それ以外のサービス (DB へ繋がらずに落ちた
# バックエンド等) の異常終了が見逃され、検証対象のタイムアウトまで待たされてしまうため、
# 起動対象サービス全体の生存を毎ポーリングで確認する。
# 初期化専用など、正常に終了しうるサービスは --allow-service-exit で除外できる。
STOPPED_TARGET_SERVICES=()
target_services_all_running() {
  STOPPED_TARGET_SERVICES=()
  [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ] || return 0
  local svc allowed_service allowed
  for svc in "${COMPOSE_TARGET_SERVICES[@]}"; do
    allowed="false"
    for allowed_service in ${ALLOW_SERVICE_EXIT[@]+"${ALLOW_SERVICE_EXIT[@]}"}; do
      if [ "$allowed_service" = "$svc" ]; then
        allowed="true"
        break
      fi
    done
    [ "$allowed" = "true" ] && continue
    containers_all_running "$svc" || STOPPED_TARGET_SERVICES+=("$svc")
  done
  [ ${#STOPPED_TARGET_SERVICES[@]} -eq 0 ]
}

# コンテナを起動する (バックグラウンド)。対象サービスは 1 回の compose up で
# 同時に起動される。
start_container() {
  if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    log "コンテナを同時に起動します (compose up -d, 対象サービス: ${COMPOSE_TARGET_SERVICES[*]}) ..."
    if [ ${#COMPOSE_TARGET_SERVICES[@]} -ne ${#COMPOSE_SERVICES[@]} ]; then
      log "  ベースサービス '${BASE_SERVICE}' はビルド専用のため起動対象から除外しました。"
    fi
  else
    log "コンテナを起動します (compose up -d, 全サービス) ..."
  fi
  # 既存コンテナを再利用した場合に前回起動の WFLYSRV0025 を誤検出しないよう、
  # compose up の直前を今回のログ取得開始時刻として記録する。
  # docker compose logs --since は RFC3339 を受け取る。表示・記録を JST に揃える
  # ため +09:00 付きで生成し、オフセットを組み立てられない環境では UTC 表記へ戻す。
  CONTAINER_LOG_SINCE="$(date '+%Y-%m-%dT%H:%M:%S.%N%:z' 2>/dev/null)"
  case "$CONTAINER_LOG_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*[+-][0-9][0-9]:[0-9][0-9]) ;;
    *) CONTAINER_LOG_SINCE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ;;
  esac
  local up_args=(-f "$COMPOSE_FILE" up -d --no-build)
  # --wait を付けると、compose が depends_on の条件に加えて対象サービス自身が
  # healthy (healthcheck 未定義なら running) になるまで待ってから戻る。
  # 依存先の healthcheck が未整備だと待てないため、compose.yml 側の整備が前提。
  if [ "$STARTUP_WAIT" = "true" ]; then
    up_args+=(--wait --wait-timeout "$STARTUP_WAIT_TIMEOUT")
    log "  compose の起動完了待ちを有効にしました (--wait, 最大 ${STARTUP_WAIT_TIMEOUT}s)。"
  fi
  up_args+=(${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"})
  COMPOSE_UP_ATTEMPTED="true"
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} "${up_args[@]}"; then
    err "コンテナの起動に失敗しました (compose up)"
    return 1
  fi
  STARTED_CONTAINER="true"
  return 0
}

# コンテナを停止・削除する (EXIT トラップから呼び出す)。
teardown_container() {
  [ "$STARTED_CONTAINER" = "true" ] || return 0
  if [ "$KEEP_CONTAINER" = "true" ]; then
    log "コンテナを残します (--keep-container)。手動で停止する場合: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
    return 0
  fi
  log "コンテナを停止・削除します (compose down) ..."
  local down_ok=0
  if [ "$SUPPRESS_REMOVED_LOGS" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down > /dev/null 2>&1 || down_ok=$?
  else
    run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down || down_ok=$?
  fi
  if [ "$down_ok" -ne 0 ]; then
    warn "コンテナの停止・削除に失敗しました。手動で確認してください: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
  fi
}

# ---- エラー終了時の終了 (SIGTERM) ログ取得 -----------------------------------
# ECS はタスク停止時に各コンテナへ SIGTERM を送るため、adot collector のような
# サイドカーは「シグナル受信 → パイプラインの graceful shutdown → 終了」までを
# ログへ出す。ローカル検証で compose down まで一気に実行すると、この終了ログは
# 誰にも取得されないままコンテナごと削除されてしまう。
# 特に adot collector の healthcheck が失敗し、depends_on の condition:
# service_healthy を満たせずバックエンドが起動しなかった場合、ECS 上でも同じく
# タスクが停止するため、終了処理まで含んだログが原因調査の手掛かりになる。
# そこでエラー終了時に限り、削除の前に SIGTERM による停止を挟み、そこで追加された
# ログを画面と全量レポートの双方へ残す。

# SIGTERM 送出前後のログ行数の差分を「終了処理で追加された行」として表示する。
# compose logs --since と同じ範囲で数えるため、ホストとコンテナの時刻差に
# 影響されない。
show_service_shutdown_logs() {
  local service_name="$1" before_count="$2"
  local logs total_count new_count new_lines containers

  logs="$(compose_logs "$service_name" | strip_ansi_codes)"
  total_count="$(count_log_lines "$logs")"
  new_count=$(( total_count - before_count ))
  [ "$new_count" -gt 0 ] || new_count=0
  containers="$(compose_service_container_summary "$service_name")"

  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "終了 (SIGTERM) 時のコンテナログ (サービス: ${service_name}, 追加 ${new_count} 行):"
  diag "コンテナ      : ${containers}"
  diag "───────────────────────────────────────────────────────────────────"
  if [ "$new_count" -gt 0 ]; then
    new_lines="$(printf '%s\n' "$logs" | tail -n "$new_count")"
    print_startup_logs_with_highlights "$new_lines"
  else
    diag "SIGTERM 受信後に追加されたログはありません。"
  fi
  diag "───────────────────────────────────────────────────────────────────"
}

# エラー終了時に SIGTERM でコンテナを終了させ、終了処理のログを取得する。
# 環境変数やディレクトリツリーは起動中のコンテナからしか取得できないため、
# 全量レポートではそれらの収集を終えた位置 (ログ本文の直前) から呼び出す。
# レポート出力が無効な場合は後始末から呼ばれるため、二重実行しないよう記録する。
capture_shutdown_logs() {
  local exit_status="$1"
  [ "$SHUTDOWN_LOGS_CAPTURED" = "true" ] && return 0
  [ "$CAPTURE_SHUTDOWN_LOGS" = "true" ] || return 0
  # 成功時は通常の後始末 (compose down) に任せ、終了ログの取得は行わない。
  [ "$exit_status" -ne 0 ] || return 0
  # 調査のためコンテナを残す指定では停止できないため、終了ログも取得しない。
  [ "$KEEP_CONTAINER" != "true" ] || return 0
  # 今回の実行が compose up まで進んでいない場合 (ビルド失敗など) は、
  # 前回の実行が残したコンテナを止めてしまわないよう対象外とする。
  [ "$COMPOSE_UP_ATTEMPTED" = "true" ] || return 0

  SHUTDOWN_LOGS_CAPTURED="true"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] エラー終了時は SIGTERM (compose stop -t ${SHUTDOWN_LOG_TIMEOUT}) でコンテナを終了させ、終了処理のログまで取得します。"
    return 0
  fi

  local -a running_services=()
  mapfile -t running_services < <(compose_started_services)
  if [ ${#running_services[@]} -eq 0 ]; then
    return 0
  fi

  # 停止前のログ行数をサービスごとに控え、停止後の増分を終了ログとして扱う。
  local svc
  local -a before_counts=()
  for svc in "${running_services[@]}"; do
    before_counts+=("$(count_log_lines "$(compose_logs "$svc" | strip_ansi_codes)")")
  done

  log "エラー終了のため、ECS のタスク停止と同じく SIGTERM でコンテナを終了させ、終了処理のログを取得します (compose stop -t ${SHUTDOWN_LOG_TIMEOUT}, 対象: ${running_services[*]}) ..."
  SHUTDOWN_STOP_EXECUTED="true"
  local stop_status=0
  if [ "$SUPPRESS_REMOVED_LOGS" = "true" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" stop -t "$SHUTDOWN_LOG_TIMEOUT" > /dev/null 2>&1 || stop_status=$?
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" stop -t "$SHUTDOWN_LOG_TIMEOUT" || stop_status=$?
  fi
  if [ "$stop_status" -ne 0 ]; then
    warn "SIGTERM による停止に失敗しました (compose stop, exit=${stop_status})。終了処理のログが欠けている可能性があります。"
  fi

  local index=0
  for svc in "${running_services[@]}"; do
    show_service_shutdown_logs "$svc" "${before_counts[$index]}"
    index=$((index + 1))
  done
  return 0
}

# jbosseap サーバーの起動完了をログから待つ。
# --startup-service 指定時は各サービスのログを個別に確認し、全サービスの
# 起動完了をもって成功とする。未指定時は対象サービス全体のログをまとめて確認する。
wait_for_startup() {
  local -a pending=()
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    pending=("${STARTUP_SERVICES[@]}")
    log "jbosseap サーバーの起動完了を確認します (対象サービス: ${pending[*]}, 最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  else
    log "jbosseap サーバーの起動完了を確認します (最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] compose logs を ${STARTUP_INTERVAL}s 間隔でポーリングし、上記パターンに一致するまで待ちます。"
    return 0
  fi
  local deadline now logs normalized_logs svc failure_line
  local -a remaining=()
  now="$(date +%s)"
  deadline=$(( now + STARTUP_TIMEOUT ))
  while :; do
    if [ ${#pending[@]} -gt 0 ]; then
      # サービスごとにログを確認し、起動完了したものを pending から外す。
      remaining=()
      for svc in "${pending[@]}"; do
        logs="$(compose_logs "$svc")"
        normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
        if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
          failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
          err "JBoss EAP 8.1 が正常起動しませんでした: サービス '${svc}'"
          err "  ${failure_line}"
          dump_startup_logs_from_snapshot "$normalized_logs" "対象サービス: ${svc}"
          return 1
        elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
          log "jbosseap サーバーの起動完了を確認しました: サービス '${svc}'"
          show_startup_logs "$normalized_logs" "対象サービス: ${svc}"
        else
          remaining+=("$svc")
        fi
      done
      pending=(${remaining[@]+"${remaining[@]}"})
      if [ ${#pending[@]} -eq 0 ]; then
        show_companion_service_logs
        log "指定した全サービスの起動完了を確認しました。"
        return 0
      fi
    else
      logs="$(compose_logs)"
      normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
      if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
        failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
        err "JBoss EAP 8.1 が正常起動しませんでした。"
        err "  ${failure_line}"
        dump_startup_logs_from_snapshot "$normalized_logs" "全対象サービス"
        return 1
      elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
        log "jbosseap サーバーの起動完了を確認しました。"
        show_startup_logs "$normalized_logs" "全対象サービス"
        show_companion_service_logs
        return 0
      fi
    fi
    # コンテナが途中で停止していないか確認する (起動失敗の早期検知)。
    if ! containers_all_running ${pending[@]+"${pending[@]}"}; then
      err "コンテナが起動途中で停止しました。jbosseap の起動に失敗した可能性があります。"
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    # 検証対象以外の起動対象サービス (DB 接続に失敗して落ちたバックエンド等) の異常終了も
    # 検知する。見逃すと検証対象のタイムアウトまで原因不明のまま待たされるため。
    if ! target_services_all_running; then
      err "起動対象の Compose サービスが停止しました: ${STOPPED_TARGET_SERVICES[*]}"
      err "  依存サービスの準備完了を待てているか (compose.yml の healthcheck / depends_on) を確認してください。"
      err "  正常に終了しうるサービスは --allow-service-exit で除外できます。"
      dump_startup_logs "${STOPPED_TARGET_SERVICES[@]}"
      return 1
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      if [ ${#pending[@]} -gt 0 ]; then
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できなかったサービス: ${pending[*]})。"
      else
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できませんでした)。"
      fi
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    sleep "$STARTUP_INTERVAL"
  done
}

# 取得済みスナップショットを使い、失敗時の起動ログと同時起動サービスログを表示する。
# 失敗原因を隠さないよう、--suppress-startup-logs 指定時もログを表示する。
dump_startup_logs_from_snapshot() {
  local logs="$1" target_desc="$2"
  show_startup_logs "$logs" "$target_desc" "false"
  show_companion_service_logs "false"
}

# 失敗時に設定行数分のコンテナ起動ログを出力する (原因調査用)。
# 引数でサービスを指定した場合はそのサービスのログのみ出力する。
dump_startup_logs() {
  local logs target_desc
  logs="$(compose_logs "$@")"
  if [ $# -gt 0 ]; then
    target_desc="対象サービス: $*"
  else
    target_desc="全対象サービス"
  fi
  dump_startup_logs_from_snapshot "$logs" "$target_desc"
}

# 指定 URL へ HTTP リクエストを送り、期待するステータスコードを確認する。
verify_url() {
  local request_desc="[${URL_METHOD}] ${VERIFY_URL}"
  if [ -n "$URL_CONTENT_TYPE" ]; then
    request_desc="${request_desc} (Content-Type: ${URL_CONTENT_TYPE})"
  fi
  log "URL 応答を確認します: ${request_desc} (期待ステータス: ${EXPECT_STATUS}, 最大 ${URL_TIMEOUT}s) ..."
  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "$URL_BODY_JSON" ]; then
      log "[DRY-RUN] JSON ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    elif [ -n "$URL_BODY_FORM" ]; then
      log "[DRY-RUN] form ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    else
      log "[DRY-RUN] curl で ${VERIFY_URL} を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    fi
    return 0
  fi

  local curl_opts=(-s -S -m 30 -o "$URL_BODY_FILE" -w '%{http_code}' -X "$URL_METHOD")
  [ "$URL_INSECURE" = "true" ] && curl_opts+=(-k)
  [ -n "$URL_CONTENT_TYPE" ] && curl_opts+=(-H "Content-Type: ${URL_CONTENT_TYPE}")
  if [ -n "$URL_BODY_JSON" ]; then
    curl_opts+=(--data "$URL_BODY_JSON")
  elif [ -n "$URL_BODY_FORM" ]; then
    curl_opts+=(--data "$URL_BODY_FORM")
  fi

  local deadline now code last_code=""
  now="$(date +%s)"
  deadline=$(( now + URL_TIMEOUT ))
  while :; do
    # curl 失敗 (接続不可等) の場合は code が空/000 になるため、|| true で継続する。
    code="$(curl "${curl_opts[@]}" "$VERIFY_URL" 2>/dev/null || true)"
    [ -z "$code" ] && code="000"
    last_code="$code"
    if [ "$code" = "$EXPECT_STATUS" ]; then
      log "URL 応答を確認しました: HTTP ${code} (期待通り)。"
      show_url_body
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      err "URL 応答の確認に失敗しました: 最後の応答 HTTP ${last_code} (期待: ${EXPECT_STATUS})。"
      show_url_body
      return 1
    fi
    log "  HTTP ${code} (期待 ${EXPECT_STATUS} と不一致)。${URL_INTERVAL}s 後に再試行します ..."
    sleep "$URL_INTERVAL"
  done
}

# 直近の URL 応答本文を (先頭のみ) 表示する。
show_url_body() {
  [ -f "$URL_BODY_FILE" ] || return 0
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "URL 応答本文 (先頭 20 行):"
  diag "───────────────────────────────────────────────────────────────────"
  head -n 20 "$URL_BODY_FILE" >&2
  printf '\n' >&2
  diag "───────────────────────────────────────────────────────────────────"
}

# 起動維持後の対話操作で使う検証対象コンテナを一つ選択する。
# 検証対象が複数ある場合だけ番号入力を求め、単一の場合は自動選択する。
select_interaction_target() {
  local cid service_name container_name duplicate choice index _existing_cid _target_index
  local -a container_ids=() service_names=() container_names=()

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    duplicate="false"
    for _existing_cid in "${container_ids[@]}"; do
      if [ "$cid" = "$_existing_cid" ]; then
        duplicate="true"
        break
      fi
    done
    [ "$duplicate" = "true" ] || container_ids+=("$cid")
  done < <(verification_target_container_ids)

  if [ ${#container_ids[@]} -eq 0 ]; then
    err "対話操作の対象となる実行中コンテナが見つかりません。"
    return 1
  fi

  for cid in "${container_ids[@]}"; do
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    service_names+=("$service_name")
    container_names+=("$container_name")
  done

  index=0
  if [ ${#container_ids[@]} -gt 1 ]; then
    diag ""
    diag "対話操作を行う検証対象コンテナを選択してください:"
    for _target_index in "${!container_ids[@]}"; do
      diag "  $(( _target_index + 1 ))) service=${service_names[$_target_index]}, container=${container_names[$_target_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#container_ids[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテナ選択を読み取れませんでした。対話可能な端末から実行してください。"
        return 1
      fi
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#container_ids[@]} ]; then
            index=$(( choice - 1 ))
            break
          fi
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi

  INTERACTION_CONTAINER_ID="${container_ids[$index]}"
  INTERACTION_SERVICE_NAME="${service_names[$index]}"
  INTERACTION_CONTAINER_NAME="${container_names[$index]}"
  return 0
}

normalize_context_root() {
  local context_root="$1"
  while [ "${context_root#/}" != "$context_root" ]; do
    context_root="${context_root#/}"
  done
  if [ -n "$context_root" ]; then
    context_root="/${context_root}"
  else
    context_root="/"
  fi
  while [ "$context_root" != "/" ] && [ "${context_root%/}" != "$context_root" ]; do
    context_root="${context_root%/}"
  done
  printf '%s\n' "$context_root"
}

# JBoss EAP の登録済み Web コンテキストを WFLYUT0021 から取得する。
# 明示値を優先し、複数検出時はリクエスト対象を番号で選択する。
select_jboss_context_root() {
  local logs="$1" context_root choice index=0 _context_index
  local -a context_roots=()

  if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
    INTERACTION_CONTEXT_ROOT="$(normalize_context_root "$JBOSS_CONTEXT_ROOT")"
    log "指定された JBoss EAP コンテキストルートを使用します: ${INTERACTION_CONTEXT_ROOT}"
    return 0
  fi

  while IFS= read -r context_root; do
    [ -n "$context_root" ] && context_roots+=("$(normalize_context_root "$context_root")")
  done < <(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE "s/.*WFLYUT0021:[[:space:]]*Registered web context:[[:space:]]*'?([^'[:space:]]+)'?.*/\1/p" \
      | awk '!seen[$0]++'
  )

  if [ ${#context_roots[@]} -eq 0 ]; then
    INTERACTION_CONTEXT_ROOT="/"
    warn "WFLYUT0021 ログからコンテキストルートを検出できないため、'/' を使用します。"
  elif [ ${#context_roots[@]} -eq 1 ]; then
    INTERACTION_CONTEXT_ROOT="${context_roots[0]}"
    log "JBoss EAP ログからコンテキストルートを検出しました: ${INTERACTION_CONTEXT_ROOT}"
  else
    diag ""
    diag "HTTP 通信に使用する JBoss EAP コンテキストルートを選択してください:"
    for _context_index in "${!context_roots[@]}"; do
      diag "  $(( _context_index + 1 ))) ${context_roots[$_context_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#context_roots[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテキストルートの選択を読み取れませんでした。"
        return 1
      fi
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#context_roots[@]} ]; then
            index=$(( choice - 1 ))
            INTERACTION_CONTEXT_ROOT="${context_roots[$index]}"
            break
          fi
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi
  return 0
}

# JBoss EAP のコンテナ側 HTTP リスナーポートを WFLYUT0006 から検出する。
discover_jboss_http_port() {
  local logs="$1" detected_port=""
  if [ -n "$JBOSS_HTTP_PORT" ]; then
    INTERACTION_CONTAINER_PORT="$JBOSS_HTTP_PORT"
    log "指定された JBoss EAP HTTP リスナーポートを使用します: ${INTERACTION_CONTAINER_PORT}"
    return 0
  fi

  detected_port="$(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE 's/.*WFLYUT0006:.*Undertow HTTP listener .* listening on .*:([0-9]+).*/\1/p' \
      | tail -n 1
  )"
  if [ -n "$detected_port" ]; then
    INTERACTION_CONTAINER_PORT="$detected_port"
    log "JBoss EAP ログから HTTP リスナーポートを検出しました: ${INTERACTION_CONTAINER_PORT}"
  else
    INTERACTION_CONTAINER_PORT="8080"
    warn "WFLYUT0006 ログから HTTP リスナーポートを検出できないため、8080 を使用します。"
  fi
}

# コンテナ側リスナーポートを、ホストから curl できるアドレスへ解決する。
# 公開ポートを優先し、未公開ならコンテナ IP、取得不能なら localhost を使う。
resolve_interaction_http_endpoint() {
  local mapping="" mapped_host="" mapped_port="" container_ip=""
  mapping="$(docker port "$INTERACTION_CONTAINER_ID" "${INTERACTION_CONTAINER_PORT}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      INTERACTION_HTTP_HOST="$mapped_host"
      INTERACTION_HTTP_PORT="$mapped_port"
      log "Docker 公開ポートを検出しました: ${INTERACTION_CONTAINER_PORT}/tcp -> ${INTERACTION_HTTP_HOST}:${INTERACTION_HTTP_PORT}"
      return 0
    fi
  fi

  container_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      "$INTERACTION_CONTAINER_ID" 2>/dev/null | sed -n '/./{p;q;}' || true
  )"
  if [ -n "$container_ip" ]; then
    INTERACTION_HTTP_HOST="$container_ip"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "HTTP ポートが公開されていないため、コンテナ IP (${INTERACTION_HTTP_HOST}) へ直接接続します。"
  else
    INTERACTION_HTTP_HOST="127.0.0.1"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "公開ポートとコンテナ IP を取得できないため、localhost:${INTERACTION_HTTP_PORT} を使用します。"
  fi
  return 0
}

join_context_root_and_path() {
  local context_root="$1" request_path="$2"
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
    return 0
  fi
  if [ "${request_path#\?}" != "$request_path" ]; then
    printf '%s%s\n' "$context_root" "$request_path"
    return 0
  fi
  while [ "${request_path#/}" != "$request_path" ]; do
    request_path="${request_path#/}"
  done
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
  elif [ "$context_root" = "/" ]; then
    printf '/%s\n' "$request_path"
  else
    printf '%s/%s\n' "$context_root" "$request_path"
  fi
}

prompt_http_request_path() {
  local request_path
  while :; do
    printf 'コンテキストルート以降のパスを入力してください (空入力はルート): ' >&2
    if ! IFS= read -r request_path; then
      err "HTTP パスを読み取れませんでした。"
      return 1
    fi
    case "$request_path" in
      *://*)
        warn "完全な URL ではなく、コンテキストルート以降のパスだけを入力してください。"
        ;;
      *[[:space:]]*)
        warn "パス中の空白はパーセントエンコードして入力してください。"
        ;;
      *)
        HTTP_REQUEST_PATH="$request_path"
        return 0
        ;;
    esac
  done
}

prompt_http_method() {
  local choice
  diag ""
  diag "HTTP メソッドを選択してください:"
  diag "  1) GET"
  diag "  2) POST"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "HTTP メソッドの選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|GET|get)
        HTTP_REQUEST_METHOD="GET"
        return 0
        ;;
      2|POST|post)
        HTTP_REQUEST_METHOD="POST"
        return 0
        ;;
      *) warn "1 (GET) または 2 (POST) を選択してください。" ;;
    esac
  done
}

prompt_http_post_body() {
  local choice
  HTTP_REQUEST_BODY=""
  HTTP_REQUEST_CONTENT_TYPE=""
  diag ""
  diag "POST ボディ形式を選択してください:"
  diag "  1) JSON (application/json)"
  diag "  2) form URL encoded (application/x-www-form-urlencoded)"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "POST ボディ形式の選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|JSON|json)
        HTTP_REQUEST_CONTENT_TYPE="application/json"
        break
        ;;
      2|FORM|form)
        HTTP_REQUEST_CONTENT_TYPE="application/x-www-form-urlencoded"
        break
        ;;
      *) warn "1 (JSON) または 2 (form URL encoded) を選択してください。" ;;
    esac
  done

  if [ "$HTTP_REQUEST_CONTENT_TYPE" = "application/json" ]; then
    printf 'JSON ボディを 1 行で入力してください: ' >&2
  else
    printf 'form ボディを key=value&key2=value2 形式で入力してください: ' >&2
  fi
  if ! IFS= read -r HTTP_REQUEST_BODY; then
    err "POST ボディを読み取れませんでした。"
    return 1
  fi
  return 0
}

show_interactive_http_response() {
  local request_method="$1" request_url="$2" status_code="$3"
  diag ""
  diag "════════════════════════ HTTP 通信結果 ════════════════════════"
  diag "リクエスト             : [${request_method}] ${request_url}"
  diag "HTTP ステータスコード : ${status_code}"
  diag "────────────────────── レスポンスボディ ──────────────────────"
  if [ -s "$INTERACTIVE_HTTP_BODY_FILE" ]; then
    cat "$INTERACTIVE_HTTP_BODY_FILE" >&2
    printf '\n' >&2
  else
    diag "(空)"
  fi
  diag "═══════════════════════════════════════════════════════════════"
}

run_interactive_http_request() {
  local logs host_for_url request_path request_url status_code curl_status=0
  local -a curl_opts

  if [ "$INTERACTION_SERVICE_NAME" != "(unknown)" ]; then
    logs="$(compose_logs "$INTERACTION_SERVICE_NAME")"
  else
    logs="$(compose_logs)"
  fi
  select_jboss_context_root "$logs" || return 1
  discover_jboss_http_port "$logs" || return 1
  resolve_interaction_http_endpoint || return 1

  host_for_url="$INTERACTION_HTTP_HOST"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac

  diag ""
  diag "対話式 HTTP 通信 (サービス: ${INTERACTION_SERVICE_NAME}, コンテナ: ${INTERACTION_CONTAINER_NAME})"
  diag "  接続先       : http://${host_for_url}:${INTERACTION_HTTP_PORT}"
  diag "  コンテキスト : ${INTERACTION_CONTEXT_ROOT}"
  prompt_http_request_path || return 1
  prompt_http_method || return 1
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    prompt_http_post_body || return 1
  else
    HTTP_REQUEST_BODY=""
    HTTP_REQUEST_CONTENT_TYPE=""
  fi

  request_path="$(join_context_root_and_path "$INTERACTION_CONTEXT_ROOT" "$HTTP_REQUEST_PATH")"
  request_url="http://${host_for_url}:${INTERACTION_HTTP_PORT}${request_path}"
  if ! INTERACTIVE_HTTP_BODY_FILE="$(mktemp 2>/dev/null)"; then
    err "HTTP レスポンス保存用の一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$INTERACTIVE_HTTP_BODY_FILE"

  curl_opts=(-sS --noproxy '*' --max-time "$URL_TIMEOUT" --output "$INTERACTIVE_HTTP_BODY_FILE" \
    --write-out '%{http_code}' --request "$HTTP_REQUEST_METHOD")
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    curl_opts+=(--header "Content-Type: ${HTTP_REQUEST_CONTENT_TYPE}")
    # 入力したボディをプロセス一覧へ露出させないよう、curl の標準入力から渡す。
    curl_opts+=(--data-binary @-)
  fi

  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    status_code="$(printf '%s' "$HTTP_REQUEST_BODY" | curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  else
    status_code="$(curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  fi
  [ -n "$status_code" ] || status_code="000"
  show_interactive_http_response "$HTTP_REQUEST_METHOD" "$request_url" "$status_code"
  rm -f -- "$INTERACTIVE_HTTP_BODY_FILE"
  INTERACTIVE_HTTP_BODY_FILE=""

  if [ "$curl_status" -ne 0 ]; then
    err "curl による HTTP 通信に失敗しました (exit=${curl_status}, HTTP=${status_code})。"
    return 1
  fi
  return 0
}

# 選択された Compose サービスについて、今回の compose up 以降のログを
# --startup-log-lines の表示件数で出力する。明示的な対話操作なので、
# --suppress-startup-logs が指定されていてもここでは抑制しない。
show_interactive_compose_service_logs() {
  local service_name="$1" logs

  if ! logs="$(compose_logs "$service_name")"; then
    err "Compose サービス '${service_name}' のログを取得できませんでした。"
    [ -n "$logs" ] && printf '%s\n' "$logs" >&2
    return 1
  fi
  show_startup_logs "$logs" "サービス: ${service_name}" "false" "Compose サービスログ"
}

# healthcheck の設定・履歴・応答には URL や認証関連パラメータが含まれ得るため、
# 画面や build_and_push.sh のログへ残す前に、明示的な機微値だけを伏せ字にする。
redact_healthcheck_text() {
  LC_ALL=C sed -E \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#([?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)=)[^&[:space:]]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=[[:space:]]*")[^"]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=[[:space:]]*)[^[:space:];]+#\1[REDACTED]#Ig' \
    -e 's#((authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token)[[:space:]]*:[[:space:]]*).*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"?[[:space:]]*:[[:space:]]*")[^"]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"?[[:space:]]*:[[:space:]]*"?)[^",}[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(^|[[:space:]])(--(password|passwd|secret|token|authorization|cookie|api[_-]?key|credential))([=[:space:]]+)[^[:space:]]+#\1\2\4[REDACTED]#Ig' \
    -e 's#(^|[[:space:]])(-u|--user)([=[:space:]]*)[^[:space:]]+#\1\2\3[REDACTED]#g' \
    -e 's#(^|[[:space:]])-p[^$[:space:]][^[:space:]]*#\1-p[REDACTED]#g'
}

# healthcheck の手動再実行や HTTP 補助プローブの出力を、端末を圧迫しない範囲で表示する。
print_healthcheck_capture() {
  local capture_file="$1" empty_message="$2"
  local byte_count display_limit=32768

  if [ ! -s "$capture_file" ]; then
    diag "$empty_message"
    return 0
  fi
  byte_count="$(wc -c < "$capture_file" | tr -d '[:space:]')"
  case "$byte_count" in
    ''|*[!0-9]*) byte_count=0 ;;
  esac
  if [ "$byte_count" -gt "$display_limit" ]; then
    head -c "$display_limit" "$capture_file" | redact_healthcheck_text >&2
    printf '\n' >&2
    diag "... healthcheck 診断出力を ${display_limit}/${byte_count} bytes で省略しました。"
  else
    redact_healthcheck_text < "$capture_file" >&2
    printf '\n' >&2
  fi
}

# ---- healthcheck の実行手段解決 ---------------------------------------------
# adot-collector のような distroless イメージには /bin/sh が無く、CMD-SHELL 形式の
# healthcheck や補助スクリプトをそのまま実行できない。利用できるシェルを順に探し、
# 見つからない場合は呼び出し側でシェル不要の方式へ切り替える。
CONTAINER_SHELL_CACHE_ID=""
CONTAINER_SHELL_CACHE_PATH=""
detect_container_shell() {
  local container_id="$1" shell_candidate
  if [ "$CONTAINER_SHELL_CACHE_ID" != "$container_id" ]; then
    CONTAINER_SHELL_CACHE_ID="$container_id"
    CONTAINER_SHELL_CACHE_PATH=""
    for shell_candidate in /bin/sh /bin/bash /bin/ash /busybox/sh /usr/bin/sh /usr/bin/bash; do
      if docker exec "$container_id" "$shell_candidate" -c 'exit 0' >/dev/null 2>&1; then
        CONTAINER_SHELL_CACHE_PATH="$shell_candidate"
        break
      fi
    done
  fi
  [ -n "$CONTAINER_SHELL_CACHE_PATH" ] || return 1
  printf '%s\n' "$CONTAINER_SHELL_CACHE_PATH"
}

# Config.Healthcheck.Test を取得して配列へ格納する。healthcheck 未設定なら 1 を返す。
HEALTHCHECK_TEST_LINES=()
load_container_healthcheck_test() {
  local container_id="$1" test_text
  HEALTHCHECK_TEST_LINES=()
  test_text="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' \
      "$container_id" 2>/dev/null
  )" || return 1
  [ -n "$test_text" ] || return 1
  mapfile -t HEALTHCHECK_TEST_LINES <<< "$test_text"
  case "${HEALTHCHECK_TEST_LINES[0]:-}" in
    ''|NONE)
      HEALTHCHECK_TEST_LINES=()
      return 1
      ;;
  esac
  return 0
}

# healthcheck 定義 (Test 配列) から、形式・表示用コマンド文字列・実行ファイルパスを
# 組み立てる。CMD / CMD-SHELL 以外は 1 を返す。
HEALTHCHECK_MODE=""
HEALTHCHECK_COMMAND_TEXT=""
HEALTHCHECK_EXECUTABLE_PATH=""
parse_healthcheck_test() {
  local -a test_lines=("$@")

  HEALTHCHECK_MODE="${test_lines[0]:-}"
  HEALTHCHECK_COMMAND_TEXT=""
  HEALTHCHECK_EXECUTABLE_PATH=""
  case "$HEALTHCHECK_MODE" in
    CMD-SHELL)
      HEALTHCHECK_COMMAND_TEXT="${test_lines[1]:-}"
      if [ ${#test_lines[@]} -gt 2 ]; then
        HEALTHCHECK_COMMAND_TEXT+=$'\n'
        HEALTHCHECK_COMMAND_TEXT+="$(printf '%s\n' "${test_lines[@]:2}")"
      fi
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_COMMAND_TEXT%%[[:space:]]*}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH#\"}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH%\"}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH#\'}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH%\'}"
      ;;
    CMD)
      printf -v HEALTHCHECK_COMMAND_TEXT '%q ' "${test_lines[@]:1}"
      HEALTHCHECK_COMMAND_TEXT="${HEALTHCHECK_COMMAND_TEXT% }"
      HEALTHCHECK_EXECUTABLE_PATH="${test_lines[1]:-}"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# CMD-SHELL のコマンド文字列を、シェル無しで実行できる引数列へ分解する。
# healthcheck で定型的な `... || exit N` だけは取り除き、それ以外のシェル構文
# (パイプ・リダイレクト・変数展開・クォート) を含む場合は変換しない。
HEALTHCHECK_DIRECT_ARGV=()
build_healthcheck_direct_argv() {
  local command_text="$1" core="$1" trailer

  HEALTHCHECK_DIRECT_ARGV=()
  case "$core" in
    *'||'*)
      trailer="${core#*||}"
      core="${core%%||*}"
      printf '%s' "$trailer" \
        | grep -Eq '^[[:space:]]*exit[[:space:]]+[0-9]+[[:space:]]*$' || return 1
      ;;
  esac
  printf '%s' "$core" \
    | grep -Eq '^[[:space:]]*[A-Za-z0-9_./-]+([[:space:]]+[A-Za-z0-9_./:@=,%?&#+-]+)*[[:space:]]*$' \
    || return 1
  read -r -a HEALTHCHECK_DIRECT_ARGV <<< "$core"
  [ ${#HEALTHCHECK_DIRECT_ARGV[@]} -gt 0 ] || return 1
  return 0
}

# healthcheck コマンドをコンテナ内で実行する。実行手段を次の順に切り替える。
#   1) CMD 形式        : docker exec で直接実行 (シェル不要)
#   2) CMD-SHELL 形式  : コンテナ内シェル (/bin/sh または代替シェル) で実行
#   3) シェルが無い場合: シェル構文を含まなければ引数へ分解して直接実行
# どの手段も使えない場合は 125 を返し、呼び出し側で HTTP 等の別方式へ切り替える。
HEALTHCHECK_TIMEOUT_RUNNER=()
HEALTHCHECK_EXEC_METHOD=""
HEALTHCHECK_EXEC_AVAILABLE="false"
run_healthcheck_command_with_fallback() {
  local container_id="$1" health_mode="$2" health_command_text="$3" output_file="$4"
  shift 4
  local -a command_argv=("$@")
  local shell_path status=0

  HEALTHCHECK_EXEC_METHOD=""
  HEALTHCHECK_EXEC_AVAILABLE="false"

  if [ "$health_mode" = "CMD" ]; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="docker exec で直接実行 (コンテナ内シェル不要)"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "${command_argv[@]}" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  if shell_path="$(detect_container_shell "$container_id")"; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="コンテナ内シェル ${shell_path} で実行"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "$shell_path" -c "$health_command_text" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  if build_healthcheck_direct_argv "$health_command_text"; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="コンテナ内にシェルが無いため docker exec で直接実行: ${HEALTHCHECK_DIRECT_ARGV[*]}"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "${HEALTHCHECK_DIRECT_ARGV[@]}" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  HEALTHCHECK_EXEC_METHOD="コンテナ内にシェルが無く、シェル構文を含むコマンドのため実行不可"
  return 125
}

# healthcheck URL (コンテナ内から見たアドレス) を、ホストから到達できる URL へ変換する。
# 公開ポートを優先し、未公開ならコンテナ IP を使う。解決できない場合は 1 を返す。
resolve_healthcheck_url_for_host() {
  local container_id="$1" url="$2"
  local scheme rest hostport path port mapping mapped_host mapped_port container_ip host_for_url

  case "$url" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  scheme="${url%%://*}"
  rest="${url#*://}"
  case "$rest" in
    */*)
      hostport="${rest%%/*}"
      path="/${rest#*/}"
      ;;
    *)
      hostport="$rest"
      path="/"
      ;;
  esac
  case "$hostport" in
    \[*\]:*) port="${hostport##*:}" ;;
    \[*\])   port="" ;;
    *:*)     port="${hostport##*:}" ;;
    *)       port="" ;;
  esac
  if [ -z "$port" ]; then
    case "$scheme" in
      https) port="443" ;;
      *)     port="80" ;;
    esac
  fi
  printf '%s' "$port" | grep -qE '^[0-9]+$' || return 1

  mapping="$(docker port "$container_id" "${port}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      host_for_url="$mapped_host"
      case "$host_for_url" in
        *:*) host_for_url="[${host_for_url}]" ;;
      esac
      printf '%s://%s:%s%s\n' "$scheme" "$host_for_url" "$mapped_port" "$path"
      return 0
    fi
  fi

  container_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      "$container_id" 2>/dev/null | sed -n '/./{p;q;}' || true
  )"
  [ -n "$container_ip" ] || return 1
  host_for_url="$container_ip"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac
  printf '%s://%s:%s%s\n' "$scheme" "$host_for_url" "$port" "$path"
}

# 自動確認の手段が尽きた場合に、利用者が手元で実行できるコマンドを案内する。
# 認証情報の混入を避けるため、コマンド行は伏せ字処理を通して表示する。
print_healthcheck_manual_commands() {
  local service_name="$1" container_name="$2" health_mode="$3"
  local health_command_text="$4" http_url="$5" container_id="$6"
  local host_url=""

  diag ""
  diag "[手動で確認する場合のコマンド]"
  diag "  # Docker が記録した healthcheck の状態と履歴 (コンテナ内シェル不要)"
  diag "  docker inspect --format '{{json .State.Health}}' ${container_name}"
  diag "  # コンテナのログから稼働状況を確認"
  diag "  ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} logs ${service_name}"
  case "$health_mode" in
    CMD)
      diag "  # healthcheck と同じコマンドを直接実行 (シェル不要)"
      printf '  docker exec %s %s\n' "$container_name" "$health_command_text" \
        | redact_healthcheck_text >&2
      ;;
    CMD-SHELL)
      diag "  # シェルを持つイメージであれば同じコマンド文字列を実行"
      printf "  docker exec %s /bin/sh -c '%s'\n" "$container_name" "$health_command_text" \
        | redact_healthcheck_text >&2
      ;;
  esac
  if [ -n "$http_url" ]; then
    host_url="$(resolve_healthcheck_url_for_host "$container_id" "$http_url" || true)"
    diag "  # 対象コンテナのネットワークを借りた一時コンテナから HTTP 確認"
    diag "  # (対象イメージに curl/wget が無くても確認できる)"
    printf '  docker run --rm --network container:%s curlimages/curl:latest -sS -i %s\n' \
      "$container_name" "$http_url" | redact_healthcheck_text >&2
    if [ -n "$host_url" ]; then
      diag "  # ホストから公開ポート経由で HTTP 確認"
      printf '  curl -sS -i %s\n' "$host_url" | redact_healthcheck_text >&2
    fi
  fi
}

# CMD 形式で直接指定された /healthcheck 等について、実際に呼ばれるファイルの
# 存在・実行権限・内容識別用 SHA-256 をコンテナ内で確認する。
# シェルを持たないイメージでは確認できないため、その旨だけを表示する。
show_healthcheck_executable_file() {
  local container_id="$1" executable_path="$2" file_info file_status=0 shell_path

  case "$executable_path" in
    /*) ;;
    *) return 0 ;;
  esac

  if ! shell_path="$(detect_container_shell "$container_id")"; then
    diag ""
    diag "[healthcheck 実行ファイル]"
    diag "コンテナ内にシェルが無いため、ファイル情報を取得できません: ${executable_path}"
    diag "イメージ側から確認する場合: docker cp <コンテナ>:${executable_path} ./healthcheck-binary"
    return 0
  fi

  file_info="$(
    docker exec "$container_id" "$shell_path" -c '
      target=$1
      if [ ! -e "$target" ]; then
        printf "ファイル: %s (存在しません)\n" "$target"
        exit 66
      fi
      printf "ファイル: %s\n" "$target"
      ls -ld -- "$target" 2>/dev/null || ls -ld "$target"
      if [ -x "$target" ]; then
        printf "実行権限: あり\n"
      else
        printf "実行権限: なし\n"
      fi
      if [ -f "$target" ] && command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$target" 2>/dev/null || sha256sum "$target"
      elif [ -f "$target" ] && command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$target"
      else
        printf "SHA-256: 算出ツールなし、または通常ファイルではないため未取得\n"
      fi
    ' healthcheck-file "$executable_path" 2>&1
  )" || file_status=$?

  diag ""
  diag "[healthcheck 実行ファイル]"
  printf '%s\n' "$file_info" | redact_healthcheck_text >&2
  if [ "$file_status" -ne 0 ]; then
    warn "healthcheck 実行ファイルを完全には確認できませんでした (exit=${file_status})。"
  fi
}

# curl の通信メトリクス出力書式 (コンテナ側・ホスト側の補助リクエストで共用)。
HEALTHCHECK_CURL_METRICS_FORMAT='
[通信メトリクス]
http_status=%{http_code}
remote=%{remote_ip}:%{remote_port}
local=%{local_ip}:%{local_port}
time_connect=%{time_connect}s
time_starttransfer=%{time_starttransfer}s
time_total=%{time_total}s
size_download=%{size_download} bytes
'

# ホスト側にある HTTP クライアントを返す (curl 優先、無ければ wget)。
detect_host_http_tool() {
  local tool
  for tool in curl wget; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
      return 0
    fi
  done
  return 1
}

# ホストから URL へ補助リクエストを送る。コンテナ内にシェルや curl/wget が無い
# (distroless イメージ等) 場合のフォールバック経路。
run_healthcheck_http_probe_on_host() {
  local tool="$1" request_method="$2" request_url="$3" output_file="$4"
  local status=0
  local -a curl_args=()

  case "$tool" in
    curl)
      curl_args=(--silent --show-error --verbose --include --noproxy '*'
        --max-time "$URL_TIMEOUT" --max-filesize 1048576
        --write-out "$HEALTHCHECK_CURL_METRICS_FORMAT")
      if [ "$request_method" = "HEAD" ]; then
        curl_args+=(--head)
      fi
      curl "${curl_args[@]}" "$request_url" >"$output_file" 2>&1 || status=$?
      ;;
    wget)
      wget -S -O - -T "$URL_TIMEOUT" "$request_url" >"$output_file" 2>&1 || status=$?
      ;;
    *)
      return 125
      ;;
  esac
  return "$status"
}

# 単純な curl / wget の HTTP healthcheck について、元のチェックとは別のボディなし
# 補助リクエストを同じコンテナのネットワーク名前空間から送り、ヘッダー・本文・
# 接続メトリクスを表示する。認証ヘッダーやリクエストボディを伴う複雑な設定は扱わない。
# コンテナにシェルが無い、または curl/wget が無い場合は、公開ポート (無ければ
# コンテナ IP) へホスト側から送り直して確認する。
run_healthcheck_http_probe() {
  local container_id="$1" probe_kind="$2" request_method="$3" request_url="$4"
  local probe_status=0 probe_script shell_path="" probe_origin="" probe_url="$request_url"
  local container_probe_done="false" host_tool="" host_url=""

  case "$probe_kind" in
    curl|wget) ;;
    *) return 1 ;;
  esac
  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "healthcheck HTTP 通信の保存用一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"

  if shell_path="$(detect_container_shell "$container_id")"; then
    container_probe_done="true"
    probe_origin="選択したコンテナのネットワーク名前空間 (${shell_path})"
    case "$probe_kind" in
      curl)
        probe_script="$(cat <<HEALTHCHECK_CURL_PROBE
set -u
health_url=\$1
health_timeout=\$2
health_method=\$3
if ! command -v curl >/dev/null 2>&1; then
  printf "curl がコンテナ内にありません。\n" >&2
  exit 127
fi
set -- \\
  --silent \\
  --show-error \\
  --verbose \\
  --include \\
  --max-time "\$health_timeout" \\
  --max-filesize 1048576 \\
  --write-out '${HEALTHCHECK_CURL_METRICS_FORMAT}'
if [ "\$health_method" = "HEAD" ]; then
  set -- "\$@" --head
fi
exec curl "\$@" "\$health_url"
HEALTHCHECK_CURL_PROBE
)"
        docker exec "$container_id" "$shell_path" -c "$probe_script" \
          healthcheck-http-probe "$request_url" "$URL_TIMEOUT" "$request_method" \
          >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1 || probe_status=$?
        ;;
      wget)
        probe_script="$(cat <<'HEALTHCHECK_WGET_PROBE'
set -u
health_url=$1
health_timeout=$2
if ! command -v wget >/dev/null 2>&1; then
  printf "wget がコンテナ内にありません。\n" >&2
  exit 127
fi
exec wget -S -O - -T "$health_timeout" "$health_url"
HEALTHCHECK_WGET_PROBE
)"
        docker exec "$container_id" "$shell_path" -c "$probe_script" \
          healthcheck-http-probe "$request_url" "$URL_TIMEOUT" \
          >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1 || probe_status=$?
        ;;
    esac
  fi

  # コンテナ内で実行できない (シェル無し)、または curl/wget が無い (exit 127) 場合は、
  # ホストから到達できる URL へ切り替えて同じ確認を試みる。
  if [ "$container_probe_done" != "true" ] || [ "$probe_status" -eq 127 ]; then
    if [ "$container_probe_done" = "true" ]; then
      warn "コンテナ内に ${probe_kind} が無いため、ホストからの HTTP 確認へ切り替えます。"
    else
      warn "コンテナ内にシェルが無いため、ホストからの HTTP 確認へ切り替えます。"
    fi
    if host_url="$(resolve_healthcheck_url_for_host "$container_id" "$request_url")" \
        && host_tool="$(detect_host_http_tool)"; then
      probe_url="$host_url"
      probe_origin="ホスト (${host_tool}、コンテナへは公開ポート/コンテナ IP 経由)"
      probe_status=0
      : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
      run_healthcheck_http_probe_on_host \
        "$host_tool" "$request_method" "$host_url" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
        || probe_status=$?
    elif [ "$container_probe_done" != "true" ]; then
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      warn "コンテナ内でもホストからも HTTP 確認を実行できませんでした。"
      return 125
    fi
  fi

  diag ""
  diag "[HTTP healthcheck 通信詳細（補助リクエスト）]"
  diag "送信元     : ${probe_origin}"
  printf 'リクエスト : [%s] %s\n' "$request_method" "$probe_url" \
    | redact_healthcheck_text >&2
  diag "追加ヘッダー/ボディ: なし（通信詳細取得用の補助リクエスト）"
  diag "終了コード : ${probe_status}"
  diag "レスポンス : ヘッダー、本文、または接続エラー（最大 32768 bytes）"
  diag "───────────────────────────────────────────────────────────────────"
  print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "(レスポンス本文・ヘッダー・接続エラー出力はありません)"
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""
  if [ "$probe_status" -ne 0 ]; then
    warn "healthcheck の HTTP 補助リクエストに失敗しました (exit=${probe_status})。"
  fi
  # 呼び出し側が「別方式でも確認できなかった」を判断できるよう、実際の結果を返す。
  return "$probe_status"
}

# healthcheck コマンドから安全に再送できる単純な HTTP(S) URL を抽出し、
# curl / wget の補助プローブへ振り分ける。URL が無い、または補助リクエストを
# 自動生成できない場合は、手元で実行できるコマンドを案内する。
run_healthcheck_http_details() {
  local container_id="$1" health_command_text="$2"
  local service_name="${3:-}" container_name="${4:-}" health_mode="${5:-}"
  local http_url probe_kind="" request_method="GET" probe_status=0

  http_url="$(
    printf '%s\n' "$health_command_text" \
      | grep -Eo "https?://[^[:space:]\"'<>|;&)]+" \
      | head -n 1 || true
  )"
  if [ -z "$http_url" ]; then
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "HTTP(S) URL を含む healthcheck ではないため、HTTP 補助リクエストは対象外です。"
    diag "通信成否とコマンド出力は、Docker 実行履歴および手動再実行結果を確認してください。"
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ] && [ -n "$container_name" ]; then
      print_healthcheck_manual_commands "$service_name" "$container_name" \
        "$health_mode" "$health_command_text" "" "$container_id"
    fi
    return 0
  fi
  if printf '%s\n' "$http_url" \
      | grep -qiE '://[^/@[:space:]]+:[^/@[:space:]]+@|[?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)='; then
    warn "healthcheck URL に認証情報らしき値が含まれるため、コマンドライン露出を避けて HTTP 補助リクエストをスキップします。"
    return 0
  fi
  case "$http_url" in
    *'$'*|*'`'*)
      warn "healthcheck URL にシェル展開が必要なため、HTTP 補助リクエストをスキップします: ${http_url}"
      return 0
      ;;
  esac

  if printf '%s\n' "$health_command_text" \
      | grep -Eq '(^|[[:space:];|&()])curl([[:space:]]|$)'; then
    probe_kind="curl"
    if printf ' %s ' "$health_command_text" \
        | grep -Eq '(^|[[:space:]])(-X|--request|-d|--data[^[:space:]]*|-H|--header|-u|--user)([=[:space:]]|$)'; then
      warn "healthcheck にメソッド・ヘッダー・ボディ・認証の指定があるため、安全な HTTP 補助リクエストを自動生成できません。"
      diag "正確な実行結果は上の手動再実行結果を確認してください。"
      if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ] && [ -n "$container_name" ]; then
        print_healthcheck_manual_commands "$service_name" "$container_name" \
          "$health_mode" "$health_command_text" "$http_url" "$container_id"
      fi
      return 0
    fi
    if printf ' %s ' "$health_command_text" \
        | grep -Eq '(^|[[:space:]])(-I|--head)([[:space:]]|$)'; then
      request_method="HEAD"
    fi
  elif printf '%s\n' "$health_command_text" \
      | grep -Eq '(^|[[:space:];|&()])wget([[:space:]]|$)'; then
    probe_kind="wget"
  elif [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; then
    # 専用バイナリ等でコマンドを再実行できない場合でも、URL が判明していれば
    # 同じ URL への HTTP 確認で代替できるため、curl 相当の補助リクエストを試みる。
    probe_kind="curl"
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "healthcheck コマンドを再実行できないため、検出した URL への HTTP 確認で代替します。"
  else
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "HTTP(S) URL は検出しましたが、curl / wget 以外のため補助リクエストは実行しません。"
    diag "正確な実行結果は上の手動再実行結果を確認してください。"
    return 0
  fi

  run_healthcheck_http_probe "$container_id" "$probe_kind" "$request_method" "$http_url" \
    || probe_status=$?
  if [ "$probe_status" -eq 0 ]; then
    diag "注意: 補助リクエストは単純な GET/HEAD の通信詳細取得用で、Docker の health 状態・履歴を更新しません。"
  fi
  if [ -n "$container_name" ] \
      && { [ "$probe_status" -ne 0 ] || [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; }; then
    print_healthcheck_manual_commands "$service_name" "$container_name" \
      "$health_mode" "$health_command_text" "$http_url" "$container_id"
  fi
  return 0
}

# 選択された Compose サービスの Docker healthcheck を診断する。
# Docker が実際に実行した直近履歴と、現在時点での同一コマンド手動再実行を分けて表示する。
run_interactive_compose_healthcheck() {
  local service_name="$1" container_id container_name health_test_text health_mode
  local health_config health_state health_status health_failing_streak health_history
  local health_state_loaded="true" health_history_loaded="true"
  local retained_count=0 health_command_text="" health_command_display=""
  local executable_path="" exact_started_at exact_finished_at exact_started_epoch exact_finished_epoch
  local exact_timeout_label exact_status=0
  local -a container_ids=() health_test=() exact_runner=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  if ! health_test_text="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' \
      "$container_id"
  )"; then
    err "コンテナの healthcheck 設定を取得できませんでした: ${container_name}"
    return 1
  fi
  if [ -n "$health_test_text" ]; then
    mapfile -t health_test <<< "$health_test_text"
  fi
  health_mode="${health_test[0]:-}"

  diag ""
  diag "════════════════ Docker healthcheck 診断 ════════════════"
  diag "Compose サービス : ${service_name}"
  diag "コンテナ         : ${container_name}"
  if [ -z "$health_mode" ] || [ "$health_mode" = "NONE" ]; then
    diag "設定             : healthcheck は設定されていません。"
    diag "Docker 実行履歴  : 対象外"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if parse_healthcheck_test "${health_test[@]}"; then
    health_command_text="$HEALTHCHECK_COMMAND_TEXT"
    health_command_display="$health_command_text"
    executable_path="$HEALTHCHECK_EXECUTABLE_PATH"
  else
    warn "未対応の healthcheck 形式です: ${health_mode}"
    diag "設定値:"
    printf '%s\n' "$health_test_text" | redact_healthcheck_text >&2
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if ! health_config="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}interval={{.Config.Healthcheck.Interval}}{{"\n"}}timeout={{.Config.Healthcheck.Timeout}}{{"\n"}}retries={{.Config.Healthcheck.Retries}}{{"\n"}}start_period={{.Config.Healthcheck.StartPeriod}}{{end}}' \
      "$container_id"
  )"; then
    health_config="(取得失敗)"
  fi
  if ! health_state="$(
    docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}|{{.State.Health.FailingStreak}}{{end}}' \
      "$container_id" 2>/dev/null
  )"; then
    health_state=""
    health_state_loaded="false"
  fi
  if ! health_history="$(
    docker inspect -f \
      '{{if .State.Health}}{{range .State.Health.Log}}開始: {{.Start}}{{"\n"}}終了: {{.End}}{{"\n"}}終了コード: {{.ExitCode}}{{"\n"}}出力:{{"\n"}}{{.Output}}{{"\n"}}────────────────────{{"\n"}}{{end}}{{end}}' \
      "$container_id" 2>/dev/null
  )"; then
    health_history=""
    health_history_loaded="false"
  fi

  diag ""
  diag "[設定（Docker に反映された Config.Healthcheck）]"
  diag "形式:"
  diag "  ${health_mode}"
  diag "コマンド:"
  printf '%s\n' "$health_command_display" | redact_healthcheck_text >&2
  printf '%s\n' "$health_config" | sed 's/^/  /' >&2

  diag ""
  diag "[Docker が実際に実行した healthcheck]"
  if [ "$health_state_loaded" != "true" ]; then
    diag "現在状態       : Docker inspect に失敗したため未取得"
    diag "連続失敗回数   : 未取得"
  elif [ -n "$health_state" ]; then
    health_status="${health_state%%|*}"
    health_failing_streak="${health_state#*|}"
    diag "現在状態       : ${health_status}"
    diag "連続失敗回数   : ${health_failing_streak}"
  else
    diag "現在状態       : Docker の health 状態はまだ生成されていません。"
    diag "連続失敗回数   : 未取得"
  fi
  if [ "$health_history_loaded" != "true" ]; then
    diag "保持された履歴 : Docker inspect に失敗したため未取得"
  elif [ -n "$health_history" ]; then
    retained_count="$(printf '%s\n' "$health_history" | grep -c '^開始: ' || true)"
    diag "保持された履歴 : ${retained_count} 件 (時刻は JST 表記へ変換)"
    diag "───────────────────────────────────────────────────────────────────"
    printf '%s\n' "$health_history" | rewrite_health_history_time | redact_healthcheck_text >&2
  else
    diag "保持された履歴 : 0 件（まだ未実行、または Docker が履歴を保持していません）"
  fi

  case "$executable_path" in
    /*) show_healthcheck_executable_file "$container_id" "$executable_path" ;;
  esac

  if printf '%s\n' "$health_command_text" \
      | grep -qiE '://[^/@[:space:]]+:[^/@[:space:]]+@|[?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)=|(^|[[:space:];])(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=|(^|[[:space:]])(-u[^[:space:]]*:[^[:space:]]+|(-u|--user)(=|[[:space:]])+[^[:space:]]*:[^[:space:]]+)|(^|[[:space:]])--(password|passwd|secret|token|authorization|cookie|api[_-]?key|credential)([=[:space:]]|$)|(^|[[:space:]])-p[^$[:space:]]|(authorization|proxy-authorization|cookie|x-api-key|api-key|x-auth-token)[[:space:]]*:'; then
    warn "healthcheck コマンドに認証情報らしき指定があるため、ホストのプロセス引数への露出を避けて手動再実行と HTTP 補助リクエストをスキップします。"
    diag "Docker が実際に実行した結果は、上の State.Health と実行履歴を確認してください。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if [ ${#health_test[@]} -lt 2 ] || [ -z "$health_command_text" ]; then
    warn "healthcheck の実行コマンドが空のため、手動再実行をスキップします。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "healthcheck 手動再実行の保存用一時ファイルを作成できませんでした。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
  if command -v timeout >/dev/null 2>&1; then
    exact_runner=(timeout "${URL_TIMEOUT}s")
    exact_timeout_label="${URL_TIMEOUT} 秒 (--url-timeout)"
  else
    exact_timeout_label="未適用 (timeout コマンドなし)"
    warn "ホストに timeout コマンドがないため、healthcheck 手動再実行へ時間上限を適用できません。"
  fi
  HEALTHCHECK_TIMEOUT_RUNNER=(${exact_runner[@]+"${exact_runner[@]}"})
  exact_started_at="$(now_display_time)"
  exact_started_epoch="$(date +%s)"
  run_healthcheck_command_with_fallback \
    "$container_id" "$health_mode" "$health_command_text" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "${health_test[@]:1}" || exact_status=$?
  exact_finished_epoch="$(date +%s)"
  exact_finished_at="$(now_display_time)"

  diag ""
  diag "[現在時点の healthcheck コマンド手動再実行]"
  diag "注意: この手動再実行は Docker の health 状態・履歴を更新しません。"
  diag "実行方式   : ${HEALTHCHECK_EXEC_METHOD}"
  if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; then
    # /bin/sh が無いイメージ (distroless 等) では、コマンドをそのまま再実行できない。
    # HTTP など別方式での確認と、手元で実行できるコマンドの案内へ切り替える。
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
    warn "コンテナ内で healthcheck コマンドを再実行できないため、別方式での確認へ切り替えます。"
    diag "Docker が実際に実行した結果は、上の State.Health と実行履歴を確認してください。"
    run_healthcheck_http_details \
      "$container_id" "$health_command_text" "$service_name" "$container_name" "$health_mode"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  diag "開始       : ${exact_started_at}"
  diag "終了       : ${exact_finished_at}"
  diag "実行上限   : ${exact_timeout_label}"
  diag "所要時間   : $(( exact_finished_epoch - exact_started_epoch )) 秒"
  diag "終了コード : ${exact_status}"
  diag "stdout/stderr（最大 32768 bytes）:"
  diag "───────────────────────────────────────────────────────────────────"
  print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "(stdout/stderr 出力なし。終了コードで成否を確認してください)"
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""
  if [ "$exact_status" -eq 0 ]; then
    diag "手動再実行結果 : OK"
  else
    diag "手動再実行結果 : NG (exit=${exact_status})"
  fi

  run_healthcheck_http_details \
    "$container_id" "$health_command_text" "$service_name" "$container_name" "$health_mode"
  diag "════════════════════════════════════════════════════════"
  return 0
}

# 選択された Compose サービスの実行中コンテナへ対話式 bash で接続する。
# 同じシェルセッションが続くため、cd で移動しながら任意のコマンドを実行できる。
run_interactive_compose_bash() {
  local service_name="$1" container_id container_name
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  diag ""
  diag "Compose サービスの bash へ接続します (service=${service_name}, container=${container_name})。"
  diag "この bash セッション内では cd によるディレクトリ移動と任意のコマンド実行が可能です。"
  diag "bash を終了するとサービス操作の選択へ戻ります。コンテナは起動状態を維持します。"
  if ! docker exec -it "$container_id" /bin/bash; then
    err "Compose サービス '${service_name}' の /bin/bash へ接続できませんでした: ${container_name}"
    return 1
  fi
  log "コンテナの bash セッションを終了しました。サービス操作の選択へ戻ります。"
}

# 選択された Compose サービスが MySQL サーバーコンテナかを実行ファイルで判定する。
# サービス名やイメージタグへ依存せず、MySQL 8.0.42 と
# MySQL 8.4 / Aurora 8.4 互換系の双方を同じ経路で扱う。
compose_service_supports_mysql_client() {
  local service_name="$1" container_id
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  [ ${#container_ids[@]} -gt 0 ] || return 1
  container_id="${container_ids[0]}"
  docker exec "$container_id" /bin/sh -c '
    command -v mysql >/dev/null 2>&1 \
      && command -v mysqld >/dev/null 2>&1
  ' >/dev/null 2>&1
}

# MySQL コンテナ内の mysql クライアントへ接続し、SQL を対話実行する。
# 認証情報は Docker のコマンドラインへ含めず、コンテナ内で MYSQL_* または
# MYSQL_*_FILE から解決して、一時的なクライアントオプションファイルへ格納する。
run_interactive_compose_mysql() {
  local service_name="$1" container_id container_name mysql_client_script
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  mysql_client_script="$(cat <<'MYSQL_CLIENT_SCRIPT'
set -eu

read_mysql_setting() {
  _mysql_setting_value="$1"
  _mysql_setting_file="$2"
  _mysql_setting_name="$3"
  if [ -n "$_mysql_setting_value" ] && [ -n "$_mysql_setting_file" ]; then
    printf '%s と %s_FILE を同時には指定できません。\n' \
      "$_mysql_setting_name" "$_mysql_setting_name" >&2
    return 64
  fi
  if [ -n "$_mysql_setting_file" ]; then
    if [ ! -r "$_mysql_setting_file" ]; then
      printf '%s_FILE の参照先を読み取れません: %s\n' \
        "$_mysql_setting_name" "$_mysql_setting_file" >&2
      return 66
    fi
    cat -- "$_mysql_setting_file"
  else
    printf '%s' "$_mysql_setting_value"
  fi
}

# MySQL のオプションファイルで意味を持つバイトをエスケープする。
# LC_ALL=C と od を使い、改行を含む Docker secret も 1 行の値として安全に記録する。
escape_mysql_option_value() {
  LC_ALL=C od -An -v -t u1 | LC_ALL=C awk '
    {
      for (i = 1; i <= NF; i++) {
        byte = $i + 0
        if (byte == 8) {
          printf "\\b"
        } else if (byte == 9) {
          printf "\\t"
        } else if (byte == 10) {
          printf "\\n"
        } else if (byte == 13) {
          printf "\\r"
        } else if (byte == 34) {
          printf "\\\""
        } else if (byte == 92) {
          printf "\\\\"
        } else {
          printf "%c", byte
        }
      }
    }
  '
}

for mysql_required_command in mysql mktemp od awk cat rm; do
  if ! command -v "$mysql_required_command" >/dev/null 2>&1; then
    printf 'MySQL 接続に必要なコマンドがコンテナ内に見つかりません: %s\n' \
      "$mysql_required_command" >&2
    exit 127
  fi
done

mysql_configured_user="$(read_mysql_setting \
  "${MYSQL_USER:-}" "${MYSQL_USER_FILE:-}" MYSQL_USER)" || exit $?
mysql_database="$(read_mysql_setting \
  "${MYSQL_DATABASE:-}" "${MYSQL_DATABASE_FILE:-}" MYSQL_DATABASE)" || exit $?
mysql_password_known=false

if [ -n "$mysql_configured_user" ] && [ "$mysql_configured_user" != "root" ]; then
  mysql_user="$mysql_configured_user"
  mysql_password="$(read_mysql_setting \
    "${MYSQL_PASSWORD:-}" "${MYSQL_PASSWORD_FILE:-}" MYSQL_PASSWORD)" || exit $?
  if [ "${MYSQL_PASSWORD+x}" = "x" ] || [ -n "${MYSQL_PASSWORD_FILE:-}" ]; then
    mysql_password_known=true
  fi
else
  mysql_user=root
  mysql_password="$(read_mysql_setting \
    "${MYSQL_ROOT_PASSWORD:-}" "${MYSQL_ROOT_PASSWORD_FILE:-}" \
    MYSQL_ROOT_PASSWORD)" || exit $?
  if [ "${MYSQL_ROOT_PASSWORD+x}" = "x" ] \
      || [ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ] \
      || [ -n "${MYSQL_ALLOW_EMPTY_PASSWORD:-}" ]; then
    mysql_password_known=true
  fi
fi

umask 077
mysql_option_file="$(mktemp /tmp/build-and-verify-mysql-client.XXXXXX)"
cleanup_mysql_option_file() {
  rm -f -- "$mysql_option_file"
}
trap cleanup_mysql_option_file EXIT HUP INT TERM

{
  printf '[client]\n'
  if [ "$mysql_password_known" = "true" ]; then
    printf 'password="'
    printf '%s' "$mysql_password" | escape_mysql_option_value
    printf '"\n'
  fi
} > "$mysql_option_file"

set -- --defaults-extra-file="$mysql_option_file" --protocol=socket --user="$mysql_user"
if [ "$mysql_password_known" != "true" ]; then
  printf 'MYSQL_* からパスワードを解決できないため、ユーザー %s のパスワードを入力してください。\n' \
    "$mysql_user" >&2
  set -- "$@" --password
fi
if [ -n "$mysql_database" ]; then
  set -- "$@" --database="$mysql_database"
fi
mysql "$@"
MYSQL_CLIENT_SCRIPT
)"

  diag ""
  diag "MySQL クライアントへ接続します (service=${service_name}, container=${container_name})。"
  diag "SQL クエリを対話実行できます。終了するには exit または \\q を入力してください。"
  diag "MySQL クライアントを終了するとサービス操作の選択へ戻ります。"
  if ! docker exec -it "$container_id" /bin/sh -c "$mysql_client_script"; then
    err "Compose サービス '${service_name}' の MySQL クライアントへ接続できませんでした: ${container_name}"
    return 1
  fi
  log "MySQL セッションを終了しました。サービス操作の選択へ戻ります。"
}

# 可観測性ヘルパーの JSON は認証ヘッダー等を含み得るため、生データを表示せず
# Python 3 で必要な項目だけを抽出する。logs モード全体の必須依存にはせず、
# 専用ヘルパーが選択された時点で利用可否を確認する。
resolve_observability_python() {
  local candidate

  [ -n "$OBSERVABILITY_PYTHON" ] && return 0
  for candidate in python3 python /usr/libexec/platform-python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
          >/dev/null 2>&1; then
      OBSERVABILITY_PYTHON="$candidate"
      return 0
    fi
  done
  err "可観測性ヘルパーの JSON 解析に必要な Python 3 が見つかりません。"
  err "python3、python (Python 3)、または /usr/libexec/platform-python を利用可能にしてください。"
  return 1
}

require_observability_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    err "可観測性ヘルパーの HTTP 確認に必要な curl が見つかりません。"
    return 1
  fi
  resolve_observability_python
}

# Compose サービスのコンテナ側 HTTP ポートをホストから到達できる URL へ解決する。
# 公開ポートを優先し、未公開の場合はコンテナ IP を使用する。
resolve_compose_service_http_endpoint() {
  local service_name="$1" container_port="$2"
  local container_id container_name mapping="" mapped_host="" mapped_port=""
  local container_ip="" host_for_url=""
  local -a container_ids=()

  OBSERVABILITY_HTTP_HOST=""
  OBSERVABILITY_HTTP_PORT=""
  OBSERVABILITY_HTTP_BASE_URL=""
  OBSERVABILITY_CONTAINER_NAME=""

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  mapping="$(docker port "$container_id" "${container_port}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      OBSERVABILITY_HTTP_HOST="$mapped_host"
      OBSERVABILITY_HTTP_PORT="$mapped_port"
    fi
  fi

  if [ -z "$OBSERVABILITY_HTTP_HOST" ]; then
    container_ip="$(
      docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
        "$container_id" 2>/dev/null | sed -n '/./{p;q;}' || true
    )"
    if [ -z "$container_ip" ]; then
      err "Compose サービス '${service_name}' の公開ポートまたはコンテナ IP を解決できませんでした。"
      return 1
    fi
    OBSERVABILITY_HTTP_HOST="$container_ip"
    OBSERVABILITY_HTTP_PORT="$container_port"
    warn "サービス '${service_name}' のポート ${container_port}/tcp は未公開のため、コンテナ IP (${container_ip}) へ接続します。"
  fi

  host_for_url="$OBSERVABILITY_HTTP_HOST"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac
  OBSERVABILITY_HTTP_BASE_URL="http://${host_for_url}:${OBSERVABILITY_HTTP_PORT}"
  OBSERVABILITY_CONTAINER_NAME="$container_name"
  log "Compose サービスの確認 URL を解決しました: ${service_name} -> ${OBSERVABILITY_HTTP_BASE_URL}"
}

# Python ヘルパーへ JSON を渡す共通経路。
# プロセス置換と追加 fd (3< <(...)) は、Windows 版 Python を使う Git Bash のように
# 子プロセスが 0-2 以外の fd を継承できない環境で失敗するため、標準入力へ NUL 区切りで
# 渡す方式に統一する。JSON テキストに NUL バイトは現れないため区切りとして安全で、
# 機微情報を含み得る JSON を一時ファイルやコマンドライン引数へ出さずに渡せる。
# 使い方: run_observability_python "<プログラム>" <JSON 個数> [JSON...] [プログラム引数...]
run_observability_python() {
  local program="$1" document_count="$2"
  shift 2
  local index
  local -a documents=()

  while [ "$document_count" -gt 0 ]; do
    documents+=("$1")
    shift
    document_count=$((document_count - 1))
  done
  # レポートは日本語と罫線文字を含むため、ロケール既定の文字コード (Windows の cp932 等)
  # で出力が落ちないよう UTF-8 を明示する。
  {
    for index in "${!documents[@]}"; do
      [ "$index" -eq 0 ] || printf '\000'
      printf '%s' "${documents[$index]}"
    done
  } | PYTHONIOENCODING=utf-8 "$OBSERVABILITY_PYTHON" -c "$program" "$@"
}

# 各 Python ヘルパーの先頭へ連結する、入出力の共通定義。
# プログラム本文側にも同じ import があるが、二重 import は無害。
OBSERVABILITY_PYTHON_JSON_LOADER='
import json
import sys

# Windows の Python は既定でロケール文字コード変換と LF -> CRLF 変換を行う。
# レポートの罫線が化けたり、シェルが受け取る値へ CR が混入したりしないよう明示する。
try:
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
except Exception:
    pass


def load_json_documents(labels):
    """標準入力の NUL 区切り JSON を、labels の順に解析して返す。"""
    chunks = sys.stdin.buffer.read().split(b"\0")
    documents = []
    for index, label in enumerate(labels):
        chunk = chunks[index] if index < len(chunks) else b""
        try:
            documents.append(json.loads(chunk.decode("utf-8")))
        except Exception as exc:
            print(f"[ERROR] {label} の JSON を解析できません: {exc}", file=sys.stderr)
            raise SystemExit(2)
    return documents
'

observability_http_get() {
  curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" "$1"
}

observability_http_post_json() {
  local url="$1"
  curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" \
    --request POST --header "Content-Type: application/json" \
    --data-binary @- "$url"
}

wiremock_request_count() {
  local base_url="$1" target="$2" payload response

  payload="$(printf '{"method":"POST","url":"/","headers":{"X-Amz-Target":{"equalTo":"%s"}}}' "$target")"
  if ! response="$(printf '%s' "$payload" | observability_http_post_json "${base_url}/__admin/requests/count")"; then
    return 1
  fi
  # 改行を書かずに返し、Windows の Python が付ける CR が値へ混ざらないようにする。
  printf '%s' "$response" | PYTHONIOENCODING=utf-8 "$OBSERVABILITY_PYTHON" -c \
    'import json,sys; value=json.load(sys.stdin).get("count"); sys.stdout.write(str(value) if isinstance(value, int) else "?")'
}

# 標準入力の 1 つ目に cwagent 設定、2 つ目に WireMock request journal を受け取る。
# Authorization 等のヘッダーは読み捨て、設定済み送信先と PutLogEvents 本文だけを表示する。
render_cloudwatch_delivery_report() {
  local config_json="$1" journal_json="$2"
  local create_group_count="$3" create_stream_count="$4" put_count="$5"
  local program

  program="$(cat <<'PY'
import base64
import datetime
import json
import re
import sys


def header_value(request, name):
    headers = request.get("headers") or {}
    value = headers.get(name)
    if value is None:
        for key, candidate in headers.items():
            if str(key).lower() == name.lower():
                value = candidate
                break
    if isinstance(value, list):
        return str(value[0]) if value else ""
    if isinstance(value, dict):
        values = value.get("values")
        if isinstance(values, list):
            return str(values[0]) if values else ""
        return str(value.get("value") or "")
    return str(value or "")


def request_body(request):
    body = request.get("body")
    if isinstance(body, dict):
        return body
    if isinstance(body, str) and body:
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}
    encoded = request.get("bodyAsBase64")
    if encoded:
        try:
            return json.loads(base64.b64decode(encoded).decode("utf-8"))
        except Exception:
            return {}
    return {}


def clean_text(value, limit=500):
    text = str(value if value is not None else "")
    text = text.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    text = re.sub(
        r"(?i)\b(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"
        r"(\s*[:=]\s*)([^\s,;]+)",
        lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]",
        text,
    )
    return text if len(text) <= limit else text[:limit] + "...(省略)"


# 表示時刻はスクリプト全体と揃えて JST 固定にする (ログイベントの元値は UTC epoch)。
JST = datetime.timezone(datetime.timedelta(hours=9), "JST")


def event_time(value):
    try:
        stamp = float(value) / 1000.0
        return datetime.datetime.fromtimestamp(
            stamp, JST
        ).isoformat(timespec="milliseconds").replace("+09:00", " JST")
    except Exception:
        return clean_text(value)


config, journal = load_json_documents(["cwagent 設定", "WireMock request journal"])
create_group_count, create_stream_count, put_count = sys.argv[1:4]
event_limit = int(sys.argv[4])
journal_limit = int(sys.argv[5])

collect_list = (
    config.get("logs", {})
    .get("logs_collected", {})
    .get("files", {})
    .get("collect_list", [])
)
expected = []
for entry in collect_list if isinstance(collect_list, list) else []:
    if not isinstance(entry, dict):
        continue
    expected.append(
        (
            str(entry.get("log_group_name") or ""),
            str(entry.get("log_stream_name") or ""),
            str(entry.get("file_path") or ""),
        )
    )

destination_stats = {}
events = []
recent_put_requests = 0
records = journal.get("requests", []) if isinstance(journal, dict) else []
for record in records if isinstance(records, list) else []:
    if not isinstance(record, dict):
        continue
    request = record.get("request") if isinstance(record.get("request"), dict) else record
    if header_value(request, "X-Amz-Target") != "Logs_20140328.PutLogEvents":
        continue
    recent_put_requests += 1
    body = request_body(request)
    group = str(body.get("logGroupName") or "")
    stream = str(body.get("logStreamName") or "")
    key = (group, stream)
    stat = destination_stats.setdefault(key, {"requests": 0, "events": 0})
    stat["requests"] += 1
    log_events = body.get("logEvents")
    if not isinstance(log_events, list):
        log_events = []
    stat["events"] += len(log_events)
    for event in log_events:
        if not isinstance(event, dict):
            continue
        events.append(
            {
                "timestamp": event.get("timestamp"),
                "group": group,
                "stream": stream,
                "message": event.get("message", ""),
            }
        )

print("")
print("════════════ CloudWatch Logs 偽装送達レポート ════════════")
print(f"WireMock API 受信総数: CreateLogGroup={create_group_count}, "
      f"CreateLogStream={create_stream_count}, PutLogEvents={put_count}")
print(f"直近 {journal_limit} リクエスト内で解析した PutLogEvents: {recent_put_requests} 件")
print("")
print("[cwagent 設定と受信先の照合]")
if expected:
    for group, stream, file_path in expected:
        stat = destination_stats.get((group, stream), {"requests": 0, "events": 0})
        state = "OK" if stat["requests"] > 0 and stat["events"] > 0 else "未確認"
        print(f"  [{state}] {file_path}")
        print(f"         log group : {clean_text(group)}")
        print(f"         log stream: {clean_text(stream)}")
        print(f"         requests={stat['requests']}, events={stat['events']}")
else:
    print("  [WARN] cwagent 設定から collect_list を取得できませんでした。")

expected_keys = {(group, stream) for group, stream, _ in expected}
unexpected = [key for key in destination_stats if key not in expected_keys]
if unexpected:
    print("")
    print("[設定外の受信先]")
    for group, stream in sorted(unexpected):
        stat = destination_stats[(group, stream)]
        print(f"  {clean_text(group)} / {clean_text(stream)} "
              f"(requests={stat['requests']}, events={stat['events']})")

print("")
print(f"[受信ログイベント（新しい順、最大 {event_limit} 件）]")
events.sort(key=lambda event: float(event["timestamp"] or 0), reverse=True)
if not events:
    print("  PutLogEvents のログイベント本文は確認できませんでした。")
else:
    for event in events[:event_limit]:
        print(f"  {event_time(event['timestamp'])} "
              f"{clean_text(event['group'], 160)} / {clean_text(event['stream'], 160)}")
        print(f"    {clean_text(event['message'])}")
print("═══════════════════════════════════════════════════════════")
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 2 "$config_json" "$journal_json" \
    "$create_group_count" "$create_stream_count" "$put_count" \
    "$OBSERVABILITY_EVENT_DISPLAY_LIMIT" "$OBSERVABILITY_WIREMOCK_REQUEST_LIMIT"
}

run_cloudwatch_logs_delivery_helper() {
  local selected_service="$1" cwagent_service="cwagent"
  local cwagent_id cwagent_config journal create_group_count create_stream_count put_count
  local agent_logs agent_diagnostics
  local -a cwagent_ids=()

  require_observability_tools || return 1
  mapfile -t cwagent_ids < <(compose_container_ids "$cwagent_service")
  if [ ${#cwagent_ids[@]} -eq 0 ]; then
    err "CloudWatch Logs 送信元の Compose サービス 'cwagent' が実行中ではありません。"
    return 1
  fi
  cwagent_id="${cwagent_ids[0]}"
  if ! cwagent_config="$(docker exec "$cwagent_id" cat /etc/cwagentconfig/cwagent-config.json 2>/dev/null)"; then
    warn "cwagent の設定ファイルを取得できないため、送信先との自動照合は限定されます。"
    cwagent_config='{}'
  fi

  resolve_compose_service_http_endpoint "cloudwatch-logs-mock" "8080" || return 1
  diag ""
  diag "CloudWatch Agent → CloudWatch Logs 偽装サービスの送達を確認します。"
  diag "選択サービス: ${selected_service} / mock: ${OBSERVABILITY_CONTAINER_NAME}"
  diag "WireMock request journal: ${OBSERVABILITY_HTTP_BASE_URL}"
  diag "注意: 実 AWS CloudWatch Logs ではなく、Compose 内 WireMock の受信記録を確認します。"

  create_group_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogGroup" || printf '?')"
  create_stream_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogStream" || printf '?')"
  put_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.PutLogEvents" || printf '?')"
  if ! journal="$(observability_http_get "${OBSERVABILITY_HTTP_BASE_URL}/__admin/requests?limit=${OBSERVABILITY_WIREMOCK_REQUEST_LIMIT}")"; then
    err "cloudwatch-logs-mock の request journal を取得できませんでした。"
    return 1
  fi

  if ! render_cloudwatch_delivery_report "$cwagent_config" "$journal" \
      "$create_group_count" "$create_stream_count" "$put_count" >&2; then
    err "CloudWatch Logs 偽装送達レポートを生成できませんでした。"
    return 1
  fi

  if agent_logs="$(compose_logs "$cwagent_service" 2>/dev/null)"; then
    agent_diagnostics="$(
      printf '%s\n' "$agent_logs" | strip_ansi_codes \
        | grep -Ei '(^|[[:space:]])(E!|W!|ERROR|WARN|failed|denied|timeout)' \
        | tail -n 20 || true
    )"
    diag ""
    diag "[cwagent の警告・エラー（最大 20 行）]"
    if [ -n "$agent_diagnostics" ]; then
      printf '%s\n' "$agent_diagnostics" >&2
    else
      diag "  今回の起動以降に該当する警告・エラーは見つかりませんでした。"
    fi
  fi
  diag ""
  diag "判定基準: 設定済み log group / log stream に PutLogEvents とイベント本文があれば送達確認済みです。"
  diag "未確認の場合は cwagent の force_flush_interval (対象構成は 5 秒) 以上待ってから再実行してください。"
  diag "メッセージには機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"
}

find_first_running_compose_service() {
  local candidate
  local -a candidate_ids=()

  for candidate in "$@"; do
    candidate_ids=()
    mapfile -t candidate_ids < <(compose_container_ids "$candidate")
    if [ ${#candidate_ids[@]} -gt 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

extract_jaeger_services() {
  local services_json="$1" program

  program="$(cat <<'PY'
import json
import sys

document, = load_json_documents(["Jaeger サービス一覧"])

services = document.get("data", []) if isinstance(document, dict) else []
if not isinstance(services, list):
    print("[ERROR] Jaeger サービス一覧の data が配列ではありません。", file=sys.stderr)
    raise SystemExit(2)
for service in services:
    if isinstance(service, str) and service:
        print(service)
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 1 "$services_json"
}

# Jaeger Query API の応答から、トレース、スパン、親子関係、リソース属性、
# スパン属性、イベントを人間が追いやすい形式へ整形する。
render_jaeger_trace_report() {
  local traces_json="$1" selected_trace_service="$2"
  local program

  program="$(cat <<'PY'
import datetime
import json
import re
import sys


SENSITIVE_KEY = re.compile(
    r"(?i)(password|passwd|pwd|secret|token|authorization|cookie|api[._-]?key|credential)"
)
SENSITIVE_TEXT = re.compile(
    r"(?i)\b(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"
    r"(\s*[:=]\s*)([^\s,;]+)"
)


def clean_value(key, value, limit=300):
    if SENSITIVE_KEY.search(str(key)):
        return "[REDACTED]"
    if isinstance(value, (dict, list)):
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    elif value is None:
        text = ""
    else:
        text = str(value)
    text = text.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    text = SENSITIVE_TEXT.sub(
        lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]", text
    )
    return text if len(text) <= limit else text[:limit] + "...(省略)"


def tags_as_pairs(tags):
    pairs = []
    for tag in tags if isinstance(tags, list) else []:
        if not isinstance(tag, dict):
            continue
        pairs.append((str(tag.get("key") or ""), tag.get("value")))
    return pairs


# スパンの時刻も JST 表記へ統一する (Jaeger の元値は UTC のマイクロ秒 epoch)。
JST = datetime.timezone(datetime.timedelta(hours=9), "JST")


def micros_to_time(value):
    try:
        stamp = float(value) / 1_000_000.0
        return datetime.datetime.fromtimestamp(
            stamp, JST
        ).isoformat(timespec="milliseconds").replace("+09:00", " JST")
    except Exception:
        return clean_value("time", value)


def millis(value):
    try:
        return f"{float(value) / 1000.0:.3f} ms"
    except Exception:
        return clean_value("duration", value)


def span_is_error(span):
    values = {key: value for key, value in tags_as_pairs(span.get("tags"))}
    error_value = values.get("error")
    status = str(values.get("otel.status_code") or values.get("status.code") or "").upper()
    return error_value is True or str(error_value).lower() == "true" or status == "ERROR"


def trace_start(trace):
    starts = [
        span.get("startTime")
        for span in trace.get("spans", [])
        if isinstance(span, dict) and isinstance(span.get("startTime"), (int, float))
    ]
    return min(starts) if starts else 0


document, = load_json_documents(["Jaeger トレース"])
selected_service = sys.argv[1]
traces = document.get("data", []) if isinstance(document, dict) else []
if not isinstance(traces, list):
    print("[ERROR] Jaeger トレース応答の data が配列ではありません。", file=sys.stderr)
    raise SystemExit(2)
traces = [trace for trace in traces if isinstance(trace, dict)]
traces.sort(key=trace_start, reverse=True)

print("")
print("════════════ X-Ray 代替 Jaeger トレースレポート ════════════")
print(f"検索サービス: {clean_value('service', selected_service)}")
print(f"取得トレース: {len(traces)} 件")
if not traces:
    print("  Jaeger にトレースがありません。アプリへリクエストを送り、")
    print("  app → Collector → Jaeger の順にログと接続先を確認してください。")
    print("════════════════════════════════════════════════════════════")
    raise SystemExit(0)

for trace_index, trace in enumerate(traces, 1):
    trace_id = str(trace.get("traceID") or "(unknown)")
    spans = [span for span in trace.get("spans", []) if isinstance(span, dict)]
    spans.sort(key=lambda span: span.get("startTime") or 0)
    processes = trace.get("processes") if isinstance(trace.get("processes"), dict) else {}
    services = sorted(
        {
            str(process.get("serviceName"))
            for process in processes.values()
            if isinstance(process, dict) and process.get("serviceName")
        }
    )
    starts = [
        span.get("startTime")
        for span in spans
        if isinstance(span.get("startTime"), (int, float))
    ]
    ends = [
        span.get("startTime") + span.get("duration")
        for span in spans
        if isinstance(span.get("startTime"), (int, float))
        and isinstance(span.get("duration"), (int, float))
    ]
    start = min(starts) if starts else 0
    duration = max(ends) - start if start and ends else 0
    error_count = sum(1 for span in spans if span_is_error(span))

    print("")
    print(f"[Trace {trace_index}] traceID={clean_value('traceID', trace_id, 80)}")
    print(f"  開始={micros_to_time(start)}, 所要時間={millis(duration)}, "
          f"spans={len(spans)}, errorSpans={error_count}")
    print(f"  services={', '.join(clean_value('service', name, 120) for name in services) or '(unknown)'}")

    if processes:
        print("  [リソース]")
        for process_id, process in sorted(processes.items()):
            if not isinstance(process, dict):
                continue
            service_name = clean_value("service", process.get("serviceName") or "(unknown)", 120)
            print(f"    {clean_value('processID', process_id, 80)}: service.name={service_name}")
            process_tags = tags_as_pairs(process.get("tags"))
            for key, value in process_tags[:20]:
                print(f"      {clean_value('key', key, 120)}={clean_value(key, value)}")
            if len(process_tags) > 20:
                print(f"      ... {len(process_tags) - 20} 属性を省略")

    print("  [スパン]")
    for span_index, span in enumerate(spans[:50], 1):
        process = processes.get(span.get("processID"), {})
        service_name = (
            process.get("serviceName")
            if isinstance(process, dict)
            else "(unknown)"
        )
        references = span.get("references") if isinstance(span.get("references"), list) else []
        parent_refs = []
        for reference in references:
            if not isinstance(reference, dict):
                continue
            parent_refs.append(
                f"{reference.get('refType', 'REF')}:{reference.get('spanID', '?')}"
            )
        relative_start = 0
        if start and isinstance(span.get("startTime"), (int, float)):
            relative_start = span.get("startTime") - start
        error_marker = " ERROR" if span_is_error(span) else ""
        print(
            f"    {span_index}. [{clean_value('service', service_name, 100)}] "
            f"{clean_value('operationName', span.get('operationName') or '(unknown)', 180)}"
            f"{error_marker}"
        )
        print(
            f"       spanID={clean_value('spanID', span.get('spanID') or '?', 80)}, "
            f"parent={clean_value('parent', ','.join(parent_refs) or '(root)', 180)}, "
            f"offset={millis(relative_start)}, duration={millis(span.get('duration') or 0)}"
        )
        span_tags = tags_as_pairs(span.get("tags"))
        if span_tags:
            print("       attributes:")
            for key, value in span_tags[:30]:
                print(f"         {clean_value('key', key, 140)}={clean_value(key, value)}")
            if len(span_tags) > 30:
                print(f"         ... {len(span_tags) - 30} 属性を省略")

        span_logs = span.get("logs") if isinstance(span.get("logs"), list) else []
        if span_logs:
            print("       events:")
            for event in span_logs[:10]:
                if not isinstance(event, dict):
                    continue
                print(f"         - {micros_to_time(event.get('timestamp'))}")
                fields = tags_as_pairs(event.get("fields"))
                for key, value in fields[:20]:
                    print(f"             {clean_value('key', key, 140)}={clean_value(key, value)}")
                if len(fields) > 20:
                    print(f"             ... {len(fields) - 20} フィールドを省略")
            if len(span_logs) > 10:
                print(f"         ... {len(span_logs) - 10} イベントを省略")
    if len(spans) > 50:
        print(f"    ... {len(spans) - 50} スパンを省略")

print("")
print("════════════════════════════════════════════════════════════")
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 1 "$traces_json" \
    "$selected_trace_service"
}

# OTel Collector (adot-collector / otel) の稼働確認。
# compose サービスに設定された healthcheck 定義を最優先で実行し、/bin/sh を持たない
# distroless イメージでも確認できるよう、次の順にフォールバックする。
#   1) compose の healthcheck 定義 (CMD はそのまま、CMD-SHELL はシェル→直接実行)
#   2) ADOT Collector 同梱の /healthcheck バイナリを直接実行 (シェル不要)
#   3) health_check 拡張のエンドポイント (13133) へ HTTP 確認
#   4) Docker が記録した State.Health を参照
# いずれも使えない場合は、利用者が手元で実行できるコマンドを案内する。
verify_otel_collector_health() {
  local service_name="$1" container_id="$2"
  local container_name health_state health_status="" status=0
  local health_mode="" health_command_text="" http_url="" host_url="" host_tool=""
  local -a health_test=()

  container_name="$(normalize_container_name \
    "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"

  # Docker が記録した health 状態は、コンテナ内へ一切立ち入らずに参照できる。
  health_state="$(
    docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}|{{.State.Health.FailingStreak}}{{end}}' \
      "$container_id" 2>/dev/null || true
  )"
  if [ -n "$health_state" ]; then
    health_status="${health_state%%|*} (連続失敗 ${health_state#*|} 回)"
  fi

  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "OTel Collector ヘルスチェックの保存用一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"

  # 1) compose に設定された healthcheck 定義を使う。
  if load_container_healthcheck_test "$container_id" \
      && parse_healthcheck_test "${HEALTHCHECK_TEST_LINES[@]}"; then
    health_test=("${HEALTHCHECK_TEST_LINES[@]}")
    health_mode="$HEALTHCHECK_MODE"
    health_command_text="$HEALTHCHECK_COMMAND_TEXT"
    HEALTHCHECK_TIMEOUT_RUNNER=()
    if command -v timeout >/dev/null 2>&1; then
      HEALTHCHECK_TIMEOUT_RUNNER=(timeout "${URL_TIMEOUT}s")
    fi
    status=0
    run_healthcheck_command_with_fallback \
      "$container_id" "$health_mode" "$health_command_text" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
      "${health_test[@]:1}" || status=$?
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" = "true" ] && [ "$status" -eq 0 ]; then
      log "OTel Collector ヘルスチェック: OK (service=${service_name})"
      diag "確認方式: compose の healthcheck 定義を ${HEALTHCHECK_EXEC_METHOD}"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 0
    fi
    # 125-127 はコマンド自体を起動できなかった場合 (シェル無し・コマンド未同梱)。
    # healthcheck の失敗ではないため、次の確認方式へ進む。
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" = "true" ] \
        && [ "$status" -ne 125 ] && [ "$status" -ne 126 ] && [ "$status" -ne 127 ]; then
      warn "OTel Collector の healthcheck が失敗しました (service=${service_name}, exit=${status})。"
      diag "確認方式: compose の healthcheck 定義を ${HEALTHCHECK_EXEC_METHOD}"
      print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(healthcheck の出力はありません)"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 1
    fi
    warn "compose の healthcheck をコンテナ内で実行できません (${HEALTHCHECK_EXEC_METHOD}, exit=${status})。別方式で確認します。"
    http_url="$(
      printf '%s\n' "$health_command_text" \
        | grep -Eo "https?://[^[:space:]\"'<>|;&)]+" | head -n 1 || true
    )"
  else
    warn "compose サービス '${service_name}' に healthcheck が設定されていないため、既定の方式で確認します。"
  fi

  # 2) ADOT Collector 同梱の /healthcheck バイナリ (シェル不要)。
  status=0
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
  if docker exec "$container_id" /healthcheck >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1; then
    log "OTel Collector ヘルスチェック: OK (service=${service_name})"
    diag "確認方式: コンテナ同梱の /healthcheck を docker exec で直接実行"
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
    return 0
  fi
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""

  # 3) health_check 拡張のエンドポイントへ HTTP 確認 (コンテナ内ツール不要)。
  [ -n "$http_url" ] || http_url="http://127.0.0.1:${OTEL_HEALTH_CHECK_PORT}/"
  if host_url="$(resolve_healthcheck_url_for_host "$container_id" "$http_url")" \
      && host_tool="$(detect_host_http_tool)"; then
    if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
      warn "OTel Collector ヘルスチェックの保存用一時ファイルを作成できませんでした。"
      return 1
    fi
    status=0
    run_healthcheck_http_probe_on_host "$host_tool" "GET" "$host_url" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
      || status=$?
    if [ "$status" -eq 0 ]; then
      log "OTel Collector ヘルスチェック: OK (service=${service_name})"
      diag "確認方式: ホストから health_check エンドポイントへ HTTP 確認 (${host_url})"
      print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(レスポンス本文はありません)"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 0
    fi
    warn "health_check エンドポイントへの HTTP 確認にも失敗しました (${host_url}, exit=${status})。"
    print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(レスポンス本文・接続エラー出力はありません)"
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
  fi

  # 4) 実行系がすべて使えない場合は、Docker の記録と手動コマンドで補う。
  if [ -n "$health_status" ]; then
    warn "OTel Collector を能動的に確認できないため、Docker が記録した health 状態のみ表示します: ${health_status} (service=${service_name})"
  else
    warn "OTel Collector のヘルスチェックを確認できませんでした (service=${service_name})。"
  fi
  print_healthcheck_manual_commands "$service_name" "$container_name" \
    "$health_mode" "$health_command_text" "$http_url" "$container_id"
  return 1
}

run_otel_jaeger_trace_helper() {
  local selected_service="$1" collector_service="" collector_id=""
  local jaeger_service="jaeger" services_json services_text selected_trace_service traces_json
  local collector_logs collector_evidence choice index _service_index
  local -a collector_ids=() trace_services=()

  require_observability_tools || return 1
  case "$selected_service" in
    otel|adot-collector)
      collector_service="$selected_service"
      ;;
    jaeger)
      collector_service="$(find_first_running_compose_service adot-collector otel || true)"
      ;;
  esac

  if [ -n "$collector_service" ]; then
    mapfile -t collector_ids < <(compose_container_ids "$collector_service")
    if [ ${#collector_ids[@]} -gt 0 ]; then
      collector_id="${collector_ids[0]}"
      verify_otel_collector_health "$collector_service" "$collector_id" || true

      if collector_logs="$(compose_logs "$collector_service" 2>/dev/null)"; then
        collector_evidence="$(
          printf '%s\n' "$collector_logs" | strip_ansi_codes \
            | grep -Ei 'TracesExporter|resource spans|[[:space:]]spans([:=]|[[:space:]])' \
            | tail -n 10 || true
        )"
        diag ""
        diag "[Collector のスパン受信根拠（最大 10 行）]"
        if [ -n "$collector_evidence" ]; then
          printf '%s\n' "$collector_evidence" >&2
        else
          warn "今回の起動以降の Collector ログにスパン受信を示す行が見つかりません。"
        fi
      fi
    fi
  else
    warn "実行中の OTel Collector サービス (adot-collector / otel) を見つけられないため、Jaeger 側だけを確認します。"
  fi

  resolve_compose_service_http_endpoint "$jaeger_service" "16686" || return 1
  diag ""
  diag "OTel Collector → X-Ray 偽装 Jaeger のトレース送達を確認します。"
  diag "Jaeger Query API: ${OBSERVABILITY_HTTP_BASE_URL}"
  diag "注意: これは Compose 内 Jaeger への送達確認であり、実 AWS X-Ray への送信確認ではありません。"
  if ! services_json="$(observability_http_get "${OBSERVABILITY_HTTP_BASE_URL}/api/services")"; then
    err "Jaeger Query API からサービス一覧を取得できませんでした。"
    return 1
  fi
  if ! services_text="$(extract_jaeger_services "$services_json")"; then
    return 1
  fi
  while IFS= read -r selected_trace_service; do
    [ -n "$selected_trace_service" ] && trace_services+=("$selected_trace_service")
  done <<< "$services_text"
  if [ ${#trace_services[@]} -eq 0 ]; then
    warn "Jaeger にトレースサービスが登録されていません。アプリへリクエストを送ってから再確認してください。"
    return 0
  fi

  diag ""
  diag "Jaeger で確認するトレースサービスを選択してください:"
  for _service_index in "${!trace_services[@]}"; do
    diag "  $(( _service_index + 1 ))) ${trace_services[$_service_index]}"
  done
  diag "  0) トレース確認を中止"
  while :; do
    printf '選択番号 [0-%s]: ' "${#trace_services[@]}" >&2
    if ! IFS= read -r choice; then
      err "Jaeger トレースサービスの選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      0)
        log "Jaeger トレース確認を中止しました。"
        return 0
        ;;
      ''|*[!0-9]*|0*)
        warn "0 から ${#trace_services[@]} の番号を入力してください。"
        ;;
      *)
        if [ "$choice" -ge 1 ] 2>/dev/null \
            && [ "$choice" -le ${#trace_services[@]} ] 2>/dev/null; then
          index=$(( choice - 1 ))
          selected_trace_service="${trace_services[$index]}"
          break
        fi
        warn "0 から ${#trace_services[@]} の番号を入力してください。"
        ;;
    esac
  done

  if ! traces_json="$(
    curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" --get \
      --data-urlencode "service=${selected_trace_service}" \
      --data-urlencode "limit=${OBSERVABILITY_TRACE_LIMIT}" \
      --data-urlencode "lookback=1h" \
      "${OBSERVABILITY_HTTP_BASE_URL}/api/traces"
  )"; then
    err "Jaeger Query API からトレースを取得できませんでした: ${selected_trace_service}"
    return 1
  fi
  if ! render_jaeger_trace_report "$traces_json" "$selected_trace_service" >&2; then
    err "Jaeger トレースレポートを生成できませんでした。"
    return 1
  fi
  diag "トレース属性・イベントには機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"
}

# 選択済み Compose サービスについて、ログ表示、対話式 bash / MySQL 接続、
# healthcheck 診断、対応サービスのローカル可観測性診断を繰り返す。
# 0 を選択すると、起動中 Compose サービスの選択へ戻る。
compose_service_observability_helper_kind() {
  case "$1" in
    cwagent|cloudwatch-logs-mock) printf 'cloudwatch\n' ;;
    otel|adot-collector|jaeger) printf 'xray\n' ;;
    *) return 1 ;;
  esac
}

pause_compose_service_actions() {
  printf 'Enter キーでサービス操作の選択へ戻ります: ' >&2
  if ! IFS= read -r; then
    err "サービス操作の選択へ戻るための入力を読み取れませんでした。"
    return 1
  fi
}

run_interactive_compose_service_actions() {
  local service_name="$1" action helper_kind="" max_action=3
  local mysql_action=0 observability_action=0

  helper_kind="$(compose_service_observability_helper_kind "$service_name" || true)"
  if compose_service_supports_mysql_client "$service_name"; then
    max_action=$(( max_action + 1 ))
    mysql_action="$max_action"
  fi
  if [ -n "$helper_kind" ]; then
    max_action=$(( max_action + 1 ))
    observability_action="$max_action"
  fi
  while :; do
    diag ""
    diag "Compose サービス '${service_name}' で実行する操作を選択してください:"
    diag "  1) ログを表示"
    diag "  2) bash へ接続 (cd・任意コマンドを実行可能)"
    diag "  3) healthcheck 設定・実行履歴・通信を確認"
    if [ "$mysql_action" -gt 0 ]; then
      diag "  ${mysql_action}) MySQL クライアントへ接続 (SQL クエリを対話実行)"
    fi
    case "$helper_kind" in
      cloudwatch)
        diag "  ${observability_action}) CloudWatch Logs 偽装送達を確認 (ロググループ / ストリーム / イベント)"
        ;;
      xray)
        diag "  ${observability_action}) X-Ray 偽装 Jaeger のトレースを確認 (サービス / トレース / スパン)"
        ;;
    esac
    diag "  0) Compose サービスの選択へ戻る"
    printf '選択番号 [0-%s]: ' "$max_action" >&2
    if ! IFS= read -r action; then
      err "Compose サービス操作の選択を読み取れませんでした。対話可能な端末から実行してください。"
      return 1
    fi

    case "$action" in
      1)
        if ! show_interactive_compose_service_logs "$service_name"; then
          warn "ログ表示に失敗しました。サービス操作の選択へ戻ります。"
        fi
        pause_compose_service_actions || return 1
        ;;
      2)
        if ! run_interactive_compose_bash "$service_name"; then
          warn "bash 接続に失敗しました。サービス操作の選択へ戻ります。"
        fi
        ;;
      3)
        if ! run_interactive_compose_healthcheck "$service_name"; then
          warn "healthcheck 診断に失敗しました。サービス操作の選択へ戻ります。"
        fi
        pause_compose_service_actions || return 1
        ;;
      0)
        log "Compose サービス '${service_name}' の操作を終了し、サービス選択へ戻ります。"
        return 0
        ;;
      *)
        if [ "$mysql_action" -gt 0 ] && [ "$action" = "$mysql_action" ]; then
          if ! run_interactive_compose_mysql "$service_name"; then
            warn "MySQL 接続に失敗しました。サービス操作の選択へ戻ります。"
          fi
        elif [ "$observability_action" -gt 0 ] && [ "$action" = "$observability_action" ]; then
          case "$helper_kind" in
            cloudwatch)
              if ! run_cloudwatch_logs_delivery_helper "$service_name"; then
                warn "CloudWatch Logs 偽装送達の確認に失敗しました。"
              fi
              ;;
            xray)
              if ! run_otel_jaeger_trace_helper "$service_name"; then
                warn "X-Ray 偽装 Jaeger のトレース確認に失敗しました。"
              fi
              ;;
          esac
          pause_compose_service_actions || return 1
        else
          warn "0 から ${max_action} の番号を入力してください。"
        fi
        ;;
    esac
  done
}

# 起動中の Compose サービスを番号で選択し、サービス操作メニューを表示する。
# サービス操作から戻るたびに最新の一覧を再取得し、0 が選択されるまで繰り返す。
run_interactive_compose_service_menu() {
  local choice index service_name _service_index
  local -a started_services=()

  while :; do
    started_services=()
    mapfile -t started_services < <(compose_started_services)
    if [ ${#started_services[@]} -eq 0 ]; then
      err "対話操作できる起動中の Compose サービスが見つかりません。"
      return 1
    fi

    diag ""
    diag "操作する起動中の Compose サービスを選択してください:"
    for _service_index in "${!started_services[@]}"; do
      diag "  $(( _service_index + 1 ))) ${started_services[$_service_index]}"
    done
    diag "  0) 対話操作を終了"

    while :; do
      printf '選択番号 [0-%s]: ' "${#started_services[@]}" >&2
      if ! IFS= read -r choice; then
        err "Compose サービスの選択を読み取れませんでした。対話可能な端末から実行してください。"
        return 1
      fi
      case "$choice" in
        0)
          log "Compose サービスの対話操作を終了しました。"
          return 0
          ;;
        ''|*[!0-9]*|0*)
          warn "0 から ${#started_services[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] 2>/dev/null \
              && [ "$choice" -le ${#started_services[@]} ] 2>/dev/null; then
            index=$(( choice - 1 ))
            break
          fi
          warn "0 から ${#started_services[@]} の番号を入力してください。"
          ;;
      esac
    done

    service_name="${started_services[$index]}"
    run_interactive_compose_service_actions "$service_name" || return 1
  done
}

run_keep_container_interaction() {
  [ -n "$KEEP_CONTAINER_MODE" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    case "$KEEP_CONTAINER_MODE" in
      bash)
        log "[DRY-RUN] 検証対象コンテナを選択し、docker exec -it <container> /bin/bash で直接接続します。"
        ;;
      http)
        log "[DRY-RUN] JBoss EAP のコンテキストルートと HTTP ポートを解決し、パス・GET/POST・POST ボディ形式の対話入力後に curl を実行します。"
        ;;
      logs)
        log "[DRY-RUN] 起動中の Compose サービスを番号で選択し、ログ表示、対話式 bash / MySQL 接続、healthcheck 設定・実行履歴・通信確認、cwagent / OTel のローカル送達診断を繰り返し実行します。"
        ;;
    esac
    return 0
  fi

  case "$KEEP_CONTAINER_MODE" in
    bash)
      select_interaction_target || return 1
      diag ""
      diag "検証対象コンテナの bash へ接続します (service=${INTERACTION_SERVICE_NAME}, container=${INTERACTION_CONTAINER_NAME})。"
      diag "bash を終了してもコンテナは起動状態のまま残ります。"
      if ! docker exec -it "$INTERACTION_CONTAINER_ID" /bin/bash; then
        err "検証対象コンテナの /bin/bash へ接続できませんでした: ${INTERACTION_CONTAINER_NAME}"
        return 1
      fi
      log "コンテナの bash セッションを終了しました。コンテナは起動状態を維持します。"
      ;;
    http)
      select_interaction_target || return 1
      run_interactive_http_request || return 1
      ;;
    logs)
      run_interactive_compose_service_menu || return 1
      ;;
  esac
  return 0
}

# Docker CLI の人間可読サイズ (例: 1.5GB / 20MiB) をバイトへ変換する。
human_size_to_bytes() {
  local value="$1" number unit multiplier
  value="${value//[[:space:]]/}"
  if [ "$value" = "0" ]; then
    printf '0\n'
    return 0
  fi
  if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)(B|kB|KB|MB|GB|TB|PB|KiB|MiB|GiB|TiB|PiB)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$unit" in
    B)   multiplier=1 ;;
    kB|KB) multiplier=1000 ;;
    MB)  multiplier=1000000 ;;
    GB)  multiplier=1000000000 ;;
    TB)  multiplier=1000000000000 ;;
    PB)  multiplier=1000000000000000 ;;
    KiB) multiplier=1024 ;;
    MiB) multiplier=1048576 ;;
    GiB) multiplier=1073741824 ;;
    TiB) multiplier=1099511627776 ;;
    PiB) multiplier=1125899906842624 ;;
    *) return 1 ;;
  esac
  LC_ALL=C awk -v number="$number" -v multiplier="$multiplier" \
    'BEGIN { printf "%.0f\n", number * multiplier }'
}

# docker system df の全カテゴリを合計し、Docker 管理対象の使用量を返す。
docker_storage_bytes() {
  local summary type size bytes total=0 found="false"
  if ! summary="$(LC_ALL=C docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null)"; then
    return 1
  fi
  while IFS='|' read -r type size; do
    [ -n "$type" ] || continue
    if ! bytes="$(human_size_to_bytes "$size")"; then
      return 1
    fi
    total=$(( total + bytes ))
    found="true"
  done <<< "$summary"
  [ "$found" = "true" ] || return 1
  printf '%s\n' "$total"
}

format_bytes() {
  local bytes="$1"
  LC_ALL=C awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", units, " ")
      value = bytes + 0
      unit = 1
      while (value >= 1024 && unit < 6) {
        value /= 1024
        unit++
      }
      if (unit == 1) {
        printf "%.0f %s", value, units[unit]
      } else {
        printf "%.2f %s", value, units[unit]
      }
    }'
}

docker_object_count() {
  local output
  if ! output="$("$@" 2>/dev/null)"; then
    printf '取得不可'
    return 1
  fi
  if [ -z "$output" ]; then
    printf '0'
  else
    printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }'
  fi
}

current_docker_endpoint() {
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    docker context inspect "$DOCKER_CONTEXT" \
      --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  elif [ -n "${DOCKER_HOST:-}" ]; then
    printf '%s\n' "$DOCKER_HOST"
  else
    docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  fi
}

# 確認表示後に別プロセスが既定 context を切り替えても削除先が変わらないよう、
# DOCKER_HOST 未指定時は現在の context 名をこのプロセスへ固定する。
freeze_current_docker_target() {
  [ -n "${DOCKER_CONTEXT:-}" ] && return 0
  [ -n "${DOCKER_HOST:-}" ] && return 0
  local context
  if ! context="$(docker context show 2>/dev/null)" || [ -z "$context" ]; then
    return 1
  fi
  export DOCKER_CONTEXT="$context"
}

docker_endpoint_description() {
  case "$1" in
    unix://*) printf 'ローカル Unix ソケット' ;;
    npipe://*) printf 'ローカル Windows named pipe' ;;
    ssh://*) printf 'リモート SSH 接続' ;;
    tcp://*|http://*|https://*) printf 'TCP 接続 (リモートの可能性あり)' ;;
    '') printf '取得不可' ;;
    *) printf 'その他の接続方式' ;;
  esac
}

show_docker_cleanup_notice() {
  local usage_before="$1" context endpoint
  local running_count container_count image_count volume_count network_count
  context="$(docker context show 2>/dev/null || true)"
  [ -n "$context" ] || context="取得不可"
  endpoint="$(current_docker_endpoint || true)"
  running_count="$(docker_object_count docker container ls -q || true)"
  container_count="$(docker_object_count docker container ls -aq || true)"
  image_count="$(docker_object_count docker image ls -aq || true)"
  volume_count="$(docker_object_count docker volume ls -q || true)"
  network_count="$(docker_object_count docker network ls --filter type=custom -q || true)"

  diag ""
  diag "╔══════════════════════════════════════════════════════════════════╗"
  diag "║ 警告: 現在の Docker context の全ローカルデータを削除します      ║"
  diag "╚══════════════════════════════════════════════════════════════════╝"
  diag "  Docker context: $context"
  diag "  Docker 接続方式: $(docker_endpoint_description "$endpoint")"
  diag "  Docker 管理対象の使用量: $usage_before"
  diag ""
  diag "削除・停止する対象:"
  diag "  1. 実行中の全 Docker コンテナ: $running_count 件"
  diag "     Compose を含め、一時停止中は解除後、通常の docker stop で停止します。"
  diag "  2. 全コンテナ (停止済みを含む): $container_count 件"
  diag "  3. 全ローカルイメージ / タグ: $image_count 件"
  diag "  4. 全ローカルボリュームと、その中の永続データ: $volume_count 件"
  diag "  5. 未使用のユーザー定義ネットワーク: $network_count 件"
  diag "  6. 現在の Docker daemon で削除可能な全ビルドキャッシュ"
  diag ""
  diag "この操作は同じ Docker daemon を使う他プロジェクトにも影響し、元に戻せません。"
  diag "Docker daemon / Docker Desktop、標準ネットワーク、Docker context、"
  diag "レジストリ認証情報、daemon 設定は削除・停止しません。"
}

filesystem_free_bytes() {
  local path="$1" free_kib
  free_kib="$(df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
  case "$free_kib" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$(( free_kib * 1024 ))"
}

run_docker_cleanup_step() {
  local description="$1"
  shift
  log "$description ..."
  if "$@"; then
    return 0
  fi
  warn "失敗しました: $description"
  return 1
}

verify_docker_list_empty() {
  local description="$1" remaining count
  shift
  if ! remaining="$("$@" 2>/dev/null)"; then
    warn "クリーンアップ後の確認に失敗しました: $description"
    return 1
  fi
  [ -z "$remaining" ] && return 0
  count="$(printf '%s\n' "$remaining" | awk 'NF { count++ } END { print count + 0 }')"
  warn "クリーンアップ後も $description が $count 件残っています。"
  return 1
}

# 明示指定された場合だけ、現在の Docker context のローカルデータを全削除する。
cleanup_all_docker_data() {
  [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] || return 0

  local before_bytes="" after_bytes="" before_display="取得不可"
  local docker_endpoint="" docker_root="" host_before="" host_after=""
  local released host_released response paused_output running_output _container_id
  local cleanup_failed=0 measurement_reported="false"
  local -a paused_ids=() running_ids=()

  if ! freeze_current_docker_target; then
    if [ "$DRY_RUN" = "true" ]; then
      warn "Docker context を固定できませんでしたが、DRY-RUN のため削除せずに表示を続けます。"
    else
      err "Docker context を固定できないため、安全のため全体クリーンアップを中止します。"
      return 1
    fi
  fi

  if before_bytes="$(docker_storage_bytes)"; then
    before_display="$(format_bytes "$before_bytes") (docker system df による概算)"
  fi
  show_docker_cleanup_notice "$before_display"

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 確認入力と Docker データ削除は行いません。実行予定の処理:"
    log "[DRY-RUN] docker container unpause <一時停止中の全コンテナ ID>"
    log "[DRY-RUN] docker container stop <実行中の全コンテナ ID>"
    log "[DRY-RUN] docker container prune --force"
    log "[DRY-RUN] docker builder prune --all --force"
    log "[DRY-RUN] docker image prune --all --force"
    log "[DRY-RUN] docker volume prune --all --force"
    log "[DRY-RUN] docker network prune --force"
    log "[DRY-RUN] docker system prune --all --volumes --force"
    return 0
  fi

  printf "続行するには '%s' と正確に入力してください: " \
    "$DOCKER_CLEANUP_CONFIRM_PHRASE" >&2
  if ! IFS= read -r response; then
    warn "確認入力を読み取れなかったため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi
  if [ "$response" != "$DOCKER_CLEANUP_CONFIRM_PHRASE" ]; then
    warn "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi

  log "確認フレーズを受け付けました。Docker 完全クリーンアップを開始します。"
  docker_endpoint="$(current_docker_endpoint || true)"
  if [[ "$docker_endpoint" = unix://* ]]; then
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  fi
  if [ -n "$docker_root" ]; then
    host_before="$(filesystem_free_bytes "$docker_root" || true)"
  fi

  if paused_output="$(docker container ls -q --filter status=paused)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && paused_ids+=("$_container_id")
    done <<< "$paused_output"
    if [ ${#paused_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "一時停止中のコンテナを安全に停止できる状態へ戻します (${#paused_ids[@]} 件)" \
        docker container unpause "${paused_ids[@]}" || cleanup_failed=1
    fi
  else
    warn "一時停止中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  if running_output="$(docker container ls -q)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && running_ids+=("$_container_id")
    done <<< "$running_output"
    if [ ${#running_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "Compose を含む全実行中コンテナを通常停止します (${#running_ids[@]} 件)" \
        docker container stop "${running_ids[@]}" || cleanup_failed=1
    else
      log "実行中の Docker コンテナはありません。"
    fi
  else
    warn "実行中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  run_docker_cleanup_step "停止済みを含む全コンテナを削除します" \
    docker container prune --force || cleanup_failed=1
  run_docker_cleanup_step "削除可能な全 Docker ビルドキャッシュを削除します" \
    docker builder prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルイメージを削除します" \
    docker image prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルボリュームと永続データを削除します" \
    docker volume prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "未使用のユーザー定義ネットワークを削除します" \
    docker network prune --force || cleanup_failed=1
  run_docker_cleanup_step "Docker の未使用データを最終確認・削除します" \
    docker system prune --all --volumes --force || cleanup_failed=1

  verify_docker_list_empty "コンテナ" docker container ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルイメージ" docker image ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルボリューム" docker volume ls -q || cleanup_failed=1
  verify_docker_list_empty "ユーザー定義ネットワーク" \
    docker network ls --filter type=custom -q || cleanup_failed=1

  if after_bytes="$(docker_storage_bytes)"; then
    if [ -n "$before_bytes" ]; then
      released=$(( before_bytes - after_bytes ))
      if [ "$released" -lt 0 ]; then
        warn "Docker 使用量が処理中に増加したため、削減量を 0 bytes として表示します。"
        released=0
      fi
      log "容量削減結果 (Docker 管理対象・概算): $(format_bytes "$released")"
      log "  削除前: $(format_bytes "$before_bytes")"
      log "  削除後: $(format_bytes "$after_bytes")"
      measurement_reported="true"
    fi
    if [ "$after_bytes" -ne 0 ]; then
      warn "クリーンアップ後も Docker 管理対象データが約 $(format_bytes "$after_bytes") 残っています。"
      cleanup_failed=1
    fi
  fi

  if [ -n "$docker_root" ]; then
    host_after="$(filesystem_free_bytes "$docker_root" || true)"
  fi
  if [ -n "$host_before" ] && [ -n "$host_after" ]; then
    host_released=$(( host_after - host_before ))
    if [ "$host_released" -ge 0 ]; then
      log "ホストファイルシステムの空き容量増加: $(format_bytes "$host_released")"
      measurement_reported="true"
    else
      warn "同時実行中の別処理の影響により、ホストの空き容量は $(format_bytes "$(( -host_released ))") 減少しました。"
    fi
  fi

  if [ "$measurement_reported" != "true" ]; then
    warn "容量削減結果を測定できませんでした。各 prune コマンドの出力を確認してください。"
    cleanup_failed=1
  fi

  if [ "$cleanup_failed" -ne 0 ]; then
    err "Docker 完全クリーンアップは一部未完了です。上記の警告を確認してください。"
    return 1
  fi
  log "Docker 完全クリーンアップが完了しました。"
  return 0
}

# ---- 全量ビルドレポート ------------------------------------------------------
# 失敗時の一次調査をレポート 1 枚で完結させるため、Compose サービスごとのログ全文を
# 追記する。起動確認対象だけでなく adot collector などのサイドカーも含む全サービスを
# 対象とし、どこからどこまでが 1 サービスのログかを見出しと罫線で区切る。
# 画面表示用の行数上限 (--startup-log-lines) や抑制指定は適用しない。
append_compose_service_logs_report() {
  local report_file="$1"
  local service_name index=0 normalized_logs line_count containers log_scope
  local -a services=()

  if [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_scope="今回の compose up 以降 (--since ${CONTAINER_LOG_SINCE})"
  else
    log_scope="コンテナ作成時からの全期間 (compose up 到達前に終了)"
  fi
  printf '取得範囲      : %s\n' "$log_scope" >> "$report_file"
  printf '出力方針      : サービス単位に全行を出力 (画面表示の行数制限は適用しない)\n' >> "$report_file"
  if [ "$SHUTDOWN_STOP_EXECUTED" = "true" ]; then
    printf '終了処理      : SIGTERM (compose stop -t %s) 送出後の終了ログまで含む\n' \
        "$SHUTDOWN_LOG_TIMEOUT" >> "$report_file"
  fi

  mapfile -t services < <(compose_all_service_names)
  if [ ${#services[@]} -eq 0 ]; then
    printf '対象サービス  : (なし)\n' >> "$report_file"
    printf 'Compose サービスを特定できなかったため、ログを取得していません。\n' >> "$report_file"
    return 0
  fi
  printf '対象サービス  : %s (%s サービス)\n' "${services[*]}" "${#services[@]}" >> "$report_file"

  for service_name in "${services[@]}"; do
    index=$((index + 1))
    containers="$(compose_service_container_summary "$service_name")"
    normalized_logs="$(compose_logs "$service_name" | strip_ansi_codes)"
    if [ -n "$normalized_logs" ]; then
      line_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
    else
      line_count=0
    fi

    printf '\n' >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    printf '[7-%s] Compose サービス: %s\n' "$index" "$service_name" >> "$report_file"
    printf 'コンテナ      : %s\n' "$containers" >> "$report_file"
    printf 'ログ行数      : %s 行\n' "$line_count" >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    if [ "$line_count" -gt 0 ]; then
      printf '%s\n' "$normalized_logs" >> "$report_file"
    else
      printf '(このサービスのログはありません)\n' >> "$report_file"
    fi
  done
  return 0
}

# EXIT トラップからコンテナ停止前に呼び、画面表示の制限にかかわらず環境変数は
# 全件、各ディレクトリは全深度・全ファイル名で保存する。
write_build_report() {
  local exit_status="$1" overall_status build_status report_dir report_base candidate
  local counter=1 report_tmp report_finished_at cid service_name container_name
  local diagnostic_line
  local -a target_container_ids=()

  [ -n "$BUILD_REPORT_DIR" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 全量ビルドレポートのファイル出力をスキップします: ${BUILD_REPORT_DIR}/build_and_verify_${RUN_TIMESTAMP}.txt"
    return 0
  fi
  if ! mkdir -p -- "$BUILD_REPORT_DIR"; then
    warn "全量ビルドレポートの出力先を作成できませんでした: $BUILD_REPORT_DIR"
    return 1
  fi

  report_dir="${BUILD_REPORT_DIR%/}"
  [ -n "$report_dir" ] || report_dir="/"
  report_base="build_and_verify_${RUN_TIMESTAMP}"
  candidate="${report_dir%/}/${report_base}.txt"
  while [ -e "$candidate" ]; do
    candidate="${report_dir%/}/${report_base}_${counter}.txt"
    counter=$((counter + 1))
  done
  if ! report_tmp="$(mktemp "${report_dir%/}/.${report_base}.tmp.XXXXXX" 2>/dev/null)"; then
    warn "全量ビルドレポート用の一時ファイルを作成できませんでした: $report_dir"
    return 1
  fi

  if [ "$exit_status" -eq 0 ]; then
    overall_status="成功"
  else
    overall_status="失敗 (exit=${exit_status})"
  fi
  build_status="$BUILD_RESULT_STATUS"
  if [ "$exit_status" -ne 0 ] && [ "$build_status" = "実行中" ]; then
    build_status="失敗 (ビルド処理中に中断)"
  fi
  report_finished_at="$(now_display_time)"

  if ! {
    printf '===================================================================\n'
    printf 'build_and_verify.sh 全量ビルドレポート\n'
    printf '===================================================================\n'
    printf '処理開始日時 : %s\n' "$RUN_STARTED_AT"
    printf 'レポート日時 : %s\n' "$report_finished_at"
    printf '全体結果     : %s\n' "$overall_status"
    printf 'Compose 定義 : %s\n' "$COMPOSE_FILE"
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      printf 'ビルド対象   : %s\n' "${COMPOSE_SERVICES[*]}"
    else
      printf 'ビルド対象   : 全サービス\n'
    fi
    if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
      printf '起動対象     : %s\n' "${COMPOSE_TARGET_SERVICES[*]}"
    else
      printf '起動対象     : 全サービス\n'
    fi
    printf '\n[1] ビルド結果\n'
    printf '結果          : %s\n' "$build_status"
    printf '詳細          : %s\n' "${BUILD_RESULT_DETAIL:-(なし)}"
    printf 'イメージ      : %s\n' "${BUILD_IMAGE_INFO:-(未確認)}"
    printf '保存ポリシー  : 環境変数は全件、ツリーは全深度・全ファイル名\n'
    printf '                JVM パラメータと OpenTelemetry 設定は検出した全件\n'
    printf '                失敗時は全 Compose サービスのログをサービス単位に全行保存\n'
    printf '                (SIGTERM で終了させたうえで、終了処理のログまで含める)\n'
  } > "$report_tmp"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートのヘッダーを書き込めませんでした: $candidate"
    return 1
  fi

  if [ "$JBOSS_SECRET_ENABLED" = "true" ]; then
    {
      if [ "$JBOSS_PASSWORD_SHOW_VALUES" = "true" ]; then
        printf '\n[1-A] JBoss マスターパスワード推移診断 (秘密値表示あり: 明示指定)\n'
        printf '注意            : 入力側設定値・不一致/直接照合不能文字列がこのレポートに含まれ得ます。\n'
      else
        printf '\n[1-A] JBoss マスターパスワード推移診断 (平文・ハッシュ非表示)\n'
      fi
      printf '取得元          : %s\n' "$JBOSS_PASSWORD_SOURCE"
      printf 'Compose secret  : %s\n' "$JBOSS_PASSWORD_COMPOSE_STATUS"
      printf 'Dockerfile mount: %s\n' "$JBOSS_PASSWORD_DOCKERFILE_STATUS"
      printf 'standalone.xml  : %s\n' "$JBOSS_PASSWORD_XML_STATUS"
      printf '診断ログ:\n'
      if [ ${#JBOSS_PASSWORD_DIAGNOSTIC_LINES[@]} -eq 0 ]; then
        printf '  (診断記録なし)\n'
      else
        for diagnostic_line in "${JBOSS_PASSWORD_DIAGNOSTIC_LINES[@]}"; do
          printf '  %s\n' "$diagnostic_line"
        done
      fi
    } >> "$report_tmp"
  fi

  if [ "$STARTED_CONTAINER" = "true" ]; then
    mapfile -t target_container_ids < <(verification_target_container_ids)
  fi
  if [ ${#target_container_ids[@]} -eq 0 ]; then
    {
      printf '\n[2] 環境変数一覧 (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[5] Java JVM パラメータ (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[6] OpenTelemetry 環境変数・JVM パラメータ (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
    } >> "$report_tmp"
  else
    load_build_arg_env_name_set
    printf '\n[2] 環境変数一覧 (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_env_report "$cid" "$service_name" "$container_name" "$report_tmp" "all"
    done

    printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "/" "コンテナ内ディレクトリツリー" "all" "all"
    done

    printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "all" "all"
    done

    printf '\n[5] Java JVM パラメータ (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_jvm_parameter_report "$cid" "$service_name" "$container_name" "$report_tmp"
    done

    printf '\n[6] OpenTelemetry 環境変数・JVM パラメータ (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_otel_report "$cid" "$service_name" "$container_name" "$report_tmp"
    done
  fi

  # 失敗時は、ログ本文を集める前に SIGTERM でコンテナを終了させ、adot collector
  # などの終了処理ログまでレポートへ含める。環境変数・ツリー・JVM パラメータは
  # 起動中のコンテナからしか取得できないため、[2]〜[6] を集め終えたこの位置で停止する。
  capture_shutdown_logs "$exit_status"

  # 失敗時は原因調査に必要なため全サービスのログ全文を残す。成功時は同じ内容が
  # 画面へ出ており、レポートを不必要に肥大化させるだけなので省略する。
  printf '\n[7] Compose サービス別ログ (全サービス・全行)\n' >> "$report_tmp"
  if [ "$exit_status" -eq 0 ]; then
    printf '処理が成功したため、Compose サービス別ログの全文出力は省略しました。\n' >> "$report_tmp"
  else
    append_compose_service_logs_report "$report_tmp"
  fi

  if ! mv -- "$report_tmp" "$candidate"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートを確定できませんでした: $candidate"
    return 1
  fi
  BUILD_REPORT_FILE="$candidate"
  log "全量ビルドレポートを出力しました: $BUILD_REPORT_FILE"
  return 0
}

# ---- 後始末 (任意の Docker 完全クリーンアップ → 通常後始末) ----------------
URL_BODY_FILE=""
cleanup_all() {
  local original_status=$? cleanup_status=0
  # この関数内の exit で EXIT トラップが再帰しないよう、先に解除する。
  trap - EXIT

  # コンテナの停止・Docker 全体削除より前に、取得可能な全量情報を保存する。
  # (エラー時の終了ログ取得は、レポート内でログ本文を集める直前に実行される)
  if ! write_build_report "$original_status"; then
    cleanup_status=1
  fi
  # レポート出力が無効な場合でも、エラー時は SIGTERM で終了させて終了ログを
  # 画面へ残す。レポート側で実行済みならここでは何もしない。
  capture_shutdown_logs "$original_status"

  # 全体クリーンアップを先に実行し、削除前容量へ今回の Compose コンテナも含める。
  # 未承認・失敗時は、その後に従来どおり今回起動したコンテナだけを後始末する。
  if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ]; then
    if cleanup_all_docker_data; then
      [ "$DRY_RUN" = "true" ] || STARTED_CONTAINER="false"
    else
      cleanup_status=1
    fi
  fi
  teardown_container
  cleanup_copied_files
  [ -n "$URL_BODY_FILE" ] && rm -f "$URL_BODY_FILE"
  [ -n "$INTERACTIVE_HTTP_BODY_FILE" ] && rm -f "$INTERACTIVE_HTTP_BODY_FILE"
  [ -n "$HEALTHCHECK_DIAGNOSTIC_FILE" ] && rm -f "$HEALTHCHECK_DIAGNOSTIC_FILE"
  cleanup_jboss_password_diagnostics

  # 本処理が既に失敗している場合は元の終了コードを優先する。
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に後始末する
trap cleanup_all EXIT

# URL 応答本文の一時ファイル (URL 確認時のみ使用)
if [ -n "$VERIFY_URL" ]; then
  URL_BODY_FILE="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/url_body.$$")"
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
prepare_jboss_password

# compose.yml の environment 型シークレット (既定: JBOSS_MASTER_PASSWORD) は、
# 環境変数が未定義だと compose build が失敗するため、シークレットを使わない
# 場合でも空文字で定義しておく (既に値が入っていればそのまま維持する)。
export JBOSS_MASTER_PASSWORD="${JBOSS_MASTER_PASSWORD:-}"
if ! verify_jboss_compose_secret_mapping; then
  BUILD_RESULT_STATUS="失敗"
  BUILD_RESULT_DETAIL="JBoss マスターパスワードの Compose secret 対応関係が不一致です。"
  exit 1
fi

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_all) により
# 処理終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド -----------------------------------------------------------------
# tty の上書き表示でビルドステップの出力が欠落しないよう、BuildKit の進捗形式を
# 明示する。BUILDKIT_PROGRESS が事前定義されている場合は利用者の指定を維持する。
export BUILDKIT_PROGRESS="$BUILD_PROGRESS"
log "BuildKit のビルドログ表示形式: ${BUILD_PROGRESS}"
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi

# ローカルベースイメージが生成されたか確認する。
# 複数サービス指定時は base の先行ビルド直後に確認し、問題があれば他サービスを
# ビルドする前に中止する。dry-run では実際にビルドしていないため確認をスキップする。
verify_local_image() {
  local image_info image_id image_created image_size
  if [ "$DRY_RUN" = "true" ]; then
    BUILD_IMAGE_INFO="ローカルイメージ確認は DRY-RUN のため未実行: ${LOCAL_IMAGE}"
    log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
  elif ! image_info="$(docker image inspect --format '{{.Id}}|{{.Created}}|{{.Size}}' "$LOCAL_IMAGE" 2>/dev/null)"; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="compose build 後にローカルベースイメージを確認できませんでした。"
    err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
    return 1
  else
    IFS='|' read -r image_id image_created image_size <<< "$image_info"
    # docker が返す作成日時は UTC 固定のため、表示前に JST へ変換する。
    image_created="$(to_jst_display_time "$image_created")"
    BUILD_IMAGE_INFO="image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
    log "ビルド結果: image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
  fi
  return 0
}

BUILD_RESULT_STATUS="実行中"
BUILD_RESULT_DETAIL="docker compose build を開始しました。"
if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
  # ベースイメージを参照するサービス群と base を同時にビルドすると、base の
  # 完成前に他サービスのビルドが始まる可能性がある。そこで base を第 1 フェーズで
  # 必ず単独ビルドし、成功確認後に残りを 1 回の compose build で並列ビルドする。
  log "複数の compose サービスが指定されました。ベースサービス '${BASE_SERVICE}' を先行ビルドします ..."
  if ! execute_compose_build "base:${BASE_SERVICE}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "$BASE_SERVICE"; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました。"
    err "ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました"
    exit 1
  fi
  [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${BASE_SERVICE})。"
  if ! verify_local_image; then
    exit 1
  fi

  # base が明示的な指定に含まれていても再ビルドしない。含まれていない場合も
  # base はビルド専用の前提サービスとして扱い、起動対象には追加しない。
  REMAINING_SERVICES=()
  for _service in "${COMPOSE_SERVICES[@]}"; do
    [ "$_service" = "$BASE_SERVICE" ] || REMAINING_SERVICES+=("$_service")
  done

  if [ ${#REMAINING_SERVICES[@]} -gt 0 ]; then
    log "ベースサービス以外をまとめて並列ビルドします (${COMPOSE_FILE}, 対象サービス: ${REMAINING_SERVICES[*]}) ..."
    if ! execute_compose_build "services:${REMAINING_SERVICES[*]}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "${REMAINING_SERVICES[@]}"; then
      BUILD_RESULT_STATUS="失敗"
      BUILD_RESULT_DETAIL="ベースサービス以外の compose build に失敗しました: ${REMAINING_SERVICES[*]}"
      err "ベースサービス以外の compose build に失敗しました (対象サービス: ${REMAINING_SERVICES[*]})"
      exit 1
    fi
    [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${REMAINING_SERVICES[*]})。"
  else
    log "ベースサービス以外のビルド対象はありません。"
  fi
else
  if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    log "docker compose build を実行します (${COMPOSE_FILE}, 対象サービス: ${COMPOSE_SERVICES[*]}) ..."
  else
    log "docker compose build を実行します (${COMPOSE_FILE}, 全サービス) ..."
  fi
  if ! execute_compose_build "services:${COMPOSE_SERVICES[*]:-all}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="compose build に失敗しました。"
    err "compose build に失敗しました"
    exit 1
  fi
  if [ "$DRY_RUN" != "true" ]; then
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      log "compose build に成功しました (対象サービス: ${COMPOSE_SERVICES[*]})。"
    else
      log "compose build に成功しました (全サービス)。"
    fi
  fi
  if ! verify_local_image; then
    exit 1
  fi
fi

if ! verify_jboss_standalone_password "$LOCAL_IMAGE"; then
  BUILD_RESULT_STATUS="失敗"
  BUILD_RESULT_DETAIL="standalone.xml の JBoss credential-store マスターパスワード照合に失敗しました。"
  exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
  BUILD_RESULT_STATUS="DRY-RUN (未実行)"
  BUILD_RESULT_DETAIL="ビルドコマンドのプレビューが完了しました。"
else
  BUILD_RESULT_STATUS="成功"
  BUILD_RESULT_DETAIL="docker compose build とローカルイメージ確認が完了しました。"
fi

# ---- 起動確認が不要ならここで終了 -------------------------------------------
if [ "$NEED_CONTAINER" != "true" ]; then
  if [ "$ENV_LIST_LIMIT" != "all" ] || [ -n "$ENV_LIST_FILE" ]; then
    warn "環境変数一覧はコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_TREE_DEPTH_SET" = "true" ]; then
    warn "コンテナ内ディレクトリツリーはコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] || [ ${#DEPLOYMENT_DIR_ENVS[@]} -gt 0 ]; then
    warn "ファイル表示切替と JBoss EAP デプロイ構造はコンテナ起動を伴う動作確認時のみ画面表示されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$BUILD_REPORT_DIR_SET" = "true" ]; then
    warn "全量レポートの環境変数・ツリー・JBoss EAP デプロイ構造・JVM パラメータ・OpenTelemetry 設定は、コンテナ未起動のため未取得として記録します。"
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] ビルドのみが完了しました (実際のビルドは行われていません)。"
  else
    log "ビルドのみが完了しました。"
  fi
  exit 0
fi

# ---- コンテナ起動 -----------------------------------------------------------
if ! start_container; then
  exit 1
fi

# ---- jbosseap 起動確認 ------------------------------------------------------
# --verify-startup 指定時はログから起動完了を確認する。
# (--verify-url のみの場合は起動ログ確認をスキップし、URL のリトライで readiness を担保する)
if [ "$VERIFY_STARTUP" = "true" ]; then
  if ! wait_for_startup; then
    err "起動確認に失敗しました。"
    exit 1
  fi
fi

# ---- URL 応答確認 -----------------------------------------------------------
if [ -n "$VERIFY_URL" ]; then
  if ! verify_url; then
    err "URL 応答確認に失敗しました。"
    exit 1
  fi
fi

# ---- 起動維持後の対話操作 ---------------------------------------------------
if ! run_keep_container_interaction; then
  err "起動維持後の対話操作に失敗しました。コンテナは起動状態のまま残します。"
  exit 1
fi

show_verified_container_envs
show_verified_container_directory_trees
show_verified_container_deployment_structures
show_verified_container_jvm_parameters
show_verified_container_otel_settings

if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "ビルドおよび確認が完了しました。"
fi
exit 0
