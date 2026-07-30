# ベースイメージのサンプル。実際のベースイメージ内容に置き換えてください。
FROM public.ecr.aws/docker/library/alpine:3.20

LABEL org.opencontainers.image.title="j1/base.local"

# 例: 共通で入れておきたいパッケージなど
RUN apk add --no-cache ca-certificates

# 例: JBoss のマスターパスワードを BuildKit シークレットとして参照する場合。
# シークレットはビルド中のみ /run/secrets/<id> にマウントされ、イメージの
# レイヤ・履歴・環境変数には残らない。id は compose 版は compose.yml の secrets 名、
# buildx 版は --jboss-secret-id (既定: jboss_master_password) と一致させる。
# RUN --mount=type=secret,id=jboss_master_password \
#     JBOSS_MASTER_PASSWORD="$(cat /run/secrets/jboss_master_password)" \
#     && /opt/jboss/bin/setup-credential-store.sh "$JBOSS_MASTER_PASSWORD"

CMD ["/bin/sh"]
