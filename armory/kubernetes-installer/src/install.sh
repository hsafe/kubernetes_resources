#!/bin/bash -e
cd "$(dirname "$0")"
if [ ! -z "${ARMORY_DEBUG}" ]; then
  set +e
  set -x
fi

export BUILD_DIR=build/
export CONTINUE_FILE=/tmp/armory.env
export ARMORY_CONF_STORE_PREFIX=front50
export DOCKER_REGISTRY=${DOCKER_REGISTRY:-docker.io/armory}
export LATEST_VERSION_MANIFEST_URL="https://s3-us-west-2.amazonaws.com/armory-web/install/release/armoryspinnaker-latest-version.manifest"
export LIBRARY_DOCKER_REGISTRY=${LIBRARY_DOCKER_REGISTRY:-docker.io/library}
# Start from a fresh build dir
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Ubuntu Linux, for one, will attempt to run xargs command even if no args.
# We don't want that.  However, its argument doesn't work on Mac, which does
# what we want without arguments.
echo "Testing xargs behavior..."
export XARGS_CMD="xargs --no-run-if-empty"
test_xargs=$(echo yes | xargs --no-run-if-empty 2> /dev/null) || export XARGS_CMD=xargs
echo "Using ${XARGS_CMD}"

function describe_installer() {
  if [[ ! -z "${NOPROMPT}" || ${USE_CONTINUE_FILE} == "y" ]]; then
    return
  fi

  echo "
  This installer will launch v${armoryspinnaker_version} Armory Platform into your Kubernetes cluster.
  The following are required:
    - An existing Kubernetes cluster.
    - S3, GCS, or S3 Compatible Store (ceph,minio,etc)
    If using AWS:
      - AWS Credentials File
      - AWS CLI
    If using GCP:
      - GCP Credentials
      - gcloud sdk (gsutil in particular)
    - kubectl and kubeconfig file

  The following will be created:
    - AWS S3 bucket to persist configuration (If using S3)
    - GCP bucket to persist configuration (If using GCP)
    - Kubernetes namespace '${NAMESPACE}'
    - Service account in the Kubernetes cluster for redeploying the platform.

Need help, advice, or just want to say hello during the installation?
Chat with our eng. team at http://go.Armory.io/chat.
Press 'Enter' key to continue. Ctrl+C to quit.
"
  read
}

function fetch_latest_version_manifest() {
  ONLINE="true"

  echo

  # let's check to see if we have internet
  if ! curl -sS "${LATEST_VERSION_MANIFEST_URL}" > build/armoryspinnaker-latest-version.manifest ; then
    echo "Warning: Seems like you're offline, however, this is OK!   We'll just use src/version.manifest"
    ONLINE="false"
    rm "${BUILD_DIR}/armoryspinnaker-latest-version.manifest"  # there's nothing in this file, lets just clean it up
  fi

  if [[ ${ONLINE} == "true" ]]; then
    if [[ ${FETCH_LATEST_EDGE_VERSION} == true || ${ARMORYSPINNAKER_JENKINS_JOB_ID} != "" ]]; then
      echo "Fetching edge version to src/build/version.manifest..."
      ../bin/fetch-latest-armory-version.sh
      cp build/armoryspinnaker-jenkins-version.manifest build/version.manifest
    else # we're going to fetch stable by default  ${FETCH_LATEST_STABLE_VERSION} == true
      echo "Fetching latest stable to src/build/version.manifest..."
      source build/armoryspinnaker-latest-version.manifest

      curl -sS "${armoryspinnaker_version_manifest_url}" > build/version.manifest
    fi
  fi

  # src/version.manifest has pins, let's override the one we found
  if [[ ${ONLINE} == "false" ]] || grep -q "^\s*export" version.manifest; then
    echo "Adding versions found in src/version.manifest"
    cat <<EOF >> build/version.manifest

## Overrides for version.manifest below ##
###############################################
EOF
    grep -v '^$\|^## ' version.manifest >> build/version.manifest || true # remove the empty lines and ## comments
  fi
}


function check_kubectl_version() {
  version=$(kubectl version help | grep "^Client Version" | sed 's/^.*GitVersion:"v\([0-9\.v]*\)".*$/\1/')
  version_major=$(echo $version | cut -d. -f1)
  version_minor=$(echo $version | cut -d. -f2)

  if [ $version_major -lt 1 ] || [ $version_minor -lt 8 ]; then
    error "I require 'kubectl' version 1.8.x or higher. Ref: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
  fi
}

function check_prereqs() {
  if [[ "$CONFIG_STORE" == "S3" ]]; then
    type aws >/dev/null 2>&1 || { echo "I require aws but it's not installed. Ref: http://docs.aws.amazon.com/cli/latest/userguide/installing.html" 1>&2 && exit 1; }
  fi
  type kubectl >/dev/null 2>&1 || { echo "I require 'kubectl' but it's not installed. Ref: https://kubernetes.io/docs/tasks/tools/install-kubectl/" 1>&2 && exit 1; }
  check_kubectl_version
  if [[ "$CONFIG_STORE" == "GCS" ]]; then
    type gsutil >/dev/null 2>&1 || { echo "I require 'gsutil' but it's not installed. Ref: https://cloud.google.com/storage/docs/gsutil_install#sdk-install" 1>&2 && exit 1; }
  fi
  type envsubst >/dev/null 2>&1 || { echo -e "I require 'envsubst' but it's not installed. Please install the 'gettext' package." 1>&2;
                                     echo -e "On Mac OS X, you can run:\n   brew install gettext && brew link --force gettext" 1>&2 && exit 1; }

  type jq >/dev/null 2>&1 || { echo -e "I require 'jq' but it's not installed. Please install the 'jq' package: https://stedolan.github.io/jq/download/" 1>&2;
                                     echo -e "On Mac OS X, you can run:\n   brew install jq && brew link --force jq" 1>&2 && exit 1; }
}

function validate_profile() {
  local profile=${1}
  aws configure get ${profile}.aws_access_key_id &> /dev/null
  local result=$?
  if [ "$result" == "0" ]; then
    echo "Valid Profile selected."
  else
    echo "Could not find access key id for profile '${profile}'. Are you sure there is a profile with that name in your AWS credentials file?"
  fi
  return $result
}

function validate_kubeconfig() {
  local file=${1}
  if [ -z "$file" ]; then
    echo "Using default kubeconfig"
  else
    if [ -f "$file" ]; then
      echo "Found kubeconfig."
      export KUBECONFIG=${file}
      export KUBECTL_OPTIONS="${KUBECTL_OPTIONS} --kubeconfig=$file"
    else
      echo "Could not find file ${file}"
      return 1
    fi
  fi
  return 0
}

function validate_kubeconfig_deploy() {
  local file=${1}
  if [ -z "$file" ]; then
    echo "Using default kubeconfig"
  else
    if [ -f "$file" ]; then
      echo "Found kubeconfig."
    else
      echo "Could not find file ${file}"
      return 1
    fi
  fi
  return 0
}

function validate_gcp_creds() {
  # might need more robust validation of creds
  if [ ! -f "$1" ]; then
    echo "$1 does not exist!" 1>&2
    return 1
  fi
  return 0
}

function validate_deploy_method() {
  if [[ "$1" != "1" ]] && [[ "$1" != "2" ]]; then
    echo "must input either '1' or '2'"
    return 1
  fi
  return 0
}

function get_var() {
  local text=$1
  local var_name="${2}"
  local val_func=${3}
  local val_list=${4}
  local default_val="${5}"
  debug "prompt:${var_name}"
  if [ -z ${!var_name} ]; then
    [ ! -z "$val_list" ] && $val_list
    echo -ne "${text}"
    read value
    if [ -z "${value}" ]; then
      if [ -z ${default_val+x} ]; then
        echo "This value can not be blank."
        get_var "$1" $2 $3
      else
        echo "Using default ${default_val}"
        save_response ${var_name} ${default_val}
      fi
    elif [ ! -z "$val_func" ] && ! $val_func ${value}; then
      get_var "$1" $2 $3
    else
      save_response ${var_name} ${value}
    fi
  fi
}

function prompt_user() {
  cat <<EOF
  *****************************************************************************
  * A kubeconfig file is needed to install The Armory Platform inside a       *
  * kubernetes cluster within a namespace. The same kubeconfig file can also  *
  * be added to the cluster as a secret. Alternatively, we can create a       *
  * service account in the cluster to allow The Armory Platform to redeploy   *
  * itself.                                                                   *
  *                                                                           *
  * Note: If you choose to add a kubeconfig to the cluster it must only have  *
  * one context. Specifically, context for the cluster where we are installing*
  *****************************************************************************

EOF
  get_var "What Kubernetes namespace would you like to use? [default: armory]: " NAMESPACE "" "" "armory"
  export KUBECTL_OPTIONS="--namespace=${NAMESPACE}"

  echo "Armory Platform needs access to the namespace ${NAMESPACE} to setup the environment. This is only needed when (re)installing."
  get_var "Path to kubeconfig \033[1mused for setup\033[0m [if blank default will be used]: " KUBECONFIG validate_kubeconfig "" "${HOME}/.kube/config"

  echo -e "\nArmory Platform needs access to the Kubernetes namespace ${NAMESPACE} \033[1mfor deployments\033[0m. Select your preferred method:"

  get_var "1) Use a kubeconfig file which will be mounted as a secret\n2) Create a service account\n[1/2]: " DEPLOY_AUTH_METHOD validate_deploy_method "" "1"

  if [[ "$DEPLOY_AUTH_METHOD" == "2" ]]; then
    export USE_SERVICE_ACCOUNT=true

  else
    get_var "Path to kubeconfig used for deployments [if blank default will be used]: " KUBECONFIG_DEPLOY validate_kubeconfig_deploy "" "${HOME}/.kube/config"
    export USE_SERVICE_ACCOUNT=false
    export KUBECONFIG_CONFIG_ENTRY="kubeconfigFile: /opt/spinnaker/credentials/custom/default-kubeconfig"
    encode_kubeconfig
  fi

  get_var "Please enter an email address to use as owner of the armory pipeline [changeme@armory.io]: " APP_EMAIL "" "" "changeme@armory.io"
  debug "prompt:email"

  prompt_user_for_config_store

  local bucket_name=$(awk '{ print tolower($0) }' <<< ${NAMESPACE}-platform-$(uuidgen) | cut -c 1-51)
  get_var "Bucket to use [if blank, a bucket will be generated for you]: " ARMORY_CONF_STORE_BUCKET "" "" $bucket_name

  if [[ "$CONFIG_STORE" == "S3" ]]; then
    export S3_ENABLED=true
    export GCS_ENABLED=false
  cat <<EOF

  *****************************************************************************
  * We use an AWS profile from your ~/.aws/credentials file to access the S3  *
  * bucket during this installation. The associated credentials for the       *
  * profile will also be used to generate a secret in the k8s cluster called  *
  * 'aws-s3-credentials'. The platform will use those credentials while       *
  * running to persist data to S3.                                            *
  *                                                                           *
  * Notes:                                                                    *
  * 1. If you would like to create an AWS user/role specifically for this     *
  *    task, you can replace the k8s secret after the installation is         *
  *    complete.                                                              *
  * 2. The secret is formatted as a normal AWS credentials file.              *
  * 3. If the profile you specify is using assume role, the associated keys   *
  *    will expire. In that case please create a user/role and replace the    *
  *    secret.                                                                *
  *****************************************************************************

EOF
    get_var "Enter your AWS Profile [default]: " AWS_PROFILE validate_profile "" "default"
  elif [[ "$CONFIG_STORE" == "MINIO" ]]; then
    export S3_ENABLED=true
    export GCS_ENABLED=false
  cat <<EOF

  ********************************************************************************
  * S3 compatible store access key ID and secret access key are used to          *
  * access the bucket during the installation. The keys will be placed in a      *
  * profile and added to a secret in the k8s cluster called 'aws-s3-credentials' *
  *                                                                              *
  * Notes:                                                                       *
  * 1. If you would like to create a user specifically for this                  *
  *    task, you can replace the k8s secret after the installation is            *
  *    complete.                                                                 *
  * 2. The secret is formatted as a normal AWS credentials file.                 *
  ********************************************************************************

EOF
    get_var "Enter your access key: " AWS_ACCESS_KEY_ID
    get_var "Enter your secret key: " AWS_SECRET_ACCESS_KEY
    get_var "Enter your endpoint (ex: http://172.0.10.1:9000): " MINIO_ENDPOINT
    #this is a bit of hack until this gets https://github.com/spinnaker/front50/pull/308, check description of PR
    export ENDPOINT_PROPERTY="endpoint: ${MINIO_ENDPOINT}"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY MINIO_ENDPOINT
  elif [[ "$CONFIG_STORE" == "GCS" ]]; then
    export GCS_ENABLED=true
    export S3_ENABLED=false
    export GCP_CREDS_MNT_PATH="/home/spinnaker/.gcp/gcp.json"
  fi
}

function prompt_user_for_config_store() {
  if [ ! -z $CONFIG_STORE ]; then
    return
  fi

  cat <<EOF

  *****************************************************************************
  * Configuration for the Armory Platform needs to be persisted to either S3, *
  * GCS, or S3 Compliant Store. This includes your pipeline configurations,   *
  * deployment target accounts, etc. We can create a storage bucket for you   *
  * or you can provide an already existing one.                               *
  *****************************************************************************

EOF
  options=("S3" "GCS" "S3 Compatible Store")
  echo "Which backing object store would you like to use for storing Spinnaker configs: "
  PS3='Enter choice: '
  select opt in "${options[@]}"
  do
    case $opt in
        "S3"|"GCS")
            echo "Using $opt"
            save_response CONFIG_STORE "$opt"
            break
            ;;
        "S3 Compatible Store")
            save_response CONFIG_STORE "MINIO"
            break
            ;;
        *) echo "Invalid option";;
    esac
  done
}


function select_kubectl_context() {
  if [ ! -z $KUBE_CONTEXT ]; then
      kubectl config use-context "${KUBE_CONTEXT}"
      return
  fi

  options=($(kubectl config get-contexts -o name))
  if [ ${#options[@]} -eq 0 ]; then
      echo "It appears you do not have any K8s contexts in your KUBECONFIG file. Please refer to the docs to setup access to clusters:" 1>&2
      echo "https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/"  1>&2
      exit 1
  else
    echo ""
    echo "Found the following K8s context(s) in you KUBECONFIG file: "
    PS3='Please select the one you want to use: '
    select opt in "${options[@]}"
    do
      kubectl config use-context "$opt"
      save_response KUBE_CONTEXT $opt
      break
    done
  fi
}

function select_gcp_service_account_and_encode_creds() {
  if [[ ! -z $B64CREDENTIALS ]]; then
    return
  fi

  export PROJECT_ID=$(gcloud config get-value core/project)
  export SERVICE_ACCOUNT_NAME="$(mktemp -u $NAMESPACE-svc-acct-XXXXXXXXXXXX | tr '[:upper:]' '[:lower:]' | cut -c 1-30)"
  mkdir -p ${BUILD_DIR}/credentials
  export GCP_CREDS="${BUILD_DIR}/credentials/service-account.json"

  cat <<EOF

  *****************************************************************************
  * During the installation the active GCP settings/account are used to       *
  * create and/or access the GCS bucket. After the installation, a GCP service*
  * account is used. If you already have a service account with access to the *
  * bucket, we can use it. Alternatively, we can create one for you.          *
  *****************************************************************************

EOF

  echo "Would you like to use an existing service account or create a new one?"
  PS3='Enter choice: '
  options=("Use existing" "Create new")
  select opt in "${options[@]}"
  do
    case $opt in
        "Use existing")
            accts=($(gcloud iam service-accounts list | awk '{print $NF}' | grep -v EMAIL))
            if [ ${#accts[@]} -eq 0 ]; then
                echo "Could not find any existing service account(s)" 1>&2
                exit 1
            else
              echo "Found the following service account(s):"
              PS3='Please select the one you want to use: '
              select acct in "${accts[@]}"
              do
                if [ -z "$acct" ]; then
                  echo "Invalid option"
                else
                  gcloud iam service-accounts keys create \
                    --iam-account "$acct" ${GCP_CREDS}
                  save_response B64CREDENTIALS $(base64 -w 0 -i "$GCP_CREDS" 2>/dev/null || base64 -i "$GCP_CREDS")
                  break
                fi
              done
            fi
            break
            ;;
        "Create new")
            gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
              --display-name "Armory GCS service account"
            gcloud projects add-iam-policy-binding ${PROJECT_ID} \
              --member="serviceAccount:${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
              --role='roles/storage.admin' > /dev/null 2>&1
            gcloud iam service-accounts keys create \
              --iam-account "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
              ${GCP_CREDS} > /dev/null 2>&1
            save_response B64CREDENTIALS $(base64 -w 0 -i "$GCP_CREDS" 2>/dev/null || base64 -i "$GCP_CREDS")
            break
            ;;
        *) echo "Invalid option";;
    esac
  done
}

function make_minio_bucket() {
  if AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} aws s3 ls --endpoint-url ${MINIO_ENDPOINT} "s3://${ARMORY_CONF_STORE_BUCKET}" > /dev/null 2>&1; then
    echo "Bucket already exists"
    return
  else
    echo "Creating bucket to store configuration and persist data."
    AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} aws s3 mb --endpoint-url ${MINIO_ENDPOINT} "s3://${ARMORY_CONF_STORE_BUCKET}"
  fi
}

function make_s3_bucket() {
  aws --profile "${AWS_PROFILE}" --region us-east-1 s3 ls "s3://${ARMORY_CONF_STORE_BUCKET}" > /dev/null 2>&1 || {
    echo "Creating S3 bucket '${ARMORY_CONF_STORE_BUCKET}' to store configuration and persist data."
    aws --profile "${AWS_PROFILE}" --region us-east-1 s3 mb "s3://${ARMORY_CONF_STORE_BUCKET}"
  }
}

function get_gcloud_project() {
  if [[ ! -z  $GCLOUD_PROJECT ]]; then
    return
  fi
  echo "Found the following gcloud projects: "
  options=($(gcloud projects list | grep -v PROJECT_ID | awk '{print $1}'))
  PS3='Please select the project where you want to create the bucket: '
  select opt in "${options[@]}"
  do
    if [ ! -z "$opt" ]; then
      break
    else
      echo "Invalid Choice"
    fi
  done
  export GCLOUD_PROJECT=$opt
  save_response GCLOUD_PROJECT $opt
}

function make_gcs_bucket() {
  get_gcloud_project
  gsutil ls -p "$GCLOUD_PROJECT" "gs://${ARMORY_CONF_STORE_BUCKET}/" || {
        echo "Creating GCS bucket to store configuration and persist data."
        gsutil mb -p "$GCLOUD_PROJECT" "gs://${ARMORY_CONF_STORE_BUCKET}/"
  }
}

function create_k8s_namespace() {
  if [ ! -z $SKIP_CREATE_NS ]; then
    return
  fi

  kubectl ${KUBECTL_OPTIONS} get ns ${NAMESPACE} 2>&1 >/dev/null || kubectl ${KUBECTL_OPTIONS} create namespace ${NAMESPACE}
}

function create_k8s_nginx_load_balancer() {
  echo "Creating load balancer for the Web UI."
  envsubst < manifests/nginx-svc.json > ${BUILD_DIR}/nginx-svc.json
  # Wait for IP
  kubectl ${KUBECTL_OPTIONS} apply -f ${BUILD_DIR}/nginx-svc.json
  if [[ "${LB_TYPE}" == "ClusterIP" ]]; then
    if [[ ! -z "$NGINX_PREDEFINED_URL" ]]; then
      export NGINX_IP=$NGINX_PREDEFINED_URL
      return
    fi
    #we use loopback because we create a tunnel later
    export NGINX_IP="127.0.0.1"
  else
    local IP=$(kubectl ${KUBECTL_OPTIONS} get services armory-nginx --no-headers -o wide | awk '{ print $4 }')
    echo -n "Waiting for load balancer to receive an IP..."
    while [ "$IP" == "<pending>" ] || [ -z "$IP" ]; do
      sleep 5
      local IP=$(kubectl ${KUBECTL_OPTIONS} get services armory-nginx --no-headers -o wide | awk '{ print $4 }')
      echo -n "."
    done
    echo "Found IP $IP"
    export NGINX_IP=$IP
  fi
}

function create_k8s_svcs_and_rs() {
  cat <<EOF

  *****************************************************************************
  * Creating k8s resources. This includes 'deployments', 'services',          *
  * 'config-maps' and 'secrets'.                                              *
  *****************************************************************************

EOF
  export custom_credentials_secret_name="custom-credentials"
  export nginx_certs_secret_name="nginx-certs"
  for filename in manifests/*.json; do
    envsubst < "$filename" > "$BUILD_DIR/$(basename $filename)"
  done
  for filename in build/*.json; do
    if [[ "$filename" =~ "fiat-deployment.json" ]]; then
      echo "Skipping $filename... needs configuration before deployment"
    else
      echo "Applying $filename..."
      kubectl ${KUBECTL_OPTIONS} apply -f "$filename"
    fi

  done
}

function check_for_custom_configmap() {
  echo "Checking for existing configuration..."
  foundmap=`kubectl $KUBECTL_OPTIONS get cm -o=custom-columns=NAME:.metadata.name | grep custom-config | tail -n 1`
  if [[ $foundmap ]]; then
    get_var "Found custom-config from previous run, would you like to use it? (y/n): " UPGRADE_ONLY
  fi
}

function remove_k8s_configmaps() {
  if [[ "$UPGRADE_ONLY" != "y" ]]; then
    echo "Deleting config maps and secrets if they exist"
    kubectl $KUBECTL_OPTIONS get cm default-config custom-config init-env -o=custom-columns=NAME:.metadata.name --no-headers \
      | ${XARGS_CMD} kubectl $KUBECTL_OPTIONS delete cm
  else
    echo "Deleting default config maps and secrets if they exist"
    kubectl $KUBECTL_OPTIONS get cm default-config -o=custom-columns=NAME:.metadata.name --no-headers \
      | ${XARGS_CMD} kubectl $KUBECTL_OPTIONS delete cm
  fi
}

function create_k8s_default_config() {
  kubectl ${KUBECTL_OPTIONS} create cm default-config --from-file=$(pwd)/config/default
}

function create_k8s_custom_config() {
  if [[ "$UPGRADE_ONLY" != "y" ]]; then
    mkdir -p ${BUILD_DIR}/config/custom/
    cp "config/custom/nginx.conf" "${BUILD_DIR}/config/custom/nginx.conf"
    for filename in config/custom/*.yml; do
      envsubst < $filename > ${BUILD_DIR}/config/custom/$(basename $filename)
    done
    # dump to a file to upload to S3. Used when we deploy, we use dry-run to accomplish this
    kubectl ${KUBECTL_OPTIONS} create configmap custom-config \
      -o json \
      --dry-run \
      --from-file=${BUILD_DIR}/config/custom | jq '. + {kind:"ConfigMap",apiVersion:"v1" }' \
      > ${BUILD_DIR}/config/custom/custom-config.json


    local config_file="${BUILD_DIR}/config/custom/custom-config.json"
    local config_s3_path="s3://${ARMORY_CONF_STORE_BUCKET}/front50/config_v2/config.json"
    local config_gs_path="gs://${ARMORY_CONF_STORE_BUCKET}/front50/config_v2/config.json"
    if [[ "${CONFIG_STORE}" == "S3" ]]; then

      if aws --profile "${AWS_PROFILE}" --region us-east-1 s3 ls "${config_s3_path}" > /dev/null 2>&1; then
        get_var "config.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CONFIG
      fi
      if [[ "${OVERWRITE_CONFIG}" != "n" ]] ; then
        aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
          "${config_file}" \
          "${config_s3_path}"
      else
        aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
          "${config_s3_path}" \
          "${config_file}"
      fi

    elif [[ "${CONFIG_STORE}" == "MINIO" ]]; then

      if AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 ls \
        --endpoint-url=${MINIO_ENDPOINT} "${config_s3_path}" > /dev/null 2>&1; then
          get_var "config.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CONFIG
      fi
      if [[ "${OVERWRITE_CONFIG}" != "n" ]] ; then
        AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
          --endpoint-url=${MINIO_ENDPOINT} "${config_file}" "${config_s3_path}"
      else
          AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
          --endpoint-url=${MINIO_ENDPOINT} "${config_s3_path}" "${config_file}"
      fi

    elif [[ "${CONFIG_STORE}" == "GCS" ]]; then

      if gsutil ls "${config_gs_path}" > /dev/null 2>&1; then
        get_var "config.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CONFIG
      fi
      if [[ "${OVERWRITE_CONFIG}" != "n" ]] ; then
        gsutil cp "${config_file}" "${config_gs_path}"
      else
        gsutil cp "${config_gs_path}" "${config_file}"
      fi

    fi
    # This should be applied on condition of preservering or overwriting configs
    kubectl ${KUBECTL_OPTIONS} apply -f ${BUILD_DIR}/config/custom/custom-config.json
  else
    echo "Re-using existing custom-config configmap"
  fi
}

function upload_custom_credentials() {
  debug "progress:upload_credentials"
  if [[ "$UPGRADE_ONLY" != "y" ]]; then
    local credentials_manifest="${BUILD_DIR}/custom-credentials.json"
    local certificates_manifest="${BUILD_DIR}/nginx-certs.json"
    local credentials_s3_path="s3://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/custom-credentials.json"
    local certificates_s3_path="s3://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/nginx-certs.json"
    local credentials_gs_path="gs://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/custom-credentials.json"
    local certificates_gs_path="gs://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/nginx-certs.json"
    if [[ "${CONFIG_STORE}" == "S3" ]]; then

      if aws --profile "${AWS_PROFILE}" --region us-east-1 s3 ls "${credentials_s3_path}" > /dev/null 2>&1; then
        get_var "custom-credentials.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CREDENTIALS
      fi
      if [[ "${OVERWRITE_CREDENTIALS}" != "n" ]] ; then
        aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
          "${credentials_manifest}" \
          "${credentials_s3_path}"
      fi

      if aws --profile "${AWS_PROFILE}" --region us-east-1 s3 ls "${certificates_s3_path}" > /dev/null 2>&1; then
        get_var "nginx-certs.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CERTIFICATES
      fi
      if [[ "${OVERWRITE_CERTIFICATES}" != "n" ]] ; then
        aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
          "${certificates_manifest}" \
          "${certificates_s3_path}"
      fi

    elif [[ "${CONFIG_STORE}" == "MINIO" ]]; then

      if AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 ls \
        --endpoint-url=${MINIO_ENDPOINT} "${credentials_s3_path}" > /dev/null 2>&1; then
          get_var "custom-credentials.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CREDENTIALS
      fi
      if [[ "${OVERWRITE_CREDENTIALS}" != "n" ]] ; then
        AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
          --endpoint-url=${MINIO_ENDPOINT} "${credentials_manifest}" "${credentials_s3_path}"
      fi

      if AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 ls \
        --endpoint-url=${MINIO_ENDPOINT} "${certificates_s3_path}" > /dev/null 2>&1; then
          get_var "nginx-certs.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CERTIFICATES
      fi
      if [[ "${OVERWRITE_CERTIFICATES}" != "n" ]] ; then
        AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
          --endpoint-url=${MINIO_ENDPOINT} "${certificates_manifest}" "${certificates_s3_path}"
      fi

    elif [[ "${CONFIG_STORE}" == "GCS" ]]; then

      if gsutil ls "${credentials_gs_path}" > /dev/null 2>&1; then
        get_var "custom-credentials.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CREDENTIALS
      fi
      if [[ "${OVERWRITE_CREDENTIALS}" != "n" ]] ; then
        gsutil cp "${credentials_manifest}" "${credentials_gs_path}"
      fi

      if gsutil ls "${certificates_gs_path}" > /dev/null 2>&1; then
        get_var "nginx-certs.json already exists, would you like to overwrite it? [y/n]: " OVERWRITE_CERTIFICATES
      fi
      if [[ "${OVERWRITE_CERTIFICATES}" != "n" ]] ; then
        gsutil cp "${certificates_manifest}" "${certificates_gs_path}"
      fi

    fi
  fi
}

function create_k8s_port_forward() {
  if [ "$SERVICE_TYPE" != "ClusterIP" ] || [ ! -z "$NGINX_PREDEFINED_URL" ]; then
    return
  fi

  nginx_pod=$(kubectl $KUBECTL_OPTIONS get pods -o=custom-columns=NAME:.metadata.name | grep armory-nginx | tail -1)
  cat <<EOL

********************************************************************************

 ClusterIP service type requires port forwarding using 'kubectl port-forward'
 Please run the following command in another shell:


 sudo kubectl $KUBECTL_OPTIONS port-forward $nginx_pod 80:80

********************************************************************************

EOL
  get_var "Press enter to continue after you've executed the command in another shell: " SKIP_PORT_FORWARD
}

function create_k8s_resources() {
  debug "create_resources"
  create_k8s_namespace
  create_k8s_nginx_load_balancer
  #remove the configmaps so this script is more idempotent
  remove_k8s_configmaps
  create_k8s_default_config
  create_k8s_custom_config
  if [[ "$UPGRADE_ONLY" != "y" ]]; then
    create_k8s_svcs_and_rs
    create_k8s_port_forward
  fi
}

function set_aws_vars() {
  role_arn=$(aws configure get ${AWS_PROFILE}.role_arn || true)
  if [[ "${role_arn}" == "" ]]; then
    export AWS_ACCESS_KEY_ID=$(aws configure get ${AWS_PROFILE}.aws_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(aws configure get ${AWS_PROFILE}.aws_secret_access_key)
  else
    #for more info on setting up your credentials file go here: http://docs.aws.amazon.com/cli/latest/topic/config-vars.html#using-aws-iam-roles
    source_profile=$(aws configure get ${AWS_PROFILE}.source_profile)
    temp_session_data=$(aws sts assume-role --role-arn ${role_arn} --role-session-name armory-spinnaker --profile ${source_profile} --output text)
    export AWS_ACCESS_KEY_ID=$(echo ${temp_session_data} | awk '{print $5}')
    export AWS_SECRET_ACCESS_KEY=$(echo ${temp_session_data} | awk '{print $7}')
    export AWS_SESSION_TOKEN=$(echo ${temp_session_data} | awk '{print $8}')
  fi
  export AWS_REGION=us-east-1
}

function encode_credentials() {
  if [[ "$CONFIG_STORE" == "S3" ]]; then
      set_aws_vars
  fi
  #both MINIO and S3 can use the same credentials file since we'll use the S3 protocol
  if [[ "$CONFIG_STORE" == "S3" || "$CONFIG_STORE" == "MINIO" ]]; then

      export CREDENTIALS_FILE="[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
"
      export B64CREDENTIALS=$(base64 -w 0 <<< "${CREDENTIALS_FILE}" 2>/dev/null || base64 <<< "${CREDENTIALS_FILE}")
  elif [[ "$CONFIG_STORE" == "GCS" ]]; then
    select_gcp_service_account_and_encode_creds
  fi
}

function encode_kubeconfig() {
  B64KUBECONFIG=$(base64 -w 0 "${KUBECONFIG_DEPLOY}" 2>/dev/null || base64 "${KUBECONFIG_DEPLOY}")
  export KUBECONFIG_ENTRY_IN_SECRETS_FILE="\"default-kubeconfig\": \"${B64KUBECONFIG}\""
}

function output_install_results() {
cat <<EOF

Installation complete. You can finish configuring the Armory Platform via:

  http://${NGINX_IP}/#/platform/config

Your new Armory deploying Armory pipeline is here:

  http://${NGINX_IP}/#/applications/armory/executions

Your configuration has been stored in the ${CONFIG_STORE} bucket:

  ${ARMORY_CONF_STORE_BUCKET}

EOF
}

function output_upgrade_results() {
cat <<EOF

Deploy configuration complete. To update the running instance, run the Deploy
pipeline here:

  <your spinnaker>/#/applications/armory/executions

EOF
}

function touch_last_modified() {
  # Need to "touch" front50/pipelines/last-modified so that front50 reloads
  # the pipeline.

  local bucket_path="front50/pipelines/last-modified"
  cat <<EOF > ${BUILD_DIR}/last-modified.json
{
  "lastModified": `date +%s`000
}
EOF
  if [[ "${CONFIG_STORE}" == "S3" ]]; then
    aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
      "${BUILD_DIR}/last-modified.json" \
      "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}.json"
  elif [[ "${CONFIG_STORE}" == "MINIO" ]]; then
    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
      --endpoint-url=${MINIO_ENDPOINT} \
      "${BUILD_DIR}/last-modified.json" \
      "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}.json"
  elif [[ "${CONFIG_STORE}" == "GCS" ]]; then
    if [[ "$UPGRADE_ONLY" == "y" ]]; then
      gsutil setmeta "gs://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}"
    fi
  fi
}

function upload_undo_pipeline() {
  local src_json="pipelines/undo.json"
  local dest_json="${BUILD_DIR}/pipeline/undo_pipeline.json"
  envsubst < "$src_json" > "$dest_json"
  local bucket_path="front50/pipelines/undo-armory-update"
  if [[ "${CONFIG_STORE}" == "S3" ]]; then
    aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
      "${dest_json}" \
      "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/pipeline-metadata.json"
  elif [[ "${CONFIG_STORE}" == "MINIO" ]]; then
    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
      --endpoint-url=${MINIO_ENDPOINT} "${dest_json}" "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/pipeline-metadata.json"
  elif [[ "${CONFIG_STORE}" == "GCS" ]]; then
    gsutil cp "${dest_json}" "gs://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/specification.json"
  fi

}

function upload_upgrade_pipeline() {
  local pipeline_json="${BUILD_DIR}/pipeline/pipeline.json"
  local bucket_path="front50/pipelines/update-spinnaker"
  if [[ "${CONFIG_STORE}" == "S3" ]]; then
    aws --profile "${AWS_PROFILE}" --region us-east-1 s3 cp \
      "${pipeline_json}" \
      "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/pipeline-metadata.json"
  elif [[ "${CONFIG_STORE}" == "MINIO" ]]; then
    AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} aws s3 cp \
      --endpoint-url=${MINIO_ENDPOINT} "${pipeline_json}" "s3://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/pipeline-metadata.json"
  elif [[ "${CONFIG_STORE}" == "GCS" ]]; then
    gsutil cp "${pipeline_json}" "gs://${ARMORY_CONF_STORE_BUCKET}/${bucket_path}/specification.json"
  fi

  upload_undo_pipeline
  touch_last_modified
}

function create_upgrade_pipeline() {
  debug "progress:create_pipeline"
  cat <<EOF

  *****************************************************************************
  * After the installation is complete, a re-deploy pipeline will be provided *
  * You can find it by navigating the Web UI URL (provided later), selecting  *
  * 'Applications' from the top navigation bar, click on 'armory', then click *
  * on 'Pipelines'. You should see a pipeline called 'Deploy'. It can be used *
  * to both upgrade and redeploy after a configuration change.                *
  *****************************************************************************

EOF
  echo "Creating..."

  export custom_credentials_secret_name=$(echo -ne \${\#stage\(\'Deploy Credentials\'\)[\'context\'][\'artifacts\'][0][\'reference\']})
  export nginx_certs_secret_name=$(echo -ne \${\#stage\(\'Deploy Certificates\'\)[\'context\'][\'artifacts\'][0][\'reference\']})

  mkdir -p ${BUILD_DIR}/pipeline
  for filename in manifests/*-deployment.json; do
    envsubst < "$filename" > "$BUILD_DIR/pipeline/pipeline-$(basename $filename)"
  done

  if [[ "${S3_ENABLED}" == "true" ]]; then
    export CONFIG_ARTIFACT_URI=s3://${ARMORY_CONF_STORE_BUCKET}/front50/config_v2/config.json
    export SECRET_ARTIFACT_URI=s3://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/custom-credentials.json
    export CERT_ARTIFACT_URI=s3://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/nginx-certs.json
    export ARTIFACT_KIND=s3
    export ARTIFACT_ACCOUNT=armory-config-s3-account
  elif [[ "${GCS_ENABLED}" == "true" ]]; then
    export CONFIG_ARTIFACT_URI=gs://${ARMORY_CONF_STORE_BUCKET}/front50/config_v2/config.json
    export SECRET_ARTIFACT_URI=gs://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/custom-credentials.json
    export CERT_ARTIFACT_URI=gs://${ARMORY_CONF_STORE_BUCKET}/front50/secrets/nginx-certs.json
    export ARTIFACT_KIND=gcs
    export ARTIFACT_ACCOUNT=armory-config-gcs-account
  else
    error "Either S3 or GCS must be enabled."
  fi

cat <<EOF > ${BUILD_DIR}/app.json
{
  "job": [
    { "type": "createApplication",
      "application": {
        "name": "armory",
        "email": "${APP_EMAIL}"
      },
      "user": "[anonymous]" }
  ],
  "application":"armory",
  "description":"Create Application: armory"
}
EOF

cat <<EOF > ${BUILD_DIR}/pipeline/pipeline.json
{
  "application": "armory",
  "name": "Deploy Armory",
  "id": "update-spinnaker",
  "armoryVersion": "${armoryspinnaker_version}",
  "keepWaitingPipelines": false,
  "limitConcurrent": true,
  "expectedArtifacts": [
    {
      "defaultArtifact": {
        "kind": "default.${ARTIFACT_KIND}",
        "name": "${CONFIG_ARTIFACT_URI}",
        "reference": "${CONFIG_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "id": "ced981ba-4bf5-41e2-8ee0-07209f79d190",
      "matchArtifact": {
        "kind": "${ARTIFACT_KIND}",
        "name": "${CONFIG_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "useDefaultArtifact": true,
      "usePriorExecution": false
    },
    {
      "defaultArtifact": {
        "kind": "default.${ARTIFACT_KIND}",
        "name": "${SECRET_ARTIFACT_URI}",
        "reference": "${SECRET_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "id": "ced981ba-4bf5-41e2-8ee0-07209f79d191",
      "matchArtifact": {
        "kind": "${ARTIFACT_KIND}",
        "name": "${SECRET_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "useDefaultArtifact": true,
      "usePriorExecution": false
    },
    {
      "defaultArtifact": {
        "kind": "default.${ARTIFACT_KIND}",
        "name": "${CERT_ARTIFACT_URI}",
        "reference": "${CERT_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "id": "ced981ba-4bf5-41e2-8ee0-07209f79d192",
      "matchArtifact": {
        "kind": "${ARTIFACT_KIND}",
        "name": "${CERT_ARTIFACT_URI}",
        "type": "${ARTIFACT_KIND}/object"
      },
      "useDefaultArtifact": true,
      "usePriorExecution": false
    }
  ],
  "stages": [
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifestArtifactAccount": "${ARTIFACT_ACCOUNT}",
      "manifestArtifactId": "ced981ba-4bf5-41e2-8ee0-07209f79d190",
      "moniker": {
        "app": "armory",
        "cluster": "custom-config"
      },
      "name": "Deploy Config",
      "refId": "1",
      "relationships": {
        "loadBalancers": [],
        "securityGroups": []
      },
      "requisiteStageRefIds": [],
      "source": "artifact",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifestArtifactAccount": "${ARTIFACT_ACCOUNT}",
      "manifestArtifactId": "ced981ba-4bf5-41e2-8ee0-07209f79d191",
      "moniker": {
        "app": "armory",
        "cluster": "custom-credentials"
      },
      "name": "Deploy Credentials",
      "refId": "12",
      "relationships": {
        "loadBalancers": [],
        "securityGroups": []
      },
      "requisiteStageRefIds": [],
      "source": "artifact",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifestArtifactAccount": "${ARTIFACT_ACCOUNT}",
      "manifestArtifactId": "ced981ba-4bf5-41e2-8ee0-07209f79d192",
      "moniker": {
        "app": "armory",
        "cluster": "nginx-certs"
      },
      "name": "Deploy Certificates",
      "refId": "2",
      "relationships": {
        "loadBalancers": [],
        "securityGroups": []
      },
      "requisiteStageRefIds": [],
      "source": "artifact",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-rosco-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "rosco"
      },
      "name": "Deploy Rosco",
      "refId": "10",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-clouddriver-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "clouddriver"
      },
      "name": "Deploy clouddriver",
      "refId": "11",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-deck-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "deck"
      },
      "name": "Deploy deck",
      "refId": "3",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-echo-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "echo"
      },
      "name": "Deploy echo",
      "refId": "4",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-front50-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "front50"
      },
      "name": "Deploy front50",
      "refId": "5",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-gate-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "gate"
      },
      "name": "Deploy gate",
      "refId": "6",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-igor-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "igor"
      },
      "name": "Deploy igor",
      "refId": "7",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-lighthouse-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "lighthouse"
      },
      "name": "Deploy lighthouse",
      "refId": "8",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-dinghy-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "dinghy"
      },
      "name": "Deploy dinghy",
      "refId": "9",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-configurator-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "configurator"
      },
      "name": "Deploy configurator",
      "refId": "18",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-orca-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "orca"
      },
      "name": "Deploy orca",
      "refId": "13",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-nginx-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "nginx"
      },
      "name": "Deploy nginx",
      "refId": "14",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-kayenta-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "kayenta"
      },
      "name": "Deploy kayenta",
      "refId": "15",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-fiat-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "fiat"
      },
      "name": "Deploy fiat",
      "refId": "16",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "stageEnabled": {
        "expression": "false",
        "type": "expression"
      },
      "type": "deployManifest"
    },
    {
      "account": "kubernetes",
      "cloudProvider": "kubernetes",
      "manifests": [
          $(cat ${BUILD_DIR}/pipeline/pipeline-platform-deployment.json)
      ],
      "moniker": {
          "app": "armory",
          "cluster": "platform"
      },
      "name": "Deploy platform",
      "refId": "17",
      "requisiteStageRefIds": ["2", "1", "12"],
      "overrideTimeout": true,
      "stageTimeoutMs": 900000,
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "source": "text",
      "type": "deployManifest"
    },
    {
      "completeOtherBranchesThenFail": false,
      "continuePipeline": true,
      "failPipeline": false,
      "name": "Check Status",
      "preconditions": [
        {
          "context": {
            "expression": "\${#stage('Deploy deck')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy echo')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy front50')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy gate')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy igor')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy lighthouse')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy dinghy')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy Rosco')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy clouddriver')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy orca')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy nginx')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy kayenta')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy platform')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        },
        {
          "context": {
            "expression": "\${#stage('Deploy configurator')['status'].toString() == 'SUCCEEDED'}"
          },
          "failPipeline": true,
          "type": "expression"
        }
      ],
      "refId": "19",
      "requisiteStageRefIds": [
        "3",
        "10",
        "11",
        "4",
        "6",
        "5",
        "7",
        "8",
        "9",
        "18",
        "13",
        "14",
        "15",
        "16",
        "17"
      ],
      "type": "checkPreconditions"
    },
    {
      "application": "armory",
      "failPipeline": true,
      "name": "Undo",
      "pipeline": "undo-armory-update",
      "refId": "20",
      "requisiteStageRefIds": [
        "19"
      ],
      "stageEnabled": {
        "expression": "\${#stage('Check Status')['status'].toString() != 'SUCCEEDED'}",
        "type": "expression"
      },
      "type": "pipeline",
      "waitForCompletion": true
    }
  ]
}
EOF


  echo "Waiting for the API gateway to become ready, we'll then create an Armory deploy Armory pipeline!"
  echo "This may take several minutes."
  counter=0
  set +e
  while true; do
    curl --max-time 10 -s -o /dev/null http://${NGINX_IP}/api/applications
    exit_code=$?
    if [[ "$exit_code" == "0" ]]; then
      # Ensure the application exists.
      curl --max-time 10 -s -o /dev/null -X POST -d@${BUILD_DIR}/app.json -H "Content-type: application/json" "http://${NGINX_IP}/api/applications/armory/tasks"
      break
    fi
    if [ "$counter" -gt 200 ]; then
      echo "ERROR: Timeout occurred waiting for http://${NGINX_IP}/api to become available"
      exit 2
    fi
    counter=$((counter+1))
    echo -n "."
    sleep 2
  done
  set -e
  upload_upgrade_pipeline
}

function set_custom_profile() {
  cpu_vars=("CLOUDDRIVER_CPU" "CONFIGURATOR_CPU" "DECK_CPU" "DINGHY_CPU" "ECHO_CPU" "FIAT_CPU" "FRONT50_CPU" "GATE_CPU" "IGOR_CPU" "KAYENTA_CPU" "LIGHTHOUSE_CPU" "ORCA_CPU" "PLATFORM_CPU" "REDIS_CPU" "ROSCO_CPU")
  for v in "${cpu_vars[@]}"; do
    echo "What allocation would you like for $v?"
    options=("500m" "1000m" "1500m" "2000m" "2500m")
    PS3="Enter choice: "
    select opt in "${options[@]}"
    do
      case $opt in
          "500m"|"1000m"|"1500m"|"2000m"|"2500m")
              echo "Setting $v to $opt"
              export "$v"="$opt"
              break
              ;;
          *) echo "Invalid option";;
      esac
    done
  done
  mem_vars=("CLOUDDRIVER_MEMORY" "CONFIGURATOR_MEMORY" "DECK_MEMORY" "DINGHY_MEMORY" "ECHO_MEMORY" "FIAT_MEMORY" "FRONT50_MEMORY" "GATE_MEMORY" "IGOR_MEMORY" "KAYENTA_MEMORY" "LIGHTHOUSE_MEMORY" "ORCA_MEMORY" "PLATFORM_MEMORY" "REDIS_MEMORY" "ROSCO_MEMORY")
  for v in "${mem_vars[@]}"; do
    echo "What allocation would you like for $v?"
    options=("512Mi" "1Gi" "2Gi" "4Gi" "8Gi" "16Gi")
    PS3="Enter choice: "
    select opt in "${options[@]}"
    do
      case $opt in
          "512Mi"|"1Gi"|"2Gi"|"4Gi"|"8Gi"|"16Gi")
              echo "Setting $v to $opt"
              export "$v"="$opt"
              break
              ;;
          *) echo "Invalid option";;
      esac
    done
  done
}


function set_resources() {
  if [ ! -z $NOPROMPT ]; then
    source sizing_profiles/small.env
    return
  fi

  if [ ! -z $SIZE_PROFILE ]; then
    file=`echo ${SIZE_PROFILE} | tr [:upper:] [:lower:]`
    source sizing_profiles/${file}.env
    return
  fi

  cat <<EOF

  ******************************************************************************************
  * The Armory Platform can be installed with 4 different resource                         *
  * configurations. Which one you choose will be dependent on your expected                *
  * load. For explanation of the units for CPU & MEMORY, please refer to:                  *
  * https://kubernetes.io/docs/concepts/configuration/manage-compute-resources-container/  *
  * NOTE: the cluster should have nodes with enough resources to accommodate each          *
  * microservice's CPU/MEMORY requirements, else the pods might become "unschedulable"     *
  ******************************************************************************************

EOF
  echo ""
  echo "  'Small'"
  echo "       CPU: 250m per microservice"
  echo "       MEMORY: 256Mi per microservice"
  echo "       Total CPU: 4000m (4 vCPUs)"
  echo "       Total MEMORY: 4096Mi (~4 GB)"
  echo ""
  echo "  'Medium'"
  echo "       CPU: 500m for configurator, deck, dinghy, echo, fiat, front50, gate, igor, kayenta,"
  echo "                      lighthouse, platform, redis, & rosco"
  echo "            1000m for clouddriver, & orca"
  echo "       MEMORY: 512Mi for deck, dinghy, fiat, echo, kayenta, lighthouse, platform, & rosco"
  echo "               1Gi for front50, gate, igor, & rosco"
  echo "               2Gi for clouddriver, orca, & redis"
  echo "       Total CPU: 10000m (10 vCPUs)"
  echo "       Total MEMORY: 18.5Gi (~19.86 GB)"
  echo ""
  echo "  'Large'"
  echo "       CPU: 500m for configurator, dinghy, kayenta, lighthouse, & platform"
  echo "            1000m for deck, echo, fiat, front50, gate, igor, redis, & rosco"
  echo "            2000m for clouddriver, & orca"
  echo "       MEMORY: 521Mi for configurator, deck, dinghy, fiat, kayenta, lighthouse, & platform"
  echo "               1Gi for echo, & rosco"
  echo "               2Gi for front50, gate & igor"
  echo "               4Gi for orca"
  echo "               16Gi for redis"
  echo "       Total CPU: 19500m (19.5 vCPUs)"
  echo "       Total MEMORY: 28.5Gi (~30.6 GB)"
  echo ""
  echo "  'Custom'"
  echo "       You enter the CPU/MEMORY for each microservice"
  echo ""

  options=("Small" "Medium" "Large" "Custom")
  PS3='Which profile would you like to use: '
  select opt in "${options[@]}"
  do
    case $opt in
        "Small"|"Medium"|"Large")
            save_response SIZE_PROFILE $opt
            echo "Using profile: '${SIZE_PROFILE}'"
            file=`echo ${SIZE_PROFILE} | tr [:upper:] [:lower:]`
            source sizing_profiles/${file}.env
            break
            ;;
        "Custom")
            echo "Using profile: 'Custom'"
            set_custom_profile
            break
            ;;
        *) echo "Invalid option";;
    esac
  done
}

function set_lb_type() {
  if [ ! -z $LB_TYPE ]; then
    return
  fi
  cat <<EOF

  *****************************************************************************
  * When the Armory Platform runs it exposes one loadbalancer to users.       *
  * Depending on how your network is configured, you will want these load     *
  * balancers to either be 'internal', 'external' or a 'clusterIP'.  For      *
  * clusterIP deployments it uses 'kubectl' to create a tunnel to the         *
  * cluster. After installation, it is also recommended that you configure    *
  * a firewall rule or security group to only allow access to whitelisted IPs.*
  *****************************************************************************

EOF
  echo "Load balancer types: "
  options=("Internal" "External" "ClusterIP")
  PS3='Select the LB type you want to use: '
  select opt in "${options[@]}"
  do
    case $opt in
        "Internal"|"External"|"ClusterIP")
            save_response LB_TYPE "$opt"
            echo "Using LB type: $opt"
            break
            ;;
        *) echo "Invalid option";;
    esac
  done

  if [[ "${LB_TYPE}" == "ClusterIP" ]]; then
    save_response SERVICE_TYPE $LB_TYPE
  else
    save_response SERVICE_TYPE "LoadBalancer"
  fi

  # using internal load balancers requires extra info for AWS
  # https://github.com/kubernetes/kubernetes/blob/master/pkg/cloudprovider/providers/aws/aws.go#L102
  if [[ "${LB_TYPE}" == "Internal" ]]; then
    save_response LB_INTERNAL "true"
  else
    # `false` is evaluated by an empty string not the word false
    # https://github.com/kubernetes/kubernetes/blob/7bbe309d8d64adf72b13ced258f1e97567dd945d/pkg/cloudprovider/providers/aws/aws.go#L3316
    save_response LB_INTERNAL ""
  fi

  if [[ "${LB_TYPE}" == "ClusterIP" ]]; then
    get_var "Enter a pre-defined URL for the environment if applicable. If none, we'll ask you to bind your service before continuing: " NGINX_PREDEFINED_URL
  fi
}

function save_response() {
  export ${1}=${2}
  echo "export ${1}=${2}" >> $CONTINUE_FILE
}

function continue_env() {
    debug "prompt:continue_env"
    if [[ ! -z  $NOPROMPT ]]; then
      return
    fi

    if [[ -f $CONTINUE_FILE ]]; then
        get_var "Found continue file at $CONTINUE_FILE from previous run, would you like to use it? (y/n): " USE_CONTINUE_FILE
        if [[ "$USE_CONTINUE_FILE" == "y" ]]; then
          source $CONTINUE_FILE
        else
          echo "removing continue file at $CONTINUE_FILE"
          rm $CONTINUE_FILE
        fi
    fi
}

function make_bucket() {
  if [ "$CONFIG_STORE" == "S3" ]; then
    make_s3_bucket
  elif [ "$CONFIG_STORE" == "GCS" ]; then
    make_gcs_bucket
  elif [ "$CONFIG_STORE" == "MINIO" ]; then
    make_minio_bucket
  fi
}

function debug() {
  detail_type=$(echo "$1" | awk '{print tolower($0)}')
  curl -s -X POST https://debug.armory.io/ -H "Authorization: Armory ${ARMORY_ID}" -d"{
    \"content\": {
      \"status\": \"success\",
      \"email\": \"${APP_EMAIL}\"
    },
    \"details\": {
      \"source\": \"installer\",
      \"type\": \"installation:$detail_type\"
    }
  }" 1&2 2>>/dev/null || true
}

function error() {
  curl -s -X POST https://debug.armory.io/ -H "Authorization: Armory ${ARMORY_ID}" -d"{
    \"content\": {
      \"status\": \"failure\",
      \"error\": \"$1\",
      \"email\": \"${APP_EMAIL}\"
    },
    \"details\": {
      \"source\": \"installer\",
      \"type\": \"installation:failure\"
    }
  }" 1&2 2>>/dev/null || true
  >&2 echo $1
  exit 1
}

function print_options_message() {
cat <<EOF

Armory Platform installer for Kubernetes.

usage: [--stable, -s][--edge, -e][--help, -h]

  -s, --stable   fetch the latest stable build of Armory.
  -e, --edge     fetch the latest edge build of Armory.
  -h, --help     show this message

EOF
}

# Transform short options to long ones
for arg in "$@"; do
  shift
  case "$arg" in
    "-h") set -- "$@" "--help" ;;
    "-e") set -- "$@" "--edge" ;;
    "-s") set -- "$@" "--stable" ;;
    *) set -- "$@" "$arg"
  esac
done


while getopts ":-:" optchar; do
  case "${optchar}" in
    -)
      case "${OPTARG}" in
        help)
          print_options_message
          exit 0
          ;;
        stable)
          FETCH_LATEST_STABLE_VERSION=${FETCH_LATEST_STABLE_VERSION:-true}
          ;;
        edge)
          FETCH_LATEST_EDGE_VERSION=${FETCH_LATEST_EDGE_VERSION:-true}
          ;;
        *)
          echo "Unknown option --${OPTARG}" >&2
          print_options_message
          exit 2
          ;;
      esac;;
    *)
      echo "Unknown option -${OPTARG}" >&2
      print_options_message
      exit 2
      ;;
  esac
done

fetch_latest_version_manifest
source build/version.manifest


function main() {
  export ARMORY_ID=$(uuidgen 2>>/dev/null || date +%s 2>>/dev/null || echo $(( RANDOM % 1000000 )))
  debug "started"
  continue_env
  describe_installer
  prompt_user
  check_prereqs
  select_kubectl_context
  set_lb_type
  set_resources
  check_for_custom_configmap
  make_bucket
  encode_credentials
  create_k8s_resources
  upload_custom_credentials
  create_upgrade_pipeline
  if [[ "$UPGRADE_ONLY" != "y" ]]; then
    output_install_results
  else
    output_upgrade_results
  fi
  debug "success"
}

main
