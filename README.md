## Kubescape Scan & Report Automation Script

### 1. Overview

This script provides a powerful, dual-mode solution for executing Kubescape security scans. It can be run as an **interactive wizard** for guided, on-demand scans, or as a **fully-automated, non-interactive script** suitable for CI/CD pipelines and scheduled `cron` jobs.

The script manages the entire workflow: dependency checking, automatic `kubescape` installation, multi-framework scanning (NSA, MITRE), and the archival of reports and logs to both a local directory and an AWS S3 bucket.

### 2. Features

* **Dual Execution Modes**: Supports both an interactive wizard for manual runs and a fully-parameterized mode for automation.
* **Command-Line Interface**: The non-interactive mode is controlled via standard command-line flags for easy integration.
* **Automatic Dependency Management**: Checks for required tools and installs `kubescape` if it is not found.
* **Multi-Framework Scanning**: Runs scans against key security frameworks, including **NSA** and **MITRE**.
* **Flexible Report Formatting**: Allows selection of the report format (`html`, `json`, `pdf`).
* **Automated S3 Bucket Handling**: Can be authorized via a flag to create the target S3 bucket if it doesn't exist, preventing failures in automated runs.
* **Structured Archival**: Saves all artifacts to timestamped directories locally (`~/kubescape_reports/`) and in S3 for clear, auditable records.
* **IAM Permission Awareness**: Displays the AWS identity being used for the operations, promoting security awareness.

### 3. Prerequisites

The following command-line tools must be installed and configured:

* **AWS CLI**: Configured with credentials for a valid IAM principal.
* **kubectl**: Configured with access to the target Kubernetes cluster.
* **git**: Required for cloning the repository.
* **jq**: Recommended.

### 4. Usage

The script operates in one of two modes based on whether command-line flags are provided.

#### 4.1. Interactive Mode (for Manual Scans)

Run the script without any arguments to launch the interactive wizard. It will prompt you for the AWS Region, S3 bucket, and report format.

```bash
# Clone the repository and run interactively
git clone https://github.com/musheer090/kubescape-automator.git
cd kubescape-automator
chmod +x kubescape_scan_automated.sh
./kubescape_scan_automated.sh
```

#### 4.2. Non-Interactive Mode (for Automation & Cron Jobs)

Provide command-line flags to run the script without user prompts. This is the required mode for any automated environment.

**Command-Line Arguments:**

| Flag | Argument | Description | Required |
| :--- | :--- | :--- | :--- |
| `-r` | `REGION` | The AWS Region for the S3 bucket (e.g., `us-east-1`). | **Yes** |
| `-b` | `BUCKET` | The S3 bucket name. Defaults to `kubeguard-reports`. | No |
| `-f` | `FORMAT` | The report output format (`html`, `json`, `pdf`). Defaults to `json`. | No |
| `-c` | | Flag to authorize the creation of the S3 bucket if it does not exist. | No |
| `-h` | | Displays the help message. | No |

**One-Liner Execution Example:**

This command clones the repository, makes the script executable, and runs it in **non-interactive mode**, specifying all required parameters.

```bash
git clone https://github.com/musheer090/kubescape-automator.git /tmp/kubescape_automator && \
cd /tmp/kubescape_automator && \
chmod +x kubescape_scan_automated.sh && \
./kubescape_scan_automated.sh -r ap-south-1 -b kubeguard-reports -f html -c && \
cd .. && \
rm -rf /tmp/kubescape_automator
```

### 5. Scheduling with Cron

To run a daily scan at 3 AM, edit your crontab (`crontab -e`) and add the following line, ensuring you use absolute paths and provide the necessary flags.

```bash
# Run Kubescape scan every day at 3:00 AM
0 3 * * * /path/to/your/scripts/kubescape_scan_automated.sh -r us-east-1 -b my-automated-scans -f json -c >> /var/log/kubescape_cron.log 2>&1
```

### 6. IAM Permissions

The IAM principal executing the script requires the following minimum permissions.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSTSActions",
            "Effect": "Allow",
            "Action": "sts:GetCallerIdentity",
            "Resource": "*"
        },
        {
            "Sid": "AllowS3BucketInteractions",
            "Effect": "Allow",
            "Action": [
                "s3:HeadBucket",
                "s3:CreateBucket"
            ],
            "Resource": "arn:aws:s3:::<YOUR_BUCKET_NAME>"
        },
        {
            "Sid": "AllowReportUpload",
            "Effect": "Allow",
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::<YOUR_BUCKET_NAME>/kubescape-reports/*"
        }
    ]
}
```
***Note: Replace `<YOUR_BUCKET_NAME>` with your actual bucket name.***
