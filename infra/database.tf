resource "aws_db_subnet_group" "sonarqube" {
  name       = "sonarqube"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]
}

resource "aws_rds_cluster" "sonarqube" {
  cluster_identifier        = "sonarqube"
  engine                    = "aurora-postgresql"
  engine_version            = "17.11"
  database_name             = "sonarqube"
  master_username           = "sonarqube"
  master_password           = random_password.db.result
  db_subnet_group_name      = aws_db_subnet_group.sonarqube.name
  vpc_security_group_ids    = [aws_security_group.database.id]
  storage_encrypted         = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "sonarqube-final"
  copy_tags_to_snapshot     = true

  lifecycle {
    ignore_changes = [engine_version]
  }

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 2
    seconds_until_auto_pause = 300
  }
}

resource "aws_rds_cluster_instance" "sonarqube" {
  identifier          = "sonarqube"
  cluster_identifier  = aws_rds_cluster.sonarqube.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.sonarqube.engine
  engine_version      = aws_rds_cluster.sonarqube.engine_version
  publicly_accessible = false

  lifecycle {
    ignore_changes = [engine_version]
  }
}
