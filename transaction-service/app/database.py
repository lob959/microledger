import os
from typing import TYPE_CHECKING

import boto3

# TYPE_CHECKING is False at runtime — this import never executes in production.
# It exists purely for IDE autocompletion and mypy static analysis.
if TYPE_CHECKING:
    from mypy_boto3_dynamodb.service_resource import Table


def get_dynamodb_resource():
    """
    Returns a boto3 DynamoDB resource.

    In local development, DYNAMODB_ENDPOINT_URL is set in docker-compose to
    point at the DynamoDB Local container. In AWS, the env var is absent and
    boto3 uses the default credential chain (ECS task role).
    """
    endpoint_url = os.getenv("DYNAMODB_ENDPOINT_URL")

    if endpoint_url:
        # DynamoDB Local — credentials are ignored but boto3 still requires them
        return boto3.resource(
            "dynamodb",
            endpoint_url=endpoint_url,
            region_name=os.getenv("AWS_REGION", "ap-southeast-2"),
            aws_access_key_id="dummy",
            aws_secret_access_key="dummy",
        )

    # Production path — IAM task role is picked up automatically
    return boto3.resource(
        "dynamodb",
        region_name=os.getenv("AWS_REGION", "ap-southeast-2"),
    )


def get_table(table_name: str):
    """Returns a DynamoDB Table resource for the given table name."""
    return get_dynamodb_resource().Table(table_name)