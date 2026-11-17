FROM golang:1.26-trixie AS builder

WORKDIR /app

# go.sum é opcional no primeiro build — go mod tidy o gera e o CI o versiona.
COPY go.mod go.su[m] ./
RUN go mod tidy

COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /server .


FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /server /server

USER nonroot:nonroot
EXPOSE 8082

ENTRYPOINT ["/server"]
