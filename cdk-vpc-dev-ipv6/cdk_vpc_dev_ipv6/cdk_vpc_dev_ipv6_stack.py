from aws_cdk import (
    Stack,
    aws_ec2 as ec2
)
from constructs import Construct


class CdkVpcDevIpv6Stack(Stack):
    def __init__(self, scope: Construct, construct_id: str, config, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # VPC
        vpc = ec2.Vpc(
            self,
            "{}-vpc".format(config["serviceName"]),
            ip_addresses=ec2.IpAddresses.cidr(config["vpcCidr"]),
            enable_dns_hostnames=False,
            enable_dns_support=True,
            nat_gateways=0,
            subnet_configuration=[],
        )

        # Internet Gateway
        igw = ec2.CfnInternetGateway(
            self,
            "{}-igw".format(config["serviceName"]),
        )
        ec2.CfnVPCGatewayAttachment(
            self,
            "{}-GatewayAttachment".format(config["serviceName"]),
            vpc_id=vpc.vpc_id,
            internet_gateway_id=igw.ref,
        )

        # IPv6 CIDR Block
        ipv6_cidr_block = ec2.CfnVPCCidrBlock(
            self,
            "{}-IPv6CidrBlock".format(config["serviceName"]),
            vpc_id=vpc.vpc_id,
            amazon_provided_ipv6_cidr_block=True,
        )

        # Egress Only Internet Gateway
        eigw = ec2.CfnEgressOnlyInternetGateway(
            self,
            "{}-eigw".format(config["serviceName"]),
            vpc_id=vpc.vpc_id,
        )

        # Route Tables
        rtb_public = ec2.CfnRouteTable(
            self,
            "{}-rtb-public".format(config["serviceName"]),
            vpc_id=vpc.vpc_id
        )
        rtb_private = ec2.CfnRouteTable(
            self,
            "{}-rtb-private".format(config["serviceName"]),
            vpc_id=vpc.vpc_id
        )

        # Routes
        route_public = self._create_route_public(
            rtb_public.ref,
            igw.ref
        )
        route_private = self._create_route_private(
            rtb_private.ref,
            eigw.ref
        )

        subnets = {}

        # Public Subnets
        for index, subnet in enumerate(config["publicSubnets"]):
            cfn_subnet = self._create_subnet(
                "{}-subnet-{}".format(config["serviceName"], subnet["name"]),
                availability_zone=subnet["az"],
                cidr_block=subnet["IPv4Cidr"],
                vpc_id=vpc.vpc_id,
            )
            subnets[subnet["name"]] = dict(subnet=cfn_subnet)

            ec2.CfnSubnetRouteTableAssociation(
                self,
                "{}-Association".format(subnet["name"]),
                subnet_id=cfn_subnet.ref,
                route_table_id=rtb_public.ref,
            )

        # Private Subnets
        for index, subnet in enumerate(config["privateSubnets"]):
            cfn_subnet = self._create_subnet(
                "{}-subnet-{}".format(config["serviceName"], subnet["name"]),
                availability_zone=subnet["az"],
                cidr_block=subnet["IPv4Cidr"],
                vpc_id=vpc.vpc_id,
            )
            subnets[subnet["name"]] = dict(subnet=cfn_subnet)

            ec2.CfnSubnetRouteTableAssociation(
                self,
                "{}-Association".format(subnet["name"]),
                subnet_id=cfn_subnet.ref,
                route_table_id=rtb_private.ref,
            )


    def _create_subnet(self, name, availability_zone, cidr_block, vpc_id):
        return ec2.CfnSubnet(
            self,
            name,
            cidr_block=cidr_block,
            availability_zone=availability_zone,
            vpc_id=vpc_id,
            assign_ipv6_address_on_creation=True,
            map_public_ip_on_launch=False,
        )

    def _create_route_public(self, route_table_id, igw_id):
        return ec2.CfnRoute(
            self,
            "route-public-internet",
            route_table_id=route_table_id,
            destination_cidr_block="0.0.0.0/0",
            destination_ipv6_cidr_block="::/0",
            gateway_id=igw_id,
        )

    def _create_route_private(self, route_table_id, eigw_id):
        return ec2.CfnRoute(
            self,
            "route-private-internet",
            route_table_id=route_table_id,
            destination_ipv6_cidr_block="::/0",
            egress_only_internet_gateway_id=eigw_id,
        )
