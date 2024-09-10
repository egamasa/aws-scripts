import aws_cdk as core
import aws_cdk.assertions as assertions

from cdk_vpc_dev_ipv6.cdk_vpc_dev_ipv6_stack import CdkVpcDevIpv6Stack

# example tests. To run these tests, uncomment this file along with the example
# resource in cdk_vpc_dev_ipv6/cdk_vpc_dev_ipv6_stack.py
def test_sqs_queue_created():
    app = core.App()
    stack = CdkVpcDevIpv6Stack(app, "cdk-vpc-dev-ipv6")
    template = assertions.Template.from_stack(stack)

#     template.has_resource_properties("AWS::SQS::Queue", {
#         "VisibilityTimeout": 300
#     })
