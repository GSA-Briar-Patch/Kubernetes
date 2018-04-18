#!/bin/bash

# A script that is meant to be used to begin a secure bare K8s cluster:
#
# 1. In AWS.
# 2. Use Latest CIS Hardening.
# 3. All withi repo.

###################################################

scriptname=$(basename "$0")
scriptbuildnum="0.0.1"
scriptbuilddate="2018-04-18"

displayVer() {
  echo -e "${scriptname}  ver ${scriptbuildnum} - ${scriptbuilddate}"
}

while getopts ":i:ahv" arg; do
  case "${arg}" in
    a)  SECUREAMI='ami-9e9231e1';;
    i)  VERSION=${OPTARG};;
    n)  K8SNAME='joke';;
    h)  usage x; exit;;
    v)  displayVer; exit;;
    \?) echo -e "Error - Invalid option: $OPTARG"; usage; exit;;
    :)  echo "Error - $OPTARG requires an argument"; usage; exit 1;;
  esac
done

# Environment values
export REGION=us-east-1 # For example u
export NODE_ZONE=${REGION}a,${REGION}b,${REGION}c
export MASTER_ZONE=${REGION}a,${REGION}b,${REGION}c
export NODE_COUNT=3
export NODE_TYPE=t2.large
export MASTER_TYPE=t2.large
export AWS_DEFAULT_PROFILE=kops
export KUBERNETES_VERSION="1.9.6"
export SECURE_OS="ami-9e9231e1"

export STAGE=production
export DNS_ZONE=helixviper.org # Change it to your domain
export DNS_ZONE_DASH=$(echo $DNS_ZONE | sed 's/\./-/g')
export S3_BUCKET_PREFIX=$STAGE-$DNS_ZONE_DASH
export NAME=$STAGE.$DNS_ZONE

export KOPS_STATE_STORE=s3://$S3_BUCKET_PREFIX-kstate
export TF_STATE_STORE=$S3_BUCKET_PREFIX-tfstate
export K8S_CONFIG_STORE=$S3_BUCKET_PREFIX-config

###################################################

set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

readonly MAX_RETRIES=30
readonly SLEEP_BETWEEN_RETRIES_SEC=10
###################################################

export K8_SUB_DOMAIN_DEFAULT=$SCRIPT_DIR/aws/k8-sub-domain-default.json
export K8_SUB_DOMAIN_ENV=$SCRIPT_DIR/aws/k8-sub-domain.json
export HOSTED_ZONE_FILE=$SCRIPT_DIR/hosted-zone.json
###################################################

# echo $KOPS_STATE_STORE
# aws s3 ls "$KOPS_STATE_STORE" | grep -q 'An error occurred'

function create_s3_buckets {
  if aws s3 ls "${KOPS_STATE_STORE}" 2>&1 | grep -q 'An error occurred'
  then
  echo "bucket does not exist, so creating it."

  #aws s3api create-bucket --bucket ${S3_NAME} --region ${REGION}
  # Create some buckets that hold our different kops, k8s and terraform state
  aws s3api create-bucket --bucket ${S3_BUCKET_PREFIX}-kstate --region ${REGION} 
  aws s3api create-bucket --bucket ${TF_STATE_STORE} --region ${REGION} 
  aws s3api create-bucket --bucket ${K8S_CONFIG_STORE} --region ${REGION} 

  aws s3api put-bucket-versioning --bucket ${S3_BUCKET_PREFIX}-kstate --versioning-configuration Status=Enabled 
  aws s3api put-bucket-versioning --bucket ${TF_STATE_STORE} --versioning-configuration Status=Enabled 
  aws s3api put-bucket-versioning --bucket ${K8S_CONFIG_STORE} --versioning-configuration Status=Enabled 

  else
  echo "S3 bucket exists so deleting your stuff"
  aws s3 rm ${KOPS_STATE_STORE} --recursive
  aws s3 rm s3://${TF_STATE_STORE} --recursive
  aws s3 rm s3://${K8S_CONFIG_STORE} --recursive
  fi
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function create_new_keypair {
# Create a new ssh private/public keypair
    echo "Checking if you old keypairs with this name"
    if [[ $(aws ec2 describe-key-pairs --key-name "${NAME}" 2>&1 | jq -r '.KeyPairs[].KeyName') ]] ;
    then
      echo "ugh...  Cleaning your old key out"
      aws ec2 delete-key-pair --key-name "${NAME}"
      rm -r "${NAME}.pem"
      rm -f "${PUBKEY}"
    fi

    ssh-keygen -t rsa -C ${NAME} -f ${NAME}.pem -N ''
    PUBKEY=$(pwd)/${NAME}.pem.pub
    aws ec2 import-key-pair --key-name ${NAME} --public-key-material file://${PUBKEY}
    echo "### SSH Keys created and placed in AWS ###"
}

function begin_cluster_plan {
    kops create cluster \
    --cloud aws \
    --state=$KOPS_STATE_STORE \
    --node-count=$NODE_COUNT \
    --zones=$NODE_ZONE \
    --node-size=$NODE_TYPE \
    --master-size=$MASTER_TYPE \
    --topology=private \
    --image=$SECURE_OS \
    --dns=Public \
    --networking=calico \
    --cloud-labels="${NAME}:billing=infra__mt__kubernetes,Environment=${STAGE}" \
    --ssh-public-key=${PUBKEY} \
    --authorization=RBAC \
    --out=terraform/${STAGE} \
    $NAME

    #        --dns-zone=$DNS_ZONE \
    #    Having problems with terraform and DNS
    #    --out=terraform/${STAGE} \
    #    --target=terraform \
    #    --bastion \
       # Configure terraform state
    cd terraform/${STAGE}
    cat << EOF > backend.tf
    terraform {
     backend "s3" {
 bucket = "${TF_STATE_STORE}"
 key    = "terraform.tfstate"
 region = "${REGION}"
 }
}
EOF
  #envsubst <../templates/sqs.tf > sqs.tf
}

function begin_cluster_KOPS_build {
  kops update cluster $NAME --state=$KOPS_STATE_STORE --yes
}


function begin_cluster_terraform_build {
  cd terraform/${STAGE}
  terraform init -input=false
  terraform plan -input=false -out ./create-cluster.plan
  #terraform show ./create-cluster.plan | less -R # final review
  terraform apply ./create-cluster.plan # fire
  #kops validate cluster
}

getSubDomain() {

   createSubdomain
   createComment "k8 subdomain $NAME"
   createResourceRecordSet "$NAME"
   createRecordInParentDomain
}

createSubdomain() {
if dig +short $NAME soa 2>&1 | grep -q 'awsdns-hostmaster.amazon.com';
    then
        echo "you have a subdomain NS"
    else
    # From https://github.com/sasikumar-sugumar/AWS-Install-Kubernetes-Kops-Shell-Script/blob/master/Install-Kubernetes.sh
    # Need to add the Subdomain for KOPS/Terraform
    # https://github.com/kubernetes/kops/blob/master/docs/aws.md#configure-dns
	rm -rf $HOSTED_ZONE_FILE
	ID=$(uuidgen) && aws route53 create-hosted-zone --name $NAME --caller-reference $ID >> $HOSTED_ZONE_FILE
  fi
}

createResourceRecordSet() {
	SUBDOMAIN_NAME=$1
	jq '. | .Changes[0].ResourceRecordSet.Name="'"$NAME"'"' $K8_SUB_DOMAIN_ENV >>$SCRIPT_DIR/aws/k8-sub-domain-updated.json
	mv $SCRIPT_DIR/aws/k8-sub-domain-updated.json $K8_SUB_DOMAIN_ENV
	echo "Created Sub-Domain $NAME"
	createAddress
}

createComment() {
    # Kill old records if exit
    rm -rf $SCRIPT_DIR/aws/k8-sub-domain.json
    #cp $SCRIPT_DIR/aws/k8-sub-domain-default.json $SCRIPT_DIR/aws/k8-sub-domain.json
	COMMENT=$1
	jq '. | .Comment="'"$COMMENT"'"' $K8_SUB_DOMAIN_DEFAULT >>$K8_SUB_DOMAIN_ENV
	echo "Created  $COMMENT"
}

createAddress() {
	ADDRESS_1=$(jq '. | .DelegationSet.NameServers[0]' $SCRIPT_DIR/hosted-zone.json)
	ADDRESS_2=$(jq '. | .DelegationSet.NameServers[1]' $SCRIPT_DIR/hosted-zone.json)
	ADDRESS_3=$(jq '. | .DelegationSet.NameServers[2]' $SCRIPT_DIR/hosted-zone.json)
	ADDRESS_4=$(jq '. | .DelegationSet.NameServers[3]' $SCRIPT_DIR/hosted-zone.json)
	echo "Created Address $SUBDOMAIN_NAME"
	jq '. | .Changes[0].ResourceRecordSet.ResourceRecords[0].Value='"$ADDRESS_1"' | .Changes[0].ResourceRecordSet.ResourceRecords[1].Value='"$ADDRESS_2"' | .Changes[0].ResourceRecordSet.ResourceRecords[2].Value='"$ADDRESS_3"' | .Changes[0].ResourceRecordSet.ResourceRecords[3].Value='"$ADDRESS_4"' ' $K8_SUB_DOMAIN_ENV >>$SCRIPT_DIR/aws/k8-sub-domain-updated.json
	mv $SCRIPT_DIR/aws/k8-sub-domain-updated.json $K8_SUB_DOMAIN_ENV
}

createRecordInParentDomain() {
	PARENT_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq --arg DNS_ZONE "$DNS_ZONE." --raw-output '.HostedZones[] | select(.Name==$DNS_ZONE) | .Id' | cut -d/ -f3|cut -d\" -f1)
	CHANGE_ID=$(aws route53 change-resource-record-sets \
		--hosted-zone-id $PARENT_HOSTED_ZONE_ID \
		--change-batch file://$SCRIPT_DIR/aws/k8-sub-domain.json | jq --raw-output '. | .ChangeInfo.Id')
	echo "CHANGE CREATED : $CHANGE_ID"
	waitForINSYNC
}

waitForINSYNC() {
	CHANGE_STATUS="PENDING"
	while [[ $CHANGE_STATUS == "PENDING" ]]; do
		echo "TAKING A NAP FOR 5S"
		sleep 5s
		CHANGE_STATUS=$(aws route53 get-change --id $CHANGE_ID | jq --raw-output '. | .ChangeInfo.Status')
		echo "CHANGE Status : $CHANGE_STATUS"
	done
}

function cfg_cluster {
   # Configure
  echo $KOPS_STATE_STORE
   #kops update cluster production.styx.red --state=s3://${KOPS_STATE_STORE} --yes
  kops validate cluster --state=$KOPS_STATE_STORE
  kops rolling-update cluster $NAME --state=$KOPS_STATE_STORE --yes
  #begin_cluster_terraform_build
}

clean() {
    cd terraform/${STAGE}
    terraform destroy -force
    kops delete cluster $NAME --yes
    rm -rf $NAME.pem
    rm -rf "${PUBKEY}"
	rm -rf $K8_SUB_DOMAIN_ENV
	rm -rf $KOPS_HOME/k8-sub-domain-updated.json
    aws s3 rb ${KOPS_STATE_STORE} --force
    aws s3 rb s3://${TF_STATE_STORE} --force
    aws s3 rb s3://${K8S_CONFIG_STORE} --force
}


function run {
  assert_is_installed "aws"
  assert_is_installed "jq"
  assert_is_installed "terraform"
  assert_is_installed "curl"
  begin_cluster_build
  cfg_cluster
#  assert_is_installed "jq"
#  assert_is_installed "terraform"
#  assert_is_installed "curl"

#  local server_ips
#  server_ips=$(get_all_vault_server_ips)

#  wait_for_all_vault_servers_to_come_up "$server_ips"
#  print_instructions "$server_ips"
}


drawMenu() {
	# clear the screen
	tput clear

	# Move cursor to screen location X,Y (top left is 0,0)
	tput cup 3 15

	# Set a foreground colour using ANSI escape
	tput setaf 3
	echo "Brair Patch Script Aid"
	tput sgr0

	tput cup 5 17
	# Set reverse video mode
	tput rev
	echo "M A I N - M E N U"
	tput sgr0

	tput cup 7 15
	echo "1. Clean Kubernetes install"

	tput cup 8 15
	echo "2. Validate/Update cluster"

	tput cup 9 15
	echo "3. Install Kubectl"

	tput cup 10 15
	echo "4. Create K8 Cluster"

	tput cup 12 15
	echo "5. Delete Cluster"

	# Set bold mode
	tput bold
	tput cup 14 15
	# The default value for PS3 is set to #?.
	# Change it i.e. Set PS3 prompt
	read -p "Enter your choice [1-5] " choice
}

drawMenu
tput sgr0
# set deployservice list
case $choice in
	1)
		echo "#########################"
		echo "Starting a clean INSTALL. And GO GET A DRINK!  This takes about 20 mins to spin up"
	    #getSubDomain

		# Wait until the NS dig returns the name
		DNS_STATUS="PENDING"
	    #while [[ $CHANGE_STATUS == "PENDING" ]]; do
		#    echo "TAKING A NAP FOR 5S"
		#    sleep 5s
		#    CHANGE_STATUS=$(aws route53 get-change --id $CHANGE_ID | jq --raw-output '. | .ChangeInfo.Status')
		#    echo "CHANGE Status : $CHANGE_STATUS"
	    #done

		create_s3_buckets
		create_new_keypair
		begin_cluster_plan
		begin_cluster_KOPS_build
		# Having issue with terraform builds not configuring DNS*.
		#begin_cluster_terraform_build
		#begin_cluster_build
        #kops update cluster $NAME --state=s3://${KOPS_STATE_STORE} --yes
		echo "#########################"
		;;
	2)
		echo "#########################"
		echo "Validating and updating cluster"
		cfg_cluster
		echo "#########################"
		;;
	3)
		echo "#########################"
		echo "Starting a Kubectl INSTALL."
		installKubectl
		echo "#########################"
		;;
	4)
		echo "#########################"
		echo "Creating Cluster."
		#create_s3_buckets
        #create_new_keypair
        #getSubDomain
        #begin_cluster_plan
        #kops update cluster ${NAME} --yes
        #begin_cluster_build
		echo "#########################"
		;;
	5)
		echo "#########################"
		echo "Destroy the Cluster."
		clean
		echo "#########################"
		;;
	*)
		echo "Error: Please try again (select 1..3)!"
		;;
esac