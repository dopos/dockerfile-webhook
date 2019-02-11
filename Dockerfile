FROM golang:1.10.8-alpine3.9

MAINTAINER Alexey Kovrizhkin <lekovr+dopos@gmail.com>

ENV WEBHOOK_VERSION 2.6.9

WORKDIR /go/src/github.com/adnanh

RUN apk --update add curl git

# with CGO_ENABLED=0 build does not requires g++ package, so it will be faster
RUN curl -sL https://github.com/adnanh/webhook/archive/${WEBHOOK_VERSION}.tar.gz | tar -xvz && \
    mv -f webhook-${WEBHOOK_VERSION} webhook && \
    cd webhook && \
    go get -d && \
    CGO_ENABLED=0 GOOS=linux go build -a -o /usr/local/bin/webhook && \
	rm -rf /go

# ------------------------------------------------------------------------------
# Second build stage, so use cloud.docker.com instead hub.docker.com for autobuild

# Base on docker/alpine in case of docker using in hooks
FROM docker:18.06.0-ce

# Stuff used in hooks
RUN apk --update add curl curl-dev make bash git apache2-utils jq openssh-client gawk && \
	rm -rf /var/cache/apk/*

# Main app will be placed in root
WORKDIR /

COPY --from=0 /usr/local/bin/webhook .

COPY webhook /etc/webhook

# webhook default port
EXPOSE 9000

ENTRYPOINT ["/webhook"]
