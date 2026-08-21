FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /client .

FROM alpine:3.21
COPY --from=build /client /client
ENTRYPOINT ["/client"]
