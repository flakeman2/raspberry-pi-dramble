FROM golang:1.27-alpine AS build
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/blog-cms-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/blog-cms-api /blog-cms-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/blog-cms-api"]
