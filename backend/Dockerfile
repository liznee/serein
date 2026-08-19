# 构建阶段
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# modernc/sqlite 纯 Go,无需 CGO
RUN CGO_ENABLED=0 go build -o /serein-server ./cmd/server

# 运行阶段
FROM alpine:latest
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /serein-server .
EXPOSE 8080
ENTRYPOINT ["./serein-server"]
