############################ Pause / resume ############################
# What `paused = true` does (everything is kept: data, secrets, users, DNS names, configuration):
#   - ECS services scale to 0                      (aws_appautoscaling_target, ecs.tf)
#   - the RDS instance is STOPPED                  (this file; storage is kept and still billed, compute is not)
#   - the NAT gateway and its Elastic IP are removed (network.tf)
#   - the sweeper schedule is disabled             (observability.tf)
#   - the load balancer, its listener and rules, and the WAF web ACL are DELETED (edge.tf); CloudFront stays (idle it is free)
# Still billed while paused (about US$8 a month): RDS storage, KMS keys, secrets, log storage, ECR images.
# Resume recreates the load balancer and the WAF (a CloudFront update of ~10 minutes is part of it).
# AWS restarts a stopped RDS instance by itself after 7 days: run scripts/pause.sh again if you stay paused longer.

resource "terraform_data" "db_power" {
  triggers_replace = [var.paused]

  provisioner "local-exec" {
    interpreter = ["bash", "-ec"]
    command     = <<-EOT
      id=${aws_db_instance.main.identifier}; r=${var.region}
      status() { aws rds describe-db-instances --region "$r" --db-instance-identifier "$id" --query 'DBInstances[0].DBInstanceStatus' --output text; }
      if [ "${var.paused}" = "true" ]; then
        if [ "$(status)" = "available" ]; then aws rds stop-db-instance --region "$r" --db-instance-identifier "$id" >/dev/null; echo "stopping $id"; fi
      else
        for i in $(seq 1 60); do                       # up to ~15 min: a database that is still stopping must finish first
          case "$(status)" in
            stopped) aws rds start-db-instance --region "$r" --db-instance-identifier "$id" >/dev/null; echo "starting $id" ;;
            available) break ;;
          esac
          sleep 15
        done
        aws rds wait db-instance-available --region "$r" --db-instance-identifier "$id"
      fi
    EOT
  }
}
