/**
 GCS backend, configured from state.config (design §6.8):
   terraform init -backend-config=state.config

 The state bucket is created by this stack's first apply, so the very first stage 1 apply runs
 with local state and migrates it afterwards. See README.md, "First apply".
 */

terraform {
  backend "gcs" {}
}
