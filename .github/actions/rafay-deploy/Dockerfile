FROM alpine:latest as unpack

ADD https://rafay-prod-cli.s3-us-west-2.amazonaws.com/publish/rctl-linux-amd64.tar.bz2 /download/rctl.tar.bz2

RUN mkdir /unpack/
RUN tar -C /unpack/ -xf /download/rctl.tar.bz2
RUN chmod 755 /unpack/*


FROM alpine:latest

## Add packages
RUN apk add --no-cache bash yq helm

## Add external tools
COPY --from=unpack /unpack/* /usr/bin/

## Add the entrypoint
COPY deploy-addon.sh /

ENTRYPOINT [ "/deploy-addon.sh" ]