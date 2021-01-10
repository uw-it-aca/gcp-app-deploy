#!/usr/bin/env bash
set -eu
trap 'exit 1' ERR

# stage $RELEASE_NAME as flux repository branch candidate for deployment
#
# NOTES:
#      - git clone/push output piped thru sed to mask possible auth_token spill
#
# PRECONDITION: inherited env vars from application's .travis.yml MUST include:
#      RELEASE_NAME: application's name as it is expressed in k8s cluster
#      COMMIT_HASH: application's source commit to be deployed
#      IMAGE_TAG: tag of docker image to be pushed to image repository
#      DOCKER_USER, DOCKER_PASS: push docker hub repo
#      GH_AUTH_TOKEN: branch, merge flux repo
#
# OPTIONAL:
#      APP_INSTANCE: if set, used for instance in dev GCP project
#      HELM_APP_VERSION: if set, use specified helm version (default "3.0.0")
#      HELM_CHART_BRANCH: if set, use specified chart branch (default "master")
#
# NOTE:
#      helm template values will be pulled from the file
#           docker/${APP_INSTANCE}-values.yml
#      in the projects git repository
#

# master/main branch hardwired to prod GCP instance and "prod" app instance
case ${GIT_REPO_BRANCH} in
    main|master)
        APP_INSTANCE="prod"
        FLUX_INSTANCE="prod"
        GCP_PROJECT="uwit-mci-0011"
        FLUX_RELEASE_SUFFIX=""
        ;;
    *)
        APP_INSTANCE="${APP_INSTANCE:-test}"
        FLUX_INSTANCE="dev"
        GCP_PROJECT="uwit-mci-0010"
        FLUX_RELEASE_SUFFIX=""
        if [ $APP_INSTANCE != "test" ]; then
          FLUX_RELEASE_SUFFIX="-${APP_INSTANCE}"
        fi
        ;;
esac

# helm defaults
HELM_APP_VERSION="${HELM_APP_VERSION:-3.4.2}"
HELM_CHART_BRANCH="${HELM_CHART_BRANCH:-master}"
HELM_IMAGE="alpine/helm:${HELM_APP_VERSION}"

# kubeval manifest validation defaults
KUBEVAL_VERSION="${KUBEVAL_VERSION:-latest}"
KUBEVAL_SKIP_KINDS="${KUBEVAL_SKIP_KINDS:-ExternalSecret,ServiceMonitor}"
KUBEVAL_IMAGE="garethr/kubeval:${KUBEVAL_VERSION}"

# checkov security policy scan defaults
CHECKOV_VERSION="${CHECKOV_VERSION:-latest}"
CHECKOV_IMAGE="bridgecrew/checkov:${CHECKOV_VERSION}"
# acceptable policy violations:
#    CKV_K8S_21 - default namespace policy
#    CKV_K8S_35 - secret files preferred over environment
#    CKV_K8S_43 - image reference by digest
CHECKOV_SKIP_CHECKS="${CHECKOV_SKIP_CHECKS:-CKV_K8S_21,CKV_K8S_35,CKV_K8S_43}"

# GCP Registry values
GCP_REGISTRY_PROJECT="uwit-mci-axdd"

# application specific values
APP_NAME=${RELEASE_NAME}-prod-${APP_INSTANCE}
HELM_CHART_NAME=django-production-chart
HELM_CHART_VALUES=docker/${APP_INSTANCE}-values.yml
FLUX_REPO_NAME=gcp-flux-${FLUX_INSTANCE}
GITHUB_REPO_OWNER=uw-it-aca

HELM_CHART_LOCAL_DIR=${PWD}/$HELM_CHART_NAME
HELM_CHART_REPO_PATH=${GITHUB_REPO_OWNER}/${HELM_CHART_NAME}
HELM_CHART_REPO=https://github.com/${HELM_CHART_REPO_PATH}.git

FLUX_LOCAL_DIR=${PWD}/$FLUX_REPO_NAME
FLUX_REPO_PATH=${GITHUB_REPO_OWNER}/$FLUX_REPO_NAME
FLUX_REPO=https://${GH_AUTH_TOKEN}@github.com/${FLUX_REPO_PATH}.git

MANIFEST_FILE_NAME=${RELEASE_NAME}${FLUX_RELEASE_SUFFIX}.yaml
LOCAL_MANIFEST=${PWD}/$MANIFEST_FILE_NAME
FLUX_RELEASE_MANIFEST=releases/${FLUX_INSTANCE}/$MANIFEST_FILE_NAME
FLUX_RELEASE_BRANCH_NAME=release/${FLUX_INSTANCE}/${RELEASE_NAME}/$COMMIT_HASH
FLUX_PR_OUTPUT=${PWD}/pr-${FLUX_INSTANCE}-${RELEASE_NAME}-${COMMIT_HASH}.json

GITHUB_API_PULLS=https://api.github.com/repos/${FLUX_REPO_PATH}/pulls

COMMIT_MESSAGE="Automated ${FLUX_INSTANCE} deploy of ${GIT_REPO_SLUG}:${COMMIT_HASH} by build ${BUILD_NUMBER}"
PULL_REQUEST_MESSAGE="Automated ${FLUX_INSTANCE} deploy of [${GIT_REPO_SLUG}:${COMMIT_HASH}](/${GIT_REPO_SLUG}/commit/${COMMIT_HASH})  Generated build [${BUILD_NUMBER}]($BUILD_WEB_URL)"

echo "######################################"
echo "WOULD DEPLOY $APP_NAME in $GCP_PROJECT"
echo "######################################"

echo "COMMIT MESSAGE: ${COMMIT_MESSAGE}"
echo "PULL_REQUEST_MESSAGE: ${PULL_REQUEST_MESSAGE}"

echo "WOULD CLONE chart repository $HELM_CHART_REPO_PATH (${HELM_CHART_BRANCH})"

echo "WOULD GENERATE release manifest $MANIFEST_FILE_NAME using $HELM_CHART_VALUES"

echo "PWD is ${PWD}"

echo "WOULD VALIDATE generated manifest $MANIFEST_FILE_NAME"

echo "WOULD CLONE flux repository ${FLUX_REPO_PATH}"

echo "FLUX_REPO is ${FLUX_REPO}"
echo "FLUX_LOCAL_DIR is ${FLUX_LOCAL_DIR}"

echo "WOULD CREATE branch $FLUX_RELEASE_BRANCH_NAME"

echo "WOULD ADD ${FLUX_RELEASE_MANIFEST} and COMMIT"
echo "LOCAL_MANIFEST is ${LOCAL_MANIFEST}"

echo "WOULD SUBMIT $FLUX_RELEASE_BRANCH_NAME pull request"
