ARG BCI_IMAGE=registry.suse.com/bci/bci-micro:16.0
ARG BCI_BASE_IMAGE=registry.suse.com/bci/bci-base:16.0
ARG GO_IMAGE=rancher/hardened-build-base:v1.26.9b1
ARG XX_IMAGE=rancher/mirrored-tonistiigi-xx:1.6.1

FROM --platform=$BUILDPLATFORM ${XX_IMAGE} AS xx

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS base-builder
# copy xx scripts to your build stage
COPY --from=xx / /
RUN apk add file make git clang lld
ARG TARGETPLATFORM
RUN set -x && \
    xx-apk --no-cache add musl-dev gcc

FROM base-builder AS builder
ARG TAG=v0.1.0
ARG PKG="github.com/k8snetworkplumbingwg/multi-networkpolicy-nftables"
ARG SRC="github.com/k8snetworkplumbingwg/multi-networkpolicy-nftables"
RUN git clone --depth=1 https://${SRC}.git $GOPATH/src/${PKG}
WORKDIR $GOPATH/src/${PKG}
RUN git fetch --all --tags --prune
RUN git checkout tags/${TAG} -b ${TAG}
RUN go mod download
# cross-compilation setup
ARG TARGETARCH
RUN xx-go --wrap && \
    go-build-static.sh -gcflags=-trimpath=${GOPATH}/src -o bin/multi-networkpolicy-nftables ./cmd/
RUN go-assert-boring.sh bin/*
RUN xx-verify --static bin/*
RUN install bin/* /usr/local/bin

FROM ${GO_IMAGE} AS strip_binary
#strip needs to run on TARGETPLATFORM, not BUILDPLATFORM
COPY --from=builder /usr/local/bin/multi-networkpolicy-nftables /multi-networkpolicy-nftables
RUN strip /multi-networkpolicy-nftables

# knftables shells out to the nft binary, so install nftables on top of bci-micro.
# rpm scriptlets are skipped: they cannot run in the chroot under qemu emulation
# and only call ldconfig, which bci-micro does not ship anyway.
FROM ${BCI_IMAGE} AS micro
FROM ${BCI_BASE_IMAGE} AS nftables
COPY --from=micro / /chroot/
RUN zypper --non-interactive refresh && \
    zypper --non-interactive --installroot /chroot --pkg-cache-dir /tmp/rpms \
        install --download-only --no-recommends nftables && \
    rpm --root /chroot --noscripts --notriggers -Uvh /tmp/rpms/*/*/*.rpm && \
    rm -rf /tmp/rpms /chroot/var/log/zypp* /chroot/var/cache/zypp*

FROM scratch
COPY --from=nftables /chroot/ /
COPY --from=strip_binary /multi-networkpolicy-nftables /multi-networkpolicy-nftables
ARG BCI_IMAGE
LABEL org.opencontainers.image.url="https://hub.docker.com/r/rancher/hardened-multi-networkpolicy-nftables"
LABEL org.opencontainers.image.source="https://github.com/rancher/image-build-multi-networkpolicy-nftables"
LABEL org.opencontainers.image.base.name="${BCI_IMAGE}"
ENTRYPOINT ["/multi-networkpolicy-nftables"]
