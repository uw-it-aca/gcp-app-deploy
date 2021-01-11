#!/usr/bin/env bash
set -eu
trap 'exit 1' ERR

# stage $RELEASE_NAME as flux repository branch candidate for deployment
#
# NOTES:
#      - git clone/push output piped thru sed to mask possible auth_token spill
#
# PRECONDITION: inherited environment variables MUST include:
#      RELEASE_NAME: application's name as it is expressed in k8s cluster
#      COMMIT_HASH: application's source commit to be deployed
#      GIT_REPO_BRANCH: application's git repository branch to deploy
#      GIT_REPO_SLUG: application's git repository path
#      BUILD_NUMBER: id connected to automated build process
#      BUILD_WEB_URL: automated build process output reference
#      GH_AUTH_TOKEN: github token used for branching and merging flux repo
#
# OPTIONAL:
#      APP_INSTANCE: if set, used for instance in dev GCP project,
#                    used as the values prefix: docker/<APP_INSTANCE>-values.yml
#      HELM_APP_VERSION: if set, use specified helm version (default "3.0.0")
#      HELM_CHART_BRANCH: if set, use specified chart branch (default "master")
#      DRY_RUN: only output steps that would run, but do not run them
#
# NOTE:
#      helm template values will be pulled from the file
#           docker/${APP_INSTANCE}-values.yml
#      in the projects git repository
#

setup_context() {
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

    # globally useful definitions
    APP_NAME=${RELEASE_NAME}-prod-${APP_INSTANCE}

    # flux manifest
    MANIFEST_FILE_NAME=${RELEASE_NAME}${FLUX_RELEASE_SUFFIX}.yaml
    LOCAL_MANIFEST=${PWD}/$MANIFEST_FILE_NAME

    # flux repository
    FLUX_REPO_NAME=gcp-flux-${FLUX_INSTANCE}
    FLUX_RELEASE_BRANCH_NAME=release/${FLUX_INSTANCE}/${RELEASE_NAME}/$COMMIT_HASH

    # local paths
    FLUX_LOCAL_DIR=${PWD}/$FLUX_REPO_NAME
    FLUX_PR_OUTPUT=${PWD}/pr-${FLUX_INSTANCE}-${RELEASE_NAME}-${COMMIT_HASH}.json

    echo "#####################################"
    echo "DEPLOY $APP_NAME in $GCP_PROJECT"
    echo "#####################################"
}

clone_helm_chart() {
    # helm chart repository name and branch
    HELM_CHART_NAME=django-production-chart
    HELM_CHART_BRANCH="${HELM_CHART_BRANCH:-master}"

    HELM_CHART_LOCAL_DIR=${PWD}/$HELM_CHART_NAME
    HELM_CHART_REPO_PATH=uw-it-aca/${HELM_CHART_NAME}
    HELM_CHART_REPO=https://github.com/${HELM_CHART_REPO_PATH}.git

    echo "${DRY_RUN_PREFIX}CLONE chart repository $HELM_CHART_REPO_PATH (${HELM_CHART_BRANCH})"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    git clone --depth 1 "$HELM_CHART_REPO" --branch ${HELM_CHART_BRANCH} $HELM_CHART_LOCAL_DIR
}

generate_manifest() {
    # defaults
    HELM_APP_VERSION="${HELM_APP_VERSION:-3.4.2}"
    HELM_IMAGE="alpine/helm:${HELM_APP_VERSION}"

    # config
    HELM_CHART_VALUES=docker/${APP_INSTANCE}-values.yml

    echo "${DRY_RUN_PREFIX}GENERATE release manifest $MANIFEST_FILE_NAME using $HELM_CHART_VALUES"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    docker run -v ${PWD}:/app -v ${HELM_CHART_LOCAL_DIR}:/chart $HELM_IMAGE template $APP_NAME /chart --set-string "image.tag=${COMMIT_HASH}" -f /app/$HELM_CHART_VALUES > $LOCAL_MANIFEST
}

validate_manifest() {
    KUBEVAL_VERSION="${KUBEVAL_VERSION:-latest}"
    KUBEVAL_SKIP_KINDS="${KUBEVAL_SKIP_KINDS:-ExternalSecret,ServiceMonitor}"
    KUBEVAL_IMAGE="garethr/kubeval:${KUBEVAL_VERSION}"

    echo "${DRY_RUN_PREFIX}VALIDATE generated manifest $MANIFEST_FILE_NAME"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    docker run -t -v ${PWD}:/app "$KUBEVAL_IMAGE" /app/${MANIFEST_FILE_NAME} --strict --skip-kinds "$KUBEVAL_SKIP_KINDS"
}

security_policy_scan() {
    CHECKOV_VERSION="${CHECKOV_VERSION:-latest}"
    CHECKOV_IMAGE="bridgecrew/checkov:${CHECKOV_VERSION}"
    # acceptable policy violations:
    #    CKV_K8S_21 - default namespace policy
    #    CKV_K8S_35 - secret files preferred over environment
    #    CKV_K8S_43 - image reference by digest
    CHECKOV_SKIP_CHECKS="${CHECKOV_SKIP_CHECKS:-CKV_K8S_21,CKV_K8S_35,CKV_K8S_43}"

    echo "${DRY_RUN_PREFIX}SCAN generated manifest $MANIFEST_FILE_NAME against security policies"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    docker run -t -v ${PWD}/:/app "$CHECKOV_IMAGE" --quiet --skip-check "$CHECKOV_SKIP_CHECKS" -f /app/${MANIFEST_FILE_NAME}
}

clone_flux_repository() {
    FLUX_REPO_PATH=uw-it-aca/$FLUX_REPO_NAME
    FLUX_REPO=https://${GH_AUTH_TOKEN}@github.com/${FLUX_REPO_PATH}.git

    echo "${DRY_RUN_PREFIX}CLONE flux repository ${FLUX_REPO_PATH}"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    git clone --depth 1 "$FLUX_REPO" --branch master $FLUX_LOCAL_DIR 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
}

create_flux_release_branch() {
    echo "${DRY_RUN_PREFIX}CREATE branch $FLUX_RELEASE_BRANCH_NAME"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    pushd $FLUX_LOCAL_DIR
    git checkout -b $FLUX_RELEASE_BRANCH_NAME
    popd
}

add_and_commit_flux_release() {
    FLUX_RELEASE_MANIFEST=releases/${FLUX_INSTANCE}/$MANIFEST_FILE_NAME

    echo "${DRY_RUN_PREFIX}ADD ${FLUX_RELEASE_MANIFEST} and COMMIT"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    pushd $FLUX_LOCAL_DIR
    cp -p $LOCAL_MANIFEST $FLUX_RELEASE_MANIFEST
    git add $FLUX_RELEASE_MANIFEST
    git status
    git commit -m "$COMMIT_MESSAGE" $FLUX_RELEASE_MANIFEST 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
    git push origin $FLUX_RELEASE_BRANCH_NAME 2>&1 | sed -E 's/[[:xdigit:]]{32,}/[secret]/g'
    git status
    popd
}

submit_flux_pull_release() {
    GITHUB_API_PULLS=https://api.github.com/repos/${FLUX_REPO_PATH}/pulls

    COMMIT_MESSAGE="Automated ${FLUX_INSTANCE} deploy of ${GIT_REPO_SLUG}:${COMMIT_HASH} build ${BUILD_NUMBER}"
    PULL_REQUEST_MESSAGE="Automated ${FLUX_INSTANCE} deploy of [${GIT_REPO_SLUG}:${COMMIT_HASH}](/${GIT_REPO_SLUG}/commit/${COMMIT_HASH})  Generated build [${BUILD_NUMBER}]($BUILD_WEB_URL)"

    echo "${DRY_RUN_PREFIX}SUBMIT $FLUX_RELEASE_BRANCH_NAME pull request"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    pushd $FLUX_LOCAL_DIR
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
    popd
}

merge_flux_pull_request() {
    echo "${DRY_RUN_PREFIX}MERGING $FLUX_PULL_URL"

    if [[ -n $DRY_RUN_PREFIX ]]; then
        return
    fi

    GITHUB_API_MERGE="$(jq --raw-output '.url' ${FLUX_PR_OUTPUT})/merge"

    pushd $FLUX_LOCAL_DIR
    curl -H "Authorization: Token ${GH_AUTH_TOKEN}" -H "Content-type: application/json" -X PUT $GITHUB_API_MERGE -d @- <<EOF
{
  "commit_title": "Automated merge of ${PULL_REQUEST_MESSAGE}",
  "commit_message": "Automated merge of ${PULL_REQUEST_MESSAGE}",
  "sha": $(jq '.head.sha' ${FLUX_PR_OUTPUT}),
  "merge_method": "merge"
}
EOF
    popd
}

deploy() {
    if [[ -n ${DRY_RUN:-} ]]; then
        DRY_RUN_PREFIX="WOULD: "
    else
        DRY_RUN_PREFIX=""
    fi

    setup_context

    clone_helm_chart

    generate_manifest

    validate_manifest

    if [[ -n $(grep -e '^\s*securityContext\:.*$' "$LOCAL_MANIFEST") ]]; then
        security_policy_scan
    fi

    clone_flux_repository

    create_flux_release_branch

    add_and_commit_flux_release

    submit_flux_pull_release

    if [[ ! "$GIT_REPO_BRANCH" =~ ^(main|master)$ ]]; then
        merge_flux_pull_request
    fi
}

deploy
exit 0
