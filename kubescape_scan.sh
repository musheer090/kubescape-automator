#!/bin/bash

# Kubescape Scan Script - Enhanced & Automated Version
# Supports two modes:
# 1. Interactive Mode: Prompts user for input (original behavior).
# 2. Non-Interactive Mode: Accepts parameters via command-line flags for automation (e.g., cron jobs).

# --- Configuration ---
DEFAULT_S3_BUCKET_NAME="kubeguard-reports"      # Default bucket if not provided
DEFAULT_OUTPUT_FORMAT="json"                   # Default format for non-interactive mode
S3_BASE_FOLDER="kubescape-reports"             # Top-level folder in S3
FRAMEWORKS_TO_SCAN="nsa mitre"                 # Frameworks to scan
VALID_FORMATS="html json pdf"                  # Supported Kubescape output formats

# --- Helper Functions ---
spinner() {
    local pid=$1 msg=$2 spin='|/-\\' i=0
    tput civis # Hide cursor
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        echo -ne "\r[${spin:$i:1}] ${msg}"
        sleep 0.1
    done
    tput cnorm # Restore cursor
    echo -ne "\r                                                                                    \r"
}

check_tool() {
    # (This function remains unchanged from the original script)
    TOOL_NAME=$1
    echo -n "Checking for ${TOOL_NAME}... "
    if ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
        echo "[MISSING]"
        if [[ "$TOOL_NAME" == "jq" ]]; then
            echo "  Recommendation: Install jq (e.g., 'sudo apt-get install jq')."
            return 0
        elif [[ "$TOOL_NAME" == "aws" ]]; then
            echo "  Error: Please install AWS CLI v2 and configure it."
            return 1
        elif [[ "$TOOL_NAME" == "kubectl" ]]; then
            echo "  Error: Please install kubectl and ensure it's configured for your cluster."
            return 1
        elif [[ "$TOOL_NAME" == "git" ]]; then
            echo "  Error: Please install git."
            return 1
        fi
        if [[ "$TOOL_NAME" != "kubescape" ]]; then
            return 1
        fi
    else
        echo "[OK]"
        return 0
    fi
}


install_kubescape() {
    # (This function remains unchanged from the original script)
    INSTALL_LOG="${HOME}/kubescape_install.log"
    KUBESCAPE_BIN_PATH="${HOME}/.kubescape/bin/kubescape"
    echo "Attempting to install Kubescape... (logs: ${INSTALL_LOG})"
    (curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash >"${INSTALL_LOG}" 2>&1) &
    INSTALL_PID=$!
    spinner $INSTALL_PID "Installing Kubescape"
    wait $INSTALL_PID
    INSTALL_EXIT_CODE=$?
    if [[ -x "${KUBESCAPE_BIN_PATH}" ]]; then
        echo "[OK] Kubescape binary found at ${KUBESCAPE_BIN_PATH}."
        export PATH="${PATH}:${HOME}/.kubescape/bin"
        echo "  Tip: Add 'export PATH=\$PATH:${HOME}/.kubescape/bin' to your ~/.bashrc or ~/.profile."
        return 0
    else
        echo "[ERROR] Kubescape installation failed. Check log: ${INSTALL_LOG}"
        if [[ $INSTALL_EXIT_CODE -ne 0 ]]; then
            echo "  Installer script exited with non-zero status (${INSTALL_EXIT_CODE})."
        fi
        return 1
    fi
}

usage() {
    echo "Usage: $0 [-r region] [-b bucket] [-f format] [-c] [-h]"
    echo
    echo "Runs Kubescape scans and uploads reports to S3. Can be run interactively or non-interactively."
    echo
    echo "Modes:"
    echo "  Interactive:      Run script without any flags."
    echo "  Non-Interactive:  Provide all required flags for automated execution (e.g., for cron jobs)."
    echo
    echo "Options:"
    echo "  -r REGION    (Required for non-interactive) The AWS Region for the S3 bucket."
    echo "  -b BUCKET    The S3 bucket name. Defaults to '${DEFAULT_S3_BUCKET_NAME}'."
    echo "  -f FORMAT    The report output format (html, json, pdf). Defaults to '${DEFAULT_OUTPUT_FORMAT}'."
    echo "  -c           Authorize the script to create the S3 bucket if it does not exist."
    echo "  -h           Display this help message."
    echo
    echo "Example (cron job):"
    echo "  $0 -r us-east-1 -b my-kubescape-reports -f json -c"
}

# --- 0. Argument Parsing ---
# Initialize variables
REGION=""
S3_BUCKET_NAME_INPUT=""
OUTPUT_FORMAT=""
CREATE_BUCKET_FLAG=false
MODE="interactive" # Default to interactive mode

# If arguments are passed, switch to non-interactive mode
if [ "$#" -gt 0 ]; then
    MODE="non-interactive"
fi

while getopts ":r:b:f:ch" opt; do
    case ${opt} in
        r ) REGION=$OPTARG ;;
        b ) S3_BUCKET_NAME_INPUT=$OPTARG ;;
        f ) OUTPUT_FORMAT=$OPTARG ;;
        c ) CREATE_BUCKET_FLAG=true ;;
        h ) usage; exit 0 ;;
        \? ) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
        : ) echo "Invalid option: -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    esac
done

# --- 1. Dependency Checks ---
echo "--- Checking Prerequisites ---"
check_tool "aws"     || exit 1
check_tool "kubectl" || exit 1
check_tool "git"     || exit 1
check_tool "jq"

if ! command -v kubescape >/dev/null 2>&1; then
    echo "Kubescape not found in PATH."
    install_kubescape || exit 1
fi
echo "-----------------------------"
echo

# --- 2. Gather Information (Mode-Dependent) ---
echo "--- Gathering Information (Mode: ${MODE}) ---"

if [ "$MODE" == "interactive" ]; {
    # Original interactive prompts
    while true; do
        read -p "Enter the AWS Region for the S3 bucket (e.g., ap-south-1): " REGION_INPUT
        if [[ "$REGION_INPUT" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
            REGION=$REGION_INPUT
            break
        else
            echo "Invalid region format. Please use format like 'us-east-1'."
        fi
    done
    read -p "Enter the S3 bucket name to store reports [default: ${DEFAULT_S3_BUCKET_NAME}]: " S3_BUCKET_NAME_INPUT
    while true; do
        read -p "Enter desired report format (${VALID_FORMATS// /|}): " SELECTED_FORMAT
        if [[ " ${VALID_FORMATS} " =~ " $(echo "$SELECTED_FORMAT" | tr '[:upper:]' '[:lower:]') " ]]; then
            OUTPUT_FORMAT=$(echo "$SELECTED_FORMAT" | tr '[:upper:]' '[:lower:]')
            break
        else
            echo "Invalid format choice. Please select one of: ${VALID_FORMATS}"
        fi
    done
} else { # Non-interactive mode
    if [ -z "$REGION" ]; then
        echo "[ERROR] AWS Region is required for non-interactive mode. Use the -r flag." >&2
        usage
        exit 1
    fi
    # Set defaults if not provided by flags
    if [ -z "$OUTPUT_FORMAT" ]; then
        OUTPUT_FORMAT=$DEFAULT_OUTPUT_FORMAT
    fi
    # Validate format
    if [[ ! " ${VALID_FORMATS} " =~ " ${OUTPUT_FORMAT} " ]]; then
        echo "[ERROR] Invalid format '${OUTPUT_FORMAT}' provided with -f flag. Valid formats are: ${VALID_FORMATS}" >&2
        exit 1
    fi
    echo "AWS Region: ${REGION} (from -r flag)"
    echo "Report Format: ${OUTPUT_FORMAT} (from -f flag or default)"
} fi

# Common variable assignment for bucket name
S3_BUCKET_NAME=${S3_BUCKET_NAME_INPUT:-$DEFAULT_S3_BUCKET_NAME}
echo "Using S3 bucket: ${S3_BUCKET_NAME}"
echo "-----------------------------"
echo

# --- 3. AWS Identity & Permissions ---
# (This section remains unchanged)
echo "--- AWS Identity & Permissions ---"
AWS_IDENTITY=$(aws sts get-caller-identity --output text --query 'Arn' 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to get AWS caller identity. Is AWS CLI configured correctly?"
    exit 1
fi
echo "Script will run using AWS identity: ${AWS_IDENTITY}"
echo "Ensure this identity has s3:PutObject, s3:HeadBucket, and potentially s3:CreateBucket permissions."
echo "-----------------------------"
echo

# --- 4. S3 Bucket Check & Creation ---
echo "--- Checking S3 Bucket (${S3_BUCKET_NAME} in ${REGION}) ---"
aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Bucket '${S3_BUCKET_NAME}' does not exist or is not accessible."
    if [ "$MODE" == "interactive" ]; then
        read -p "Do you want to attempt to create it? (y/n): " yn
        if [[ "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
            CREATE_BUCKET_FLAG=true
        fi
    fi

    if [ "$CREATE_BUCKET_FLAG" = true ]; then
        echo "Attempting to create S3 bucket..."
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}"
        else
            aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}"
        fi
        if [ $? -eq 0 ]; then
            echo "[OK] Bucket '${S3_BUCKET_NAME}' created successfully."
        else
            echo "[ERROR] Failed to create bucket. Check AWS permissions and bucket naming rules."
            exit 1
        fi
    else
        echo "Exiting. Bucket does not exist and creation was not authorized."
        exit 1
    fi
else
    echo "[OK] Bucket '${S3_BUCKET_NAME}' found."
fi
echo "-----------------------------"
echo

# --- Sections 5, 6, 7, and 8 (Prepare Dirs, Upload Logs, Run Scans, Final Summary) ---
# These sections remain unchanged from the original script as their logic is sound.
# They will use the variables (REGION, S3_BUCKET_NAME, OUTPUT_FORMAT) set by either the
# interactive or non-interactive block above.

# --- 5. Prepare Local Directories & Filenames ---
CURRENT_DATE=$(date +'%Y-%m-%d')
CURRENT_TIME=$(date +'%H%M%S')
TIMESTAMP_FOLDER="${CURRENT_DATE}/${CURRENT_TIME}"
LOCAL_REPORTS_BASE_DIR="${HOME}/kubescape_reports"
LOCAL_TIMESTAMP_DIR="${LOCAL_REPORTS_BASE_DIR}/${TIMESTAMP_FOLDER}"

echo "--- Preparing Local Directories ---"
mkdir -p "${LOCAL_TIMESTAMP_DIR}" || { echo "[ERROR] Failed to create ${LOCAL_TIMESTAMP_DIR}"; exit 1; }
echo "[OK] Local report directory created: ${LOCAL_TIMESTAMP_DIR}"
echo "---------------------------------"
echo

# --- 6. Upload Kubescape Installation Log ---
# (Unchanged)
INSTALL_LOG_PATH="${HOME}/kubescape_install.log"
if [ -f "${INSTALL_LOG_PATH}" ]; then
    echo "--- Uploading Kubescape Install Log ---"
    S3_INSTALL_LOG_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/kubescape_install.log"
    (aws s3 cp "${INSTALL_LOG_PATH}" "${S3_INSTALL_LOG_PATH}" --region "${REGION}") &
    spinner $! "Uploading Kubescape install log"
    wait $! && echo "[OK] Log uploaded." || echo "[WARN] Failed to upload install log."
    echo "-------------------------------------"
    echo
fi

# --- 7. Run Scans & Upload Results ---
echo "--- Starting Kubescape Scans ---"
SCAN_UPLOAD_FAILED=false
for FRAMEWORK in $FRAMEWORKS_TO_SCAN; do
    FRAMEWORK_UPPER=$(echo "$FRAMEWORK" | tr '[:lower:]' '[:upper:]')
    REPORT_FILENAME="${FRAMEWORK_UPPER}_Report.${OUTPUT_FORMAT}"
    LOG_FILENAME="${FRAMEWORK_UPPER}_Scan_CLI.log"
    LOCAL_REPORT_PATH="${LOCAL_TIMESTAMP_DIR}/${REPORT_FILENAME}"
    LOCAL_LOG_PATH="${LOCAL_TIMESTAMP_DIR}/${LOG_FILENAME}"
    S3_REPORT_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${REPORT_FILENAME}"
    S3_LOG_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${LOG_FILENAME}"

    echo "----------------------------------------"
    echo "Starting Scan for Framework: ${FRAMEWORK_UPPER}"
    (kubescape scan framework "${FRAMEWORK}" --format "${OUTPUT_FORMAT}" --output "${LOCAL_REPORT_PATH}" --verbose >"${LOCAL_LOG_PATH}" 2>&1) &
    SCAN_PID=$!
    spinner $SCAN_PID "Running ${FRAMEWORK_UPPER} scan..."
    wait $SCAN_PID
    SCAN_EXIT_CODE=$?

    if [ $SCAN_EXIT_CODE -ne 0 ]; then
        echo "[ERROR] Kubescape scan failed for '${FRAMEWORK_UPPER}'. See log: ${LOCAL_LOG_PATH}"
        SCAN_UPLOAD_FAILED=true
        if [ -f "${LOCAL_LOG_PATH}" ]; then
            (aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}") &
            spinner $! "Uploading failure log for ${FRAMEWORK_UPPER}"
            wait $!
        fi
        continue
    else
        echo "[OK] Scan completed successfully for '${FRAMEWORK_UPPER}'."
    fi

    # Upload Report File
    (aws s3 cp "${LOCAL_REPORT_PATH}" "${S3_REPORT_PATH}" --region "${REGION}") &
    spinner $! "Uploading ${FRAMEWORK_UPPER} report..."
    wait $!
    if [ $? -eq 0 ]; then
        echo "[OK] Report uploaded."
    else
        echo "[ERROR] Failed to upload report for ${FRAMEWORK_UPPER}."
        SCAN_UPLOAD_FAILED=true
    fi
    
    # Upload Log File
    (aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}") &
    spinner $! "Uploading ${FRAMEWORK_UPPER} CLI log..."
    wait $! && echo "[OK] CLI log uploaded." || echo "[WARN] Failed to upload CLI log."
done

# --- 8. Final Summary ---
# (Unchanged)
echo "----------------------------------------"
echo "--- Scan and Upload Summary ---"
if $SCAN_UPLOAD_FAILED; then
    echo "[WARN] One or more scans or critical uploads failed."
    echo "Please review logs in: ${LOCAL_TIMESTAMP_DIR}"
    exit 1
else
    echo "[SUCCESS] All scans completed and reports uploaded successfully!"
    echo "Artifacts are in: ${LOCAL_TIMESTAMP_DIR}"
    echo "S3 Path: s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/"
    exit 0
fi
