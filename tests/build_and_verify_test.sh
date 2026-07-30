#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-and-verify-test.XXXXXX")"

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/build-and-verify-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'Refusing to remove unexpected test directory: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_occurrences() {
  local file="$1" expected="$2" expected_count="$3" actual_count
  actual_count="$({ grep -Fo -- "$expected" "$file" || true; } | wc -l | tr -d '[:space:]')"
  [ "$actual_count" = "$expected_count" ] \
    || fail "expected '$expected' $expected_count times in $file, found $actual_count"
}

assert_matches() {
  local file="$1" pattern="$2"
  grep -Eq -- "$pattern" "$file" || fail "expected /$pattern/ in $file"
}

assert_before() {
  local file="$1" first="$2" second="$3" first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$file" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$first_line" ] || fail "expected '$first' in $file"
  [ -n "$second_line" ] || fail "expected '$second' in $file"
  [ "$first_line" -lt "$second_line" ] || fail "expected '$first' before '$second' in $file"
}

mkdir -p "$TEST_TMP/bin"
cp "$TEST_DIR/helpers/docker" "$TEST_TMP/bin/docker"
cp "$TEST_DIR/helpers/curl" "$TEST_TMP/bin/curl"
chmod 755 "$TEST_TMP/bin/docker" "$TEST_TMP/bin/curl"

export PATH="$TEST_TMP/bin:$PATH"
export FAKE_DOCKER_CALLS="$TEST_TMP/docker.calls"
export FAKE_CURL_CALLS="$TEST_TMP/curl.calls"

success_output="$TEST_TMP/success.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 2 \
    --directory-file-limit 10 \
    --deployment-dir-env APP_CONFIG_DIR \
    --report-dir "$TEST_TMP/reports" \
    --suppress-removed-logs
) >"$success_output" 2>&1; then
  cat "$success_output" >&2
  fail "success fixture returned a non-zero status"
fi

assert_contains "$success_output" "BuildKit のビルドログ表示形式: plain"
assert_contains "$success_output" "[fake-build] BUILDKIT_PROGRESS=plain"
assert_contains "$success_output" "ビルド結果: image=j1/base.local, id=sha256:test-image"
assert_contains "$success_output" "jbosseap サーバーの起動完了を確認しました: サービス 'app'"
assert_contains "$success_output" "コンテナ起動ログ (対象サービス: app, 末尾 15/15 行 (指定上限: 50)):"
assert_contains "$success_output" "APP000001: Orders application initialized"
assert_contains "$success_output" $'\033[1;36mapp-1  | 09:17:43,001 INFO'
assert_contains "$success_output" $'\033[1;32mapp-1  | 09:17:47,305 INFO'
assert_contains "$success_output" "java:jboss/datasources/Orders#Primary"
assert_contains "$success_output" "java:app/jdbc/ReportingDS"
assert_contains "$success_output" "orders.war"
assert_contains "$success_output" "/orders"
assert_occurrences "$success_output" "java:/JmsXA" 1
# WFLYSRV0009 の 1 行に old.war が 2 回現れる (名前と runtime-name) ため、
# 「アンデプロイ済みアプリを要約側で再掲しない」= 元ログ 1 行分 = 2 件が期待値。
assert_occurrences "$success_output" "old.war" 2
assert_occurrences "$success_output" "/opt/eap/standalone/data/content/ab/cd/content" 1
assert_not_contains "$success_output" "利用可能な JNDI データソース:"
assert_not_contains "$success_output" "JNDI データソースエラー:"
assert_not_contains "$success_output" "アプリケーションデプロイ結果ログ"
assert_not_contains "$success_output" "デプロイ済みアプリケーション:"
assert_not_contains "$success_output" "登録済み Web コンテキスト:"
assert_not_contains "$success_output" "同時起動 Compose サービスログ"
assert_contains "$success_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 2)"
assert_contains "$success_output" "通常ファイル: 直下 10 件以下は全ファイル名、超過時は拡張子別件数"
assert_contains "$success_output" "├── [ファイル] LICENSE"
assert_contains "$success_output" "├── app/"
assert_contains "$success_output" "│   ├── [ファイル] application.jar"
assert_contains "$success_output" "│   ├── [ファイル] archive.tar.gz"
assert_contains "$success_output" "│   ├── [ファイル] legacy.jar"
assert_contains "$success_output" "│   └── config/"
assert_contains "$success_output" "│       ├── [ファイル] application.yaml"
assert_contains "$success_output" "│       ├── [ファイル] .env"
assert_contains "$success_output" "├── afs/"
assert_contains "$success_output" "├── aws/"
assert_contains "$success_output" "├── etc/"
assert_contains "$success_output" "├── local/"
assert_contains "$success_output" "aws-cli/"
assert_contains "$success_output" "├── proc/"
assert_contains "$success_output" "    └── share/"
assert_contains "$success_output" "├── sys/"
assert_contains "$success_output" "    ├── lib/"
assert_contains "$success_output" "lib64/"
assert_contains "$success_output" "    ├── local/"
assert_contains "$success_output" "├── empty/"
assert_contains "$success_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_contains "$success_output" "[JBoss EAP デプロイ先]"
assert_contains "$success_output" "[Web アプリケーションルート]"
assert_contains "$success_output" "[Java クラスパスルート]"
assert_contains "$success_output" "[環境変数 APP_CONFIG_DIR]"
assert_contains "$success_output" "[ファイル] .class: 11 件"
assert_contains "$success_output" "[ファイル] .properties: 1 件"
assert_contains "$success_output" "[ファイル] runtime.properties"
assert_contains "$success_output" "API_TOKEN=[REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-value"
assert_not_contains "$success_output" "Order01.class"
assert_not_contains "$success_output" "deep.json"
assert_not_contains "$success_output" "aws-cli-hidden/"
assert_not_contains "$success_output" "X11/"
assert_not_contains "$success_output" "doc/"
assert_not_contains "$success_output" "icons/"
assert_not_contains "$success_output" "licenses/"
assert_not_contains "$success_output" "man/"
assert_not_contains "$success_output" "osinfo/"
assert_not_contains "$success_output" "zoneinfo/"
assert_not_contains "$success_output" "X11-hidden"
assert_not_contains "$success_output" "doc-hidden"
assert_not_contains "$success_output" "icons-hidden"
assert_not_contains "$success_output" "licenses-hidden"
assert_not_contains "$success_output" "man-hidden"
assert_not_contains "$success_output" "osinfo-hidden"
assert_not_contains "$success_output" "zoneinfo-hidden"
assert_not_contains "$success_output" "lib64-hidden/"
assert_not_contains "$success_output" "aws-cli-hidden.txt"
assert_not_contains "$success_output" "lib64-hidden.so"
assert_not_contains "$success_output" "public/"
assert_not_contains "$success_output" "[ファイル] readme.txt"
assert_not_contains "$success_output" "zoneinfo.txt"
assert_not_contains "$success_output" "usr-local-hidden"
assert_contains "$success_output" "Java JVM パラメータ (サービス: app, コンテナ: test-app-1, Java プロセス: 1)"
assert_contains "$success_output" "[Java プロセス 1] PID: 1"
assert_contains "$success_output" "実行ファイル     : /opt/java/openjdk/bin/java"
assert_contains "$success_output" 'バージョン       : openjdk version "17.0.11" 2024-04-16 LTS'
assert_contains "$success_output" "起動対象         : -jar /opt/jboss-eap/jboss-modules.jar"
assert_contains "$success_output" "[ヒープ・メモリ] 4 件"
assert_contains "$success_output" "  -Xmx1024m"
assert_contains "$success_output" "  -XX:MaxMetaspaceSize                         = 256m"
assert_contains "$success_output" "[GC (ガベージコレクション)] 2 件"
assert_contains "$success_output" "  -XX:+UseG1GC"
assert_contains "$success_output" "[Java エージェント] 1 件"
assert_contains "$success_output" "  -javaagent                                   = /opt/otel/opentelemetry-javaagent.jar"
assert_contains "$success_output" "[JBoss / WildFly] 2 件"
assert_contains "$success_output" "[システムプロパティ (-D)] 2 件"
assert_contains "$success_output" "[クラスパス・モジュール] 2 件"
assert_contains "$success_output" "  --add-exports                                = java.base/sun.nio.ch=ALL-UNNAMED"
assert_contains "$success_output" "[その他 JVM オプション] 1 件"
assert_contains "$success_output" "[起動対象へ渡される引数] 4 件"
assert_contains "$success_output" "  org.jboss.as.standalone"
assert_contains "$success_output" "[JVM オプションを渡す環境変数] 1 件"
assert_contains "$success_output" "  JAVA_TOOL_OPTIONS                            = -javaagent:/opt/otel/opentelemetry-javaagent.jar"
# JVM パラメータ側の認証情報も環境変数一覧と同じく値だけを伏せる。
assert_contains "$success_output" "  -Djboss.password                             = [REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-jvm-value"
assert_contains "$success_output" "OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: app, コンテナ: test-app-1)"
assert_contains "$success_output" "[OpenTelemetry 標準環境変数 (OTEL_*)] 4 件"
assert_contains "$success_output" "  OTEL_SERVICE_NAME                            = orders-app"
assert_contains "$success_output" "  OTEL_EXPORTER_OTLP_ENDPOINT                  = http://adot-collector:4317"
# OTLP ヘッダは認証情報を載せる用途が多いため値を伏せる。
assert_contains "$success_output" "  OTEL_EXPORTER_OTLP_HEADERS                   = [REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-header"
assert_contains "$success_output" "[OpenTelemetry 関連環境変数] 1 件"
assert_contains "$success_output" "[OpenTelemetry 関連 JVM パラメータ (コマンドライン)] 4 件"
assert_contains "$success_output" "  -Dotel.exporter.otlp.endpoint                = http://adot-collector:4317"
assert_contains "$success_output" "[OpenTelemetry 関連 JVM パラメータ (環境変数由来)] 1 件"
assert_contains "$success_output" "  JAVA_TOOL_OPTIONS: -javaagent                = /opt/otel/opentelemetry-javaagent.jar"
assert_contains "$success_output" "[未設定の主要 OpenTelemetry 設定] 7 件"
assert_contains "$success_output" "  OTEL_PROPAGATORS (システムプロパティ -Dotel.propagators も未設定)"
# 環境変数・システムプロパティのどちらかで設定済みの項目は未設定側へ出さない。
assert_not_contains "$success_output" "OTEL_SERVICE_NAME (システムプロパティ"
assert_not_contains "$success_output" "OTEL_TRACES_EXPORTER (システムプロパティ"
assert_before "$success_output" "環境変数一覧 (サービス: app" "コンテナ内ディレクトリツリー (サービス: app"
assert_before "$success_output" "コンテナ内ディレクトリツリー (サービス: app" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_before "$success_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造" "Java JVM パラメータ (サービス: app"
assert_before "$success_output" "Java JVM パラメータ (サービス: app" "OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: app"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ app'
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / .* -path /afs .* -path /local/aws-cli .* -path /opt/jboss-eap/modules/system/layers/base .* -path /usr/share .* -path /usr/share/X11 .* -path /usr/share/doc .* -path /usr/share/icons .* -path /usr/share/licenses .* -path /usr/share/man .* -path /usr/share/osinfo .* -path /usr/share/zoneinfo .* -path /usr/lib64 .* -path /usr/local .* -prune -print0 -o -type d -print0'
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / .* -path /afs .* -path /local/aws-cli .* -path /opt/jboss-eap/modules/system/layers/base .* -path /usr/share .* -path /usr/share/X11 .* -path /usr/share/doc .* -path /usr/share/icons .* -path /usr/share/licenses .* -path /usr/share/man .* -path /usr/share/osinfo .* -path /usr/share/zoneinfo .* -path /usr/lib64 .* -path /usr/local .* -prune -o -type f -print0'
assert_not_contains "$FAKE_DOCKER_CALLS" "-path /share "
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / -maxdepth 3 .* -type f -print0'

report_files=("$TEST_TMP/reports"/build_and_verify_*.txt)
[ ${#report_files[@]} -eq 1 ] && [ -f "${report_files[0]}" ] \
  || fail "expected one timestamped full build report"
full_report="${report_files[0]}"
[[ "$(basename "$full_report")" =~ ^build_and_verify_[0-9]{14}(_[0-9]+)?\.txt$ ]] \
  || fail "unexpected full build report filename: $full_report"
assert_matches "$full_report" 'build_and_verify\.sh 全量ビルドレポート'
assert_contains "$full_report" "全体結果     : 成功"
assert_contains "$full_report" "[1] ビルド結果"
assert_contains "$full_report" "[2] 環境変数一覧 (全件)"
assert_contains "$full_report" "[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)"
assert_contains "$full_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)"
assert_contains "$full_report" "[5] Java JVM パラメータ (全件)"
assert_contains "$full_report" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)"
assert_contains "$full_report" "[7] Compose サービス別ログ (全サービス・全行)"
assert_contains "$full_report" "処理が成功したため、Compose サービス別ログの全文出力は省略しました。"
assert_contains "$full_report" "API_TOKEN=[REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-value"
assert_contains "$full_report" "[Java プロセス 1] PID: 1"
assert_contains "$full_report" "  -Djboss.password                             = [REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-jvm-value"
assert_contains "$full_report" "  OTEL_EXPORTER_OTLP_HEADERS                   = [REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-header"
assert_contains "$full_report" "  OTEL_SERVICE_NAME                            = orders-app"
assert_contains "$full_report" "[未設定の主要 OpenTelemetry 設定] 7 件"
assert_before "$full_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)" "[5] Java JVM パラメータ (全件)"
assert_before "$full_report" "[5] Java JVM パラメータ (全件)" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)"
assert_before "$full_report" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)" "[7] Compose サービス別ログ (全サービス・全行)"
assert_contains "$full_report" "application.yaml"
assert_contains "$full_report" "deep.json"
assert_contains "$full_report" "Order01.class"
assert_contains "$full_report" "Order11.class"
assert_contains "$full_report" ".galleon/"
assert_contains "$full_report" "aws-cli/"
assert_contains "$full_report" "base/"
assert_contains "$full_report" "    └── share/"
assert_contains "$full_report" "    ├── local/"
assert_contains "$full_report" "lib64/"
assert_not_contains "$full_report" "zoneinfo.txt"
assert_not_contains "$full_report" "cache/"
assert_not_contains "$full_report" "hosts"
assert_not_contains "$full_report" "ssl/"
assert_not_contains "$full_report" "galleon-hidden/"
assert_not_contains "$full_report" "metadata.json"
assert_not_contains "$full_report" "status"
assert_not_contains "$full_report" "kernel/"
assert_not_contains "$full_report" "jvm/"
assert_not_contains "$full_report" "libexample.so"
assert_not_contains "$full_report" "uevent_seqnum"
assert_not_contains "$full_report" "aws-cli-hidden/"
assert_not_contains "$full_report" "jboss-base-hidden/"
assert_not_contains "$full_report" "X11/"
assert_not_contains "$full_report" "doc/"
assert_not_contains "$full_report" "icons/"
assert_not_contains "$full_report" "licenses/"
assert_not_contains "$full_report" "man/"
assert_not_contains "$full_report" "osinfo/"
assert_not_contains "$full_report" "zoneinfo/"
assert_not_contains "$full_report" "X11-hidden"
assert_not_contains "$full_report" "doc-hidden"
assert_not_contains "$full_report" "icons-hidden"
assert_not_contains "$full_report" "licenses-hidden"
assert_not_contains "$full_report" "man-hidden"
assert_not_contains "$full_report" "osinfo-hidden"
assert_not_contains "$full_report" "zoneinfo-hidden"
assert_not_contains "$full_report" "lib64-hidden/"
assert_not_contains "$full_report" "aws-cli-hidden.txt"
assert_not_contains "$full_report" "jboss-base-hidden.xml"
assert_not_contains "$full_report" "lib64-hidden.so"
assert_not_contains "$full_report" "public/"
assert_not_contains "$full_report" "assets/"
assert_not_contains "$full_report" "readme.txt"
assert_not_contains "$full_report" "logo.svg"
assert_not_contains "$full_report" "usr-local-hidden"

startup_log_limit_output="$TEST_TMP/startup-log-limit.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --startup-log-lines 2 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$startup_log_limit_output" 2>&1; then
  cat "$startup_log_limit_output" >&2
  fail "startup log line limit scenario returned a non-zero status"
fi

assert_contains "$startup_log_limit_output" "コンテナ起動ログ (対象サービス: app, 末尾 2/15 行 (指定上限: 2)):"
assert_contains "$startup_log_limit_output" "WFLYSRV0010"
assert_contains "$startup_log_limit_output" "WFLYSRV0025"
assert_not_contains "$startup_log_limit_output" "WFLYSRV0049"
assert_not_contains "$startup_log_limit_output" "APP000001"
assert_not_contains "$startup_log_limit_output" $'\033['

companion_logs_output="$TEST_TMP/companion-logs.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app db cache"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,db,cache \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$companion_logs_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$companion_logs_output" >&2
  fail "companion Compose service log scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$companion_logs_output" "コンテナ起動ログ (対象サービス: app, 末尾 15/15 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "同時起動 Compose サービスログ (サービス: db, 末尾 50/52 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "DB003: companion service log"
assert_contains "$companion_logs_output" "DB052: companion service log"
assert_not_contains "$companion_logs_output" "DB001: companion service log"
assert_not_contains "$companion_logs_output" "DB002: companion service log"
assert_contains "$companion_logs_output" "同時起動 Compose サービスログ (サービス: cache, 末尾 2/2 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "CACHE002: accepting connections"
assert_before "$companion_logs_output" "コンテナ起動ログ (対象サービス: app" "同時起動 Compose サービスログ (サービス: db"
assert_before "$companion_logs_output" "同時起動 Compose サービスログ (サービス: db" "同時起動 Compose サービスログ (サービス: cache"
assert_before "$companion_logs_output" "同時起動 Compose サービスログ (サービス: cache" "環境変数一覧 (サービス: app"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml ps --services"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ db'
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ cache'

tree_depth_output="$TEST_TMP/tree-depth.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$tree_depth_output" 2>&1; then
  cat "$tree_depth_output" >&2
  fail "directory tree depth scenario returned a non-zero status"
fi

assert_contains "$tree_depth_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 1)"
assert_contains "$tree_depth_output" "通常ファイル: 表示しない"
assert_contains "$tree_depth_output" "├── app/"
assert_contains "$tree_depth_output" "├── empty/"
assert_contains "$tree_depth_output" "├── afs/"
assert_contains "$tree_depth_output" "├── aws/"
assert_contains "$tree_depth_output" "├── etc/"
assert_contains "$tree_depth_output" "├── proc/"
assert_contains "$tree_depth_output" "├── sys/"
assert_not_contains "$tree_depth_output" "config/"
assert_not_contains "$tree_depth_output" "[ファイル]"
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / -maxdepth 1 .* -prune -print0 -o -type d -print0'
assert_not_contains "$FAKE_DOCKER_CALLS" "-type f -print0"

invalid_startup_log_lines_output="$TEST_TMP/startup-log-lines-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --startup-log-lines 0
) >"$invalid_startup_log_lines_output" 2>&1; then
  cat "$invalid_startup_log_lines_output" >&2
  fail "invalid startup log line limit unexpectedly returned zero"
fi
assert_contains "$invalid_startup_log_lines_output" "--startup-log-lines には 1 以上の整数を指定してください: 0"

invalid_tree_depth_output="$TEST_TMP/tree-depth-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-tree-depth 0
) >"$invalid_tree_depth_output" 2>&1; then
  cat "$invalid_tree_depth_output" >&2
  fail "invalid directory tree depth unexpectedly returned zero"
fi
assert_contains "$invalid_tree_depth_output" "--directory-tree-depth には 1 以上の整数を指定してください: 0"

invalid_file_limit_output="$TEST_TMP/file-limit-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-file-limit 0
) >"$invalid_file_limit_output" 2>&1; then
  cat "$invalid_file_limit_output" >&2
  fail "invalid directory file limit unexpectedly returned zero"
fi
assert_contains "$invalid_file_limit_output" "--directory-file-limit には 1 以上の整数を指定してください: 0"

invalid_deployment_env_output="$TEST_TMP/deployment-env-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --deployment-dir-env 'INVALID-NAME'
) >"$invalid_deployment_env_output" 2>&1; then
  cat "$invalid_deployment_env_output" >&2
  fail "invalid deployment directory environment name unexpectedly returned zero"
fi
assert_contains "$invalid_deployment_env_output" "--deployment-dir-env に不正な環境変数名が指定されました: INVALID-NAME"

tree_find_failure_output="$TEST_TMP/tree-find-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_DOCKER_FIND_FAIL="true"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$tree_find_failure_output" 2>&1; then
  cat "$tree_find_failure_output" >&2
  fail "missing container find command unexpectedly failed verification"
fi
unset FAKE_DOCKER_FIND_FAIL

assert_contains "$tree_find_failure_output" "コンテナ内ディレクトリツリーを取得できませんでした (サービス: app, コンテナ: test-app-1, ルート: /)"
assert_contains "$tree_find_failure_output" "ビルドおよび確認が完了しました。"

failure_output="$TEST_TMP/failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
# 起動確認対象 (app) 以外に、コンテナを持つサイドカー (adot-collector) と
# コンテナを持たない定義だけのサービス (base / cache) を混在させる。
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector cache"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
if (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/failure-reports" \
    --suppress-removed-logs
) >"$failure_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$failure_output" >&2
  fail "failure fixture unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_contains "$failure_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failure_output" "コンテナ起動ログ (対象サービス: app, 末尾 5/5 行 (指定上限: 50)):"
assert_contains "$failure_output" $'\033[1;31mapp-1  | 09:18:00,100 ERROR'
assert_contains "$failure_output" "WFLYSRV0026"
assert_contains "$failure_output" "WFLYSRV0021"
assert_contains "$failure_output" "WFLYJCA0031"
assert_not_contains "$failure_output" "[デプロイエラー関連]"
assert_not_contains "$failure_output" "JNDI データソースエラー:"
assert_not_contains "$failure_output" "アプリケーションデプロイ結果ログ"
assert_not_contains "$failure_output" "起動完了を確認しました"
failure_report_files=("$TEST_TMP/failure-reports"/build_and_verify_*.txt)
[ ${#failure_report_files[@]} -eq 1 ] && [ -f "${failure_report_files[0]}" ] \
  || fail "expected one report for failed verification"
assert_contains "${failure_report_files[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${failure_report_files[0]}" "結果          : 成功"
# 失敗レポートには、起動確認対象・サイドカーを問わず全 Compose サービスのログを
# サービス単位に区切って残す。
assert_contains "${failure_report_files[0]}" "[7] Compose サービス別ログ (全サービス・全行)"
assert_contains "${failure_report_files[0]}" "対象サービス  : base app adot-collector cache (4 サービス)"
assert_contains "${failure_report_files[0]}" "[7-1] Compose サービス: base"
assert_contains "${failure_report_files[0]}" "[7-2] Compose サービス: app"
assert_contains "${failure_report_files[0]}" "[7-3] Compose サービス: adot-collector"
assert_contains "${failure_report_files[0]}" "[7-4] Compose サービス: cache"
assert_contains "${failure_report_files[0]}" "コンテナ      : test-app-1 (状態: running)"
assert_contains "${failure_report_files[0]}" "コンテナ      : adot-collector (状態: exited, 終了コード: 1)"
assert_contains "${failure_report_files[0]}" "ログ行数      : 5 行"
assert_contains "${failure_report_files[0]}" "ログ行数      : 1 行"
assert_contains "${failure_report_files[0]}" "ログ行数      : 2 行"
assert_contains "${failure_report_files[0]}" "WFLYSRV0026"
assert_contains "${failure_report_files[0]}" "adot-collector  | TracesExporter resource spans: 2, spans: 4"
assert_contains "${failure_report_files[0]}" "cache-1  | CACHE001: cache ready"
assert_before "${failure_report_files[0]}" "[7-1] Compose サービス: base" "[7-2] Compose サービス: app"
assert_before "${failure_report_files[0]}" "[7-2] Compose サービス: app" "[7-3] Compose サービス: adot-collector"
assert_before "${failure_report_files[0]}" "[7-3] Compose サービス: adot-collector" "[7-4] Compose サービス: cache"
assert_before "${failure_report_files[0]}" "[7-3] Compose サービス: adot-collector" "TracesExporter resource spans"
assert_before "${failure_report_files[0]}" "TracesExporter resource spans" "[7-4] Compose サービス: cache"
# レポートは画面表示の行数制限に影響されず、ANSI 色コードも残さない。
assert_not_contains "${failure_report_files[0]}" $'\033['

# adot collector の healthcheck 失敗で depends_on: service_healthy を満たせず、
# compose up が失敗する状況。ECS のタスク停止と同じく SIGTERM で終了させ、
# サイドカーの終了処理ログまで画面とレポートへ残す。
shutdown_logs_output="$TEST_TMP/shutdown-logs.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
export FAKE_COMPOSE_UP_FAIL="true"
export FAKE_COMPOSE_SHUTDOWN_MARKER="$TEST_TMP/compose-stopped"
rm -f "$FAKE_COMPOSE_SHUTDOWN_MARKER"
if (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,adot-collector \
    --startup-service app \
    --wait-healthy \
    --report-dir "$TEST_TMP/shutdown-reports"
) >"$shutdown_logs_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
  unset FAKE_COMPOSE_SHUTDOWN_MARKER
  cat "$shutdown_logs_output" >&2
  fail "unhealthy dependency scenario unexpectedly returned zero"
fi

assert_contains "$shutdown_logs_output" "コンテナの起動に失敗しました (compose up)"
assert_contains "$shutdown_logs_output" "エラー終了のため、ECS のタスク停止と同じく SIGTERM でコンテナを終了させ、終了処理のログを取得します (compose stop -t 30, 対象: app adot-collector)"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml stop -t 30'
# サイドカーは SIGTERM 受信後の graceful shutdown ログまで表示する。
assert_contains "$shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ (サービス: adot-collector, 追加 3 行):"
assert_contains "$shutdown_logs_output" 'Received signal from OS {"signal": "terminated"}'
assert_contains "$shutdown_logs_output" "Shutdown complete."
# 終了ログを出さないコンテナは、その旨を明示して差分なしと分かるようにする。
assert_contains "$shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ (サービス: app, 追加 0 行):"
assert_contains "$shutdown_logs_output" "SIGTERM 受信後に追加されたログはありません。"
assert_before "$shutdown_logs_output" \
  "終了 (SIGTERM) 時のコンテナログ (サービス: app" \
  "終了 (SIGTERM) 時のコンテナログ (サービス: adot-collector"
shutdown_reports=("$TEST_TMP/shutdown-reports"/build_and_verify_*.txt)
[ ${#shutdown_reports[@]} -eq 1 ] && [ -f "${shutdown_reports[0]}" ] \
  || fail "expected one report for unhealthy dependency scenario"
# 全量レポートのログ本文も、SIGTERM 送出後に取得した終了処理込みのものとなる。
assert_contains "${shutdown_reports[0]}" "終了処理      : SIGTERM (compose stop -t 30) 送出後の終了ログまで含む"
assert_contains "${shutdown_reports[0]}" "[7-3] Compose サービス: adot-collector"
assert_contains "${shutdown_reports[0]}" "Shutdown complete."
assert_contains "${shutdown_reports[0]}" "ログ行数      : 4 行"

# --no-shutdown-logs 指定時は SIGTERM 停止も終了ログの取得も行わない。
no_shutdown_logs_output="$TEST_TMP/no-shutdown-logs.out"
: > "$FAKE_DOCKER_CALLS"
rm -f "$FAKE_COMPOSE_SHUTDOWN_MARKER"
if (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,adot-collector \
    --startup-service app \
    --wait-healthy \
    --no-shutdown-logs
) >"$no_shutdown_logs_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
  unset FAKE_COMPOSE_SHUTDOWN_MARKER
  cat "$no_shutdown_logs_output" >&2
  fail "--no-shutdown-logs scenario unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
unset FAKE_COMPOSE_SHUTDOWN_MARKER

assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml stop"
assert_not_contains "$no_shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ"

invalid_shutdown_timeout_output="$TEST_TMP/shutdown-timeout-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --shutdown-timeout 0
) >"$invalid_shutdown_timeout_output" 2>&1; then
  cat "$invalid_shutdown_timeout_output" >&2
  fail "invalid shutdown timeout unexpectedly returned zero"
fi
assert_contains "$invalid_shutdown_timeout_output" "--shutdown-timeout には 1 以上の整数を指定してください: 0"

build_failure_output="$TEST_TMP/build-failure.out"
export FAKE_DOCKER_BUILD_FAIL="true"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_NO_CONTAINERS="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --report-dir "$TEST_TMP/build-failure-reports"
) >"$build_failure_output" 2>&1; then
  unset FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_NO_CONTAINERS
  cat "$build_failure_output" >&2
  fail "failed compose build unexpectedly returned zero"
fi
unset FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_NO_CONTAINERS
assert_contains "$build_failure_output" "compose build に失敗しました"
build_failure_reports=("$TEST_TMP/build-failure-reports"/build_and_verify_*.txt)
[ ${#build_failure_reports[@]} -eq 1 ] && [ -f "${build_failure_reports[0]}" ] \
  || fail "expected one report for failed compose build"
assert_contains "${build_failure_reports[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${build_failure_reports[0]}" "結果          : 失敗"
assert_contains "${build_failure_reports[0]}" "対象コンテナが起動していないため取得していません。"
# ビルド失敗でコンテナが 1 つも作られていない場合も、compose.yml 定義の全サービスを
# 見出しとして残し、ログがないことを明示する。
assert_contains "${build_failure_reports[0]}" "[7] Compose サービス別ログ (全サービス・全行)"
assert_contains "${build_failure_reports[0]}" "取得範囲      : コンテナ作成時からの全期間 (compose up 到達前に終了)"
assert_contains "${build_failure_reports[0]}" "対象サービス  : base app adot-collector (3 サービス)"
assert_contains "${build_failure_reports[0]}" "[7-1] Compose サービス: base"
assert_contains "${build_failure_reports[0]}" "[7-2] Compose サービス: app"
assert_contains "${build_failure_reports[0]}" "[7-3] Compose サービス: adot-collector"
assert_occurrences "${build_failure_reports[0]}" "コンテナ      : (コンテナなし)" 3
assert_occurrences "${build_failure_reports[0]}" "(このサービスのログはありません)" 3

# $ / # / ! / 二重引用符 / バッククォートを含む値が、取得元から Compose secret、
# XML エンティティ復元後の standalone.xml まで同一であり、平文はログへ残らない。
special_password='Special$#!"`Master'
jboss_password_success_output="$TEST_TMP/jboss-password-success.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD="true"
export FAKE_JBOSS_STANDALONE_XML_FILE="$TEST_DIR/fixtures/standalone-jboss-password-match.xml"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --jboss-password "$special_password" \
    --report-dir "$TEST_TMP/jboss-password-success-reports"
) >"$jboss_password_success_output" 2>&1; then
  unset FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD FAKE_JBOSS_STANDALONE_XML_FILE
  cat "$jboss_password_success_output" >&2
  fail "special-character JBoss password match scenario returned a non-zero status"
fi
unset FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD FAKE_JBOSS_STANDALONE_XML_FILE

assert_not_contains "$jboss_password_success_output" "$special_password"
assert_contains "$jboss_password_success_output" "[REDACTED:JBOSS_MASTER_PASSWORD]"
assert_contains "$jboss_password_success_output" "対象特殊文字={ドル記号($):1, 番号記号(#):1, 感嘆符(!):1, 二重引用符(\"):1, バッククォート(\`):1}"
assert_contains "$jboss_password_success_output" "パスワード推移[2/5] 取得元から環境変数 JBOSS_MASTER_PASSWORD への設定は完全一致です。"
assert_contains "$jboss_password_success_output" "パスワード推移[3/5] Compose の environment=JBOSS_MASTER_PASSWORD と build secret source=jboss_master_password の対応は一致しています。"
assert_contains "$jboss_password_success_output" "literal clear-text の照合結果=完全一致"
assert_contains "$jboss_password_success_output" "パスワード推移[5/5] JBoss CLI が standalone.xml に生成した credential-store のうち、少なくとも1件の literal clear-text は入力値と完全一致しています"
assert_contains "$FAKE_DOCKER_CALLS" "create j1/base.local"
assert_contains "$FAKE_DOCKER_CALLS" "cp cid-jboss-password-diagnostic:/opt/eap/standalone/configuration/standalone.xml"
jboss_password_success_reports=("$TEST_TMP/jboss-password-success-reports"/build_and_verify_*.txt)
[ ${#jboss_password_success_reports[@]} -eq 1 ] \
  && [ -f "${jboss_password_success_reports[0]}" ] \
  || fail "expected one report for successful JBoss password diagnostics"
assert_contains "${jboss_password_success_reports[0]}" "[1-A] JBoss マスターパスワード推移診断 (平文・ハッシュ非表示)"
assert_contains "${jboss_password_success_reports[0]}" "standalone.xml の literal clear-text と完全一致"
assert_not_contains "${jboss_password_success_reports[0]}" "$special_password"

# XML へ生成された literal clear-text だけが異なる場合は、BuildKit secret 以降から
# JBoss CLI の引用・エスケープまでを不一致区間として特定し、成功扱いにしない。
jboss_password_mismatch_output="$TEST_TMP/jboss-password-mismatch.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_JBOSS_STANDALONE_XML_FILE="$TEST_DIR/fixtures/standalone-jboss-password-mismatch.xml"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --jboss-password "$special_password"
) >"$jboss_password_mismatch_output" 2>&1; then
  unset FAKE_JBOSS_STANDALONE_XML_FILE
  cat "$jboss_password_mismatch_output" >&2
  fail "mismatched standalone.xml password unexpectedly returned zero"
fi
unset FAKE_JBOSS_STANDALONE_XML_FILE

assert_not_contains "$jboss_password_mismatch_output" "$special_password"
assert_not_contains "$jboss_password_mismatch_output" 'Special$#!"`MasteX'
assert_contains "$jboss_password_mismatch_output" "literal clear-text の照合結果=不一致"
assert_contains "$jboss_password_mismatch_output" "standalone.xml 側の credential-store マスターパスワードと入力値が一致しません"
assert_contains "$jboss_password_mismatch_output" "BuildKit secret 以降から JBoss CLI の引用・エスケープを経て XML に保存されるまでの区間"

# Compose の environment が --jboss-password-env と異なる場合はビルド前に止め、
# どちらの設定名を照合して不一致になったかを明示する。
jboss_password_env_mismatch_output="$TEST_TMP/jboss-password-env-mismatch.out"
: > "$FAKE_DOCKER_CALLS"
export CUSTOM_JBOSS_PASSWORD="$special_password"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --jboss-password-env CUSTOM_JBOSS_PASSWORD
) >"$jboss_password_env_mismatch_output" 2>&1; then
  unset CUSTOM_JBOSS_PASSWORD
  cat "$jboss_password_env_mismatch_output" >&2
  fail "mismatched Compose password environment unexpectedly returned zero"
fi
unset CUSTOM_JBOSS_PASSWORD

assert_not_contains "$jboss_password_env_mismatch_output" "$special_password"
assert_contains "$jboss_password_env_mismatch_output" "環境変数名が不一致です: 入力・export 先=CUSTOM_JBOSS_PASSWORD, Compose secret 'jboss_master_password' の参照先=JBOSS_MASTER_PASSWORD"
assert_contains "$jboss_password_env_mismatch_output" "Compose が別のパスワード設定を読むため"
assert_not_contains "$jboss_password_env_mismatch_output" "[fake-build]"

# compose 版の secret id は CLI オプションではなく compose.yml で決まるため、
# environment が一致する任意の id を正規化済み設定から逆引きできる。
jboss_custom_secret_id_output="$TEST_TMP/jboss-custom-secret-id.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_CONFIG_SECRET_ID="custom_jboss_secret"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --jboss-password "$special_password"
) >"$jboss_custom_secret_id_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SECRET_ID
  cat "$jboss_custom_secret_id_output" >&2
  fail "custom Compose secret id scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_CONFIG_SECRET_ID

assert_not_contains "$jboss_custom_secret_id_output" "$special_password"
assert_contains "$jboss_custom_secret_id_output" "Compose の environment=JBOSS_MASTER_PASSWORD と build secret source=custom_jboss_secret の対応は一致しています。"
assert_contains "$jboss_custom_secret_id_output" "最終イメージ j1/base.local の標準 EAP_HOME 候補に standalone.xml はありませんでした。"

# credential-store の復号失敗を含むビルドログは、平文をマスクしたうえで原因区間と
# 「CLI/XML の設定値 対 credential-store ファイル暗号化パスワード」を明示する。
jboss_password_build_failure_output="$TEST_TMP/jboss-password-build-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD="true"
export FAKE_DOCKER_BUILD_LOG_FILE="$TEST_DIR/fixtures/jboss-password-build-failure.log"
export FAKE_DOCKER_BUILD_FAIL="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --jboss-password "$special_password"
) >"$jboss_password_build_failure_output" 2>&1; then
  unset FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD FAKE_DOCKER_BUILD_LOG_FILE FAKE_DOCKER_BUILD_FAIL
  cat "$jboss_password_build_failure_output" >&2
  fail "JBoss password-related build failure unexpectedly returned zero"
fi
unset FAKE_DOCKER_BUILD_ECHO_JBOSS_PASSWORD FAKE_DOCKER_BUILD_LOG_FILE FAKE_DOCKER_BUILD_FAIL

assert_not_contains "$jboss_password_build_failure_output" "$special_password"
assert_contains "$jboss_password_build_failure_output" "[REDACTED:JBOSS_MASTER_PASSWORD]"
assert_contains "$jboss_password_build_failure_output" "ビルド失敗は JBoss マスターパスワード、JBoss CLI、または Elytron credential-store に関連している可能性が高いです"
assert_contains "$jboss_password_build_failure_output" "JBoss CLI / standalone.xml の credential-store マスターパスワードと、既存 credential-store ファイルを暗号化したパスワードとの照合"
assert_contains "$jboss_password_build_failure_output" "UnrecoverableKeyException: password was incorrect"
assert_contains "$jboss_password_build_failure_output" "最終イメージが確定しないため、JBoss CLI が解釈した clear-text 値と standalone.xml は直接取得できません"

# JVM を実行しないコンテナ (OTel Collector / DB など) でも、Java プロセス無しを
# 明示したうえで OpenTelemetry の環境変数側は同じ形式で一覧化する。
no_java_output="$TEST_TMP/no-java-process.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_DOCKER_NO_JAVA_PROCESS="true"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$no_java_output" 2>&1; then
  unset FAKE_DOCKER_NO_JAVA_PROCESS
  cat "$no_java_output" >&2
  fail "non-java container scenario returned a non-zero status"
fi
unset FAKE_DOCKER_NO_JAVA_PROCESS

assert_contains "$no_java_output" "Java JVM パラメータ (サービス: app, コンテナ: test-app-1, Java プロセス: 0)"
assert_contains "$no_java_output" "Java プロセスを検出できませんでした。"
assert_not_contains "$no_java_output" "[Java プロセス 1] PID:"
assert_contains "$no_java_output" "[OpenTelemetry 標準環境変数 (OTEL_*)] 4 件"
assert_contains "$no_java_output" "[OpenTelemetry 関連 JVM パラメータ (コマンドライン)] 0 件"
assert_contains "$no_java_output" "[OpenTelemetry 関連 JVM パラメータ (環境変数由来)] 1 件"

invalid_keep_mode_output="$TEST_TMP/keep-mode-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --keep-container-mode invalid
) >"$invalid_keep_mode_output" 2>&1; then
  cat "$invalid_keep_mode_output" >&2
  fail "invalid keep-container mode unexpectedly returned zero"
fi
assert_contains "$invalid_keep_mode_output" "--keep-container-mode には bash、http または logs を指定してください: invalid"

invalid_http_port_output="$TEST_TMP/keep-mode-http-invalid-port.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --keep-container-mode http \
    --jboss-http-port 65536
) >"$invalid_http_port_output" 2>&1; then
  cat "$invalid_http_port_output" >&2
  fail "invalid JBoss HTTP port unexpectedly returned zero"
fi
assert_contains "$invalid_http_port_output" "--jboss-http-port には 1 から 65535 の範囲を指定してください: 65536"

bash_mode_output="$TEST_TMP/keep-mode-bash.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --keep-container-mode bash \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$bash_mode_output" 2>&1; then
  cat "$bash_mode_output" >&2
  fail "bash keep-container mode returned a non-zero status"
fi

assert_contains "$bash_mode_output" "検証対象コンテナの bash へ接続します"
assert_contains "$bash_mode_output" "bash セッションを終了しました。コンテナは起動状態を維持します"
assert_contains "$bash_mode_output" "コンテナを残します (--keep-container)"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-app /bin/bash"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

logs_mode_output="$TEST_TMP/keep-mode-logs.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app db"
if ! printf 'invalid\n3\n2\ninvalid\n1\n\n0\n1\n2\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,db \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$logs_mode_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$logs_mode_output" >&2
  fail "Compose service action keep-container mode returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_occurrences "$logs_mode_output" "操作する起動中の Compose サービスを選択してください:" 3
assert_occurrences "$logs_mode_output" "  1) app" 3
assert_occurrences "$logs_mode_output" "  2) db" 3
assert_occurrences "$logs_mode_output" "0 から 2 の番号を入力してください。" 2
assert_occurrences "$logs_mode_output" "0 から 3 の番号を入力してください。" 1
assert_occurrences "$logs_mode_output" "Compose サービス 'db' で実行する操作を選択してください:" 3
assert_occurrences "$logs_mode_output" "Compose サービス 'app' で実行する操作を選択してください:" 3
assert_occurrences "$logs_mode_output" "  1) ログを表示" 6
assert_occurrences "$logs_mode_output" "  2) bash へ接続 (cd・任意コマンドを実行可能)" 6
assert_occurrences "$logs_mode_output" "  3) healthcheck 設定・実行履歴・通信を確認" 6
assert_not_contains "$logs_mode_output" "MySQL クライアントへ接続 (SQL クエリを対話実行)"
assert_occurrences "$logs_mode_output" "Compose サービスログ (サービス:" 1
assert_contains "$logs_mode_output" "Compose サービスログ (サービス: db, 末尾 50/52 行 (指定上限: 50)):"
assert_contains "$logs_mode_output" "DB003: companion service log"
assert_contains "$logs_mode_output" "DB052: companion service log"
assert_not_contains "$logs_mode_output" "DB001: companion service log"
assert_not_contains "$logs_mode_output" "DB002: companion service log"
assert_contains "$logs_mode_output" "Compose サービスの bash へ接続します (service=app, container=test-app-1)。"
assert_contains "$logs_mode_output" "この bash セッション内では cd によるディレクトリ移動と任意のコマンド実行が可能です。"
assert_contains "$logs_mode_output" "bash セッションを終了しました。サービス操作の選択へ戻ります。"
assert_contains "$logs_mode_output" "Docker healthcheck 診断"
assert_contains "$logs_mode_output" "Compose サービス : app"
assert_contains "$logs_mode_output" "curl -fs http://127.0.0.1:8080/health >/dev/null || exit 1"
assert_contains "$logs_mode_output" "現在状態       : healthy"
assert_contains "$logs_mode_output" "連続失敗回数   : 0"
assert_contains "$logs_mode_output" "保持された履歴 : 2 件"
assert_contains "$logs_mode_output" "healthcheck request completed"
assert_contains "$logs_mode_output" "手動再実行結果 : OK"
assert_contains "$logs_mode_output" "実行上限   : 60 秒 (--url-timeout)"
assert_contains "$logs_mode_output" "[HTTP healthcheck 通信詳細（補助リクエスト）]"
assert_contains "$logs_mode_output" "リクエスト : [GET] http://127.0.0.1:8080/health"
assert_contains "$logs_mode_output" "HTTP/1.1 200 OK"
assert_contains "$logs_mode_output" 'Set-Cookie: [REDACTED]'
assert_contains "$logs_mode_output" '"status":"UP","token":"[REDACTED]"'
assert_not_contains "$logs_mode_output" "response-cookie-secret"
assert_not_contains "$logs_mode_output" "response-token-secret"
assert_contains "$logs_mode_output" "http_status=200"
assert_contains "$logs_mode_output" "remote=127.0.0.1:8080"
assert_before "$logs_mode_output" "Compose サービスログ (サービス: db" "Compose サービスの bash へ接続します (service=app"
assert_contains "$logs_mode_output" "Compose サービス 'db' の操作を終了し、サービス選択へ戻ります。"
assert_contains "$logs_mode_output" "Compose サービス 'app' の操作を終了し、サービス選択へ戻ります。"
assert_contains "$logs_mode_output" "Compose サービスの対話操作を終了しました。"
assert_contains "$logs_mode_output" "コンテナを残します (--keep-container)"
assert_occurrences "$FAKE_DOCKER_CALLS" "compose -f compose.yml ps --services" 3
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ db'
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-app /bin/bash"
assert_contains "$FAKE_DOCKER_CALLS" ".Config.Healthcheck.Test"
assert_contains "$FAKE_DOCKER_CALLS" ".State.Health.Log"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app /bin/sh -c curl -fs http://127.0.0.1:8080/health >/dev/null || exit 1"
assert_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe http://127.0.0.1:8080/health 60 GET"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

no_healthcheck_output="$TEST_TMP/keep-mode-no-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="nohealth"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service nohealth \
    --startup-service nohealth \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$no_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$no_healthcheck_output" >&2
  fail "service without a healthcheck returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$no_healthcheck_output" "Compose サービス : nohealth"
assert_contains "$no_healthcheck_output" "設定             : healthcheck は設定されていません。"
assert_contains "$no_healthcheck_output" "Docker 実行履歴  : 対象外"
assert_not_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe"

sensitive_healthcheck_output="$TEST_TMP/keep-mode-sensitive-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_HEALTHCHECK_SECRET="true"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$sensitive_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_SECRET
  cat "$sensitive_healthcheck_output" >&2
  fail "sensitive healthcheck diagnosis returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_SECRET

assert_contains "$sensitive_healthcheck_output" "curl -u [REDACTED] -fs http://127.0.0.1:8080/health"
assert_contains "$sensitive_healthcheck_output" "ホストのプロセス引数への露出を避けて手動再実行と HTTP 補助リクエストをスキップします。"
assert_not_contains "$sensitive_healthcheck_output" "super-secret"
assert_not_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe"

failed_healthcheck_output="$TEST_TMP/keep-mode-failed-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_HEALTHCHECK_STATE_FAIL="true"
export FAKE_HEALTHCHECK_EXACT_FAIL="true"
export FAKE_HEALTHCHECK_HTTP_FAIL="true"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$failed_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_STATE_FAIL \
    FAKE_HEALTHCHECK_EXACT_FAIL FAKE_HEALTHCHECK_HTTP_FAIL
  cat "$failed_healthcheck_output" >&2
  fail "failed healthcheck diagnosis did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_STATE_FAIL \
  FAKE_HEALTHCHECK_EXACT_FAIL FAKE_HEALTHCHECK_HTTP_FAIL

assert_contains "$failed_healthcheck_output" "現在状態       : unhealthy"
assert_contains "$failed_healthcheck_output" "連続失敗回数   : 3"
assert_contains "$failed_healthcheck_output" "終了コード : 22"
assert_contains "$failed_healthcheck_output" "手動再実行結果 : NG (exit=22)"
assert_contains "$failed_healthcheck_output" "curl: (7) Failed to connect to 127.0.0.1 port 8080"
assert_contains "$failed_healthcheck_output" "healthcheck の HTTP 補助リクエストに失敗しました (exit=7)。"
assert_contains "$failed_healthcheck_output" "Compose サービスの対話操作を終了しました。"

mysql_helper_output="$TEST_TMP/keep-mode-mysql-helper.out"
: > "$FAKE_DOCKER_CALLS"
# MySQL 8.0.42 と MySQL 8.4 / Aurora 8.4 互換系を同じ操作経路で確認する。
export FAKE_COMPOSE_PS_SERVICES="app mysql80 aurora84"
if ! printf '2\n4\n0\n3\n4\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,mysql80,aurora84 \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$mysql_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$mysql_helper_output" >&2
  fail "MySQL interactive client helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_occurrences "$mysql_helper_output" "  4) MySQL クライアントへ接続 (SQL クエリを対話実行)" 4
assert_contains "$mysql_helper_output" "MySQL クライアントへ接続します (service=mysql80, container=mysql-8.0.42)。"
assert_contains "$mysql_helper_output" "MySQL クライアントへ接続します (service=aurora84, container=aurora-mysql-8.4)。"
assert_contains "$mysql_helper_output" "SQL クエリを対話実行できます。終了するには exit または \\q を入力してください。"
assert_contains "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.0.42"
assert_contains "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.4.6"
assert_before "$mysql_helper_output" "MySQL クライアントへ接続します (service=mysql80" "Welcome to the MySQL monitor.  Server version: 8.0.42"
assert_before "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.0.42" "MySQL セッションを終了しました。サービス操作の選択へ戻ります。"
assert_occurrences "$mysql_helper_output" "MySQL セッションを終了しました。サービス操作の選択へ戻ります。" 2
assert_occurrences "$mysql_helper_output" "操作する起動中の Compose サービスを選択してください:" 3
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-mysql80 /bin/sh -c"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-mysql84 /bin/sh -c"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-mysql80 /bin/sh -c set -eu"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-mysql84 /bin/sh -c set -eu"
assert_contains "$FAKE_DOCKER_CALLS" "umask 077"
assert_contains "$FAKE_DOCKER_CALLS" "trap cleanup_mysql_option_file EXIT HUP INT TERM"
assert_contains "$FAKE_DOCKER_CALLS" 'set -- --defaults-extra-file="$mysql_option_file" --protocol=socket --user="$mysql_user"'
assert_not_contains "$FAKE_DOCKER_CALLS" "--password="
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

mysql_failure_output="$TEST_TMP/keep-mode-mysql-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="mysql80"
export FAKE_MYSQL_CLIENT_FAIL="true"
if ! printf '1\n4\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service mysql80 \
    --startup-service mysql80 \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$mysql_failure_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_MYSQL_CLIENT_FAIL
  cat "$mysql_failure_output" >&2
  fail "failed MySQL client scenario did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_MYSQL_CLIENT_FAIL

assert_contains "$mysql_failure_output" "Compose サービス 'mysql80' の MySQL クライアントへ接続できませんでした"
assert_contains "$mysql_failure_output" "MySQL 接続に失敗しました。サービス操作の選択へ戻ります。"
assert_occurrences "$mysql_failure_output" "Compose サービス 'mysql80' で実行する操作を選択してください:" 2
assert_contains "$mysql_failure_output" "Compose サービスの対話操作を終了しました。"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

cwagent_helper_output="$TEST_TMP/keep-mode-cwagent-helper.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app cwagent cloudwatch-logs-mock"
export FAKE_CLOUDWATCH_JOURNAL_FILE="$TEST_DIR/fixtures/cloudwatch-wiremock-requests.json"
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$cwagent_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_CLOUDWATCH_JOURNAL_FILE
  cat "$cwagent_helper_output" >&2
  fail "cwagent CloudWatch Logs helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_CLOUDWATCH_JOURNAL_FILE

assert_contains "$cwagent_helper_output" "4) CloudWatch Logs 偽装送達を確認 (ロググループ / ストリーム / イベント)"
assert_contains "$cwagent_helper_output" "CloudWatch Agent → CloudWatch Logs 偽装サービスの送達を確認します。"
assert_contains "$cwagent_helper_output" "WireMock API 受信総数: CreateLogGroup=2, CreateLogStream=2, PutLogEvents=3"
assert_contains "$cwagent_helper_output" "[OK] /mnt/logs/app-front*.log"
assert_contains "$cwagent_helper_output" "log group : /local/myapp/efs/app-front"
assert_contains "$cwagent_helper_output" "log stream: front-local"
assert_contains "$cwagent_helper_output" "[OK] /mnt/logs/app-back*.log"
assert_contains "$cwagent_helper_output" "request completed token=[REDACTED]"
assert_contains "$cwagent_helper_output" "database call completed"
assert_not_contains "$cwagent_helper_output" "dummy-secret"
assert_not_contains "$cwagent_helper_output" "AWS4-HMAC-SHA256"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-cwagent cat /etc/cwagentconfig/cwagent-config.json"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-cloudwatch-logs-mock 8080/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18480/__admin/requests?limit=100"
assert_contains "$FAKE_CURL_CALLS" "Logs_20140328.PutLogEvents"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

otel_helper_output="$TEST_TMP/keep-mode-otel-helper.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_FILE="$TEST_DIR/fixtures/jaeger-services.json"
export FAKE_JAEGER_TRACES_FILE="$TEST_DIR/fixtures/jaeger-traces.json"
if ! printf '2\n3\n\n4\ninvalid\n1\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE
  cat "$otel_helper_output" >&2
  fail "OTel Jaeger trace helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE

assert_contains "$otel_helper_output" "4) X-Ray 偽装 Jaeger のトレースを確認 (サービス / トレース / スパン)"
assert_contains "$otel_helper_output" "[healthcheck 実行ファイル]"
assert_contains "$otel_helper_output" "ファイル: /healthcheck"
assert_contains "$otel_helper_output" "実行権限: あり"
assert_contains "$otel_helper_output" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  /healthcheck"
assert_contains "$otel_helper_output" "手動再実行結果 : OK"
assert_contains "$otel_helper_output" "HTTP(S) URL を含む healthcheck ではないため、HTTP 補助リクエストは対象外です。"
assert_contains "$otel_helper_output" "OTel Collector ヘルスチェック: OK (service=adot-collector)"
assert_contains "$otel_helper_output" "TracesExporter resource spans: 2, spans: 4"
assert_contains "$otel_helper_output" "OTel Collector → X-Ray 偽装 Jaeger のトレース送達を確認します。"
assert_contains "$otel_helper_output" "実 AWS X-Ray への送信確認ではありません。"
assert_contains "$otel_helper_output" "0 から 2 の番号を入力してください。"
assert_contains "$otel_helper_output" "検索サービス: myapp-front"
assert_contains "$otel_helper_output" "取得トレース: 1 件"
assert_contains "$otel_helper_output" "traceID=66a00000000000001234567890abcdef"
assert_contains "$otel_helper_output" "services=myapp-back, myapp-front"
assert_contains "$otel_helper_output" "[myapp-front] GET /orders"
assert_contains "$otel_helper_output" "[myapp-back] SELECT orders"
assert_contains "$otel_helper_output" "db.system=mysql"
assert_contains "$otel_helper_output" "http.request.header.authorization=[REDACTED]"
assert_contains "$otel_helper_output" "SELECT * FROM orders WHERE token=[REDACTED]"
assert_not_contains "$otel_helper_output" "dummy-secret"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-adot-collector /healthcheck"
assert_contains "$FAKE_DOCKER_CALLS" "healthcheck-file /healthcheck"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-jaeger 16686/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:16686/api/services"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode service=myapp-front"
# Python ヘルパーの出力に CR 等が混ざるとサービス名が壊れるため、後続引数まで検査する。
assert_matches "$FAKE_CURL_CALLS" 'service=myapp-front --data-urlencode'
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:16686/api/traces"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

otel_no_traces_output="$TEST_TMP/keep-mode-otel-no-traces.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_no_traces_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY
  cat "$otel_no_traces_output" >&2
  fail "empty Jaeger service scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY
assert_contains "$otel_no_traces_output" "Jaeger にトレースサービスが登録されていません。"
assert_contains "$otel_no_traces_output" "サービス操作の選択へ戻ります"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# distroless の adot-collector: /bin/sh も wget も /healthcheck も無い状態で、
# compose の healthcheck 定義 → シェル無し直接実行 → ホストからの HTTP 確認へ
# フォールバックできることを確認する。
otel_distroless_output="$TEST_TMP/keep-mode-otel-distroless.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
export FAKE_ADOT_DISTROLESS="true"
if ! printf '2\n3\n\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_distroless_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS
  cat "$otel_distroless_output" >&2
  fail "distroless adot-collector scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS

assert_contains "$otel_distroless_output" \
  "実行方式   : コンテナ内にシェルが無いため docker exec で直接実行: wget -q -O- http://127.0.0.1:13133/"
assert_contains "$otel_distroless_output" "コンテナ内にシェルが無いため、ホストからの HTTP 確認へ切り替えます。"
assert_contains "$otel_distroless_output" "送信元     : ホスト (curl、コンテナへは公開ポート/コンテナ IP 経由)"
assert_contains "$otel_distroless_output" '{"status":"Server available"}'
assert_contains "$otel_distroless_output" "OTel Collector ヘルスチェック: OK (service=adot-collector)"
assert_contains "$otel_distroless_output" "確認方式: ホストから health_check エンドポイントへ HTTP 確認"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-adot-collector wget -q -O- http://127.0.0.1:13133/"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-adot-collector 13133/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:13133/"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 自動確認の手段が尽きた場合は、手元で実行すべきコマンドを案内する。
otel_manual_output="$TEST_TMP/keep-mode-otel-manual-commands.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
export FAKE_ADOT_DISTROLESS="true"
export FAKE_OTEL_HEALTH_HTTP_FAIL="true"
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_manual_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS \
    FAKE_OTEL_HEALTH_HTTP_FAIL
  cat "$otel_manual_output" >&2
  fail "adot-collector manual command guidance scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS \
  FAKE_OTEL_HEALTH_HTTP_FAIL

assert_contains "$otel_manual_output" "health_check エンドポイントへの HTTP 確認にも失敗しました"
assert_contains "$otel_manual_output" "[手動で確認する場合のコマンド]"
assert_contains "$otel_manual_output" \
  "  docker inspect --format '{{json .State.Health}}' adot-collector"
assert_contains "$otel_manual_output" \
  "  docker run --rm --network container:adot-collector curlimages/curl:latest -sS -i http://127.0.0.1:13133/"
assert_contains "$otel_manual_output" "  curl -sS -i http://127.0.0.1:13133/"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

http_get_output="$TEST_TMP/keep-mode-http-get.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="201"
export FAKE_CURL_BODY='{"message":"ready"}'
if ! printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_get_output" 2>&1; then
  cat "$http_get_output" >&2
  fail "interactive HTTP GET mode returned a non-zero status"
fi

assert_contains "$http_get_output" "JBoss EAP ログからコンテキストルートを検出しました: /orders"
assert_contains "$http_get_output" "JBoss EAP ログから HTTP リスナーポートを検出しました: 8080"
assert_contains "$http_get_output" "Docker 公開ポートを検出しました: 8080/tcp -> 127.0.0.1:18080"
assert_contains "$http_get_output" "HTTP ステータスコード : 201"
assert_contains "$http_get_output" '{"message":"ready"}'
assert_contains "$FAKE_DOCKER_CALLS" "port cid-app 8080/tcp"
assert_contains "$FAKE_CURL_CALLS" "--request GET http://127.0.0.1:18080/orders/status"
assert_not_contains "$FAKE_CURL_CALLS" "--data-binary"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

http_json_output="$TEST_TMP/keep-mode-http-json.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="202"
export FAKE_CURL_BODY='{"accepted":true}'
if ! printf 'submit\n2\n1\n{"target":"orders"}\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_json_output" 2>&1; then
  cat "$http_json_output" >&2
  fail "interactive HTTP JSON POST mode returned a non-zero status"
fi

assert_contains "$http_json_output" "HTTP ステータスコード : 202"
assert_contains "$http_json_output" '{"accepted":true}'
assert_contains "$FAKE_CURL_CALLS" "--request POST"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/json"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" 'request-body={"target":"orders"}'
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/orders/submit"

http_form_output="$TEST_TMP/keep-mode-http-form.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="200"
export FAKE_CURL_BODY='token-issued'
if ! printf '/token\n2\n2\ngrant_type=client_credentials&scope=read\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --jboss-context-root /custom/ \
    --jboss-http-port 8080 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_form_output" 2>&1; then
  cat "$http_form_output" >&2
  fail "interactive HTTP form POST mode returned a non-zero status"
fi

assert_contains "$http_form_output" "指定された JBoss EAP コンテキストルートを使用します: /custom"
assert_contains "$http_form_output" "指定された JBoss EAP HTTP リスナーポートを使用します: 8080"
assert_contains "$http_form_output" "HTTP ステータスコード : 200"
assert_contains "$http_form_output" "token-issued"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/x-www-form-urlencoded"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" "request-body=grant_type=client_credentials&scope=read"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/custom/token"

http_failure_output="$TEST_TMP/keep-mode-http-curl-failure.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="000"
export FAKE_CURL_BODY='connection failed'
export FAKE_CURL_EXIT_STATUS="7"
if printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_failure_output" 2>&1; then
  cat "$http_failure_output" >&2
  fail "curl transport failure unexpectedly returned zero"
fi

assert_contains "$http_failure_output" "HTTP ステータスコード : 000"
assert_contains "$http_failure_output" "connection failed"
assert_contains "$http_failure_output" "curl による HTTP 通信に失敗しました (exit=7, HTTP=000)"
assert_contains "$http_failure_output" "コンテナを残します (--keep-container)"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

unset FAKE_CURL_STATUS FAKE_CURL_BODY FAKE_CURL_EXIT_STATUS

export FAKE_DOCKER_CLEANED="$TEST_TMP/docker.cleaned"

dry_run_cleanup_output="$TEST_TMP/cleanup-dry-run.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --cleanup-all-docker-data
) >"$dry_run_cleanup_output" 2>&1; then
  cat "$dry_run_cleanup_output" >&2
  fail "cleanup dry-run returned a non-zero status"
fi

assert_contains "$dry_run_cleanup_output" "現在の Docker context の全ローカルデータを削除します"
assert_contains "$dry_run_cleanup_output" "[DRY-RUN] 確認入力と Docker データ削除は行いません"
assert_contains "$dry_run_cleanup_output" "docker volume prune --all --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"

conflicting_cleanup_output="$TEST_TMP/cleanup-conflicting-options.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --cleanup-all-docker-data \
    --keep-container
) >"$conflicting_cleanup_output" 2>&1; then
  cat "$conflicting_cleanup_output" >&2
  fail "conflicting cleanup options unexpectedly returned zero"
fi
assert_contains "$conflicting_cleanup_output" "--cleanup-all-docker-data と --keep-container は同時に指定できません"

declined_cleanup_output="$TEST_TMP/cleanup-declined.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if printf 'cancel\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$declined_cleanup_output" 2>&1; then
  cat "$declined_cleanup_output" >&2
  fail "declined cleanup unexpectedly returned zero"
fi

assert_contains "$declined_cleanup_output" "続行するには 'DELETE ALL DOCKER DATA' と正確に入力してください"
assert_contains "$declined_cleanup_output" "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

failed_build_cleanup_output="$TEST_TMP/cleanup-after-failed-build.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
if printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$failed_build_cleanup_output" 2>&1; then
  cat "$failed_build_cleanup_output" >&2
  fail "failed build with confirmed cleanup unexpectedly returned zero"
fi

assert_contains "$failed_build_cleanup_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failed_build_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$failed_build_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"

confirmed_cleanup_output="$TEST_TMP/cleanup-confirmed.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$confirmed_cleanup_output" 2>&1; then
  cat "$confirmed_cleanup_output" >&2
  fail "confirmed cleanup returned a non-zero status"
fi

assert_contains "$confirmed_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$confirmed_cleanup_output" "容量削減結果 (Docker 管理対象・概算): 2.79 GiB"
assert_contains "$confirmed_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "container unpause cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container stop cid-running cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "builder prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "image prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "volume prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "network prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

printf 'PASS: build_and_verify.sh password diagnostics, startup/companion logs, tree rendering/pruning, interaction, full report, and Docker cleanup scenarios\n'
