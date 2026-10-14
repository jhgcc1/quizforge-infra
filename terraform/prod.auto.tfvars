# Non-secret settings for the production environment (loaded automatically by terraform and by the pipeline).
# This account is on the AWS free plan, which caps RDS backup retention at 1 day.
db_backup_retention_days = 1

# Same judge as the CI evaluation (see variables.tf): production and CI scores come from one method.
minimax_judge_model = "MiniMax-M3"

# While the real login is being tried from http://localhost:13000 (scripts/local-cognito.sh), keep the separate localhost client.
# Set to false (or delete the line) when the testing is over: the production client never accepts a localhost redirect.
enable_local_dev_client = true
facebook_enabled        = true
google_enabled          = true
