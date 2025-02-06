#!/bin/bash

# run the following command to execute this script
# wget -qO- https://raw.githubusercontent.com/Findings-co/aws-cloudvrm/refs/heads/main/aws-setup.sh | bash

STACK_NAME="FindingsCloudVRM"
TEMPLATE_FILE="/tmp/cloudvrm-iam-securityhub.yaml"
REGION="us-east-1"

function create_template_file() {
    cat <<EOT > "$TEMPLATE_FILE"
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  CloudFormation template that creates:
  1. An IAM User,
  2. An IAM Role (trusted by this user),
  3. Attaches AWSSecurityHubReadOnlyAccess to the role,
  4. An inline policy on the user to allow sts:AssumeRole,
  5. An IAM Access Key for the user,
  6. Outputs the user’s Access Key, Role ARN, Region, and Account ID.

Parameters:
  IAMUserName:
    Type: String
    Description: "Name of the IAM User to create."
    Default: "Findings"

  IAMRoleName:
    Type: String
    Description: "Name of the IAM Role to create."
    Default: "Findings_CloudVRM"

Resources:
  CFNUser:
    Type: AWS::IAM::User
    Properties:
      UserName: !Ref IAMUserName

  CFNRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref IAMRoleName
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              AWS: "*"
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AWSSecurityHubReadOnlyAccess

  CFNUserInlinePolicy:
    Type: AWS::IAM::Policy
    Properties:
      PolicyName: "Findings_CloudVRM_Inline"
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
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].Outputs" --output json | jq -r '.[] | select(.OutputKey == "SecretKey" or .OutputKey == "AccountID" or .OutputKey == "Region" or .OutputKey == "AccessKey") | "\u001b[32m" + .Description + ": \u001b[0m" + .OutputValue'
}

function monitor_uninstallation() {
    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "Stack deletion completed."
}

function install_stack() {
    create_template_file
    echo "Installing CloudFormation stack..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
    monitor_installation
}

function uninstall_stack() {
    echo "Uninstalling CloudFormation stack..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    monitor_uninstallation
}

if [[ "$1" == "--uninstall" ]]; then
    check_stack_exists
    if [[ $? -eq 0 ]]; then
        uninstall_stack
    else
        echo "Stack '$STACK_NAME' not found. Nothing to uninstall."
    fi
    exit 0
fi

check_stack_exists
if [[ $? -eq 0 ]]; then
    echo "CloudFormation stack '$STACK_NAME' already exists."
    read -p "Do you want to uninstall it? (y/N): " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        uninstall_stack
    else
        echo "Keeping existing stack. Exiting."
    fi
    exit 0
fi

install_stack
