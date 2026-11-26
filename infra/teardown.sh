#!/usr/bin/env bash
# Delete everything deploy.sh created. Safe to run more than once.
# Run it before submitting so no billable resources are left behind.
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="equipment-loans-${ACCOUNT_ID}"
say() { echo "==> $*"; }

say "API Gateway"
for id in $(aws apigatewayv2 get-apis --query "Items[?Name=='equipment-loans-api'].ApiId" --output text 2>/dev/null); do
  aws apigatewayv2 delete-api --api-id "$id"
done

say "Application Load Balancer"
ALB_ARN="$(aws elbv2 describe-load-balancers --names equipment-loans-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)"
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null
fi
for tg in loan-read-tg loan-write-tg; do
  arn="$(aws elbv2 describe-target-groups --names "$tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then aws elbv2 delete-target-group --target-group-arn "$arn"; fi
done
SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values=loans-alb-sg \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  for _ in 1 2 3 4 5 6; do   # network interfaces can take a minute to release
    aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null && break
    sleep 10
  done
fi

say "Lambda functions and logs"
for fn in loan-read loan-write; do
  aws lambda delete-function --function-name "$fn" >/dev/null 2>&1
  aws logs delete-log-group --log-group-name "/aws/lambda/$fn" >/dev/null 2>&1
done

say "DynamoDB table"
aws dynamodb delete-table --table-name loans >/dev/null 2>&1

say "S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws s3 rm "s3://$BUCKET" --recursive >/dev/null
  aws s3api delete-bucket --bucket "$BUCKET"
fi

rm -f "$HOME/.loans_base_url"
say "Done. Local token file kept at ~/.loans_token (outside the repo); delete it with: rm ~/.loans_token"
