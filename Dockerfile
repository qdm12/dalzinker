ARG ALPINE_VERSION=3.20
ARG GO_VERSION=1.23
ARG XCPUTRANSLATE_VERSION=v0.6.0
ARG GOLANGCI_LINT_VERSION=v1.61.0

FROM --platform=${BUILDPLATFORM} qmcgaw/xcputranslate:${XCPUTRANSLATE_VERSION} AS xcputranslate
FROM --platform=${BUILDPLATFORM} qmcgaw/binpot:golangci-lint-${GOLANGCI_LINT_VERSION} AS golangci-lint

FROM --platform=${BUILDPLATFORM} golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS base
ENV CGO_ENABLED=0
# Note: findutils needed to have xargs support `-d` flag for mocks stage.
RUN apk --update add git g++ findutils
WORKDIR /tmp/gobuild
COPY --from=xcputranslate /xcputranslate /usr/local/bin/xcputranslate
COPY --from=golangci-lint /bin /go/bin/golangci-lint
# Copy repository code and install Go dependencies
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/

FROM --platform=${BUILDPLATFORM} base AS test
# Note on the go race detector:
# - we set CGO_ENABLED=1 to have it enabled
# - we installed g++ to support the race detector
ENV CGO_ENABLED=1
ENTRYPOINT go test -race -coverpkg=./... -coverprofile=coverage.txt -covermode=atomic ./...

FROM --platform=${BUILDPLATFORM} base AS lint
COPY .golangci.yml ./
RUN golangci-lint run --timeout=10m

FROM --platform=${BUILDPLATFORM} base AS build
ARG TARGETPLATFORM
ARG VERSION=unknown
ARG CREATED="an unknown date"
ARG COMMIT=unknown
RUN GOARCH="$(xcputranslate translate -targetplatform ${TARGETPLATFORM} -field arch)" \
  GOARM="$(xcputranslate translate -targetplatform ${TARGETPLATFORM} -field arm)" \
  go build -trimpath -ldflags="-s -w \
  -X 'main.version=$VERSION' \
  -X 'main.buildDate=$CREATED' \
  -X 'main.commit=$COMMIT' \
  " -o entrypoint cmd/cli-template/main.go

FROM --platform=${BUILDPLATFORM} base AS mocks
RUN git init && \
  git config user.email ci@localhost && \
  git config user.name ci && \
  git config core.fileMode false && \
  git add -A && \
  git commit -m "snapshot" && \
  grep -lr -E '^// Code generated by MockGen\. DO NOT EDIT\.$' . | xargs -r -d '\n' rm && \
  go generate -run "mockgen" ./... && \
  git diff --exit-code && \
  rm -rf .git/

FROM scratch
ARG VERSION=unknown
ARG CREATED="an unknown date"
ARG COMMIT=unknown
LABEL \
  org.opencontainers.image.authors="quentin.mcgaw@gmail.com" \
  org.opencontainers.image.created=$CREATED \
  org.opencontainers.image.version=$VERSION \
  org.opencontainers.image.revision=$COMMIT \
  org.opencontainers.image.url="https://github.com/qdm12/cli-template" \
  org.opencontainers.image.documentation="https://github.com/qdm12/cli-template" \
  org.opencontainers.image.source="https://github.com/qdm12/cli-template" \
  org.opencontainers.image.title="cli-template" \
  org.opencontainers.image.description=""
ENTRYPOINT ["/cli-template"]
USER 1000
COPY --from=build --chown=1000 /tmp/gobuild/entrypoint /cli-template