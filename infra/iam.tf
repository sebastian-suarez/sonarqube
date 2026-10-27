data "aws_caller_identity" "current" {}

resource "aws_iam_role" "instance" {
  name = "sonarqube-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "instance" {
  name = "sonarqube-instance"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/sonarqube/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:SetDesiredCapacity"]
        Resource = [aws_autoscaling_group.sonarqube.arn]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "sonarqube-instance"
  role = aws_iam_role.instance.name
}

resource "aws_iam_user" "worker" {
  name = "sonarqube-worker"
}

resource "aws_iam_user_policy" "worker" {
  name = "sonarqube-worker"
  user = aws_iam_user.worker.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["autoscaling:SetDesiredCapacity"]
      Resource = [aws_autoscaling_group.sonarqube.arn]
    }]
  })
}

resource "aws_iam_access_key" "worker" {
  user = aws_iam_user.worker.name
}
