#!/usr/bin/env bash
#
# buildx_build_and_push.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# compose.yml を使う build_and_push.sh とは別に、docker buildx コマンドで
# ローカルベースイメージ (既定: j1/base.local) をビルドし、
#   aws ecr get-login-password | docker login  (ECR ログイン)
#   docker image tag                           (ECR 用タグ付け)
#   docker image push                          (ECR へプッシュ)
# を実行して、結果として imagedefinition.json を出力する。
#
# 権限まわりの前提 (build_and_push.sh と同じ):
#   - スクリプト開始時に、事前に aws login --remote による認証操作が実行されて
#     いるかをチェックし、未認証の場合は認証を促す警告を出して終了する (exit 1)。
#   - このステージでは CodeCommit の操作は不要。ECR の操作権限のみが必要。
#   - 現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べる:
#       (A) 既定 (--warn-only)  : スイッチバックを促す警告を出して終了 (exit 1)
#       (B)     (--auto-switchback): 別チーム提供のスイッチバック用シェルを
#                                    source で呼び出し、自動的にスイッチバック
#                                    してから処理を継続する。
#   - スイッチバック用シェルの配置場所は --switchback-shell で指定可能。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - buildx build の前に、パラメータストアの指定キー (--jboss-password-param)
#     から JBoss のマスターパスワードを取得できる。パラメータストアから取得せず
#     直接渡す (--jboss-password) ことも可能。
#   - 取得したマスターパスワードは環境変数 (--jboss-password-env, 既定:
#     JBOSS_MASTER_PASSWORD) へ export し、buildx の
#     --secret id=<id>,env=<環境変数名> (environment 型シークレット) として
#     安全にビルドへ注入する (イメージのレイヤや履歴には残らない)。
#
# 使い方:
#   ./buildx_build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
#       --jboss-password-param /j1/jboss/master-password \
#       --auto-switchback --switchback-shell /opt/team/switchback.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 表示タイムゾーン (JST 固定) --------------------------------------------
# ホストや CI が UTC でも、ログ・イメージタグ・ログファイル名の時刻を JST に揃える。
# tzdata を持たない環境でも +09:00 になるよう、Asia/Tokyo が使えない場合は tzdata
# 不要の POSIX 形式 (JST-9) へフォールバックする。
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
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
REGISTRY="${ECR_REGISTRY:-}"      # ECR レジストリ名(URL)。未指定なら <account>.dkr.ecr.<region>.amazonaws.com を組み立てる
REPOSITORY="baseimage"            # ECR 側リポジトリ名 (= プッシュするイメージ名)。ECR / Docker の規則により小文字のみ
TAG_PREFIX="BaseImage"            # イメージタグの接頭辞。タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> となる (リポジトリ名とは独立。タグは大文字可)
LOCAL_IMAGE="j1/base.local"       # buildx build で生成するローカルベースイメージ名
CONTAINER_NAME=""                 # imagedefinition.json の name。未指定なら REPOSITORY を使用
DOCKERFILE="Dockerfile"           # buildx build に渡す Dockerfile
BUILD_CONTEXT="."                 # buildx build のビルドコンテキスト
PLATFORM=""                       # 例: linux/amd64 (--load のため単一プラットフォームのみ)
BUILDER=""                        # 使用する buildx ビルダー名 (未指定なら現在のビルダー)
BUILD_ARGS=()                     # --build-arg KEY=VALUE (繰り返し指定可)
BUILD_CONTEXTS=()                 # --build-context NAME=VALUE (追加のビルドコンテキスト, 繰り返し指定可)
SECRETS=()                        # --secret id=...,src=... 等 (ビルドシークレット, 繰り返し指定可)
PROGRESS=""                       # buildx の進捗表示形式 (auto/plain/tty/rawjson)。未指定なら buildx 既定
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
OUTPUT_FILE="imagedefinition.json"
ECR_USERNAME="AWS"                # ECR ログイン時の固定ユーザー名
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
LOG_DIR=""                        # 指定時: コンソール出力をこのディレクトリのログファイルにも保存する
LOG_FILE=""                       # --log-dir 指定時に組み立てる実際のログファイルパス
TEE_PID=""                        # ログ複製用 tee (プロセス置換) の PID

# 一時ファイル (SSM のエラー出力 / push ログ)。途中終了時も残さないよう EXIT トラップで削除する。
TEMP_FILES=()

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
COPY_SPECS=()
COPIED_FILES=()

# スイッチバック関連
SWITCHBACK_SHELL="${SWITCHBACK_SHELL:-}"
AUTO_SWITCHBACK="false"           # false: 警告して終了 / true: 自動スイッチバック

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ID="jboss_master_password"     # buildx --secret の id (Dockerfile から参照する名前)
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか

# ---- ログ用ヘルパ -----------------------------------------------------------
# スクリプト開始時刻 (処理実行時間の算出に使用)
START_EPOCH="$(date +%s)"
# 表示する時刻はすべて JST。UTC と読み違えないよう、必ずタイムゾーン名を併記する。
now_display_time() { printf '%s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL"; }
log()  { printf '[%s] %s\n'  "$(now_display_time)" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(now_display_time)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(now_display_time)" "$*" >&2; }
# 診断ガイド出力用 (タイムスタンプ等の接頭辞を付けず、そのまま整形表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(now_display_time)" "$*"
    return 0
  fi
  "$@"
}

# 開始時刻からの経過時間 (処理実行時間) を人間可読な形式でログ出力する。
# EXIT トラップから呼ばれるため、成功・失敗いずれの経路でも記録される。
log_elapsed() {
  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed=$(( end_epoch - START_EPOCH ))
  log "処理実行時間: ${elapsed} 秒 ($(printf '%02d:%02d:%02d' \
      "$(( elapsed / 3600 ))" "$(( (elapsed % 3600) / 60 ))" "$(( elapsed % 60 ))"))"
}

# ログ複製 (tee) への書き込み側を閉じて EOF を通知し、tee が書き切るまで待つ。
# これを行わないとシェルの終了と tee の書き込みが競合し、ログファイル末尾の行
# (処理実行時間など) が欠けることがある。出力先を閉じるため EXIT トラップの最後で呼ぶ。
finish_logging() {
  [ -n "$TEE_PID" ] || return 0
  exec 1>&- 2>&-
  wait "$TEE_PID" 2>/dev/null
  TEE_PID=""
}

# 一時ファイルを作成してパスを返す。mktemp が使えない環境で予測可能なパス
# (/tmp/xxx.$$) へフォールバックすると、シンボリックリンク経由の上書きや
# 他プロセスとの衝突を招くため、その場で失敗させる。
new_temp_file() {
  local f
  f="$(mktemp 2>/dev/null)" || f=""
  if [ -z "$f" ]; then
    err "一時ファイルを作成できませんでした (mktemp が利用できません)。TMPDIR を確認してください。"
    return 1
  fi
  printf '%s' "$f"
}

# EXIT トラップから呼び出す一時ファイルの削除処理 (途中終了・中断時も残さない)。
cleanup_temp_files() {
  [ ${#TEMP_FILES[@]} -eq 0 ] && return 0
  local f
  for f in "${TEMP_FILES[@]}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  TEMP_FILES=()
  return 0
}

# imagedefinition.json へ埋め込む値を JSON 文字列としてエスケープする。
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

usage() {
  cat <<'EOF'
Usage: buildx_build_and_push.sh [OPTIONS]

docker buildx でビルドし、ECR ログイン / docker image tag / docker image push を
実行するスクリプト (compose.yml を使う build_and_push.sh の buildx 版)。

Options:
  --account-id ID          ECR レジストリの AWS アカウント ID (env: AWS_ACCOUNT_ID)
  --region REGION          AWS リージョン (既定: ap-northeast-1 / env: AWS_REGION)
  --registry URL           ECR レジストリ名(URL) を明示指定 (env: ECR_REGISTRY)
                           例: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
                           (未指定時は <account-id>.dkr.ecr.<region>.amazonaws.com を組み立て)
  --repository NAME        ECR リポジトリ名 = プッシュするイメージ名 (既定: baseimage)
                           ECR / Docker の規則により小文字英数字と . _ - / のみ使用できる
  --tag-prefix PREFIX      イメージタグの接頭辞 (既定: BaseImage)。リポジトリ名とは独立に
                           指定でき、タグは <PREFIX>-<YYYYMMDDHHMMSS> となる
                           例: BaseImage-20260702153000
                           (タグは大文字も使用できる。使用可能文字: 英数字 . _ -)
  --local-image NAME       buildx build で生成するローカルイメージ名 (既定: j1/base.local)
  --container-name NAME    imagedefinition.json の name (既定: --repository の値)

  --dockerfile FILE        Dockerfile のパス (既定: Dockerfile)
  --context DIR            ビルドコンテキスト (既定: .)
  --platform PLATFORM      ターゲットプラットフォーム (例: linux/amd64)。
                           ローカルに --load するため単一プラットフォームのみ指定可
  --builder NAME           使用する buildx ビルダー名 (未指定なら現在のビルダー)
  --build-arg KEY=VALUE    ビルド引数 (繰り返し指定可)
  --build-context NAME=VALUE
                           追加のビルドコンテキスト (繰り返し指定可)。
                           Dockerfile の FROM / COPY --from= で名前参照できる。
                           VALUE にはローカルディレクトリ / Git URL / イメージ
                           (docker-image://...) / URL 等を指定できる。
                           例: --build-context libs=./libs \
                               --build-context alpine=docker-image://alpine:3.20
  --secret SPEC            ビルドシークレット (繰り返し指定可)。Dockerfile の
                           RUN --mount=type=secret,id=... から参照できる。
                           SPEC は buildx の --secret と同一書式。
                           例: --secret id=npmrc,src=./.npmrc \
                               --secret id=token,env=GITHUB_TOKEN
  --progress MODE          進捗表示形式 (auto/plain/tty/rawjson)。未指定なら buildx 既定。
                           CI ログには plain が読みやすい
  --no-cache               キャッシュを破棄して buildx build する

  --output FILE            imagedefinition の出力先 (既定: imagedefinition.json)
  --log-dir DIR            コンソールに出力されるログを、DIR 配下のログファイルにも
                           保存する (画面表示は従来どおり継続)。ログ末尾には処理実行
                           時間 (経過秒数) も記録される。
                           - DIR が存在しない場合は自動作成する (mkdir -p)
                           - ファイル名は buildx_build_and_push_<YYYYMMDDHHMMSS>.log
  --dry-run                実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は
                           行わず、実行される内容のプレビューのみ表示する

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           ビルド終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc:./app --copy-file cert.pem:./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は事故防止のため中止する

  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           buildx の --secret id=<id>,env=<環境変数名> として
                           BuildKit シークレット注入される。Dockerfile からは
                           RUN --mount=type=secret,id=<id> で参照できる。
  --jboss-password VALUE   JBoss のマスターパスワードを直接指定する
                           (パラメータストアから取得しない場合)。
                           --jboss-password-param とは同時に指定できない。
                           ※ コマンドライン (ps / シェル履歴) に平文が残るため、
                             可能なら --jboss-password-param か、事前 export +
                             --jboss-password-env の利用を推奨。
  --jboss-password-env NAME
                           シークレットの受け渡しに使う環境変数名
                           (既定: JBOSS_MASTER_PASSWORD)。
                           このオプションのみを指定した場合は、事前に export
                           済みの環境変数の値をそのままパスワードとして使う。
  --jboss-secret-id ID     BuildKit シークレットの id (既定: jboss_master_password)。
                           Dockerfile の RUN --mount=type=secret,id=... と一致させる。

  --switchback-shell PATH  別チーム提供のスイッチバック用シェルのパス (source で呼び出し)
  --auto-switchback        ECR 権限が無い場合に自動でスイッチバックして継続する
  --warn-only              ECR 権限が無い場合に警告して終了する (既定)

  -h, --help               このヘルプを表示

備考:
  スクリプト開始時に AWS 認証 (aws login --remote 実施済みか) を確認し、
  未認証の場合は認証を促す警告を表示して終了する (exit 1)。
EOF
}

# ---- ログファイル出力の準備 (引数パースより前に行う) ------------------------
# --log-dir を先に解釈し、以降のコンソール出力 (stdout/stderr) を tee でログファイルへ
# 複製する。画面表示はそのまま継続し、時系列の順序を保つため stdout/stderr を
# 同一の tee にまとめる。パースエラー (不明オプション等) もログへ残すため、本パース
# より前のこの位置で設定する (--log-dir は後段の本パースでも受理する)。
# 走査では「オプションの値」をオプション名と取り違えないよう、値を取るオプションの
# 次の引数を読み飛ばす。ここに無いオプションは値なしとして扱う。
arg_takes_value() {
  case "$1" in
    --account-id|--region|--registry|--repository|--tag-prefix|--local-image) return 0 ;;
    --container-name|--dockerfile|--context|--platform|--builder|--build-arg) return 0 ;;
    --build-context|--secret|--progress|--output|--log-dir|--copy-file) return 0 ;;
    --jboss-password-param|--jboss-password|--jboss-password-env|--jboss-secret-id) return 0 ;;
    --switchback-shell) return 0 ;;
  esac
  return 1
}

_scan_args=("$@")
_scan_i=0
while [ "$_scan_i" -lt "${#_scan_args[@]}" ]; do
  _arg="${_scan_args[$_scan_i]}"
  _scan_i=$(( _scan_i + 1 ))
  if arg_takes_value "$_arg"; then
    if [ "$_scan_i" -lt "${#_scan_args[@]}" ]; then
      [ "$_arg" = "--log-dir" ] && LOG_DIR="${_scan_args[$_scan_i]}"
      _scan_i=$(( _scan_i + 1 ))
    fi
  fi
done

if [ -n "$LOG_DIR" ]; then
  if ! mkdir -p "$LOG_DIR"; then
    err "ログ出力先ディレクトリを作成できませんでした: $LOG_DIR"
    exit 1
  fi
  LOG_FILE="${LOG_DIR%/}/buildx_build_and_push_$(date '+%Y%m%d%H%M%S').log"
  # 以降の全出力を tee で LOG_FILE にも書き込む (画面にも出力)
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=$!
  # このパス以降のどの経路 (パースエラー等の途中 exit 含む) でも処理実行時間を残す。
  # 後段で一時ファイル削除も伴うトラップに差し替える。
  trap 'log_elapsed; finish_logging' EXIT
  log "コンソール出力をログファイルにも保存します: $LOG_FILE"
fi

# ---- 引数パース -------------------------------------------------------------
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
    --account-id)       need_value "$1" $#; ACCOUNT_ID="$2"; shift 2 ;;
    --region)           need_value "$1" $#; REGION="$2"; shift 2 ;;
    --registry)         need_value "$1" $#; REGISTRY="$2"; shift 2 ;;
    --repository)       need_value "$1" $#; REPOSITORY="$2"; shift 2 ;;
    --tag-prefix)       need_value "$1" $#; TAG_PREFIX="$2"; shift 2 ;;
    --local-image)      need_value "$1" $#; LOCAL_IMAGE="$2"; shift 2 ;;
    --container-name)   need_value "$1" $#; CONTAINER_NAME="$2"; shift 2 ;;
    --dockerfile)       need_value "$1" $#; DOCKERFILE="$2"; shift 2 ;;
    --context)          need_value "$1" $#; BUILD_CONTEXT="$2"; shift 2 ;;
    --platform)         need_value "$1" $#; PLATFORM="$2"; shift 2 ;;
    --builder)          need_value "$1" $#; BUILDER="$2"; shift 2 ;;
    --build-arg)        need_value "$1" $#; BUILD_ARGS+=("$2"); shift 2 ;;
    --build-context)    need_value "$1" $#; BUILD_CONTEXTS+=("$2"); shift 2 ;;
    --secret)           need_value "$1" $#; SECRETS+=("$2"); shift 2 ;;
    --progress)         need_value "$1" $#; PROGRESS="$2"; shift 2 ;;
    --no-cache)         NO_CACHE="true"; shift ;;
    --output)           need_value "$1" $#; OUTPUT_FILE="$2"; shift 2 ;;
    --log-dir)          need_value "$1" $#; LOG_DIR="$2"; shift 2 ;;  # 冒頭でログ複製を設定済み (値の再取得のみ)
    --dry-run)          DRY_RUN="true"; shift ;;
    --copy-file)        need_value "$1" $#; COPY_SPECS+=("$2"); shift 2 ;;
    --jboss-password-param) need_value "$1" $#; JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       need_value "$1" $#; JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   need_value "$1" $#; JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --jboss-secret-id)      need_value "$1" $#; JBOSS_SECRET_ID="$2"; shift 2 ;;
    --switchback-shell) need_value "$1" $#; SWITCHBACK_SHELL="$2"; shift 2 ;;
    --auto-switchback)  AUTO_SWITCHBACK="true"; shift ;;
    --warn-only)        AUTO_SWITCHBACK="false"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# 引数パース以降のどの経路 (途中の exit を含む) でも処理実行時間を記録する。
# 後段で一時ファイル削除も伴うトラップに差し替えるが、それより前の early-exit
# (依存コマンド不足など) でも経過時間が残るよう、ここで先に仕掛けておく。
trap 'cleanup_temp_files; log_elapsed; finish_logging' EXIT

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
if ! printf '%s' "$JBOSS_PASSWORD_ENV" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
  err "--jboss-password-env に不正な環境変数名が指定されました: $JBOSS_PASSWORD_ENV"
  exit 2
fi
if [ -z "$JBOSS_SECRET_ID" ]; then
  err "--jboss-secret-id に空の値は指定できません"
  exit 2
fi

# ---- 依存コマンド確認 -------------------------------------------------------
for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# docker buildx プラグインの確認
if ! docker buildx version >/dev/null 2>&1; then
  err "docker buildx が利用できません。docker-buildx-plugin をインストールしてください。"
  err "  例) dnf install docker-buildx-plugin"
  exit 1
fi

# ---- Docker デーモンへの接続確認 --------------------------------------------
# デーモン停止や権限不足はビルド開始まで気づけないため、ここで先に確認する。
if docker info >/dev/null 2>&1; then
  :
elif [ "$DRY_RUN" = "true" ]; then
  warn "Docker デーモンへ接続できませんが、DRY-RUN のため中止せずにプレビューを継続します。"
else
  err "Docker デーモンへ接続できません (docker info に失敗)。"
  err "  デーモンの起動状態 (systemctl status docker) と、実行ユーザーが docker グループに"
  err "  所属しているかを確認してください。"
  exit 1
fi

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# スクリプト実行開始時に、事前に aws login --remote による認証操作が実行されて
# いるかを sts get-caller-identity で確認する。未認証なら認証を促して終了する。
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

# --load で docker イメージストアに取り込むため、単一プラットフォームのみ許可する
if [ -n "$PLATFORM" ] && [ "${PLATFORM#*,}" != "$PLATFORM" ]; then
  err "--platform に複数プラットフォームは指定できません: $PLATFORM"
  err "  (docker image tag / docker image push を使うため --load で単一イメージとして取り込む必要があります)"
  exit 2
fi

# --progress は buildx が受け付ける形式のみ許可する
if [ -n "$PROGRESS" ]; then
  case "$PROGRESS" in
    auto|plain|tty|rawjson|quiet) ;;
    *)
      err "--progress に不正な値が指定されました: $PROGRESS"
      err "  指定可能な値: auto / plain / tty / rawjson / quiet"
      exit 2 ;;
  esac
fi

# ---- レジストリ URL の組み立て ---------------------------------------------
if [ -z "$REGISTRY" ]; then
  if [ -z "$ACCOUNT_ID" ]; then
    err "--account-id もしくは --registry を指定してください (レジストリ URL を決定できません)"
    exit 2
  fi
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi
# 末尾のスラッシュが残ると <registry>//<repository> となり参照が壊れる
REGISTRY="${REGISTRY%/}"

[ -n "$CONTAINER_NAME" ] || CONTAINER_NAME="$REPOSITORY"

# ---- イメージ参照の事前検証 -------------------------------------------------
# ECR / Docker のリポジトリ名は小文字英数字と . _ - / のみ。検証しないと、時間の
# かかるビルドが完了した後の docker image tag で
# 'invalid reference format: repository name must be lowercase' となって失敗する。
if ! printf '%s' "$REPOSITORY" \
    | grep -qE '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$'; then
  err "--repository には小文字英数字と . _ - / のみ指定できます: ${REPOSITORY}"
  err "  ECR / Docker のリポジトリ名は大文字を含められません (例: baseimage, j1/base)。"
  exit 2
fi
# タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> (接尾辞 15 文字)。タグ全体は 128 文字以内で、
# 先頭は英数字か _、以降は英数字と . _ - のみ (タグは大文字も使用できる)。
if ! printf '%s' "$TAG_PREFIX" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,112}$'; then
  err "--tag-prefix には英数字と . _ - のみ (先頭は英数字か _、113 文字以内) を指定してください: ${TAG_PREFIX}"
  exit 2
fi

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行いません。 ***"
fi

# ---- ECR 操作権限チェック ---------------------------------------------------
# ecr:GetAuthorizationToken を要求する get-login-password を叩けるかどうかで判定する。
# 成功すればパスワードを取得できるので、そのまま docker login に流用する。
# 失敗理由 (権限不足 / 認証切れ / ネットワーク不通 / リージョン誤り) を区別できるよう、
# aws の標準エラー出力は捨てずに ECR_AUTH_ERROR へ保持して失敗時に表示する。
ECR_PASSWORD=""
ECR_AUTH_ERROR=""
check_ecr_permission() {
  local errfile status
  ECR_AUTH_ERROR=""
  errfile="$(new_temp_file)" || return 1
  TEMP_FILES+=("$errfile")
  ECR_PASSWORD="$(aws ecr get-login-password --region "$REGION" 2>"$errfile")"
  status=$?
  ECR_AUTH_ERROR="$(cat "$errfile")"
  rm -f "$errfile"
  if [ "$status" -ne 0 ] || [ -z "$ECR_PASSWORD" ]; then
    return 1
  fi
  return 0
}

# ECR 権限チェック失敗時に、aws が返したエラー本文を警告として表示する。
warn_ecr_auth_error() {
  [ -n "$ECR_AUTH_ERROR" ] || return 0
  warn "aws ecr get-login-password のエラー内容:"
  printf '%s\n' "$ECR_AUTH_ERROR" | sed 's/^/    /' >&2
}

# ---- スイッチバック処理 -----------------------------------------------------
do_switchback() {
  if [ -z "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルのパスが未指定です。--switchback-shell で指定してください。"
    return 1
  fi
  if [ ! -f "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルが見つかりません: $SWITCHBACK_SHELL"
    return 1
  fi
  log "スイッチバック用シェルを source で呼び出します: $SWITCHBACK_SHELL"
  # 別チーム提供のシェルを現在のシェルに source して認証情報 / ロールを切り替える。
  # shellcheck disable=SC1090
  source "$SWITCHBACK_SHELL"
  return 0
}

# ---- JBoss マスターパスワードの取得 / BuildKit シークレット注入準備 ----------
# --jboss-password-param / --jboss-password / --jboss-password-env のいずれかが
# 指定された場合に、マスターパスワードを取得して環境変数へ export する。
# buildx build には --secret id=<JBOSS_SECRET_ID>,env=<環境変数名> として渡し、
# Dockerfile からは RUN --mount=type=secret,id=<JBOSS_SECRET_ID> で参照する。
# パスワードの値そのものは、ログにもコマンドラインにも出力しない。
prepare_jboss_password() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local password=""
  if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
    log "パラメータストアから JBoss マスターパスワードを取得します: ${JBOSS_PASSWORD_PARAM} (region=${REGION}) ..."
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] aws ssm get-parameter --name ${JBOSS_PASSWORD_PARAM} --with-decryption --region ${REGION} (値の取得・表示は行いません)"
    else
      local ssm_errfile
      ssm_errfile="$(new_temp_file)" || exit 1
      TEMP_FILES+=("$ssm_errfile")
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
      log "パラメータストアから取得しました (値はログに出力しません)。"
    fi
  elif [ -n "$JBOSS_PASSWORD_VALUE" ]; then
    log "直接指定された JBoss マスターパスワードを使用します (値はログに出力しません)。"
    password="$JBOSS_PASSWORD_VALUE"
  else
    # --jboss-password-env のみ指定: 事前に export 済みの環境変数の値をそのまま使う
    password="${!JBOSS_PASSWORD_ENV:-}"
    if [ -z "$password" ] && [ "$DRY_RUN" != "true" ]; then
      err "環境変数 ${JBOSS_PASSWORD_ENV} が未設定または空です。"
      err "  --jboss-password-param / --jboss-password で渡すか、事前に export してから再実行してください。"
      exit 1
    fi
    log "既存の環境変数 ${JBOSS_PASSWORD_ENV} の値を JBoss マスターパスワードとして使用します。"
  fi
  export "${JBOSS_PASSWORD_ENV}=${password}"
  log "JBoss マスターパスワードを環境変数 ${JBOSS_PASSWORD_ENV} 経由で BuildKit シークレット (id=${JBOSS_SECRET_ID}) として注入します。"
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
      log "[DRY-RUN] cp $src -> $dest (ビルド後に自動削除)"
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

# EXIT トラップから呼び出す削除処理。コピーしたファイルのみ削除する。
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
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に削除する。
# 併せて一時ファイルの削除と処理実行時間 (経過秒数) の記録を行い、最後にログ複製を
# 閉じる。SIGINT / SIGTERM で中断した場合も EXIT トラップが実行されるため、
# コピーしたファイルは残らない。
trap 'cleanup_copied_files; cleanup_temp_files; log_elapsed; finish_logging' EXIT

# ---- docker push 失敗時の原因診断 / 調査ガイド ------------------------------
# 各原因カテゴリごとの詳細な説明・AWS CLI 調査コマンド・AWS コンソール確認箇所を出力する。
# ${ACCOUNT_ID:-<account-id>} 等でアカウント ID 未指定時も雛形として読める形にする。
_repo_arn() { printf 'arn:aws:ecr:%s:%s:repository/%s' "$REGION" "${ACCOUNT_ID:-<account-id>}" "$REPOSITORY"; }

guide_iam() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 A】IAM 権限エラー (ecr:* アクションの許可不足)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  docker push は内部で以下の ECR API を順に呼び出します。いずれかの"
  diag "  権限が不足すると 'denied' / 'not authorized to perform' になります:"
  diag "    - ecr:GetAuthorizationToken       (ログイン)"
  diag "    - ecr:BatchCheckLayerAvailability (レイヤ存在確認)"
  diag "    - ecr:InitiateLayerUpload         (アップロード開始)"
  diag "    - ecr:UploadLayerPart             (レイヤ送信)"
  diag "    - ecr:CompleteLayerUpload         (アップロード完了)"
  diag "    - ecr:PutImage                    (マニフェスト登録)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # 1) 今どの IAM プリンシパルとして実行しているか"
  diag "    aws sts get-caller-identity"
  diag "    # 2) トークン取得可否 (= ecr:GetAuthorizationToken の可否)"
  diag "    aws ecr get-login-password --region ${REGION} >/dev/null && echo OK"
  diag "    # 3) 実際に拒否されているアクションをポリシーシミュレータで特定"
  diag "    aws iam simulate-principal-policy \\"
  diag "      --policy-source-arn <上記 get-caller-identity の Arn> \\"
  diag "      --action-names ecr:InitiateLayerUpload ecr:UploadLayerPart \\"
  diag "                     ecr:CompleteLayerUpload ecr:PutImage \\"
  diag "                     ecr:BatchCheckLayerAvailability \\"
  diag "      --resource-arns $(_repo_arn)"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - IAM > ユーザー/ロール > (get-caller-identity のプリンシパル) >"
  diag "      「アクセス許可」で ECR 系ポリシーがアタッチされているか"
  diag "    - CloudTrail > イベント履歴 で errorCode=AccessDenied を検索し、"
  diag "      eventName (どの ecr:* が拒否されたか) と userIdentity を確認"
}

guide_endpoint_policy() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 B】ECR エンドポイント権限設定エラー (ポリシーによる拒否)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  IAM 権限があっても、次のポリシーが拒否していると 'denied' になります:"
  diag "    (1) ECR リポジトリポリシー (リポジトリ単位のリソースベースポリシー)"
  diag "    (2) VPC エンドポイントポリシー (com.amazonaws.${REGION}.ecr.api /"
  diag "        .ecr.dkr のインターフェース型, および S3 ゲートウェイ型)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # リポジトリポリシー (拒否ステートメントが無いか)"
  diag "    aws ecr get-repository-policy --repository-name ${REPOSITORY} --region ${REGION}"
  diag "    # ECR インターフェース型エンドポイントのポリシー/状態"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Policy:PolicyDocument}'"
  diag "    # ecr.api / s3 についても Values を差し替えて同様に確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - ECR > リポジトリ > ${REPOSITORY} > 「アクセス許可」タブ (リポジトリポリシー)"
  diag "    - VPC > エンドポイント > ecr.api / ecr.dkr / s3 の「ポリシー」タブが"
  diag "      当該操作/プリンシパルを許可しているか (フルアクセスまたは明示 Allow)"
}

guide_endpoint_missing() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 C】ECR エンドポイント不存在疑い (ネットワーク到達不可)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'no such host' / 'timeout' / 'dial tcp' / 'connection refused' 等は"
  diag "  DNS 解決失敗または TCP 到達失敗です。インターネットに出られない"
  diag "  プライベートサブネットでは、ECR 用の VPC エンドポイントが必須です:"
  diag "    - com.amazonaws.${REGION}.ecr.api  (インターフェース型)"
  diag "    - com.amazonaws.${REGION}.ecr.dkr  (インターフェース型, レイヤ転送)"
  diag "    - com.amazonaws.${REGION}.s3       (ゲートウェイ型, レイヤ実体は S3)"
  diag "  これらが未作成 / PrivateDNS 無効 / SG・ルートテーブル不備だと失敗します。"
  diag ""
  diag "  ▼ 到達性・DNS の調査 (EC2 上で実行):"
  diag "    getent hosts ${REGISTRY}          # 名前解決できるか"
  diag "    curl -v https://${REGISTRY}/v2/   # 443 で到達できるか (401 なら到達OK)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Subnets:SubnetIds,SG:Groups}'"
  diag "    # ecr.api / s3 についても Values を差し替えて存在と State=available を確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - VPC > エンドポイント: ecr.api / ecr.dkr が『available』かつ"
  diag "      『プライベート DNS 名を有効化』が ON、s3 ゲートウェイ型が存在するか"
  diag "    - EC2 のサブネットのルートテーブル (s3 ゲートウェイへの経路)"
  diag "    - エンドポイントの SG / EC2 の SG のアウトバウンドで 443/tcp が許可か"
}

guide_repo_not_found() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 D】ECR リポジトリが存在しない"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'name unknown' / 'does not exist in the registry' は、プッシュ先の"
  diag "  リポジトリ '${REPOSITORY}' が (このリージョン/アカウントに) 未作成です。"
  diag "  ECR は push 時に自動作成しません。リージョン取り違えも多い原因です。"
  diag ""
  diag "  ▼ AWS CLI での調査 / 対処:"
  diag "    # 一覧して存在とリージョンを確認"
  diag "    aws ecr describe-repositories --region ${REGION} \\"
  diag "      --query 'repositories[].repositoryName'"
  diag "    # 無ければ作成"
  diag "    aws ecr create-repository --repository-name ${REPOSITORY} --region ${REGION}"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - 画面右上のリージョンが ${REGION} になっているか"
  diag "    - ECR > リポジトリ 一覧に ${REPOSITORY} が存在するか"
}

guide_token_expired() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 E】認証トークンの期限切れ / 未ログイン"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'authorization token has expired' / 'no basic auth credentials' /"
  diag "  '401 Unauthorized' は、ECR ログインが無効化 (トークン有効期限 12h) 済み。"
  diag ""
  diag "  ▼ 再ログイン:"
  diag "    aws ecr get-login-password --region ${REGION} \\"
  diag "      | docker login --username AWS --password-stdin ${REGISTRY}"
}

# docker push の出力 (push_log) を解析し、該当する原因ガイドを出力する。
diagnose_push_failure() {
  local push_log="$1"
  local out=""
  [ -f "$push_log" ] && out="$(cat "$push_log")"

  err "==================================================================="
  err "docker image push に失敗しました: ${TARGET_IMAGE}"
  err "AWS API の応答を確認し、原因の切り分けと詳細な調査方法を表示します。"
  err "==================================================================="

  # --- AWS API を実際に呼び出して事実確認する (読み取り専用) ---
  diag ""
  diag "▼ 現在の認証情報 (aws sts get-caller-identity):"
  local identity
  if identity="$(aws sts get-caller-identity --output text 2>&1)"; then
    diag "  ${identity}"
  else
    diag "  取得に失敗: ${identity}"
    diag "  → 認証情報が無効/期限切れの可能性大 (スイッチバックが必要かもしれません)。"
  fi

  diag ""
  diag "▼ ECR リポジトリの実在確認 (aws ecr describe-repositories):"
  local repo_out repo_exists="unknown"
  if repo_out="$(aws ecr describe-repositories --repository-names "$REPOSITORY" --region "$REGION" --output text 2>&1)"; then
    diag "  リポジトリ '${REPOSITORY}' は ${REGION} に存在します。"
    repo_exists="yes"
  else
    diag "  確認できませんでした:"
    diag "    ${repo_out}"
    if printf '%s' "$repo_out" | grep -qiE 'RepositoryNotFoundException|does not exist'; then
      repo_exists="no"
    elif printf '%s' "$repo_out" | grep -qiE 'AccessDenied|not authorized'; then
      diag "  → describe すら AccessDenied。IAM 権限不足の可能性が高いです。"
    fi
  fi

  # --- push 出力のパターンから原因カテゴリを判定 ---
  diag ""
  diag "▼ docker image push の出力から推定される原因:"
  local matched=0

  if [ "$repo_exists" = "no" ] || printf '%s' "$out" | grep -qiE 'name unknown|does not exist in the registry|repositorynotfoundexception|repository .* does not exist'; then
    guide_repo_not_found; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'no such host|server misbehaving|dial tcp|i/o timeout|deadline exceeded|connection refused|tls handshake|could not resolve|temporary failure in name resolution|network is unreachable|no route to host'; then
    guide_endpoint_missing; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'authorization token has expired|no basic auth credentials|401 unauthorized|authentication required'; then
    guide_token_expired; matched=1
  fi

  # 'denied' 系は IAM 権限とエンドポイント/リポジトリポリシーの双方が候補
  if printf '%s' "$out" | grep -qiE 'not authorized to perform|access ?denied|is not authorized|denied: |ecr:(initiatelayerupload|uploadlayerpart|completelayerupload|putimage|batchchecklayeravailability|getauthorizationtoken)'; then
    guide_iam; guide_endpoint_policy; matched=1
  fi

  if [ "$matched" -eq 0 ]; then
    diag "  出力から自動判定できるパターンに一致しませんでした。"
    diag "  以下の全観点で切り分けてください。"
    guide_iam
    guide_endpoint_policy
    guide_endpoint_missing
    guide_repo_not_found
    guide_token_expired
  fi

  diag ""
  err "==================================================================="
  err "上記の調査コマンド/コンソール確認で原因を特定してください。"
  err "==================================================================="
}

log "ECR 操作権限を確認します (region=${REGION}) ..."
if ! check_ecr_permission; then
  warn "現在の操作権限では ECR を操作できません。"
  warn_ecr_auth_error
  if [ "$AUTO_SWITCHBACK" = "true" ]; then
    # (B) 終了せず、自動的にスイッチバックして継続する
    log "自動スイッチバックモードです。スイッチバックを実行します。"
    if ! do_switchback; then
      err "スイッチバックに失敗しました。処理を中止します。"
      exit 1
    fi
    log "スイッチバック後に再度 ECR 操作権限を確認します ..."
    if ! check_ecr_permission; then
      err "スイッチバック後も ECR を操作できません。権限設定を確認してください。"
      warn_ecr_auth_error
      exit 1
    fi
    log "スイッチバックにより ECR 操作が可能になりました。処理を継続します。"
  elif [ "$DRY_RUN" = "true" ]; then
    # dry-run では中止せず、権限が無い旨を警告してプレビューを継続する
    warn "ECR 操作権限がありませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合はスイッチバック (--auto-switchback など) が必要です。"
  else
    # (A) 警告して終了する
    err "ECR への操作権限がありません。スイッチバックしてから再実行してください。"
    if [ -n "$SWITCHBACK_SHELL" ]; then
      err "  例) source \"$SWITCHBACK_SHELL\" を実行してスイッチバックしてください。"
    else
      err "  スイッチバック用シェル (別チーム提供) を source で読み込んでスイッチバックしてください。"
    fi
    err "  自動でスイッチバックする場合は --auto-switchback を付けて再実行してください。"
    exit 1
  fi
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
# パラメータストアへのアクセスに AWS 権限が必要なため、スイッチバック確定後に行う。
prepare_jboss_password

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_copied_files) により
# ビルド終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド (docker buildx build) -------------------------------------------
if [ ! -f "$DOCKERFILE" ]; then
  err "Dockerfile が見つかりません: $DOCKERFILE"
  exit 1
fi
if [ ! -d "$BUILD_CONTEXT" ]; then
  err "ビルドコンテキストが存在しません: $BUILD_CONTEXT"
  exit 1
fi

# docker image tag / docker image push を別コマンドとして使うため、
# --load でビルド結果をローカルの docker イメージストアへ取り込む。
BUILDX_OPTS=(--load -t "$LOCAL_IMAGE" -f "$DOCKERFILE")
if [ -n "$BUILDER" ]; then
  BUILDX_OPTS+=(--builder "$BUILDER")
fi
if [ -n "$PLATFORM" ]; then
  BUILDX_OPTS+=(--platform "$PLATFORM")
fi
if [ -n "$PROGRESS" ]; then
  BUILDX_OPTS+=(--progress "$PROGRESS")
fi
if [ "$NO_CACHE" = "true" ]; then
  BUILDX_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi
for build_arg in ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}; do
  BUILDX_OPTS+=(--build-arg "$build_arg")
done
for build_context in ${BUILD_CONTEXTS[@]+"${BUILD_CONTEXTS[@]}"}; do
  BUILDX_OPTS+=(--build-context "$build_context")
done
for secret in ${SECRETS[@]+"${SECRETS[@]}"}; do
  BUILDX_OPTS+=(--secret "$secret")
done
# JBoss マスターパスワードを environment 型シークレットとして注入する。
# --secret の引数に含まれるのは id と環境変数名のみで、値そのものは含まれない
# (dry-run のコマンドプレビューにも値は表示されない)。
if [ "$JBOSS_SECRET_ENABLED" = "true" ]; then
  BUILDX_OPTS+=(--secret "id=${JBOSS_SECRET_ID},env=${JBOSS_PASSWORD_ENV}")
fi

log "docker buildx build を実行します (dockerfile=${DOCKERFILE}, context=${BUILD_CONTEXT}) ..."
if ! run docker buildx build "${BUILDX_OPTS[@]}" "$BUILD_CONTEXT"; then
  err "docker buildx build に失敗しました"
  exit 1
fi

# ローカルベースイメージが生成されたか確認 (dry-run ではビルドしていないためスキップ)
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
elif ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (buildx の --load 取り込みを確認してください)"
  exit 1
else
  log "ローカルベースイメージを確認しました: $LOCAL_IMAGE"
fi

# ---- タグ (<接頭辞>-<処理年月日時分秒>) -------------------------------------
# タグの接頭辞 (TAG_PREFIX) はリポジトリ名とは独立に --tag-prefix で指定できる。
# 例: TAG_PREFIX=BaseImage のとき BaseImage-20260702153000
IMAGE_TAG="${TAG_PREFIX}-$(date '+%Y%m%d%H%M%S')"
TARGET_IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

# ---- ECR ログイン (get-login-password | docker login --password-stdin) -----
log "ECR にログインします: $REGISTRY (user=${ECR_USERNAME}) ..."
# ECR_PASSWORD は権限チェック時に取得済み。--password-stdin で安全に渡す。
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker login --username ${ECR_USERNAME} --password-stdin ${REGISTRY} (password は非表示)"
elif ! printf '%s' "$ECR_PASSWORD" | docker login --username "$ECR_USERNAME" --password-stdin "$REGISTRY"; then
  err "docker login に失敗しました: $REGISTRY"
  exit 1
fi

# ---- タグ付け & プッシュ ----------------------------------------------------
log "docker image tag ${LOCAL_IMAGE} -> ${TARGET_IMAGE}"
if ! run docker image tag "$LOCAL_IMAGE" "$TARGET_IMAGE"; then
  err "docker image tag に失敗しました"
  exit 1
fi

log "docker image push ${TARGET_IMAGE} ..."
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker image push ${TARGET_IMAGE}"
else
  # push の出力を画面に流しつつ (tee) ログへ保存し、失敗時に原因解析へ回す。
  # pipefail 有効のため、docker image push 失敗時はパイプライン全体も失敗扱いになる。
  PUSH_LOG="$(new_temp_file)" || exit 1
  TEMP_FILES+=("$PUSH_LOG")
  if docker image push "$TARGET_IMAGE" 2>&1 | tee "$PUSH_LOG"; then
    log "docker image push に成功しました。"
  else
    diagnose_push_failure "$PUSH_LOG"
    exit 1
  fi
  rm -f "$PUSH_LOG"
fi

# ---- imagedefinition.json 出力 ---------------------------------------------
# CodePipeline の ECS デプロイ等で使われる標準フォーマット。
# name / imageUri に " や \ が含まれても壊れた JSON にならないようエスケープする。
IMAGEDEF_CONTENT="$(cat <<EOF
[
  {
    "name": "$(json_escape "$CONTAINER_NAME")",
    "imageUri": "$(json_escape "$TARGET_IMAGE")"
  }
]
EOF
)"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ${OUTPUT_FILE} に以下を出力します (実際には書き込みません):"
  printf '%s\n' "$IMAGEDEF_CONTENT"
else
  # 書き込み失敗 (権限不足・容量不足など) を見逃すと、後続の CodePipeline が
  # 古い imagedefinition を参照してしまうため、必ず結果を確認する。
  if ! printf '%s\n' "$IMAGEDEF_CONTENT" > "$OUTPUT_FILE"; then
    err "imagedefinition の書き込みに失敗しました: ${OUTPUT_FILE}"
    exit 1
  fi
  log "imagedefinition を出力しました: ${OUTPUT_FILE}"
fi

log "  name     = ${CONTAINER_NAME}"
log "  imageUri = ${TARGET_IMAGE}"
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "完了しました。"
fi
