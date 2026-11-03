#!/bin/sh

set -e

echo "Setup variables ..."

APP=$1
AWS_ACCESS_KEY_ID=$2
AWS_SECRET_ACCESS_KEY=$3
AWS_ACCOUNT=$4
AWS_DEFAULT_REGION=$5
GITHUB_KEY=$6
ENVIRONMENT=$7
VERSION=$8
INFRA_REPO=$9
INFRA_BRANCH=${10}

echo "Setting up ssh ..."

if [ ! -d /root/.ssh/ ]; then
   mkdir -p /root/.ssh/
fi

echo '' > /root/.ssh/known_hosts

ssh-keygen -R github.com
ssh-keyscan -H github.com >> /root/.ssh/known_hosts

echo "${GITHUB_KEY}" > /root/.ssh/id_rsa
chmod 0500 /root/.ssh/id_rsa

echo "Setting up ssh agent ..."

eval `ssh-agent -s`
ssh-add /root/.ssh/id_rsa

echo "Cloning Infra ... "
# Default to 'main' branch if not specified
git clone -b ${INFRA_BRANCH} --single-branch ${INFRA_REPO} caterspot_infra
cd caterspot_infra/cdk/caterspot

echo "Installing dependencies ..."
# yarn has no deadline on a tarball download. --network-timeout only fires when
# a connection goes silent; one that keeps trickling bytes never trips it, and
# the install waits forever. That is what cancelled caterspot-content-helper's
# deploys on 2026-11-03: stuck on "Fetching packages..." until the caller's
# 15-minute job timeout, with the service silently left on the old image.
# Reproduced against a registry trickling 1 byte / 10s: yarn hangs with no
# error, and npm hangs too and ignores SIGTERM. Hence a KILL deadline + retry.
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-180}
INSTALL_ATTEMPTS=${INSTALL_ATTEMPTS:-3}

# Under /github/workspace (mounted from the runner), so a caller can persist
# it with actions/cache. With no cache restored it is simply a cold cache.
YARN_CACHE_DIR=${YARN_CACHE_DIR:-/github/workspace/.cdk-yarn-cache}

# With a lockfile, install exactly it and prefer the cache over the network.
# Without one (older infra branches), keep the previous behaviour.
YARN_FLAGS="--non-interactive --cache-folder ${YARN_CACHE_DIR}"
if [ -f yarn.lock ]; then
  YARN_FLAGS="${YARN_FLAGS} --frozen-lockfile --prefer-offline"
fi

# Which download stalled? yarn writes each package into the cache as it
# arrives and adds .yarn-metadata.json only once it is complete, so an entry
# without it is a download that never finished. Printing those, with how much
# arrived, and the registry address this runner resolved, turns "stuck on
# Fetching packages" into a named tarball and host.
report_unfinished_downloads() {
  echo "Downloads that did not finish (cache entries without .yarn-metadata.json):"
  found=0
  for dir in "${YARN_CACHE_DIR}"/v*/npm-*; do
    [ -d "${dir}" ] || continue
    set -- "${dir}"/node_modules/*/.yarn-metadata.json "${dir}"/node_modules/@*/*/.yarn-metadata.json
    complete=0
    for meta in "$@"; do [ -f "${meta}" ] && complete=1 && break; done
    [ "${complete}" -eq 1 ] && continue
    found=1
    kb=$(du -sk "${dir}" 2>/dev/null | cut -f1)
    echo "  ${dir##*/} (${kb:-0} KB received)"
  done
  [ "${found}" -eq 1 ] || echo "  none found in the cache"
  echo "registry.yarnpkg.com resolved to:"
  nslookup registry.yarnpkg.com 2>/dev/null | awk '/^Address/ && NR > 2 {print "  " $NF}' || true
}

attempt=1
until timeout -s KILL "${INSTALL_TIMEOUT}" yarn install ${YARN_FLAGS}; do
  report_unfinished_downloads
  if [ "${attempt}" -ge "${INSTALL_ATTEMPTS}" ]; then
    echo "yarn install failed ${attempt} times (limit ${INSTALL_TIMEOUT}s each), giving up"
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "yarn install failed or exceeded ${INSTALL_TIMEOUT}s, retrying (${attempt}/${INSTALL_ATTEMPTS}) ..."
done

echo "Deploying ${APP} to ${ENVIRONMENT} ..."
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}

scripts/$APP/deploy.sh $ENVIRONMENT $VERSION

echo 'ok'
