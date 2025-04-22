#!/bin/bash

# Kubescape Scan Script - Enhanced Version
# -------------------------------------------------------------------
# Makes Kubescape scans look slick with colors and banners.

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

banner() {
  echo -e "${CYAN}╔═════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}   ${GREEN}Kubesec   C L I   S C A N S${NC}   ${CYAN}║${NC}"
  echo -e "${CYAN}╚═════════════════════════════════════════╝${NC}\n"
}

spinner() {
    local pid=$1 msg=$2 spin='|/-\\' i=0
    tput civis
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        echo -ne "\r${YELLOW}[${spin:$i:1}]${NC} ${msg}"
        sleep 0.1
    done
    tput cnorm
    echo -ne "\r \r"
}

header() {
  echo -e "\n${BLUE}--- $1 ---${NC}\n"
}

status() {
  local code=$1 msg=$2
  if [ $code -eq 0 ]; then
    echo -e "${GREEN}[OK]${NC} ${msg}"
  else
    echo -e "${RED}[ERROR]${NC} ${msg}"
  fi
}

# --- Configuration ---
DEFAULT_S3_BUCKET_NAME="kubeguard-reports"
S3_BASE_FOLDER="kubescape-reports"
FRAMEWORKS_TO_SCAN="nsa mitre"
VALID_FORMATS="html json pdf"

# --- Functions ---
check_tool() {
    echo -ne "Checking for $1... "
    if ! command -v $1 &>/dev/null; then
        echo -e "${RED}[MISSING]${NC}"
        return 1
    else
        echo -e "${GREEN}[OK]${NC}"
        return 0
    fi
}

install_kubescape() {
    local logfile="$HOME/kubescape_install.log"
    echo -e "${MAGENTA}Installing Kubescape... logs -> ${logfile}${NC}"
    (curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | bash >"$logfile" 2>&1) &
    spinner $! "${MAGENTA}Kubescape install in progress...${NC}"
    wait $!
    export PATH=$PATH:/home/cloudshell-user/.kubescape/bin
    if ! command -v kubescape &>/dev/null; then
        echo -e "${RED}[ERROR] Installation failed. Check ${logfile}${NC}"
        return 1
    else
        echo -e "${GREEN}[OK] Kubescape installed!${NC}"
        return 0
    fi
}

# --- MAIN ---
clear
banner

# 1) Dependency Checks
header "Checking Prerequisites"
for tool in aws kubectl git jq; do
  check_tool $tool || { echo "${RED}Please install $tool before proceeding.${NC}"; exit 1; }
done
if ! command -v kubescape &>/dev/null; then
  install_kubescape || exit 1
else
  status 0 "Kubescape found: $(command -v kubescape)"
fi
kubescape version | sed "s/^/${CYAN}>> ${NC}/"

# 2) User Input
header "Gathering Information"
while true; do
  read -rp "${YELLOW}Region (e.g., ap-south-1): ${NC}" REGION
  [[ $REGION =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] && break || echo -e "${RED}Invalid region.${NC}"
done
read -rp "${YELLOW}S3 bucket [default: $DEFAULT_S3_BUCKET_NAME]: ${NC}" S3_IN
S3_BUCKET=${S3_IN:-$DEFAULT_S3_BUCKET_NAME}
while true; do
  read -rp "${YELLOW}Format (${VALID_FORMATS// /|}): ${NC}" fmt
  fmt=${fmt,,}
  [[ " ${VALID_FORMATS} " =~ " $fmt " ]] && { OUTPUT_EXT=$fmt; break; } || echo -e "${RED}Invalid.${NC}"
done

# 3) AWS Identity
header "AWS Identity"
aws sts get-caller-identity --output text | while read -r line; do echo -e "${CYAN}$line${NC}"; done

# 4) S3 Bucket
header "S3 Bucket Check"
if ! aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" &>/dev/null; then
  while true; do
    read -rp "${YELLOW}Create $S3_BUCKET in $REGION? (y/n): ${NC}" yn
    case $yn in
      [Yy]*) aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION" && break;;
      [Nn]*) echo "${RED}Exiting.${NC}"; exit 1;;
      *) echo "${RED}Choose y or n.${NC}";;
    esac
done
fi
status $? "S3 bucket ready"

# 5) Prepare dirs
header "Preparing Reports Dir"
NOW=$(date +"%Y%m%d/%H%M%S")
OUTDIR="$HOME/kubescape_reports/$NOW"
mkdir -p "$OUTDIR"
status $? "Created $OUTDIR"

# Upload install log
if [ -f "$HOME/kubescape_install.log" ]; then
  aws s3 cp "$HOME/kubescape_install.log" "s3://$S3_BUCKET/$S3_BASE_FOLDER/$NOW/install.log" --region "$REGION"
  status $? "Uploaded install.log"
fi

# 6) Run Scans
header "Running Scans"
for fw in $FRAMEWORKS_TO_SCAN; do
  echo -e "${BLUE}-- $fw Scan${NC}"
  outfile="$OUTDIR/${fw^^}_Report.${OUTPUT_EXT}"
  logfile="$OUTDIR/${fw}_cli.log"
  (kubescape scan framework $fw --format $OUTPUT_EXT --output "$outfile" --verbose >"$logfile" 2>&1) &
  spinner $! "${MAGENTA}$fw in progress...${NC}"
  wait $!
  status $? "$fw report -> $outfile"
  aws s3 cp "$outfile" "s3://$S3_BUCKET/$S3_BASE_FOLDER/$NOW/$(basename $outfile)" --region "$REGION"
  aws s3 cp "$logfile" "s3://$S3_BUCKET/$S3_BASE_FOLDER/$NOW/$(basename $logfile)" --region "$REGION"
  status $? "$fw files uploaded"
done

# 7) Final
header "All Done"
echo -e "${GREEN}Reports & logs in:$NC $OUTDIR"
cd ~
exit 0
