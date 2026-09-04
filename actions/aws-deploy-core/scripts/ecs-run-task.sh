#!/usr/bin/env bash
# Runs one ECS one-off task, waits for it to stop, fails on a nonzero exit
# code. Shared by the ecs-service target's migrate-command and
# post-deploy-command steps — same shape, only COMMAND and LABEL differ.
set -euo pipefail

: "${CLUSTER:?}" "${TASK_DEFINITION_ARN:?}" "${CONTAINER_NAME:?}" \
  "${COMMAND:?}" "${NETWORK_CONFIGURATION:?}" "${TASK_TIMEOUT:?}" "${LABEL:?}"

# COMMAND is a JSON array, not a space-separated string — an argument like
# an Elixir eval expression can itself contain spaces.
if ! echo "$COMMAND" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::$LABEL command must be a JSON array, e.g. '[\"/app/bin/migrate\"]'. Got: $COMMAND" >&2
  exit 1
fi
overrides=$(jq -n --arg name "$CONTAINER_NAME" --argjson cmd "$COMMAND" \
  '{containerOverrides: [{name: $name, command: $cmd}]}')

task_arn=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --launch-type FARGATE \
  --network-configuration "$NETWORK_CONFIGURATION" \
  --overrides "$overrides" \
  --query 'tasks[0].taskArn' --output text)

if [ -z "$task_arn" ] || [ "$task_arn" = "None" ]; then
  echo "::error::$LABEL task failed to start." >&2
  exit 1
fi
echo "$LABEL task $task_arn started, waiting up to ${TASK_TIMEOUT}s..."

deadline=$(( SECONDS + TASK_TIMEOUT ))
status=PENDING
while [ "$SECONDS" -lt "$deadline" ]; do
  status=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
    --query 'tasks[0].lastStatus' --output text)
  [ "$status" = "STOPPED" ] && break
  sleep 10
done

if [ "$status" != "STOPPED" ]; then
  echo "::error::$LABEL task $task_arn did not stop within ${TASK_TIMEOUT}s (last status: $status)." >&2
  exit 1
fi

exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
  --query "tasks[0].containers[?name=='$CONTAINER_NAME'].exitCode | [0]" --output text)
stopped_reason=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
  --query 'tasks[0].stoppedReason' --output text)

echo "$LABEL task $task_arn stopped. exitCode=$exit_code reason=$stopped_reason"

if [ "$exit_code" != "0" ]; then
  echo "::error::$LABEL task $task_arn exited $exit_code: $stopped_reason" >&2
  exit 1
fi
