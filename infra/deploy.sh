#!/usr/bin/env bash
# Deploy the equipment-loans API into the AWS Academy sandbox (us-east-1).
#
# Run it in AWS CloudShell or the sandbox Lab IDE terminal, from the repo root:
#
#   ./infra/deploy.sh                                   # API Gateway + DynamoDB (as in the slide)
#   STORAGE_BACKEND=s3 ./infra/deploy.sh                # API Gateway + S3
#   API_FRONT=alb STORAGE_BACKEND=s3 ./infra/deploy.sh  # ALB + S3 (if API Gateway is blocked)
#
# Secrets: the API token is generated randomly and saved to ~/.loans_token
# (outside the repo). It is never printed and never committed.
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
STORAGE_BACKEND="${STORAGE_BACKEND:-dynamodb}"   # dynamodb | s3
API_FRONT="${API_FRONT:-apigw}"                  # apigw | alb
RUNTIME="${RUNTIME:-python3.12}"
ALB_CIDR="${ALB_CIDR:-0.0.0.0/0}"                # who may reach the ALB (alb only)

TABLE="loans"
API_NAME="equipment-loans-api"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="$HOME/.loans_token"
URL_FILE="$HOME/.loans_base_url"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="equipment-loans-${ACCOUNT_ID}"
ROLE_ARN="$(aws iam get-role --role-name LabRole --query Role.Arn --output text)"

echo "==> storage: $STORAGE_BACKEND | front door: $API_FRONT | region: $REGION"

# ---- secret token (not printed) ------------------------------------------
if [ -n "${API_TOKEN:-}" ]; then
  TOKEN="$API_TOKEN"
elif [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
else
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
fi
umask 077
printf '%s' "$TOKEN" > "$TOKEN_FILE"
echo "==> API token saved to $TOKEN_FILE (not printed)"

# ---- 1. build -------------------------------------------------------------
echo "==> building packages"
python3 "$ROOT/infra/build.py"

# ---- 2. storage -----------------------------------------------------------
if [ "$STORAGE_BACKEND" = "dynamodb" ]; then
  if aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
    echo "==> DynamoDB table $TABLE already exists"
  else
    echo "==> creating DynamoDB table $TABLE"
    aws dynamodb create-table --table-name "$TABLE" \
      --attribute-definitions AttributeName=id,AttributeType=S \
      --key-schema AttributeName=id,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
    aws dynamodb wait table-exists --table-name "$TABLE"
  fi
elif [ "$STORAGE_BACKEND" = "s3" ]; then
  if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "==> S3 bucket $BUCKET already exists"
  else
    echo "==> creating S3 bucket $BUCKET"
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    aws s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
else
  echo "STORAGE_BACKEND must be dynamodb or s3" >&2; exit 1
fi

# ---- 3. Lambda functions ---------------------------------------------------
deploy_function() {  # name  environment-variables
  local name="$1" envvars="$2"
  if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
    echo "==> updating function $name"
    aws lambda update-function-code --function-name "$name" \
      --zip-file "fileb://$ROOT/build/$name.zip" >/dev/null
    aws lambda wait function-updated --function-name "$name"
    aws lambda update-function-configuration --function-name "$name" \
      --environment "Variables={$envvars}" >/dev/null
    aws lambda wait function-updated --function-name "$name"
  else
    echo "==> creating function $name"
    aws lambda create-function --function-name "$name" \
      --runtime "$RUNTIME" --role "$ROLE_ARN" \
      --handler handler.lambda_handler \
      --zip-file "fileb://$ROOT/build/$name.zip" \
      --timeout 10 --memory-size 128 \
      --environment "Variables={$envvars}" >/dev/null
    aws lambda wait function-active-v2 --function-name "$name"
  fi
}

STORE_VARS="STORAGE_BACKEND=$STORAGE_BACKEND,LOANS_TABLE=$TABLE,LOANS_BUCKET=$BUCKET"
deploy_function loan-read  "$STORE_VARS"
deploy_function loan-write "$STORE_VARS,API_TOKEN=$TOKEN"

READ_ARN="$(aws lambda get-function --function-name loan-read --query Configuration.FunctionArn --output text)"
WRITE_ARN="$(aws lambda get-function --function-name loan-write --query Configuration.FunctionArn --output text)"

allow_invoke() {  # function principal source-arn statement-id
  aws lambda add-permission --function-name "$1" --principal "$2" \
    --source-arn "$3" --statement-id "$4" --action lambda:InvokeFunction >/dev/null 2>&1 || true
}

# ---- 4. front door ---------------------------------------------------------
if [ "$API_FRONT" = "apigw" ]; then
  API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)"
  if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
    echo "==> creating HTTP API $API_NAME"
    API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
      --query ApiId --output text)"
    INT_READ="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
      --integration-type AWS_PROXY --integration-uri "$READ_ARN" \
      --payload-format-version 2.0 --query IntegrationId --output text)"
    INT_WRITE="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
      --integration-type AWS_PROXY --integration-uri "$WRITE_ARN" \
      --payload-format-version 2.0 --query IntegrationId --output text)"
    for route in "GET /health" "GET /loans" "GET /loans/{id}"; do
      aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$route" \
        --target "integrations/$INT_READ" >/dev/null
    done
    for route in "POST /loans" "PUT /loans/{id}" "DELETE /loans/{id}"; do
      aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$route" \
        --target "integrations/$INT_WRITE" >/dev/null
    done
    aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' \
      --auto-deploy >/dev/null
  else
    echo "==> HTTP API $API_NAME already exists ($API_ID)"
  fi
  SOURCE="arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*"
  allow_invoke loan-read  apigateway.amazonaws.com "$SOURCE" apigw-invoke
  allow_invoke loan-write apigateway.amazonaws.com "$SOURCE" apigw-invoke
  BASE_URL="https://$API_ID.execute-api.$REGION.amazonaws.com"

elif [ "$API_FRONT" = "alb" ]; then
  VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"
  SUBNETS="$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text)"

  SG_ID="$(aws ec2 describe-security-groups --filters Name=group-name,Values=loans-alb-sg \
    Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)"
  if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    echo "==> creating security group loans-alb-sg"
    SG_ID="$(aws ec2 create-security-group --group-name loans-alb-sg \
      --description "HTTP access to the equipment loans ALB" --vpc-id "$VPC_ID" \
      --query GroupId --output text)"
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port 80 --cidr "$ALB_CIDR" >/dev/null
  fi

  echo "==> creating load balancer"
  # shellcheck disable=SC2086
  ALB_ARN="$(aws elbv2 create-load-balancer --name equipment-loans-alb \
    --type application --scheme internet-facing --security-groups "$SG_ID" \
    --subnets $SUBNETS --query 'LoadBalancers[0].LoadBalancerArn' --output text)"

  make_target_group() {  # name function-arn function-name
    local tg
    tg="$(aws elbv2 create-target-group --name "$1" --target-type lambda \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
    allow_invoke "$3" elasticloadbalancing.amazonaws.com "$tg" alb-invoke
    aws elbv2 register-targets --target-group-arn "$tg" --targets "Id=$2" >/dev/null
    echo "$tg"
  }
  TG_READ="$(make_target_group loan-read-tg "$READ_ARN" loan-read)"
  TG_WRITE="$(make_target_group loan-write-tg "$WRITE_ARN" loan-write)"

  LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"404","ContentType":"application/json","MessageBody":"{\"error\":\"route not found\"}"}}]' \
    --query 'Listeners[0].ListenerArn' --output text)"

  aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 10 \
    --conditions '[{"Field":"http-request-method","HttpRequestMethodConfig":{"Values":["GET"]}},{"Field":"path-pattern","PathPatternConfig":{"Values":["/health","/loans","/loans/*"]}}]' \
    --actions "Type=forward,TargetGroupArn=$TG_READ" >/dev/null
  aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 20 \
    --conditions '[{"Field":"http-request-method","HttpRequestMethodConfig":{"Values":["POST","PUT","DELETE"]}},{"Field":"path-pattern","PathPatternConfig":{"Values":["/loans","/loans/*"]}}]' \
    --actions "Type=forward,TargetGroupArn=$TG_WRITE" >/dev/null

  echo "==> waiting for the load balancer to become active (1-3 minutes)"
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
  DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  BASE_URL="http://$DNS"
else
  echo "API_FRONT must be apigw or alb" >&2; exit 1
fi

printf '%s' "$BASE_URL" > "$URL_FILE"
echo
echo "Deployed. Base URL: $BASE_URL"
echo "Try:   curl $BASE_URL/health"
echo "Test:  ./tests/smoke_test.sh"
