resource "aws_resourcegroups_group" "sonarqube" {
  name = "sonarqube"

  resource_query {
    type = "TAG_FILTERS_1_0"
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [{
        Key    = "Project"
        Values = ["sonarqube"]
      }]
    })
  }
}
