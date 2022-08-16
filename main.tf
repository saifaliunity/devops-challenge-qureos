provider "aws" {
  region  = "us-east-1"
  profile = "default"
}

module "vpc" {
  source   = "./vpc"
  key_name = "${module.key_pair.key_name}"
  vpc_name = "${var.vpc_name}"
}

module "key_pair" {
  source     = "./key_pair"
  key_name   = "mongo-key-pair"
  public_key = "${file("~/.ssh/id_rsa.pub")}"
}

module "bastion" {
  source    = "./bastion"
  key_name  = "${module.key_pair.key_name}"
  vpc_id    = "${module.vpc.vpc_id}"
  subnet_id = "${module.vpc.public_subnet_ids[1]}"
}

module "mongodb_cluster" {
  source              = "./mongodb_cluster"
  key_name            = "${module.key_pair.key_name}"
  vpc_id              = "${module.vpc.vpc_id}"
  vpc_cidr_block      = "${module.vpc.vpc_cidr_block}"
  primary_node_type   = "${var.primary_node_type}"
  secondary_node_type = "${var.secondary_node_type}"
  private_subnet_ids  = "${module.vpc.private_subnet_ids}"
  bastion_public_ip   = "${module.bastion.bastion_public_ip}"
  replica_set_name    = "${var.replica_set_name}"
  num_secondary_nodes = "${var.num_secondary_nodes}"
  mongo_username      = "${var.mongo_username}"
  mongo_database      = "${var.mongo_database}"
  mongo_password      = "${var.mongo_password}"
}

resource "aws_ecs_cluster" "devops-cluster" {
  name = "devops-cluster" # Naming the cluster
  depends_on = [
    aws_vpc.main
  ]
}

resource "aws_ecs_cluster_capacity_providers" "cluster-cp" {
  
  cluster_name = aws_ecs_cluster.devops-cluster.name
  capacity_providers = ["FARGATE_SPOT", "FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
  }
  depends_on = [
    aws_ecs_cluster.devops-cluster
  ]
}


resource "aws_iam_role" "ecsTaskExecutionRole" {
  name_prefix               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs-autoscale-role" {
  name_prefix = "ecs-scale-application"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "application-autoscaling.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs-autoscale" {
  role = aws_iam_role.ecs-autoscale-role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
}
