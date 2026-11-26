#!/usr/bin/env python3
"""Change environment variables of a Lambda function without touching the others.

  python3 infra/lambda_env.py set <function> KEY=VALUE [KEY=VALUE ...]

Values are never printed (one of them can be the API token).
"""
import sys

import boto3


def main(argv):
    if len(argv) < 4 or argv[1] != "set":
        sys.exit(__doc__)
    function = argv[2]
    updates = dict(item.split("=", 1) for item in argv[3:])

    client = boto3.client("lambda")
    current = client.get_function_configuration(FunctionName=function)
    variables = dict(current.get("Environment", {}).get("Variables", {}))
    variables.update(updates)

    client.update_function_configuration(FunctionName=function, Environment={"Variables": variables})
    client.get_waiter("function_updated").wait(FunctionName=function)
    print(f"{function}: updated {', '.join(sorted(updates))}")


if __name__ == "__main__":
    main(sys.argv)
