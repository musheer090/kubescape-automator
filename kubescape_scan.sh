#!/bin/bash

# Kubescape Scan Script - Enhanced Version (with Color & Symbols)
# Author: Musheer (Research Intern @ CloudThat) - Based on previous version
# Date: 2025-04-22
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
INSTALL_LOG="${HOME}/kubescape_install.log"     # Kubescape installation log location

# --- Colors and Symbols ---
# Usage: echo -e "${GREEN}Success!${NC}"
#        echo -e "${RED}Error!${NC}"
#        echo -e "${YELLOW}Warning!${NC}"
#        echo -e "${BLUE}Info...${NC}"
#        echo -e "${CYAN}Prompt:${NC}"
#        echo -e "${BOLD}Bold Text${NC}"

NC='\033[0m' # No Color
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m' # Added for section headers

# Symbols
CHECK_MARK="${GREEN}✓${NC}"
CROSS_MARK="${RED}✗${NC}"
INFO_ICON="${BLUE}ℹ${NC}"
WARN_ICON="${YELLOW}⚠${NC}"
ARROW="${CYAN}➜${NC}"

# --- Helper Functions ---
spinner() {
    local pid=$1 msg=$2 spin='|/-\\' i=0
    # Hide cursor
    tput civis
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        # Use -e to interpret backslash escapes like \r
        echo -ne "\r${CYAN}[${spin:$i:1}]${NC} ${msg}..."
        sleep 0.1
    done
    # Show cursor
    tput cnorm
    # Clear the spinner line completely
    echo -ne "\r"
    tput el # Clears from cursor to end of line
}

check_tool() {
    local TOOL_NAME=$1
    echo -n -e "${BLUE}Checking for ${BOLD}${TOOL_NAME}${NC}... "
    if ! command -v ${TOOL_NAME} >/dev/null 2>&1; then
        echo -e "${CROSS_MARK} ${YELLOW}Missing${NC}"
        if [[ "$TOOL_NAME" == "jq" ]]; then
            echo -e "   ${WARN_ICON} ${YELLOW}Recommendation:${NC} Please install jq for potential advanced processing (e.g., 'sudo apt-get update && sudo apt-get install -y jq' or 'sudo yum install -y jq')."
            # jq is often optional, so don't return 1 unless critical elsewhere
            return 0
        elif [[ "$TOOL_NAME" == "aws" ]]; then
            echo -e "   ${CROSS_MARK} ${RED}Error:${NC} AWS CLI v2 is required. Please install it."
            return 1
        elif [[ "$TOOL_NAME" == "kubectl" ]]; then
            echo -e "   ${CROSS_MARK} ${RED}Error:${NC} kubectl is required. Please install it."
            return 1
        elif [[ "$TOOL_NAME" == "git" ]]; then
            echo -e "   ${WARN_ICON} ${YELLOW}Attempting to install git...${NC}"
            # Try common package managers
            (sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y git >/dev/null 2>&1) || \
            (sudo yum install -y git >/dev/null 2>&1) || \
            (sudo dnf install -y git >/dev/null 2>&1) # Add dnf for Fedora/RHEL 8+
            if command -v git >/dev/null 2>&1; then
                 echo -e "   ${CHECK_MARK} ${GREEN}Git installed successfully.${NC}"
                 return 0
            else
                 echo -e "   ${CROSS_MARK} ${RED}Error:${NC} Failed to automatically install git. Please install it manually."
                 return 1
            fi
        # For other tools, just report missing and fail if they are not Kubescape
        elif [[ "$TOOL_NAME" != "kubescape" ]]; then
            echo -e "   ${CROSS_MARK} ${RED}Error:${NC} ${TOOL_NAME} is required. Please install it."
            return 1
        fi
        # If it got here, it was a non-critical tool or Kubescape (handled separately)
        return 0
    else
        echo -e "${CHECK_MARK} ${GREEN}OK${NC} ($(command -v ${TOOL_NAME}))"
        return 0
    fi
}


install_kubescape() {
    echo -e "${INFO_ICON} ${BLUE}Attempting to install Kubescape...${NC} (Logs: ${INSTALL_LOG})"
    # Run installer in background to show spinner
    (curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash >"${INSTALL_LOG}" 2>&1) &
    spinner $! "Installing Kubescape"
    wait $!
    local install_exit_code=$?

    # Attempt to find Kubescape binary location dynamically
    KUBESCAPE_BIN_PATH=$(command -v kubescape)

    if [ $install_exit_code -ne 0 ] || [ -z "$KUBESCAPE_BIN_PATH" ]; then
        echo -e "${CROSS_MARK} ${RED}Error:${NC} Kubescape installation failed. Check the log: ${INSTALL_LOG}"
        # Attempt to show last few lines of log if it exists
        if [ -f "${INSTALL_LOG}" ]; then
             echo -e "${YELLOW}--- Last 5 lines of log ---${NC}"
             tail -n 5 "${INSTALL_LOG}"
             echo -e "${YELLOW}---------------------------${NC}"
        fi
        return 1
    else
        echo -e "${CHECK_MARK} ${GREEN}OK:${NC} Kubescape installed successfully to ${BOLD}${KUBESCAPE_BIN_PATH}${NC}."
        echo -e "   ${INFO_ICON} ${BLUE}Log file:${NC} ${INSTALL_LOG}"
        # Check if the path is already in PATH
        if ! echo "$PATH" | grep -q "$(dirname "$KUBESCAPE_BIN_PATH")"; then
            echo -e "   ${WARN_ICON} ${YELLOW}Action required:${NC} Add Kubescape to your PATH. Add this line to your ~/.bashrc or ~/.zshrc:"
            echo -e "     ${BOLD}export PATH=\$PATH:$(dirname "$KUBESCAPE_BIN_PATH")${NC}"
            echo -e "   ${YELLOW}Then run 'source ~/.bashrc' or restart your shell.${NC}"
        else
             echo -e "   ${CHECK_MARK} ${GREEN}Kubescape directory is already in your PATH.${NC}"
        fi
        return 0
    fi
}

# --- Script Start ---
echo -e "${PURPLE}======================================${NC}"
echo -e "${PURPLE}=== ${BOLD}Enhanced Kubescape Scan Script${NC} ===${NC}"
echo -e "${PURPLE}======================================${NC}"
echo

# --- 1. Dependency Checks ---
echo -e "${BLUE}--- ${BOLD}Phase 1: Checking Prerequisites${NC} ---"
FAILED_PRECHECK=false
check_tool "aws"     || FAILED_PRECHECK=true
check_tool "kubectl" || FAILED_PRECHECK=true
check_tool "git"     || FAILED_PRECHECK=true
check_tool "jq"      # Recommend but non-fatal, check_tool returns 0

if $FAILED_PRECHECK; then
    echo -e "\n${CROSS_MARK} ${RED}Error:${NC} Critical prerequisites missing. Please install them and try again."
    exit 1
fi

# Specifically check for Kubescape and install if needed
echo -n -e "${BLUE}Checking for ${BOLD}kubescape${NC}... "
if ! command -v kubescape >/dev/null 2>&1; then
    echo -e "${WARN_ICON} ${YELLOW}Missing${NC}"
    install_kubescape || exit 1
else
    echo -e "${CHECK_MARK} ${GREEN}OK${NC} ($(command -v kubescape))"
fi

# Show Kubescape version
echo -n -e "${INFO_ICON} ${BLUE}Kubescape version:${NC} "
kubescape version || echo -e "${WARN_ICON} ${YELLOW}Could not determine Kubescape version.${NC}"
echo -e "${BLUE}--------------------------------------${NC}"
echo

# --- 2. User Input ---
echo -e "${CYAN}--- ${BOLD}Phase 2: Gathering Information${NC} ---"
# AWS Region
while true; do
    read -p "$(echo -e ${ARROW} ${CYAN}Enter AWS Region (e.g., ap-south-1):${NC} )" REGION
    # Slightly more robust regex allowing for gov, cn etc. partitions
    if [[ "$REGION" =~ ^[a-z]{2}(-gov)?(-iso)?(-isob)?(-cn)?-[a-z]+-[0-9]$ ]]; then
        echo -e "   ${CHECK_MARK} ${GREEN}Region format valid: ${REGION}${NC}"
        break
    else
        echo -e "   ${CROSS_MARK} ${YELLOW}Invalid format. Please use format like 'us-east-1', 'ap-southeast-2', etc.${NC}"
    fi
done

# S3 Bucket Name
read -p "$(echo -e ${ARROW} ${CYAN}Enter S3 bucket name [default: ${DEFAULT_S3_BUCKET_NAME}]:${NC} )" S3_BUCKET_NAME_INPUT
S3_BUCKET_NAME=${S3_BUCKET_NAME_INPUT:-$DEFAULT_S3_BUCKET_NAME}
echo -e "   ${INFO_ICON} ${BLUE}Using S3 bucket:${NC} ${BOLD}${S3_BUCKET_NAME}${NC}"

# Report Format
VALID_FORMATS_DISPLAY=$(echo "$VALID_FORMATS" | sed 's/ /, /g') # For display: html, json, pdf
while true; do
    read -p "$(echo -e ${ARROW} ${CYAN}Select Report format (${VALID_FORMATS_DISPLAY}):${NC} )" SELECTED_FORMAT
    SELECTED_FORMAT_LOWER=$(echo "$SELECTED_FORMAT" | tr '[:upper:]' '[:lower:]')
    # Check if the input (lowercase) is in the list of valid formats
    if [[ " ${VALID_FORMATS} " =~ " ${SELECTED_FORMAT_LOWER} " ]]; then
        OUTPUT_FORMAT=$SELECTED_FORMAT_LOWER
        OUTPUT_EXT=$SELECTED_FORMAT_LOWER
        echo -e "   ${CHECK_MARK} ${GREEN}Using report format:${NC} ${BOLD}${OUTPUT_FORMAT}${NC}"
        break
    else
        echo -e "   ${CROSS_MARK} ${YELLOW}Invalid choice. Please select one of: ${VALID_FORMATS_DISPLAY}${NC}"
    fi
done
echo -e "${CYAN}--------------------------------------${NC}"
echo

# --- 3. AWS Identity & Permissions Check ---
echo -e "${BLUE}--- ${BOLD}Phase 3: Verifying AWS Identity & Permissions${NC} ---"
echo -n -e "${INFO_ICON} ${BLUE}Checking AWS Caller Identity...${NC} "
AWS_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null) # Capture JSON output
if [ $? -ne 0 ]; then
    echo -e "${CROSS_MARK} ${RED}Error:${NC} Failed to get AWS caller identity. Is AWS CLI configured correctly? (check 'aws configure list')"
    exit 1
else
    # Use jq if available for nicer output, otherwise fallback
    if command -v jq >/dev/null 2>&1; then
        AWS_USER_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn')
        AWS_ACCOUNT=$(echo "$AWS_IDENTITY" | jq -r '.Account')
        echo -e "${CHECK_MARK} ${GREEN}OK${NC}"
        echo -e "   ${INFO_ICON} ${BLUE}Account:${NC} ${BOLD}${AWS_ACCOUNT}${NC}"
        echo -e "   ${INFO_ICON} ${BLUE}Identity ARN:${NC} ${BOLD}${AWS_USER_ARN}${NC}"
    else
        # Fallback using text output if jq is not installed
        AWS_IDENTITY_TEXT=$(aws sts get-caller-identity --output text)
        echo -e "${CHECK_MARK} ${GREEN}OK${NC}"
        echo -e "   ${INFO_ICON} ${BLUE}Identity Info:${NC}\n${AWS_IDENTITY_TEXT}"
        echo -e "   ${WARN_ICON} ${YELLOW}(Install 'jq' for formatted identity output)${NC}"
    fi
    echo -e "   ${WARN_ICON} ${YELLOW}Ensure this identity has ${BOLD}s3:PutObject${NC} permission on:"
    echo -e "     ${BOLD}s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/*${NC}"
fi
echo -e "${BLUE}---------------------------------------------${NC}"
echo


# --- 4. S3 Bucket Check & Creation ---
echo -e "${BLUE}--- ${BOLD}Phase 4: Checking S3 Bucket Status${NC} ---"
echo -n -e "${INFO_ICON} ${BLUE}Checking if bucket ${BOLD}${S3_BUCKET_NAME}${NC} exists in region ${BOLD}${REGION}${NC}... "
# Use head-bucket which is faster and requires fewer permissions than list-bucket
aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${WARN_ICON} ${YELLOW}Bucket not found or access denied.${NC}"
    while true; do
        read -p "$(echo -e ${ARROW} ${CYAN}Attempt to create bucket '${S3_BUCKET_NAME}' in ${REGION}? (y/n):${NC} )" yn
        yn=${yn,,} # Convert to lowercase
        if [[ "$yn" == "y" ]]; then
            echo -n -e "   ${INFO_ICON} ${BLUE}Creating bucket ${BOLD}${S3_BUCKET_NAME}${NC}... "
            # Handle us-east-1 region explicitly as it doesn't need LocationConstraint
            if [[ "$REGION" == "us-east-1" ]]; then
                aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" >/dev/null &
                spinner $! "Creating bucket"
                wait $!
                create_exit_code=$?
            else
                aws s3api create-bucket --bucket "${S3_BUCKET_NAME}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null &
                spinner $! "Creating bucket"
                wait $!
                create_exit_code=$?
            fi

            if [ $create_exit_code -eq 0 ]; then
                 echo -e "${CHECK_MARK} ${GREEN}Bucket created successfully.${NC}"
                 break # Exit the prompt loop
            else
                 echo -e "${CROSS_MARK} ${RED}Error:${NC} Bucket creation failed. Check AWS permissions or bucket naming rules."
                 exit 1
            fi
        elif [[ "$yn" == "n" ]]; then
            echo -e "${INFO_ICON} ${BLUE}Exiting script as requested.${NC}"
            exit 1
        else
             echo -e "   ${YELLOW}Invalid input. Please enter 'y' or 'n'.${NC}"
        fi
    done
else
    echo -e "${CHECK_MARK} ${GREEN}Bucket exists and is accessible.${NC}"
fi
echo -e "${BLUE}--------------------------------------${NC}"
echo

# --- 5. Prepare Directories & Initial Upload ---
echo -e "${BLUE}--- ${BOLD}Phase 5: Preparing Local Storage & Uploading Logs${NC} ---"
CURRENT_DATE=$(date +'%Y%m%d')
CURRENT_TIME=$(date +'%H%M%S')
TIMESTAMP_FOLDER="${CURRENT_DATE}/${CURRENT_TIME}" # Path segment like 20250422/163045
LOCAL_TEMP_REPORT_DIR="${HOME}/kubescape_reports/${TIMESTAMP_FOLDER}"
S3_TARGET_FOLDER_URI="s3://${S3_BUCKET_NAME}/${S3_BASE_FOLDER}/${TIMESTAMP_FOLDER}" # Full S3 path

echo -e "${INFO_ICON} ${BLUE}Creating local directory:${NC} ${LOCAL_TEMP_REPORT_DIR}"
mkdir -p "${LOCAL_TEMP_REPORT_DIR}"
if [ $? -ne 0 ]; then
    echo -e "${CROSS_MARK} ${RED}Error:${NC} Failed to create local directory ${LOCAL_TEMP_REPORT_DIR}"
    exit 1
fi
echo -e "${CHECK_MARK} ${GREEN}Local directory created.${NC}"

# Upload Kubescape install log to S3 if it exists
if [ -f "${INSTALL_LOG}" ]; then
    echo -n -e "${INFO_ICON} ${BLUE}Uploading Kubescape install log (${INSTALL_LOG}) to ${S3_TARGET_FOLDER_URI}/ ...${NC}"
    aws s3 cp "${INSTALL_LOG}" "${S3_TARGET_FOLDER_URI}/kubescape_install.log" --region "${REGION}" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "\r${INFO_ICON} ${BLUE}Uploading Kubescape install log (${INSTALL_LOG}) to ${S3_TARGET_FOLDER_URI}/ ... ${CHECK_MARK} ${GREEN}OK${NC}"
    else
        echo -e "\r${INFO_ICON} ${BLUE}Uploading Kubescape install log (${INSTALL_LOG}) to ${S3_TARGET_FOLDER_URI}/ ... ${WARN_ICON} ${YELLOW}Failed${NC}"
        # Non-fatal warning
    fi
else
    echo -e "${INFO_ICON} ${BLUE}Kubescape install log not found (expected at ${INSTALL_LOG}), skipping upload.${NC}"
fi
echo -e "${BLUE}-------------------------------------------------------${NC}"
echo


# --- 6. Run Scans & Upload ---
echo -e "${PURPLE}--- ${BOLD}Phase 6: Running Kubescape Scans${NC} ---"
echo -e "${INFO_ICON} ${BLUE}Local reports will be saved in:${NC} ${LOCAL_TEMP_REPORT_DIR}"
echo -e "${INFO_ICON} ${BLUE}Reports will be uploaded to:${NC} ${S3_TARGET_FOLDER_URI}/"
echo -e "${INFO_ICON} ${BLUE}Terminal output will be kept clean during scans. See individual log files for details.${NC}"
echo

SCAN_UPLOAD_FAILED=false # Flag to track if any step fails
OVERALL_SUCCESS=true

for FRAMEWORK in $FRAMEWORKS_TO_SCAN; do
    echo -e "${PURPLE}---------------- Scan: ${BOLD}${FRAMEWORK^^}${NC} ----------------"
    SCAN_MSG="Running ${FRAMEWORK^^} scan (format: ${OUTPUT_FORMAT^^})"
    REPORT_FILENAME="${FRAMEWORK^^}_Report_${CURRENT_DATE}_${CURRENT_TIME}.${OUTPUT_EXT}"
    LOCAL_REPORT_PATH="${LOCAL_TEMP_REPORT_DIR}/${REPORT_FILENAME}"
    S3_REPORT_PATH="${S3_TARGET_FOLDER_URI}/${REPORT_FILENAME}"
    LOG_FILENAME="${FRAMEWORK}_cli_scan_logs.log"
    LOCAL_LOG_PATH="${LOCAL_TEMP_REPORT_DIR}/${LOG_FILENAME}"
    S3_LOG_PATH="${S3_TARGET_FOLDER_URI}/${LOG_FILENAME}"

    echo -e "  ${ARROW} ${CYAN}Framework:${NC} ${BOLD}${FRAMEWORK}${NC}"
    echo -e "  ${ARROW} ${CYAN}Output Format:${NC} ${BOLD}${OUTPUT_FORMAT}${NC}"
    echo -e "  ${ARROW} ${CYAN}Local Report:${NC} ${LOCAL_REPORT_PATH}"
    echo -e "  ${ARROW} ${CYAN}Local Log:${NC} ${LOCAL_LOG_PATH}"
    echo -e "  ${ARROW} ${CYAN}S3 Target Report:${NC} ${S3_REPORT_PATH}"
    echo -e "  ${ARROW} ${CYAN}S3 Target Log:${NC} ${S3_LOG_PATH}"

    # Run Kubescape scan in the background, redirecting stdout and stderr to log file
    kubescape scan framework "${FRAMEWORK}" --format "${OUTPUT_FORMAT}" --output "${LOCAL_REPORT_PATH}" --verbose >"${LOCAL_LOG_PATH}" 2>&1 &
    spinner $! "${SCAN_MSG}"
    wait $! # Wait for the background scan job to finish
    scan_exit_code=$?

    if [ $scan_exit_code -ne 0 ]; then
        echo -e "  ${CROSS_MARK} ${RED}Error:${NC} Kubescape scan failed for framework '${FRAMEWORK}'. Check log: ${LOCAL_LOG_PATH}"
        SCAN_UPLOAD_FAILED=true
        OVERALL_SUCCESS=false
        # Optionally upload the failed log file anyway
        echo -n -e "  ${INFO_ICON} ${BLUE}Attempting to upload failure log ${LOG_FILENAME} to S3...${NC}"
        aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}" >/dev/null 2>&1
        if [ $? -eq 0 ]; then echo -e "\r  ${INFO_ICON} ${BLUE}Attempting to upload failure log ${LOG_FILENAME} to S3... ${CHECK_MARK} ${GREEN}OK${NC}"; else echo -e "\r  ${INFO_ICON} ${BLUE}Attempting to upload failure log ${LOG_FILENAME} to S3... ${WARN_ICON} ${YELLOW}Failed${NC}"; fi
        continue # Skip to the next framework
    else
        echo -e "  ${CHECK_MARK} ${GREEN}Scan completed successfully for ${FRAMEWORK}.${NC}"
    fi

    # Upload the generated report
    echo -n -e "  ${INFO_ICON} ${BLUE}Uploading report ${REPORT_FILENAME} to S3...${NC}"
    aws s3 cp "${LOCAL_REPORT_PATH}" "${S3_REPORT_PATH}" --region "${REGION}" >/dev/null 2>&1 &
    spinner $! "Uploading report ${REPORT_FILENAME}"
    wait $!
    upload_report_exit_code=$?

    if [ $upload_report_exit_code -eq 0 ]; then
        echo -e "  ${CHECK_MARK} ${GREEN}Report upload successful.${NC}"
    else
        echo -e "  ${CROSS_MARK} ${RED}Error:${NC} Failed to upload report ${REPORT_FILENAME} to ${S3_REPORT_PATH}"
        SCAN_UPLOAD_FAILED=true
        OVERALL_SUCCESS=false
    fi

    # Upload the scan log file
    echo -n -e "  ${INFO_ICON} ${BLUE}Uploading log ${LOG_FILENAME} to S3...${NC}"
    aws s3 cp "${LOCAL_LOG_PATH}" "${S3_LOG_PATH}" --region "${REGION}" >/dev/null 2>&1 &
    spinner $! "Uploading log ${LOG_FILENAME}"
    wait $!
    upload_log_exit_code=$?

    if [ $upload_log_exit_code -eq 0 ]; then
        echo -e "  ${CHECK_MARK} ${GREEN}Scan log upload successful.${NC}"
    else
        echo -e "  ${WARN_ICON} ${YELLOW}Warning:${NC} Failed to upload scan log ${LOG_FILENAME} to ${S3_LOG_PATH}"
        # Consider this a warning, not necessarily a full failure
        SCAN_UPLOAD_FAILED=true # Mark as failed for summary, but don't set OVERALL_SUCCESS=false unless desired
    fi
    echo -e "${PURPLE}--------------------------------------------------${NC}"
done

# --- 7. Final Summary ---
echo
echo -e "${PURPLE}=========================================${NC}"
echo -e "${PURPLE}===           ${BOLD}Scan Summary${NC}           ===${NC}"
echo -e "${PURPLE}=========================================${NC}"

if ! $OVERALL_SUCCESS; then
    echo -e "${WARN_ICON} ${YELLOW}Warning:${NC} One or more steps encountered errors."
    echo -e "   ${INFO_ICON} ${BLUE}Please review the output above and check log files in:${NC}"
    echo -e "     ${LOCAL_TEMP_REPORT_DIR}"
    echo -e "   ${INFO_ICON} ${BLUE}Uploaded content (may be incomplete) is under:${NC}"
    echo -e "     ${S3_TARGET_FOLDER_URI}/"
    echo -e "${PURPLE}=========================================${NC}"
    # No need for 'cd ~', exit directly
    exit 1
else
    echo -e "${CHECK_MARK} ${GREEN}Success:${NC} All Kubescape scans completed and reports uploaded successfully!"
    echo -e "   ${INFO_ICON} ${BLUE}Local reports and logs are available in:${NC}"
    echo -e "     ${BOLD}${LOCAL_TEMP_REPORT_DIR}${NC}"
    echo -e "   ${INFO_ICON} ${BLUE}Reports and logs have been uploaded to:${NC}"
    echo -e "     ${BOLD}${S3_TARGET_FOLDER_URI}/${NC}"
    echo -e "${PURPLE}=========================================${NC}"
    # No need for 'cd ~', exit directly
    exit 0
fi
