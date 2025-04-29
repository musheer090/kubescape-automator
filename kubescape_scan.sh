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
DEFAULT_S3_BUCKET_NAME="kubeguard-reports"      # Default bucket
S3_BASE_FOLDER="kubescape-reports"              # Top-level folder in S3
FRAMEWORKS_TO_SCAN="nsa mitre"                  # Frameworks to scan
VALID_FORMATS="html json pdf"                   # Supported Kubescape output formats

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
    # Clear the spinner line
    echo -ne "\r                                                                                \r"
}

check_tool() {
    TOOL_NAME=$1
    echo -n "Checking for ${TOOL_NAME}... "
    if ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
        echo "[MISSING]"
        # Specific installation guidance (can be enhanced)
        if [[ "$TOOL_NAME" == "jq" ]]; then
            echo "  Recommendation: Install jq (e.g., 'sudo apt-get update && sudo apt-get install -y jq' or 'sudo yum install -y jq'). Required for some advanced features."
            # Returning 0 as jq is recommended but not strictly essential for basic script operation
            return 0
        elif [[ "$TOOL_NAME" == "aws" ]]; then
            echo "  Error: Please install AWS CLI v2 and configure it."
            return 1
        elif [[ "$TOOL_NAME" == "kubectl" ]]; then
            echo "  Error: Please install kubectl and ensure it's configured for your cluster."
            return 1
        elif [[ "$TOOL_NAME" == "git" ]]; then
             echo "  Error: Please install git (e.g., 'sudo apt-get update && sudo apt-get install -y git' or 'sudo yum install -y git')."
             return 1
        fi
        # If we reach here for a tool other than kubescape and it's missing, it's an error
        if [[ "$TOOL_NAME" != "kubescape" ]]; then
             return 1
        fi
    else
        echo "[OK]"
        return 0
    fi
}

install_kubescape() {
    INSTALL_LOG="${HOME}/kubescape_install.log"
    KUBESCAPE_BIN_PATH="${HOME}/.kubescape/bin/kubescape"
    echo "Attempting to install Kubescape... (logs: ${INSTALL_LOG})"
    echo "Installer output will be saved to ${INSTALL_LOG}"

    # Run installer in background to show spinner
    (curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash >"${INSTALL_LOG}" 2>&1) &
    INSTALL_PID=$! # Capture the PID
    spinner $INSTALL_PID "Installing Kubescape"
    wait $INSTALL_PID
    INSTALL_EXIT_CODE=$? # Capture the exit code of the install script

    # Verify if the binary exists and is executable AFTER the install script ran
    if [[ -x "${KUBESCAPE_BIN_PATH}" ]]; then
        echo "[OK] Kubescape binary found at ${KUBESCAPE_BIN_PATH}."
        echo "      See full installation log: ${INSTALL_LOG}"
        # Export the PATH for the *current* script session
        export PATH="${PATH}:${HOME}/.kubescape/bin"
        echo "      Temporarily added Kubescape to PATH for this script run."
        echo "      Tip: Add 'export PATH=\$PATH:${HOME}/.kubescape/bin' to your ~/.bashrc or ~/.profile for future sessions."
        return 0 # Signal success
    else
        echo "[ERROR] Kubescape installation failed."
        echo "       Reason: Binary not found or not executable at expected location (${KUBESCAPE_BIN_PATH})."
        echo "       Please check the installation log for details: ${INSTALL_LOG}"
        # Optionally report the installer script's exit code if it was non-zero
        if [[ $INSTALL_EXIT_CODE -ne 0 ]]; then
             echo "       Installer script also exited with non-zero status (${INSTALL_EXIT_CODE})."
        fi
        return 1 # Signal failure
    fi
}

# --- 1. Dependency Checks ---
echo "--- Checking Prerequisites ---"
check_tool "aws"     || exit 1
check_tool "kubectl" || exit 1
check_tool "git"     || exit 1
check_tool "jq"      # Recommend jq but don't exit if missing

# Check for Kubescape and install if necessary
if ! command -v kubescape >/dev/null 2>&1; then
    echo "Kubescape not found in PATH initially."
    install_kubescape || exit 1 # Try to install, exit if install_kubescape function reports failure

    # Verify again AFTER install_kubescape ran and potentially updated PATH
    if ! command -v kubescape >/dev/null 2>&1; then
         echo "[FATAL] Kubescape installed but 'command -v kubescape' still fails. Check installation log and PATH setup."
         exit 1
    fi
    echo "Kubescape is now available in PATH: $(command -v kubescape)"
else
    echo "Kubescape found: $(command -v kubescape)"
fi

# Display Kubescape version if available
if command -v kubescape >/dev/null 2>&1; then
    echo -n "Kubescape version: "
    # CORRECTED LINE: Removed the invalid '--verbose=false' flag
    kubescape version
    # Optional: Check exit status, though the original script continued anyway
    if [ $? -ne 0 ]; then
        echo "[WARN] 'kubescape version' command reported an error, but proceeding."
    fi
else
    echo "[WARN] Could not display Kubescape version."
fi
echo "-----------------------------"
echo

# --- 2. User Input ---
echo "--- Gathering Information ---"
# Get AWS Region
while true; do
    read -p "Enter the AWS Region for the S3 bucket (e.g., ap-south-1): " REGION
    # Basic validation regex for AWS region format
    if [[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
        break
    else
        echo "Invalid region format. Please use format like 'us-east-1', 'ap-southeast-2', etc."
    fi
done

# Get S3 Bucket Name
read -p "Enter the S3 bucket name to store reports [default: ${DEFAULT_S3_BUCKET_NAME}]: " S3_BUCKET_NAME_INPUT
S3_BUCKET_NAME=${S3_BUCKET_NAME_INPUT:-$DEFAULT_S3_BUCKET_NAME}
echo "Using S3 bucket: ${S3_BUCKET_NAME}"

# Get Report Format
while true; do
    read -p "Enter desired report format (${VALID_FORMATS// /|}): " SELECTED_FORMAT
    SELECTED_FORMAT_LOWER=$(echo "$SELECTED_FORMAT" | tr '[:upper:]' '[:lower:]') # Convert to lowercase
    # Check if the lowercase input is in the list of valid formats
    if [[ " ${VALID_FORMATS} " =~ " ${SELECTED_FORMAT_LOWER} " ]]; then
        OUTPUT_FORMAT=$SELECTED_FORMAT_LOWER
        OUTPUT_EXT=$SELECTED_FORMAT_LOWER
        break
    else
        echo "Invalid format choice. Please select one of: ${VALID_FORMATS}"
    fi
done
echo "Selected report format: ${OUTPUT_FORMAT}"
echo "-----------------------------"
echo

# --- 3. AWS Identity & Permissions ---
echo "--- AWS Identity & Permissions ---"
echo "Checking AWS identity being used..."
AWS_IDENTITY=$(aws sts get-caller-identity --output text --query 'Arn')
if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to get AWS caller identity. Is AWS CLI configured correctly?"
    exit 1
fi
echo "Script will run using AWS identity: ${AWS_IDENTITY}"
echo "Ensure this identity has 's3:PutObject' permissions on 's3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/*'"
echo "Ensure this identity has 's3:CreateBucket' permissions if the bucket needs to be created."
echo "Ensure this identity has 's3:HeadBucket' or 's3:ListBucket' permissions to check if the bucket exists."
echo "-----------------------------"
echo

# --- 4. S3 Bucket Check & Creation ---
echo "--- Checking S3 Bucket (${S3_BUCKET_NAME} in ${REGION}) ---"
# Check if bucket exists using head-bucket
aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1
S3_CHECK_EXIT_CODE=$?

if [ $S3_CHECK_EXIT_CODE -ne 0 ]; then
    echo "Bucket '${S3_BUCKET_NAME}' does not seem to exist in region ${REGION} or you lack permissions to check."
    CREATE_BUCKET=false
    while true; do
        read -p "Do you want to attempt to create the bucket '${S3_BUCKET_NAME}' in region ${REGION}? (y/n): " yn
        yn_lower=$(echo "$yn" | tr '[:upper:]' '[:lower:]') # Convert to lowercase
        if [[ "$yn_lower" == "y" ]]; then
            CREATE_BUCKET=true
            break
        elif [[ "$yn_lower" == "n" ]]; then
            echo "Exiting script as the required S3 bucket does not exist and creation was declined."
            exit 1
        else
            echo "Invalid input. Please enter 'y' or 'n'."
        fi
    done

    if $CREATE_BUCKET; then
        echo "Attempting to create S3 bucket '${S3_BUCKET_NAME}' in region ${REGION}..."
        # Handle us-east-1 needing no LocationConstraint
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}"
        else
            aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}"
        fi

        if [ $? -eq 0 ]; then
            echo "[OK] Bucket '${S3_BUCKET_NAME}' created successfully."
        else
            echo "[ERROR] Failed to create bucket '${S3_BUCKET_NAME}'. Check AWS permissions and bucket naming rules."
            exit 1
        fi
    fi
else
    echo "[OK] Bucket '${S3_BUCKET_NAME}' exists in region ${REGION} (or is accessible)."
fi
echo "-----------------------------"
echo

# --- 5. Prepare Local Directories & Filenames ---
CURRENT_DATE=$(date +'%Y-%m-%d') # Use ISO 8601 date format
CURRENT_TIME=$(date +'%H%M%S')
TIMESTAMP_FOLDER="${CURRENT_DATE}/${CURRENT_TIME}" # Structure: YYYY-MM-DD/HHMMSS
LOCAL_REPORTS_BASE_DIR="${HOME}/kubescape_reports"
LOCAL_TIMESTAMP_DIR="${LOCAL_REPORTS_BASE_DIR}/${TIMESTAMP_FOLDER}"

echo "--- Preparing Local Directories ---"
echo "Local report directory: ${LOCAL_TIMESTAMP_DIR}"
mkdir -p "${LOCAL_TIMESTAMP_DIR}"
if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to create local report directory: ${LOCAL_TIMESTAMP_DIR}"
    exit 1
fi
echo "[OK] Local directory created."
echo "---------------------------------"
echo

# --- 6. Upload Kubescape Installation Log (if it exists) ---
INSTALL_LOG_PATH="${HOME}/kubescape_install.log"
S3_INSTALL_LOG_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/kubescape_install.log"

if [ -f "${INSTALL_LOG_PATH}" ]; then
    echo "--- Uploading Kubescape Install Log ---"
    echo "Uploading ${INSTALL_LOG_PATH} to ${S3_INSTALL_LOG_PATH}"
    (aws s3 cp "${INSTALL_LOG_PATH}" "${S3_INSTALL_LOG_PATH}" --region "${REGION}") &
    spinner $! "Uploading Kubescape install log"
    wait $!
    if [ $? -eq 0 ]; then
        echo "[OK] Kubescape install log uploaded."
    else
        echo "[WARN] Failed to upload Kubescape install log. Check S3 permissions or network."
        # Do not exit, continue with scans
    fi
    echo "-------------------------------------"
    echo
fi

# --- 7. Run Scans & Upload Results ---
echo "--- Starting Kubescape Scans ---"
echo "Reports will be saved locally in: ${LOCAL_TIMESTAMP_DIR}"
echo "Reports and CLI logs will be uploaded to: s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/"
echo "(Scan progress messages will be minimal; detailed output is logged to files)"
echo

SCAN_UPLOAD_FAILED=false # Flag to track if any scan or upload fails

for FRAMEWORK in $FRAMEWORKS_TO_SCAN; do
    FRAMEWORK_UPPER=$(echo "$FRAMEWORK" | tr '[:lower:]' '[:upper:]') # Uppercase for filenames/messages
    REPORT_FILENAME="${FRAMEWORK_UPPER}_Report_${CURRENT_DATE}_${CURRENT_TIME}.${OUTPUT_EXT}"
    LOG_FILENAME="${FRAMEWORK_UPPER}_Scan_CLI_${CURRENT_DATE}_${CURRENT_TIME}.log"

    LOCAL_REPORT_PATH="${LOCAL_TIMESTAMP_DIR}/${REPORT_FILENAME}"
    LOCAL_LOG_PATH="${LOCAL_TIMESTAMP_DIR}/${LOG_FILENAME}"

    S3_REPORT_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${REPORT_FILENAME}"
    S3_LOG_PATH="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/${LOG_FILENAME}"

    echo "----------------------------------------"
    echo "Starting Scan for Framework: ${FRAMEWORK_UPPER}"
    echo "  Report Format: ${OUTPUT_FORMAT}"
    echo "  Local Report: ${LOCAL_REPORT_PATH}"
    echo "  Local Log:    ${LOCAL_LOG_PATH}"
    echo "  S3 Report:    ${S3_REPORT_PATH}"
    echo "  S3 Log:       ${S3_LOG_PATH}"

    # Execute Kubescape scan, redirect stdout and stderr to the log file, run in background for spinner
    (kubescape scan framework "${FRAMEWORK}" --format "${OUTPUT_FORMAT}" --output "${LOCAL_REPORT_PATH}" --verbose >"${LOCAL_LOG_PATH}" 2>&1) &
    SCAN_PID=$!
    spinner $SCAN_PID "Running ${FRAMEWORK_UPPER} scan..."
    wait $SCAN_PID
    SCAN_EXIT_CODE=$?

    if [ $SCAN_EXIT_CODE -ne 0 ]; then
        echo "[ERROR] Kubescape scan failed for framework '${FRAMEWORK_UPPER}'. Exit code: ${SCAN_EXIT_CODE}."
        echo "        Check the CLI log file for details: ${LOCAL_LOG_PATH}"
        SCAN_UPLOAD_FAILED=true
        # Attempt to upload the log file even if scan failed
        if [ -f "${LOCAL_LOG_PATH}" ]; then
            echo "        Attempting to upload the failure log..."
            (aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}") &
            spinner $! "Uploading failure log for ${FRAMEWORK_UPPER}"
            wait $!
             [ $? -eq 0 ] && echo "[OK] Failure log uploaded." || echo "[WARN] Failed to upload failure log."
        fi
        continue # Skip report upload and proceed to the next framework
    else
         echo "[OK] Scan completed for framework '${FRAMEWORK_UPPER}'."
         echo "      Report generated: ${LOCAL_REPORT_PATH}"
         echo "      CLI log generated: ${LOCAL_LOG_PATH}"
    fi

    # Upload Report File
    if [ -f "${LOCAL_REPORT_PATH}" ]; then
        (aws s3 cp "${LOCAL_REPORT_PATH}" "${S3_REPORT_PATH}" --region "${REGION}") &
        spinner $! "Uploading ${FRAMEWORK_UPPER} report..."
        wait $!
        if [ $? -eq 0 ]; then
             echo "[OK] Report uploaded for ${FRAMEWORK_UPPER}."
        else
             echo "[ERROR] Failed to upload report for ${FRAMEWORK_UPPER}. Check S3 permissions or network."
             SCAN_UPLOAD_FAILED=true
        fi
    else
         echo "[WARN] Report file ${LOCAL_REPORT_PATH} not found after successful scan? Skipping upload."
         SCAN_UPLOAD_FAILED=true
    fi

    # Upload Log File (even on success, for auditing)
    if [ -f "${LOCAL_LOG_PATH}" ]; then
         (aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}") &
         spinner $! "Uploading ${FRAMEWORK_UPPER} CLI log..."
         wait $!
        if [ $? -eq 0 ]; then
             echo "[OK] CLI log uploaded for ${FRAMEWORK_UPPER}."
        else
             echo "[WARN] Failed to upload CLI log for ${FRAMEWORK_UPPER}. Check S3 permissions or network."
             # Don't mark as overall failure just for log upload failing if scan/report worked
        fi
    else
        echo "[WARN] CLI log file ${LOCAL_LOG_PATH} not found? Skipping log upload."
    fi

done

# --- 8. Final Summary ---
echo "----------------------------------------"
echo "--- Scan and Upload Summary ---"
if $SCAN_UPLOAD_FAILED; then
    echo "[WARN] One or more scans or critical uploads failed."
    echo "        Please review the output above and check the local logs in: ${LOCAL_TIMESTAMP_DIR}"
    echo "        Also check the S3 bucket path: s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/"
    # Consider exiting with non-zero status
    echo "Exiting with status 1 (failure)."
    exit 1
else
    echo "[SUCCESS] All Kubescape scans completed and reports uploaded successfully!"
    echo " Local reports and logs are available in: ${LOCAL_TIMESTAMP_DIR}"
    echo " Reports and logs were uploaded to S3 path: s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}/"
    echo "Exiting with status 0 (success)."
    exit 0
fi
