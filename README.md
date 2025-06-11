## Interactive Kubescape Scan & Report Script

### 1. Overview

This is an advanced, interactive shell script designed to streamline the process of running Kubescape security scans against a Kubernetes cluster. It guides the user through a series of prompts to configure the scan, automatically handles dependencies, executes scans against multiple security frameworks, and archives the resulting reports and logs to both a local directory and a specified AWS S3 bucket.

This tool is ideal for on-demand security assessments where user input is desired to control parameters like output format and storage location.

### 2. Features

* **Interactive Setup Wizard**: Guides the user through configuration for AWS Region, S3 bucket, and report format, ensuring correct parameters for each run.
* **Automatic Dependency Management**: Checks for required tools and features an installer that automatically downloads and configures `kubescape` if it is not found in the system's PATH.
* **Multi-Framework Scanning**: Pre-configured to run scans against key security frameworks, including **NSA** and **MITRE**.
* **Flexible Report Formatting**: Allows the user to select the output format for reports from a list of supported types (e.g., `html`, `json`, `pdf`).
* **Dynamic S3 Bucket Handling**: Checks for the existence of the target S3 bucket and offers to create it on the user's behalf if it is missing.
* **IAM Permission Awareness**: Displays the AWS identity (ARN) being used for the operations, promoting awareness of the security context, and lists the required permissions.
* **Structured Archival**: Saves all artifacts (reports, CLI logs, installation logs) to neatly organized, timestamped directories both locally (`~/kubescape_reports/`) and in S3 for clear, auditable records.
* **Robust Logging and Error Handling**: Captures detailed CLI output for each scan and provides a clear final summary indicating the success or failure of the operation.

### 3. Prerequisites

The script requires the following command-line tools to be installed and configured on the machine where it is run:

* **AWS CLI**: Must be installed (v2 recommended) and configured with credentials for a valid IAM principal.
* **kubectl**: Must be installed and configured with access to the target Kubernetes cluster.
* **git**: Required for cloning the source repository.
* **jq**: Recommended for certain script functions. The script will provide installation guidance if `jq` is missing but will not halt execution.

The script will automatically attempt to install **Kubescape** if it is not already present.

### 4. Usage

#### 4.1. Quick Start Execution

For a single-use or trial run, the following command will clone the repository to a temporary directory, set permissions, execute the interactive script, and clean up the local repository upon completion.

```bash
git clone https://github.com/musheer090/kubescape-automator.git /tmp/kubescape_automator && \
cd /tmp/kubescape_automator && \
chmod +x kubescape_scan.sh && \
./kubescape_scan.sh && \
cd .. && \
rm -rf /tmp/kubescape_automator
```

#### 4.2. The Interactive Session

Upon execution, the script will prompt you for the following information:
1.  **AWS Region**: The region where your S3 bucket is or should be located (e.g., `us-east-1`).
2.  **S3 Bucket Name**: The name of the bucket for storing reports. A default value is provided.
3.  **Report Format**: Your choice of output format (`html`, `json`, or `pdf`).
4.  **S3 Bucket Creation**: If the specified bucket does not exist, you will be asked for confirmation to create it.

### 5. IAM Permissions

The IAM principal (User or Role) executing this script requires the following minimum permissions on AWS.

| Permission | Purpose |
| :--- | :--- |
| `sts:GetCallerIdentity` | To verify and display the AWS identity being used by the script. |
| `s3:HeadBucket` | To check if the target S3 bucket exists. |
| `s3:CreateBucket` | (Optional) To create the S3 bucket if it doesn't exist and the user consents. |
| `s3:PutObject` | To upload the reports and log files to the S3 bucket. |

**Sample IAM Policy:**

*Note: Replace `<BUCKET_NAME>` with the name of the S3 bucket you intend to use.*

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
            "Resource": "arn:aws:s3:::<BUCKET_NAME>"
        },
        {
            "Sid": "AllowReportUpload",
            "Effect": "Allow",
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::<BUCKET_NAME>/kubescape-reports/*"
        }
    ]
}
```

### 6. Output Artifacts

The script generates and archives several files for each run.

* **Local Storage**: All artifacts are stored locally in `~/kubescape_reports/YYYY-MM-DD/HHMMSS/`.
* **S3 Storage**: All artifacts are uploaded to `s3://<BUCKET_NAME>/kubescape-reports/YYYY-MM-DD/HHMMSS/`.

The following files are generated for each scanned framework (e.g., NSA):
* `NSA_Report_[...].<format>`: The main security report in the format you selected.
* `NSA_Scan_CLI_[...].log`: The complete stdout/stderr from the Kubescape command for debugging and auditing.
* `kubescape_install.log`: (If applicable) The log from the Kubescape installation process.

### 7. Note on Automation

Due to its interactive nature, this script is not suitable for use in non-interactive, automated environments like a standard `cron` job. To adapt this script for full automation, the interactive `read` prompts would need to be replaced with a mechanism for parsing command-line arguments (e.g., using `getopts`).
