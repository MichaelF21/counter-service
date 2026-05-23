# Remote state lives in the S3 bucket created by infra/bootstrap.
# Run `terraform init -reconfigure -backend-config="bucket=<bootstrap-output>"`.
# Locking uses S3 conditional writes (.tflock object); no DynamoDB needed
# since Terraform 1.10.
terraform {
  backend "s3" {
    bucket       = "counter-service-tfstate-630943284793-eu-west-2"
    key          = "counter-service/prod/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
