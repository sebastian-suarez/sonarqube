mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az3"]
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/acceptance"
      user_id    = "ACCEPTANCE"
    }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-00000000000000001" }
  }
  mock_resource "aws_internet_gateway" {
    defaults = { id = "igw-00000000000000001" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-00000000000000001" }
  }
  mock_resource "aws_autoscaling_group" {
    defaults = { arn = "arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:00000000-0000-0000-0000-000000000001:autoScalingGroupName/sonarqube" }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { endpoint = "sonarqube.cluster-acceptance.us-east-1.rds.amazonaws.com" }
  }
  mock_resource "aws_iam_access_key" {
    defaults = {
      id     = "AKIDACCEPTANCEONLY"
      secret = "acceptance-aws-secret-do-not-render"
    }
  }
}
mock_provider "cloudflare" {
  mock_resource "cloudflare_zero_trust_tunnel_cloudflared" {
    defaults = { id = "00000000-0000-4000-8000-000000000001" }
  }
  mock_data "cloudflare_zero_trust_tunnel_cloudflared_token" {
    defaults = { token = "acceptance-tunnel-token-do-not-render" }
  }
}
mock_provider "random" {}

override_resource {
  target = aws_route_table.public
  values = { id = "rtb-00000000000000001" }
}
override_resource {
  target = aws_route_table.private
  values = { id = "rtb-00000000000000002" }
}
override_resource {
  target = random_password.db
  values = { result = "acceptance-db-password-do-not-render" }
}
override_resource {
  target = random_password.admin
  values = { result = "acceptance-admin-password-do-not-render" }
}
override_resource {
  target = random_password.wake
  values = { result = "acceptance-wake-key-do-not-render-0123456789" }
}
override_resource {
  target = random_bytes.jwt
  values = { base64 = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" }
}
override_resource {
  target = aws_security_group.instance
  values = { id = "sg-00000000000000001" }
}
override_resource {
  target = aws_security_group.database
  values = { id = "sg-00000000000000002" }
}
override_resource {
  target = aws_subnet.public["us-east-1a"]
  values = { id = "subnet-00000000000000001" }
}
override_resource {
  target = aws_subnet.public["us-east-1b"]
  values = { id = "subnet-00000000000000002" }
}
override_resource {
  target = aws_subnet.public["us-east-1c"]
  values = { id = "subnet-00000000000000003" }
}
override_resource {
  target = aws_subnet.private["us-east-1a"]
  values = { id = "subnet-00000000000000011" }
}
override_resource {
  target = aws_subnet.private["us-east-1b"]
  values = { id = "subnet-00000000000000012" }
}
override_resource {
  target = aws_subnet.private["us-east-1c"]
  values = { id = "subnet-00000000000000013" }
}

variables {
  cloudflare_account_id = "00000000000000000000000000000001"
  cloudflare_zone_id    = "00000000000000000000000000000002"
}

run "A3_A4_single_instance_and_unmanaged_desired_capacity" {
  command = plan
  assert {
    condition = (
      aws_autoscaling_group.sonarqube.name == "sonarqube" &&
      aws_autoscaling_group.sonarqube.min_size == 0 &&
      aws_autoscaling_group.sonarqube.max_size == 1 &&
      aws_autoscaling_group.sonarqube.capacity_rebalance == false
    )
    error_message = "A4: group must allow zero or one instance without capacity rebalancing."
  }
  assert {
    condition = (
      aws_autoscaling_group.sonarqube.name == "sonarqube" &&
      can(regex("ignore_changes\\s*=\\s*\\[[^]]*\\bdesired_capacity\\b[^]]*\\]", file("asg.tf"))) &&
      length(regexall("(?m)^\\s*desired_capacity\\s*=", file("asg.tf"))) == 0
    )
    error_message = "A4: asg.tf must ignore desired_capacity and must not assign it."
  }
}

run "A5_spot_policy_and_exact_instance_types" {
  command = plan
  assert {
    condition = (
      aws_autoscaling_group.sonarqube.mixed_instances_policy[0].instances_distribution[0].on_demand_base_capacity == 0 &&
      aws_autoscaling_group.sonarqube.mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 0 &&
      aws_autoscaling_group.sonarqube.mixed_instances_policy[0].instances_distribution[0].spot_allocation_strategy == "price-capacity-optimized" &&
      toset([for item in aws_autoscaling_group.sonarqube.mixed_instances_policy[0].launch_template[0].override : item.instance_type]) == toset(["t3.medium", "t3a.medium", "t2.medium", "t3.large", "t3a.large", "c7i-flex.large"]) &&
      length(aws_autoscaling_group.sonarqube.mixed_instances_policy[0].launch_template[0].override) == 6 &&
      aws_autoscaling_group.sonarqube.mixed_instances_policy[0].launch_template[0].launch_template_specification[0].launch_template_id == aws_launch_template.sonarqube.id
    )
    error_message = "A5: Spot only, price-capacity-optimized, exactly the six frozen instance types."
  }
}

run "A6_public_subnet_in_each_available_az" {
  command = plan
  assert {
    condition = (
      data.aws_availability_zones.available.state == "available" &&
      anytrue([for filter in data.aws_availability_zones.available.filter : filter.name == "opt-in-status" && toset(filter.values) == toset(["opt-in-not-required"])]) &&
      toset(keys(aws_subnet.public)) == toset(data.aws_availability_zones.available.names) &&
      toset(aws_autoscaling_group.sonarqube.vpc_zone_identifier) == toset([for subnet in aws_subnet.public : subnet.id]) &&
      alltrue([for az, subnet in aws_subnet.public : subnet.availability_zone == az && subnet.map_public_ip_on_launch && subnet.vpc_id == aws_vpc.main.id]) &&
      alltrue([for az, association in aws_route_table_association.public : association.subnet_id == aws_subnet.public[az].id && association.route_table_id == aws_route_table.public.id]) &&
      toset(keys(aws_route_table_association.public)) == toset(keys(aws_subnet.public)) &&
      anytrue([for route in aws_route_table.public.route : route.cidr_block == "0.0.0.0/0" && route.gateway_id == aws_internet_gateway.main.id])
    )
    error_message = "A6: every available, opt-in-not-required AZ must have an associated public subnet in the group."
  }
}

run "A7_hardened_launch_template" {
  command = plan
  assert {
    condition = (
      data.aws_ssm_parameter.al2023.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" &&
      aws_launch_template.sonarqube.image_id == data.aws_ssm_parameter.al2023.value &&
      aws_launch_template.sonarqube.metadata_options[0].http_tokens == "required" &&
      (aws_launch_template.sonarqube.key_name == null || aws_launch_template.sonarqube.key_name == "") &&
      aws_launch_template.sonarqube.network_interfaces[0].associate_public_ip_address == "true" &&
      toset(aws_launch_template.sonarqube.network_interfaces[0].security_groups) == toset([aws_security_group.instance.id]) &&
      length(aws_security_group.instance.ingress) == 0 &&
      length(aws_launch_template.sonarqube.block_device_mappings) == 1 &&
      aws_launch_template.sonarqube.block_device_mappings[0].device_name == "/dev/xvda" &&
      aws_launch_template.sonarqube.block_device_mappings[0].ebs[0].encrypted == "true" &&
      aws_launch_template.sonarqube.block_device_mappings[0].ebs[0].volume_type == "gp3" &&
      aws_launch_template.sonarqube.block_device_mappings[0].ebs[0].delete_on_termination == "true"
    )
    error_message = "A7: AL2023 x86_64, IMDSv2, no SSH key/ingress, public IPv4 and disposable encrypted gp3 root."
  }
  assert {
    condition     = length(aws_security_group.instance.ingress) == 0 && length(regexall("resource\\s+\"(aws_vpc_security_group_ingress_rule|aws_security_group_rule|aws_route)\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 0
    error_message = "A6/A7/A8: use inline SG ingress and route-table routes so their complete policies are inspectable."
  }
}

run "A8_private_aurora_17_autopause_and_data_guards" {
  command = plan
  assert {
    condition = (
      aws_rds_cluster.sonarqube.engine == "aurora-postgresql" &&
      startswith(aws_rds_cluster.sonarqube.engine_version, "17.") &&
      aws_rds_cluster.sonarqube.serverlessv2_scaling_configuration[0].min_capacity == 0 &&
      aws_rds_cluster.sonarqube.serverlessv2_scaling_configuration[0].max_capacity == 2 &&
      aws_rds_cluster.sonarqube.serverlessv2_scaling_configuration[0].seconds_until_auto_pause == 300 &&
      aws_rds_cluster.sonarqube.storage_encrypted &&
      aws_rds_cluster.sonarqube.deletion_protection &&
      !aws_rds_cluster.sonarqube.skip_final_snapshot &&
      aws_rds_cluster_instance.sonarqube.instance_class == "db.serverless" &&
      !aws_rds_cluster_instance.sonarqube.publicly_accessible &&
      contains([aws_rds_cluster.sonarqube.id, aws_rds_cluster.sonarqube.cluster_identifier], aws_rds_cluster_instance.sonarqube.cluster_identifier) &&
      aws_rds_cluster.sonarqube.db_subnet_group_name == aws_db_subnet_group.sonarqube.name &&
      toset(aws_rds_cluster.sonarqube.vpc_security_group_ids) == toset([aws_security_group.database.id])
    )
    error_message = "A8: one private Aurora PostgreSQL 17.x serverless instance, 0..2 ACU, 300s pause and deletion guards."
  }
  assert {
    condition = (
      length(regexall("resource\\s+\"aws_rds_cluster_instance\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 1 &&
      toset(aws_db_subnet_group.sonarqube.subnet_ids) == toset([for subnet in aws_subnet.private : subnet.id]) &&
      length(aws_subnet.private) >= 2 &&
      alltrue([for subnet in aws_subnet.private : !subnet.map_public_ip_on_launch && subnet.vpc_id == aws_vpc.main.id]) &&
      toset(keys(aws_route_table_association.private)) == toset(keys(aws_subnet.private)) &&
      alltrue([for az, association in aws_route_table_association.private : association.subnet_id == aws_subnet.private[az].id && association.route_table_id == aws_route_table.private.id]) &&
      alltrue([for route in aws_route_table.private.route : route.gateway_id == null || route.gateway_id == ""]) &&
      length(aws_security_group.database.ingress) == 1 &&
      alltrue([for rule in aws_security_group.database.ingress : rule.protocol == "tcp" && rule.from_port == 5432 && rule.to_port == 5432 && toset(rule.security_groups) == toset([aws_security_group.instance.id]) && length(rule.cidr_blocks) == 0 && length(rule.ipv6_cidr_blocks) == 0 && !rule.self])
    )
    error_message = "A8: database subnets cannot route to an IGW; only the instance SG may reach TCP 5432."
  }
}

run "A9_worker_iam_exactly_one_scoped_action_and_key" {
  command = plan
  assert {
    condition = (
      aws_iam_user_policy.worker.user == aws_iam_user.worker.name &&
      aws_iam_access_key.worker.user == aws_iam_user.worker.name &&
      length(jsondecode(aws_iam_user_policy.worker.policy).Statement) == 1 &&
      alltrue([for statement in jsondecode(aws_iam_user_policy.worker.policy).Statement : statement.Effect == "Allow" && toset(statement.Action) == toset(["autoscaling:SetDesiredCapacity"]) && toset(statement.Resource) == toset([aws_autoscaling_group.sonarqube.arn]) && !contains(keys(statement), "NotAction") && !contains(keys(statement), "NotResource")]) &&
      length(regexall("resource\\s+\"aws_iam_access_key\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 1 &&
      length(regexall("resource\\s+\"aws_iam_user_policy\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 1
    )
    error_message = "A9: Worker has one key and one Allow statement scoped to this ASG's SetDesiredCapacity."
  }
}

run "A10_instance_iam_has_no_managed_or_overbroad_policies" {
  command = plan
  assert {
    condition = (
      contains([aws_iam_role.instance.id, aws_iam_role.instance.name], aws_iam_role_policy.instance.role) &&
      length(jsondecode(aws_iam_role_policy.instance.policy).Statement) == 3 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.instance.policy).Statement : statement.Effect == "Allow" && !contains(keys(statement), "NotAction") && !contains(keys(statement), "NotResource") && (
        (toset(statement.Action) == toset(["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]) && toset(statement.Resource) == toset(["*"])) ||
        (toset(statement.Action) == toset(["ssm:GetParameter", "ssm:GetParameters"]) && toset(statement.Resource) == toset(["arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/sonarqube/*"])) ||
        (toset(statement.Action) == toset(["autoscaling:SetDesiredCapacity"]) && toset(statement.Resource) == toset([aws_autoscaling_group.sonarqube.arn]))
      )]) &&
      toset(flatten([for statement in jsondecode(aws_iam_role_policy.instance.policy).Statement : statement.Action])) == toset(["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel", "ssm:GetParameter", "ssm:GetParameters", "autoscaling:SetDesiredCapacity"]) &&
      length(regexall("resource\\s+\"aws_iam_(role_policy_attachment|user_policy_attachment|policy_attachment)\"|managed_policy_arns\\s*=|inline_policy\\s*\\{|AmazonSSMManagedInstanceCore", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 0 &&
      length(regexall("resource\\s+\"aws_iam_role_policy\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 1
    )
    error_message = "A10: exactly the three scoped inline permission groups, no managed policy attachments."
  }
}

run "A11_tunnel_dns_route_and_worker_bindings" {
  command = plan
  assert {
    condition = (
      length(cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube.config.ingress) == 2 &&
      cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube.tunnel_id == cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id &&
      cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube.config.ingress[0].hostname == "sonar.sebastiansuarez.dev" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube.config.ingress[0].service == "http://localhost:9000" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.sonarqube.config.ingress[1].service == "http_status:404" &&
      cloudflare_dns_record.sonar.type == "CNAME" &&
      contains(["sonar", "sonar.sebastiansuarez.dev"], cloudflare_dns_record.sonar.name) &&
      cloudflare_dns_record.sonar.content == "${cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id}.cfargotunnel.com" &&
      cloudflare_dns_record.sonar.proxied &&
      cloudflare_workers_route.sonar.pattern == "sonar.sebastiansuarez.dev/*" &&
      cloudflare_workers_route.sonar.script == cloudflare_workers_script.sonarqube.script_name
    )
    error_message = "A11: hostname -> Worker -> tunnel -> localhost:9000, with terminal 404 ingress."
  }
  assert {
    condition = (
      toset([for binding in cloudflare_workers_script.sonarqube.bindings : binding.name if binding.type == "secret_text"]) == toset(["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "WAKE_KEY", "JWT_SECRET"]) &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "AWS_ACCESS_KEY_ID" && binding.type == "secret_text"]) == aws_iam_access_key.worker.id &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "AWS_SECRET_ACCESS_KEY" && binding.type == "secret_text"]) == aws_iam_access_key.worker.secret &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "ASG_NAME" && binding.type == "plain_text"]) == "sonarqube" &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "AWS_REGION" && binding.type == "plain_text"]) == "us-east-1"
    )
    error_message = "A11: four secret bindings and plain ASG_NAME/AWS_REGION, with the scoped IAM key."
  }
}

run "A12_secure_parameters_and_shared_random_values" {
  command = apply
  assert {
    condition = (
      aws_ssm_parameter.db_password.name == "/sonarqube/db-password" &&
      aws_ssm_parameter.admin_password.name == "/sonarqube/admin-password" &&
      aws_ssm_parameter.tunnel_token.name == "/sonarqube/tunnel-token" &&
      aws_ssm_parameter.wake_key.name == "/sonarqube/wake-key" &&
      aws_ssm_parameter.jwt_secret.name == "/sonarqube/jwt-secret" &&
      alltrue([for parameter in [aws_ssm_parameter.db_password, aws_ssm_parameter.admin_password, aws_ssm_parameter.tunnel_token, aws_ssm_parameter.wake_key, aws_ssm_parameter.jwt_secret] : parameter.type == "SecureString"]) &&
      aws_ssm_parameter.db_password.value == random_password.db.result &&
      aws_ssm_parameter.admin_password.value == random_password.admin.result &&
      aws_ssm_parameter.wake_key.value == random_password.wake.result &&
      random_password.wake.length >= 32 &&
      aws_ssm_parameter.jwt_secret.value == random_bytes.jwt.base64 &&
      random_bytes.jwt.length == 32 &&
      aws_ssm_parameter.tunnel_token.value == data.cloudflare_zero_trust_tunnel_cloudflared_token.sonarqube.token &&
      data.cloudflare_zero_trust_tunnel_cloudflared_token.sonarqube.tunnel_id == cloudflare_zero_trust_tunnel_cloudflared.sonarqube.id &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "WAKE_KEY"]) == aws_ssm_parameter.wake_key.value &&
      one([for binding in cloudflare_workers_script.sonarqube.bindings : binding.text if binding.name == "JWT_SECRET"]) == aws_ssm_parameter.jwt_secret.value
    )
    error_message = "A12: all five SecureStrings have the specified random/tunnel provenance and shared Worker values."
  }
  assert {
    condition = (
      random_bytes.jwt.length == 32 &&
      can(regex("source\\s*=\\s*\"hashicorp/aws\"\\s+version\\s*=\\s*\"6\\.70\\.0\"", file("providers.tf"))) &&
      can(regex("source\\s*=\\s*\"cloudflare/cloudflare\"\\s+version\\s*=\\s*\"5\\.28\\.1\"", file("providers.tf"))) &&
      can(regex("source\\s*=\\s*\"hashicorp/random\"\\s+version\\s*=\\s*\"3\\.9\\.1\"", file("providers.tf")))
    )
    error_message = "Offline contract: exact provider pins in providers.tf: aws 6.70.0, cloudflare 5.28.1, random 3.9.1."
  }
}

run "A13_tagged_monthly_budget_and_notifications" {
  command = plan
  assert {
    condition = (
      aws_budgets_budget.sonarqube.budget_type == "COST" &&
      tonumber(aws_budgets_budget.sonarqube.limit_amount) == 10 &&
      aws_budgets_budget.sonarqube.limit_unit == "USD" &&
      aws_budgets_budget.sonarqube.time_unit == "MONTHLY" &&
      anytrue([for filter in aws_budgets_budget.sonarqube.cost_filter : filter.name == "TagKeyValue" && toset(filter.values) == toset(["user:Project$sonarqube"])]) &&
      length(aws_budgets_budget.sonarqube.notification) == 2 &&
      toset([for notification in aws_budgets_budget.sonarqube.notification : notification.notification_type]) == toset(["ACTUAL", "FORECASTED"]) &&
      alltrue([for notification in aws_budgets_budget.sonarqube.notification : notification.comparison_operator == "GREATER_THAN" && notification.threshold == 100 && notification.threshold_type == "PERCENTAGE" && toset(notification.subscriber_email_addresses) == toset(["aws@sebastiansuarez.dev"])]) &&
      length(regexall("resource\\s+\"aws_ce_cost_allocation_tag\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 0 &&
      length(regexall("resource\\s+\"aws_ce_cost_allocation_tag\"", join("\n", [for path in fileset("bootstrap", "*.tf") : file("bootstrap/${path}")]))) == 0
    )
    error_message = "A13: $10/month Project tag COST budget, 100% actual/forecast emails and no cost allocation tag resource in either root."
  }
}

run "A14_main_backend_native_lock_and_region" {
  command = plan
  assert {
    condition = (
      aws_autoscaling_group.sonarqube.name == "sonarqube" &&
      can(regex("(?s)backend\\s+\"s3\"\\s*\\{[^}]*use_lockfile\\s*=\\s*true", file("backend.tf"))) &&
      can(regex("(?s)backend\\s+\"s3\"\\s*\\{[^}]*region\\s*=\\s*\"us-east-1\"", file("backend.tf"))) &&
      can(regex("(?s)backend\\s+\"s3\"\\s*\\{[^}]*profile\\s*=\\s*\"sonarqube\"", file("backend.tf"))) &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*profile\\s*=\\s*\"sonarqube\"[^}]*default_tags\\s*\\{", file("providers.tf"))) &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*allowed_account_ids\\s*=\\s*\\[\\s*\"368861736633\"\\s*\\][^}]*default_tags\\s*\\{", file("providers.tf")))
    )
    error_message = "A14: S3 backend must use native lockfile, us-east-1 and profile sonarqube; AWS provider must set profile sonarqube and allowed_account_ids [368861736633] before default_tags."
  }
}

run "A15_aws_region_and_default_project_tag" {
  command = plan
  assert {
    condition     = anytrue([for tag in aws_autoscaling_group.sonarqube.tag : tag.key == "Project" && tag.value == "sonarqube" && tag.propagate_at_launch])
    error_message = "A15: ASG requires an explicit propagated Project tag because default_tags does not cover it."
  }
  assert {
    condition = (
      aws_autoscaling_group.sonarqube.name == "sonarqube" &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*region\\s*=\\s*\"us-east-1\"", file("providers.tf"))) &&
      can(regex("(?s)provider\\s+\"aws\"\\s*\\{[^}]*default_tags\\s*\\{\\s*tags\\s*=\\s*\\{[^}]*Project\\s*=\\s*\"sonarqube\"", file("providers.tf")))
    )
    error_message = "A15: AWS provider must use us-east-1 and default_tags Project=sonarqube."
  }
}

run "A16_public_subnet_bpa_exclusions" {
  command = plan
  assert {
    condition = (
      toset(keys(aws_vpc_block_public_access_exclusion.public)) == toset(keys(aws_subnet.public)) &&
      alltrue([for az, exclusion in aws_vpc_block_public_access_exclusion.public : exclusion.subnet_id == aws_subnet.public[az].id && exclusion.vpc_id == null && exclusion.internet_gateway_exclusion_mode == "allow-bidirectional" && !contains([for subnet in aws_subnet.private : subnet.id], exclusion.subnet_id)]) &&
      length(regexall("resource\\s+\"aws_vpc_block_public_access_exclusion\"", join("\n", [for path in fileset(".", "*.tf") : file(path)]))) == 1
    )
    error_message = "A16: exactly the public subnet map must have subnet-only allow-bidirectional exclusions; no private subnet or VPC exclusion."
  }
}

run "A17_tag_based_resource_group" {
  command = plan
  assert {
    condition = (
      aws_resourcegroups_group.sonarqube.name == "sonarqube" &&
      aws_resourcegroups_group.sonarqube.resource_query[0].type == "TAG_FILTERS_1_0" &&
      jsondecode(aws_resourcegroups_group.sonarqube.resource_query[0].query) == {
        ResourceTypeFilters = ["AWS::AllSupported"]
        TagFilters          = [{ Key = "Project", Values = ["sonarqube"] }]
      }
    )
    error_message = "A17: Resource Group sonarqube must use TAG_FILTERS_1_0 for AWS::AllSupported with Project=sonarqube."
  }
}

run "F1_rendered_boot_configuration" {
  command = plan
  assert {
    condition = (
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/etc/sysctl.d/99-sonarqube.conf") &&
      can(regex("vm\\.max_map_count\\s*=\\s*524288", base64decode(aws_launch_template.sonarqube.user_data))) &&
      can(regex("fs\\.file-max\\s*=\\s*131072", base64decode(aws_launch_template.sonarqube.user_data))) &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "sysctl --system") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "ssm get-parameter") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "--with-decryption") &&
      alltrue([for name in ["db-password", "admin-password", "tunnel-token", "jwt-secret"] : strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/sonarqube/${name}")]) &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "timeout 180") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/dev/tcp/") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/5432") &&
      can(regex("(?s)timeout 180.*?/dev/tcp/.*?/5432.*?systemctl start sonarqube", base64decode(aws_launch_template.sonarqube.user_data))) &&
      length(regexall("systemctl (enable --now|restart|start) sonarqube(\\s|$)", base64decode(aws_launch_template.sonarqube.user_data))) == 1 &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "sonarqube:26.10.0.133078-community") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "jdbc:postgresql://${aws_rds_cluster.sonarqube.endpoint}:5432/") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "sonar.auth.jwtBase64Hs256Secret") &&
      can(regex("(?s)sonar\\.auth\\.jwtBase64Hs256Secret[^\\n]*JWT_SECRET", base64decode(aws_launch_template.sonarqube.user_data))) &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "%h %l %reqAttribute{LOGIN} [%t{dd/MMM/yyyy:HH:mm:ss Z}] \"%r\" %s %b \"%i{User-Agent}\"")
    )
    error_message = "F1: persistent sysctls, runtime SSM, bounded DB wait, pinned image, writer JDBC URL, session key and shared log format."
  }
  assert {
    condition = (
      tonumber(regex("--stop-timeout[= ]+([0-9]+)", base64decode(aws_launch_template.sonarqube.user_data))[0]) >= 120 &&
      tonumber(regex("TimeoutStopSec=([0-9]+)", base64decode(aws_launch_template.sonarqube.user_data))[0]) > tonumber(regex("--stop-timeout[= ]+([0-9]+)", base64decode(aws_launch_template.sonarqube.user_data))[0]) &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "OnBootSec=5min") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "OnUnitActiveSec=5min") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "ExecStart=/usr/bin/python3 /usr/local/bin/idle_check.py") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/var/log/sonarqube/access.log") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "/run/sonarqube/admin-password") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "systemctl enable --now sonarqube-idle.timer") &&
      can(regex("(?s)cloudflared[^\\n]*--token[= ]+[^\\n]*TUNNEL_TOKEN", base64decode(aws_launch_template.sonarqube.user_data)))
    )
    error_message = "F1: clean container shutdown, 5-minute idle timer, runtime tunnel token."
  }
}

run "F2_no_secrets_rendered_in_user_data" {
  command = apply
  assert {
    condition = alltrue([for secret in [
      random_password.db.result, random_password.admin.result, random_password.wake.result,
      random_bytes.jwt.base64, data.cloudflare_zero_trust_tunnel_cloudflared_token.sonarqube.token,
      aws_iam_access_key.worker.id, aws_iam_access_key.worker.secret
    ] : !strcontains(base64decode(aws_launch_template.sonarqube.user_data), secret)])
    error_message = "F2: user data must contain no mock secret; read secrets at boot."
  }
}

run "F3_verified_localhost_admin_gate_before_tunnel" {
  command = plan
  assert {
    condition = (
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "http://localhost:9000/api/system/status") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "http://localhost:9000/api/authentication/validate") &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), "http://localhost:9000/api/users/change_password") &&
      can(regex("(?s)admin_authenticates\\(\\)\\s*\\{.*?valid.*?true.*?\\n\\}", base64decode(aws_launch_template.sonarqube.user_data))) &&
      can(regex("(?s)change_admin_password\\(\\)\\s*\\{.*?previousPassword.*?admin.*?password.*?ADMIN_PASSWORD.*?\\n\\}", base64decode(aws_launch_template.sonarqube.user_data))) &&
      strcontains(base64decode(aws_launch_template.sonarqube.user_data), <<-GATE
if admin_authenticates admin; then
  change_admin_password || { echo "admin password change failed" >&2; exit 1; }
fi
if admin_authenticates "$ADMIN_PASSWORD" && ! admin_authenticates admin; then
  systemctl start cloudflared
else
  echo "admin bootstrap verification failed; cloudflared remains stopped" >&2
fi
GATE
      ) &&
      length(regexall("systemctl start cloudflared", base64decode(aws_launch_template.sonarqube.user_data))) == 1 &&
      length(regexall("systemctl (enable --now|restart|start) cloudflared", base64decode(aws_launch_template.sonarqube.user_data))) == 1 &&
      can(regex("(?s)systemctl enable --now sonarqube-idle\\.timer.*?http://localhost:9000/api/system/status.*?UP.*?if admin_authenticates admin; then", base64decode(aws_launch_template.sonarqube.user_data)))
    )
    error_message = "F3: after UP, change default credentials if valid, verify SSM password AND default rejection, otherwise keep tunnel stopped and log."
  }
}
