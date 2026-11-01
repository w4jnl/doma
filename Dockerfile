# Built by goreleaser (dockers_v2): the context holds one prebuilt binary per
# platform under linux/<arch>/, nothing is compiled here. FROM scratch, so the
# image holds the static binary and CA certificates (for APNs).
FROM alpine:3.22 AS certs
RUN apk add --no-cache ca-certificates

FROM scratch
ARG TARGETPLATFORM
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY $TARGETPLATFORM/doma /doma
ENV DOMA_DB_PATH=/data/doma.db
ENV DOMA_PHOTOS_DIR=/data/photos
ENV DOMA_SECRETS_KEY_FILE=/data/secret.key
ENV DOMA_PUSH_KEY_FILE=/data/apns.p8
ENV DOMA_SERVER_LISTEN=:8080
VOLUME ["/data"]
EXPOSE 8080
# The image has no shell. The first browser visit shows the setup page.
ENTRYPOINT ["/doma"]
CMD ["serve"]
