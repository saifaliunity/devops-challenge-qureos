provider "aws" {
  region  = "us-east-1"
  profile = "default"
}

data "aws_instance" "mongo-db-primay" {

  filter {
    name   = "tag:Name"
    values = ["Mongo-Primary"]
  }

depends_on = [
  module.mongodb_cluster
]
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

## Mongo Cluster

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

## NLB

resource "aws_lb" "network_load_balancer" {
  name               = "devops-cluster-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [module.vpc.public_subnet_ids[0], module.vpc.public_subnet_ids[1], module.vpc.public_subnet_ids[2]]
  enable_deletion_protection = false

  tags = {
    Environment = var.environment
  }
depends_on = [
  module.vpc.main
]
}


resource "aws_lb_listener" "nlb-listener" {
  load_balancer_arn = "${aws_lb.network_load_balancer.arn}" # Referencing our load balancer
  port              = "80"
  protocol          = "TCP"
  
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.nlb-tg.arn}" # Referencing our tagrte group
  }
  depends_on = [
    aws_lb_target_group.nlb-tg
  ]
}

## ECS Service

resource "aws_ecs_cluster" "devops-cluster" {
  name = "devops-cluster" # Naming the cluster
  depends_on = [
    module.vpc.main,
    module.mongo_cluster
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

## ECS Service


variable "devops-cluster-backend_service_container_port" {
  default = 8080
}

variable "devops-cluster-backend_service_container_name" {
  default = "devops-cluster-backend-service"
}

//"image": "${aws_ecr_repository.devops-cluster-backend-service-ecr.repository_url}",
resource "aws_ecs_task_definition" "devops-cluster-backend-service-task-defintion" {
  family                   = "devops-cluster-backend-service" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "${var.devops-cluster-backend_service_container_name}",
      "image": "omark0/qureos:mobilesearch",
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "secretOptions": null,
        "options": {
          "awslogs-group": "${aws_cloudwatch_log_group.devops-cluster-backend-service_cw_log_group.name}",
          "awslogs-region": "${var.region}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "environment": [
          {
              "name": "MONGODB_HOST",
              "value": "${data.aws_instance.mongo-db-primay.private_ip}"
          },
          {
              "name": "MONGODB_PORT",
              "value": "27017"
          }
      ],
      "portMappings": [
        {
          "protocol": "tcp",
          "containerPort": ${var.devops-cluster-backend_service_container_port}
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION

  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our container requires
  cpu                      = 256         # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn
  task_role_arn            = aws_iam_role.ecsTaskExecutionRole.arn
  depends_on = [
    aws_cloudwatch_log_group.devops-cluster-backend-service_cw_log_group
  ]
  # lifecycle {
  #   ignore_changes = [container_definitions]
  # }
}


resource "aws_cloudwatch_log_group" "devops-cluster-backend-service_cw_log_group" {
  name = "/ecs/devops-cluster-backend-cluster/devops-cluster-backend-service"
  tags = {
    Environment = var.environment
    Application = "devops-cluster-backend-serivce"
  }
}

resource "aws_lb_target_group" "nlb-tg" {
  name        = "devops-cluster-nlb-tg"
  protocol    = "TCP"
  target_type = "ip"
  deregistration_delay = 5
  connection_termination = true
  vpc_id      = module.vpc.vpc_id
  port = var.devops-cluster-backend_service_container_port
  health_check {
    protocol = "TCP"
    port = var.devops-cluster-backend_service_container_port
  }
depends_on = [
  module.vpc
]
}


resource "aws_security_group" "devops-cluster-backend-service_security_group" {
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    # Only allowing traffic in from the load balancer security group
    #security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
depends_on = [
  module.vpc
]
}


resource "aws_ecs_service" "devops-cluster-backend-service" {
  name            = "devops-cluster-backend-service"                             # Naming our first service
  cluster         = "${aws_ecs_cluster.devops-cluster.id}"             # Referencing our created Cluster
  task_definition = "${aws_ecs_task_definition.devops-cluster-backend-service-task-defintion.arn}" # Referencing the task our service will spin up
  #Place atleast 1 task as OD and for each 1:4 place rest autoscaling for each 1 OD to 4 SPOT
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight = 1
    base = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 4
  }
  
# Break the deployment if new tasks are not able to run and revert back to previous state

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  desired_count   = 1 # Setting the number of containers to 1
  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = "${aws_lb_target_group.nlb-tg.arn}" # Referencing our target group
    container_name   = "${aws_ecs_task_definition.devops-cluster-backend-service-task-defintion.family}"
    container_port   = "${var.devops-cluster-backend_service_container_port}" # Specifying the container port
  }

  network_configuration {
    subnets            = [module.vpc.private_subnet_ids[0], module.vpc.private_subnet_ids[1], module.vpc.private_subnet_ids[2]]
    assign_public_ip = false # Providing our containers with private IPs
    security_groups  = ["${aws_security_group.devops-cluster-backend-service_security_group.id}"] # Setting the security group
  }


  depends_on = [
    aws_ecs_cluster.devops-cluster,
    aws_lb.network_load_balancer,
    aws_lb_target_group.nlb-tg
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "devops-cluster-backend-service_ecs_target" {
  max_capacity       = 10
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.devops-cluster.name}/${aws_ecs_service.devops-cluster-backend-service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  role_arn           = aws_iam_role.ecs-autoscale-role.arn
}


resource "aws_appautoscaling_policy" "ecs_target_cpu-devops-cluster-backend" {
  name               = "application-scaling-policy-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 80
  }
  depends_on = [aws_appautoscaling_target.devops-cluster-backend-service_ecs_target]
}
resource "aws_appautoscaling_policy" "ecs_target_memory-devops-cluster-backend" {
  name               = "application-scaling-policy-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.devops-cluster-backend-service_ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value = 80
  }
  depends_on = [aws_appautoscaling_target.devops-cluster-backend-service_ecs_target]
}
