# Kubernetes
This is a simple kubernetes cluster that uses KOPS and builds up complexity 


## Clone this repo and run
```
sh ./bootstrap.sh
```

## Harding the cluster



dig ns $NAME.

cd terraform/production/
terraform destroy
cd ../..


dig ns ${DNS_ZONE}
dig ns ${NAME}
kops delete cluster production.styx.red --state=s3://${KOPS_STATE_STORE} --yes


kops update cluster ${NAME} --state=s3://${KOPS_STATE_STORE} --yes -v=10

kops validate cluster ${NAME} --state=s3://${KOPS_STATE_STORE} 

kops rolling-update cluster production.styx.red --state=s3://${KOPS_STATE_STORE} 
kops update cluster ${NAME} --state=s3://${KOPS_STATE_STORE} --yes

terraform import aws_route53_zone.styx.red

ns-1272.awsdns-31.org
ns-270.awsdns-33.com
ns-840.awsdns-41.net
ns-1797.awsdns-32.co.uk

dig ns production.styx.red
dig ns subdomain.example.com


Add ClamAV, Sysdig

Remnux


aws route53 list-hosted-zones | jq '.HostedZones[] | select(.Name=="styx.red") | .Id'