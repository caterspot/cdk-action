# Container image that runs your code
FROM node:20-alpine

LABEL maintainer "Taufek Johar<taufek@caterspot.com>"

RUN apk add --no-cache --upgrade git openssh build-base aws-cli jq nodejs npm yarn bash

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]
