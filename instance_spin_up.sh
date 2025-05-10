#!/bin/bash

# AWS EC2 Ubuntu 22.04 LTS Free Tier Launch Script
# Creates multiple t2.micro instances with automatic default VPC, subnet, and security group
# Adds SSH access to default security group if needed

# Configuration - Set these values
KEY_NAME="your-keypair-name"          # Replace with your EC2 key pair name
INSTANCE_COUNT=5                     # Number of instances to launch
INSTANCE_TYPE="t2.micro"             # Instance type
REGION="us-east-1"                   # AWS region
ALLOW_SSH="yes"                      # Set to "yes" to enable SSH access (port 22)

# Validate prerequisites
command -v aws >/dev/null 2>&1 || { echo >&2 "AWS CLI is required but not installed. Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "jq is required but not installed. Aborting."; exit 1; }

# Function to handle errors
error_exit() {
    echo "$1" >&2
    exit 1
}

# Get default VPC
echo "🔍 Fetching default VPC information..."
DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
    --region $REGION \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text) || error_exit "Failed to get default VPC"

[ -z "$DEFAULT_VPC_ID" ] && error_exit "No default VPC found in region $REGION"
echo "✅ Found default VPC: $DEFAULT_VPC_ID"

# Get default subnet
echo "🔍 Finding default subnet..."
DEFAULT_SUBNET_ID=$(aws ec2 describe-subnets \
    --region $REGION \
    --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[0].SubnetId" \
    --output text) || error_exit "Failed to get default subnet"

[ -z "$DEFAULT_SUBNET_ID" ] && error_exit "No default subnet found in VPC $DEFAULT_VPC_ID"
echo "✅ Found default subnet: $DEFAULT_SUBNET_ID"

# Get default security group
echo "🔍 Finding default security group..."
DEFAULT_SG_ID=$(aws ec2 describe-security-groups \
    --region $REGION \
    --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" "Name=group-name,Values=default" \
    --query "SecurityGroups[0].GroupId" \
    --output text) || error_exit "Failed to get default security group"

[ -z "$DEFAULT_SG_ID" ] && error_exit "No default security group found in VPC $DEFAULT_VPC_ID"
echo "✅ Found default security group: $DEFAULT_SG_ID"

# Enable SSH access if requested
if [ "$ALLOW_SSH" = "yes" ]; then
    echo "🔒 Configuring SSH access in security group..."
    aws ec2 authorize-security-group-ingress \
        --group-id $DEFAULT_SG_ID \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region $REGION >/dev/null || echo "⚠️ Warning: Failed to add SSH rule (may already exist)"
fi

# Get the latest Ubuntu 22.04 LTS AMI ID
echo "🖥️  Finding latest Ubuntu 22.04 LTS AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region $REGION \
    --owners 099720109477 \  # Canonical's owner ID
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=virtualization-type,Values=hvm" \
        "Name=architecture,Values=x86_64" \
        "Name=root-device-type,Values=ebs" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text) || error_exit "Failed to find Ubuntu AMI"

[ -z "$AMI_ID" ] && error_exit "No Ubuntu 22.04 LTS AMI found"
echo "✅ Using AMI ID: $AMI_ID"

# Launch instances
echo "🚀 Launching $INSTANCE_COUNT $INSTANCE_TYPE instances..."
INSTANCE_IDS=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count $INSTANCE_COUNT \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $DEFAULT_SG_ID \
    --subnet-id $DEFAULT_SUBNET_ID \
    --region $REGION \
    --associate-public-ip-address \
    --query 'Instances[].InstanceId' \
    --output text) || error_exit "Failed to launch instances"

[ -z "$INSTANCE_IDS" ] && error_exit "No instances were launched"
echo "✅ Successfully launched instances: $INSTANCE_IDS"

# Tag the instances
echo "🏷️  Tagging instances..."
counter=1
for INSTANCE_ID in $INSTANCE_IDS; do
    aws ec2 create-tags \
        --resources $INSTANCE_ID \
        --tags "Key=Name,Value=Ubuntu-$INSTANCE_TYPE-$counter" "Key=Environment,Value=Test" \
        --region $REGION || echo "⚠️ Warning: Failed to tag instance $INSTANCE_ID"
    ((counter++))
done

# Wait for instances to initialize
echo "⏳ Waiting for instances to initialize (30 seconds)..."
sleep 30

# Get instance details
echo "📋 Instance details:"
aws ec2 describe-instances \
    --instance-ids $INSTANCE_IDS \
    --region $REGION \
    --query 'Reservations[].Instances[].[
        InstanceId,
        InstanceType,
        State.Name,
        PublicIpAddress,
        PrivateIpAddress,
        Tags[?Key==`Name`].Value | [0]
    ]' \
    --output table

echo "🎉 Script completed successfully! All instances are running."
echo "💻 $INSTANCE_COUNT Ubuntu $INSTANCE_TYPE instances launched in default VPC resources"
if [ "$ALLOW_SSH" = "yes" ]; then
    echo "🔓 SSH access enabled (port 22) from any IP"
fi