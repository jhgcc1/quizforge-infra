output "state_bucket" { value = aws_s3_bucket.state.id }
output "ecr_repository_urls" { value = { for k, r in aws_ecr_repository.svc : k => r.repository_url } }
output "gha_plan_role_arn" { value = aws_iam_role.plan.arn }
output "gha_deploy_role_arn" { value = aws_iam_role.deploy.arn }
output "region" { value = var.region }
output "backend_hcl" {
  description = "Contents for infra/terraform/backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "${var.project}/prod/terraform.tfstate"
    region       = "${var.region}"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
  EOT
}
