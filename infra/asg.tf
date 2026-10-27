data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "sonarqube" {
  name     = "sonarqube"
  image_id = data.aws_ssm_parameter.al2023.value
  user_data = base64encode(<<-EOT
    #!/bin/bash
    export DB_HOST='${aws_rds_cluster.sonarqube.endpoint}'
    export SONAR_JDBC_URL='jdbc:postgresql://${aws_rds_cluster.sonarqube.endpoint}:5432/${aws_rds_cluster.sonarqube.database_name}'
    export SONAR_JDBC_USERNAME='${aws_rds_cluster.sonarqube.master_username}'
    export SONARQUBE_IMAGE='sonarqube:26.10.0.133078-community'
    export IDLE_CHECK_B64='${filebase64("${path.module}/../instance/idle_check.py")}'
    ${file("${path.module}/../instance/boot.sh")}
  EOT
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted             = true
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = ["volume", "network-interface"]

    content {
      resource_type = tag_specifications.value
      tags          = { Project = "sonarqube" }
    }
  }
}

resource "aws_autoscaling_group" "sonarqube" {
  name                = "sonarqube"
  min_size            = 0
  max_size            = 1
  capacity_rebalance  = false
  vpc_zone_identifier = [for subnet in aws_subnet.public : subnet.id]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.sonarqube.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = ["t3.medium", "t3a.medium", "t2.medium", "t3.large", "t3a.large", "c7i-flex.large"]

        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Project"
    value               = "sonarqube"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
