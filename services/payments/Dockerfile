# G1 golden-path stub: minimal, dependency-free (stdlib only) HTTP server
# exposing /, /health, /ready. Replace with the real service when ready.

FROM golang:1.26-alpine3.23 AS build
WORKDIR /src
COPY go.mod go.sum *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

FROM alpine:3.23
RUN apk add --no-cache curl ca-certificates \
    && addgroup -g 1000 app \
    && adduser -D -u 1000 -G app app
COPY --from=build /out/app /usr/local/bin/app
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]
