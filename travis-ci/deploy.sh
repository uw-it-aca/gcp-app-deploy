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
case ${TRAVIS_BRANCH} in
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

COMMIT_MESSAGE="Automated ${FLUX_INSTANCE} deploy of ${TRAVIS_REPO_SLUG}:${COMMIT_HASH} by travis build ${TRAVIS_BUILD_NUMBER}"
PULL_REQUEST_MESSAGE="Automated ${FLUX_INSTANCE} deploy of [${TRAVIS_REPO_SLUG}:${COMMIT_HASH}](/${TRAVIS_REPO_SLUG}/commit/${COMMIT_HASH})  Generated travis build [${TRAVIS_BUILD_NUMBER}]($TRAVIS_BUILD_WEB_URL)"

GITHUB_API_PULLS=https://api.github.com/repos/${FLUX_REPO_PATH}/pulls

echo "#####################################"
echo "DEPLOY $APP_NAME in $GCP_PROJECT"
echo "#####################################"

if [ -n "${DOCKER_USER:-}" ]; then
    REPO_TAG="${DOCKER_USER}/${IMAGE_TAG}"
    echo -n "$DOCKER_PASS" | docker login --username="$DOCKER_USER" --password-stdin
elif [ -n "${GCP_JSON_KEY:-}" ]; then
    # https://cloud.google.com/container-registry/docs/advanced-authentication#json-key
    REPO_TAG="gcr.io/${GCP_REGISTRY_PROJECT}/${IMAGE_TAG}"
    cat "$GCP_JSON_KEY" | docker login --username=_json_key --password-stdin https://gcr.io
else
    echo "Missing repository configuration"
    exit 1
fi

echo "PUSH image $IMAGE_TAG to $REPO_TAG"
docker tag "$IMAGE_TAG" "$REPO_TAG"
docker push "$REPO_TAG"

echo "CLONE chart repository $HELM_CHART_REPO_PATH (${HELM_CHART_BRANCH})"
git clone --depth 1 "$HELM_CHART_REPO" --branch ${HELM_CHART_BRANCH} $HELM_CHART_LOCAL_DIR

echo "GENERATE release manifest $MANIFEST_FILE_NAME using $HELM_CHART_VALUES"
docker run -v ${PWD}:/app -v ${HELM_CHART_LOCAL_DIR}:/chart $HELM_IMAGE template $APP_NAME /chart --set-string "image.tag=${COMMIT_HASH}" -f /app/$HELM_CHART_VALUES > $LOCAL_MANIFEST

echo "VALIDATE generated manifest $MANIFEST_FILE_NAME"
docker run -t -v ${PWD}:/app "$KUBEVAL_IMAGE" /app/${MANIFEST_FILE_NAME} --strict --skip-kinds "$KUBEVAL_SKIP_KINDS"

if [[ ! -z $(grep -e '^\s*securityContext\:.*$' "$LOCAL_MANIFEST") ]]; then
    echo "SCAN generated manifest $MANIFEST_FILE_NAME against security policies"
    docker run -t -v ${PWD}/:/app "$CHECKOV_IMAGE" --quiet --skip-check "$CHECKOV_SKIP_CHECKS" -f /app/${MANIFEST_FILE_NAME}
fi

echo "CLONE flux repository ${FLUX_REPO_PATH}"
git clone --depth 1 "$FLUX_REPO" --branch master $FLUX_LOCAL_DIR 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
pushd $FLUX_LOCAL_DIR

echo "CREATE branch $FLUX_RELEASE_BRANCH_NAME"
git checkout -b $FLUX_RELEASE_BRANCH_NAME

echo "ADD ${FLUX_RELEASE_MANIFEST} and COMMIT"
cp -p $LOCAL_MANIFEST $FLUX_RELEASE_MANIFEST
git add $FLUX_RELEASE_MANIFEST
git status
git commit -m "$COMMIT_MESSAGE" $FLUX_RELEASE_MANIFEST 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
git push origin $FLUX_RELEASE_BRANCH_NAME 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
git status

echo "SUBMIT $FLUX_RELEASE_BRANCH_NAME pull request"
curl -H "Authorization: Token ${GH_AUTH_TOKEN}" -H "Content-type: application/json" -X POST $GITHUB_API_PULLS >${FLUX_PR_OUTPUT} -d @- <<EOF
{
  "title": "${COMMIT_MESSAGE}",
  "body": "${PULL_REQUEST_MESSAGE}",
  "head": "${FLUX_RELEASE_BRANCH_NAME}",
  "base": "master"
}
EOF

FLUX_PULL_URL=$(jq '.html_url' ${FLUX_PR_OUTPUT})
echo "SUBMITTED $FLUX_PULL_URL"

if [[ ! "$TRAVIS_BRANCH" =~ ^(main|master)$ ]]; then
  echo "MERGING $FLUX_PULL_URL"
  GITHUB_API_MERGE="$(jq --raw-output '.url' ${FLUX_PR_OUTPUT})/merge"
  curl -H "Authorization: Token ${GH_AUTH_TOKEN}" -H "Content-type: application/json" -X PUT $GITHUB_API_MERGE -d @- <<EOF
{
  "commit_title": "Automated merge of ${PULL_REQUEST_MESSAGE}",
  "commit_message": "Automated merge of ${PULL_REQUEST_MESSAGE}",
  "sha": $(jq '.head.sha' ${FLUX_PR_OUTPUT}),
  "merge_method": "merge"
}
EOF
fi

popd

exit 0
