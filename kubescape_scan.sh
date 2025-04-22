#!/bin/bash

# Kubescape Scan Script - Enhanced Version
# - Checks for dependencies (aws cli, kubectl, kubescape, git, jq)
# - Prompts for AWS Region and validates it
# - Prompts for S3 Bucket name (with default)
# - Checks if S3 bucket exists, asks to create if not
# - Shows AWS identity being used (for permission awareness)
# - Prompts for desired report format (html, json, pdf)
# - Runs Kubescape scans for NSA & MITRE frameworks
# - Saves reports locally in timestamped folders under ~/kubescape_reports
# - Uploads reports and installation logs to the specified S3 bucket/path

# --- Configuration ---
DEFAULT_S3_BUCKET_NAME="kubeguard-reports"   # Default bucket
S3_BASE_FOLDER="kubescape-reports"           # Top-level folder in S3
FRAMEWORKS_TO_SCAN="nsa mitre"               # Frameworks to scan
VALID_FORMATS="html json pdf"                # Supported Kubescape output formats

# --- Helper Functions ---
spinner() {
    local pid=$1 msg=$2 spin='|/-\\' i=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        echo -ne "\r[${spin:$i:1}] ${msg}"
        sleep 0.1
    done
    tput cnorm
    echo -ne "\r                         \r"
}

check_tool() {
    TOOL_NAME=$1
    echo -n "Checking for ${TOOL_NAME}... "
    if ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
        echo "[MISSING]"
        if [[ "$TOOL_NAME" == "jq" ]]; then
            echo "Please install jq: e.g. 'sudo apt-get install jq'"
        elif [[ "$TOOL_NAME" == "aws" ]]; then
            echo "Please install AWS CLI v2"
        elif [[ "$TOOL_NAME" == "kubectl" ]]; then
            echo "Please install kubectl"
        elif [[ "$TOOL_NAME" == "git" ]]; then
            echo "Attempting to install git..."
            sudo apt-get update && sudo apt-get install -y git || sudo yum install -y git || echo "Failed to install git."
            if ! command -v git >/dev/null 2>&1; then return 1; fi
            echo "[Installed]"
        fi
        if [[ "$TOOL_NAME" != "kubescape" ]] && ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
           return 1
        fi
    else
         echo "[OK]"
         return 0
    fi
}

install_kubescape() {
    INSTALL_LOG="${HOME}/kubescape_install.log"
    echo "Attempting to install Kubescape... (logs: ${INSTALL_LOG})"
    # Run installer in background to show spinner
    (curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash >"${INSTALL_LOG}" 2>&1) &
    spinner $! "Installing Kubescape"
    wait $!
    export PATH=$PATH:/home/cloudshell-user/.kubescape/bin
    if ! command -v kubescape >/dev/null 2>&1; then
        echo "[ERROR] Kubescape installation failed. See ${INSTALL_LOG}"
        return 1
    else
        echo "[OK] Kubescape installed. See log: ${INSTALL_LOG}"
        echo "Tip: Add 'export PATH=\$PATH:/home/cloudshell-user/.kubescape/bin' to ~/.bashrc"
        return 0
    fi
}

# --- 1. Dependency Checks ---
echo "--- Checking Prerequisites ---"
check_tool "aws"    || exit 1
check_tool "kubectl"|| exit 1
check_tool "git"    || exit 1
check_tool "jq"     # recommend but non-fatal
if ! command -v kubescape >/dev/null 2>&1; then
    install_kubescape || exit 1
else
    echo "Kubescape found: $(command -v kubescape)"
fi
kubescape version
echo "-----------------------------"
echo

# --- 2. User Input ---
echo "--- Gathering Information ---"
while true; do
    read -p "AWS Region (e.g., ap-south-1): " REGION
    if [[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then break; fi
    echo "Invalid format, try again."
done

read -p "S3 bucket name [default: ${DEFAULT_S3_BUCKET_NAME}]: " S3_BUCKET_NAME_INPUT
S3_BUCKET_NAME=${S3_BUCKET_NAME_INPUT:-$DEFAULT_S3_BUCKET_NAME}

while true; do
    read -p "Report format (${VALID_FORMATS// /|}): " SELECTED_FORMAT
    SELECTED_FORMAT_LOWER=$(echo "$SELECTED_FORMAT" | tr '[:upper:]' '[:lower:]')
    if [[ " ${VALID_FORMATS} " =~ " ${SELECTED_FORMAT_LOWER} " ]]; then
        OUTPUT_FORMAT=$SELECTED_FORMAT_LOWER
        OUTPUT_EXT=$SELECTED_FORMAT_LOWER
        break
    fi
    echo "Invalid choice."
done
echo "-----------------------------"
echo

# --- 3. AWS Identity ---
echo "--- AWS Identity ---"
aws sts get-caller-identity --output text || { echo "AWS CLI not configured."; exit 1; }
echo "Ensure S3 PutObject on s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/*"
echo "-----------------------------"
echo

# --- 4. S3 Bucket Check & Creation ---
echo "--- Checking S3 Bucket ---"
aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Bucket ${S3_BUCKET_NAME} missing."
    while true; do
        read -p "Create it in ${REGION}? (y/n): " yn
        yn=${yn,,}
        if [[ "$yn" == "y" ]]; then
            if [[ "$REGION" == "us-east-1" ]]; then
                aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}"
            else
                aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}"
            fi
            [ $? -eq 0 ] && break || { echo "Bucket creation failed."; exit 1; }
        elif [[ "$yn" == "n" ]]; then
            echo "Exiting."; exit 1
        fi
    done
else
    echo "Bucket exists."
fi
echo "-----------------------------"
echo

# --- 5. Prepare Directories & Filenames ---
CURRENT_DATE=$(date +'%Y%m%d')
CURRENT_TIME=$(date +'%H%M%S')
TIMESTAMP_FOLDER="${CURRENT_DATE}/${CURRENT_TIME}"
LOCAL_TEMP_REPORT_DIR="${HOME}/kubescape_reports/${TIMESTAMP_FOLDER}"
mkdir -p "${LOCAL_TEMP_REPORT_DIR}" || { echo "Cannot create ${LOCAL_TEMP_REPORT_DIR}"; exit 1; }

# Upload Kubescape install log to S3
if [ -f "${HOME}/kubescape_install.log" ]; then
    echo "Uploading Kubescape install log..."
    aws s3 cp "${HOME}/kubescape_install.log" "s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/kubescape_install.log" --region "${REGION}" || echo "[WARN] Failed to upload install log"
fi

# --- 6. Run Scans & Upload ---
echo "--- Starting Kubescape Scans ---"
echo "(Terminal kept clean; see logs in ${LOCAL_TEMP_REPORT_DIR})"

SCAN_UPLOAD_FAILED=false
for FRAMEWORK in $FRAMEWORKS_TO_SCAN; do
  echo "----------------------------------------"
  SCAN_MSG="Running ${FRAMEWORK^^} -> ${OUTPUT_FORMAT^^}"
  REPORT="${FRAMEWORK^^}_Report_${CURRENT_DATE}_${CURRENT_TIME}.${OUTPUT_EXT}"
  LOCAL_PATH="${LOCAL_TEMP_REPORT_DIR}/${REPORT}"
  S3_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${REPORT}"
  LOG_FILE="${LOCAL_TEMP_REPORT_DIR}/${FRAMEWORK}_cli_logs.log"

  echo "Framework: ${FRAMEWORK}"
  echo "Local: ${LOCAL_PATH}"
  echo "S3: ${S3_PATH}"
  echo "Log: ${LOG_FILE}"

  kubescape scan framework "${FRAMEWORK}" --format "${OUTPUT_FORMAT}" --output "${LOCAL_PATH}" --verbose \
    >"${LOG_FILE}" 2>&1 &
  spinner $! "${SCAN_MSG}"
  wait $!
  if [ $? -ne 0 ]; then
    echo "[ERROR] Scan failed for ${FRAMEWORK}. See ${LOG_FILE}"
    SCAN_UPLOAD_FAILED=true
    continue
  fi

  aws s3 cp "${LOCAL_PATH}" "${S3_PATH}" --region "${REGION}"
  aws s3 cp "${LOG_FILE}" "s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${FRAMEWORK}_cli_logs.log" --region "${REGION}"
  [ $? -eq 0 ] && echo "[OK] Uploaded ${FRAMEWORK}" || { echo "[ERROR] Upload failed for ${FRAMEWORK}"; SCAN_UPLOAD_FAILED=true; }
done

# --- 7. Final Summary ---
echo "----------------------------------------"
if $SCAN_UPLOAD_FAILED; then
  echo "[WARN] Some scans/uploads failed. Check ${LOCAL_TEMP_REPORT_DIR}"
  exit 1
else
  echo "[SUCCESS] All done! Reports & logs in ${LOCAL_TEMP_REPORT_DIR}"
  exit 0
fi
