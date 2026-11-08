terraform {
  # Empty on purpose: the build passes -backend-config=state.config (design section 6.8).
  backend "gcs" {}
}
