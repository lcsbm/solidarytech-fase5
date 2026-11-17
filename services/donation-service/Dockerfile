FROM golang:1.26-trixie AS builder

WORKDIR /app

# download, e não tidy: com go.sum versionado, um go.sum desatualizado deve
# quebrar o build aqui — nunca ser resolvido em silêncio dentro da imagem.
COPY go.mod go.sum ./
RUN go mod download

COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /server .


FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /server /server

USER nonroot:nonroot
EXPOSE 8082

ENTRYPOINT ["/server"]
