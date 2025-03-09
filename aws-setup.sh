#!/bin/bash
set -euo pipefail

# Check for required dependencies.
command -v aws >/dev/null || { echo "Error: AWS CLI is not installed."; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is not installed."; exit 1; }

# Default values.
STACK_NAME="FindingsCloudVRM"
REGION="us-east-1"
TEMPLATE_FILE="/tmp/cloudvrm-iam-securityhub.yaml"

# Flags for command line parameters.
UNINSTALL=false
PARAMS_PROVIDED=false

function usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --stack-name STACK_NAME    Specify the CloudFormation stack name (default: FindingsCloudVRM)"
    echo "  --region REGION            Specify the AWS region (default: us-east-1)"
    echo "  --uninstall                Uninstall the specified stack"
    echo "  --help, -h                 Show this help message"
}

# Parse command line arguments.
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --stack-name)
            if [[ $# -lt 2 ]]; then
                echo "Error: --stack-name requires an argument."
                usage
                exit 1
            fi
            STACK_NAME="$2"
            PARAMS_PROVIDED=true
            shift 2
            ;;
        --region)
            if [[ $# -lt 2 ]]; then
                echo "Error: --region requires an argument."
                usage
                exit 1
            fi
            REGION="$2"
            PARAMS_PROVIDED=true
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            PARAMS_PROVIDED=true
            shift 1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown parameter: $1"
            usage
            exit 1
            ;;
    esac
done

function create_template_file() {
    cat <<EOT > "$TEMPLATE_FILE"
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  CloudFormation template that creates:
  1. An IAM User,
  2. An IAM Role (trusted only by this user),
  3. Attaches AWSSecurityHubReadOnlyAccess to the role,
  4. An inline policy on the user to allow sts:AssumeRole only for the role,
  5. An IAM Access Key for the user,
  6. Outputs the user’s Access Key, Role ARN, Region, and Account ID.

Parameters:
  IAMUserName:
    Type: String
    Description: "Name of the IAM User to create."
    Default: "${STACK_NAME}_User"

  IAMRoleName:
    Type: String
    Description: "Name of the IAM Role to create."
    Default: "${STACK_NAME}_Role"

Resources:
  CFNUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Ref IAMUserName

  CFNRole:
    Type: AWS::IAM::Role
    DependsOn: CFNUser
    Properties:
      RoleName: !Ref IAMRoleName
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              AWS: !GetAtt CFNUser.Arn
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AWSSecurityHubReadOnlyAccess

  CFNUserInlinePolicy:
    Type: AWS::IAM::Policy
    Properties:
      PolicyName: "${STACK_NAME}_Inline"
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Action: "sts:AssumeRole"
            Resource: !GetAtt CFNRole.Arn
      Users:
        - !Ref IAMUserName

  CFNUserAccessKey:
    Type: AWS::IAM::AccessKey
    Properties:
      UserName: !Ref CFNUser

Outputs:
  AccountID:
    Description: "Account ID"
    Value: !Ref "AWS::AccountId"

  Region:
    Description: "Region"
    Value: !Ref "AWS::Region"

  RoleARN:
    Description: "Role ARN"
    Value: !GetAtt CFNRole.Arn

  AccessKey:
    Description: "Access Key"
    Value: !Ref CFNUserAccessKey

  SecretKey:
    Description: "Secret Key"
    Value: !GetAtt CFNUserAccessKey.SecretAccessKey
EOT
}

function check_stack_exists() {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1
    return $?  # 0 if exists, non-zero if not
}

function monitor_installation() {
    echo "Waiting for stack creation to complete..."
    aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "Fetching stack outputs..."
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].Outputs" --output json | \
      jq -r '.[] | select(.OutputKey == "SecretKey" or .OutputKey == "AccountID" or .OutputKey == "Region" or .OutputKey == "AccessKey" or .OutputKey == "RoleARN") | "\u001b[32m" + .Description + ": \u001b[0m" + .OutputValue'
}

function monitor_uninstallation() {
    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "Stack deletion completed."
}

function install_stack() {
    create_template_file
    echo "Installing CloudFormation stack '$STACK_NAME' in region '$REGION'..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
    monitor_installation
}

function uninstall_stack() {
    echo "Uninstalling CloudFormation stack '$STACK_NAME' from region '$REGION'..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    monitor_uninstallation
}

# Main logic:
# If no parameters were provided and the default stack exists in the default region, print available commands.
if [[ "$PARAMS_PROVIDED" == false ]]; then
    if check_stack_exists; then
        echo "Default stack '$STACK_NAME' exists in region '$REGION'."
        usage
        exit 0
    fi
fi

if [[ "$UNINSTALL" == true ]]; then
    if check_stack_exists; then
        uninstall_stack
    else
        echo "Stack '$STACK_NAME' not found in region '$REGION'. Nothing to uninstall."
    fi
    exit 0
fi

if check_stack_exists; then
    echo "CloudFormation stack '$STACK_NAME' already exists in region '$REGION'. Uninstall it first."
    exit 0
fi

install_stack
