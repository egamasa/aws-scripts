#!/usr/bin/env python3
import os
import yaml
import aws_cdk as cdk

from cdk_vpc_dev_ipv6.cdk_vpc_dev_ipv6_stack import CdkVpcDevIpv6Stack


app = cdk.App()

config_name = app.node.try_get_context("config")

if os.path.exists("config/{}.yaml".format(config_name)):
    config_file = open("config/{}.yaml".format(config_name), "r")
    config = yaml.safe_load(config_file)
    config_file.close()
else:
    raise Exception("Can't open config file: {}.yaml".format(config_name))

CdkVpcDevIpv6Stack(
    app,
    "cdk-{}-stack".format(config["serviceName"]),
    config=config,
    env=cdk.Environment(
        region=config["region"],
    ),
)

app.synth()
