# dev values (design sections 6.16, 6.17). Estate values are read from bootstrap/estate.json.
env             = "dev"
tier            = "nonprod"
region          = "australia-southeast1"
tf_state_bucket = "tfstate-pltfrm-ngnrng"

# Phase 1 (design section 6.17).
components = {
  classifier          = false
  steward_inbox       = false
  access_request_gate = false
  reconciler          = false
  explainer           = false
  scan_generator      = false
  sdp_notifications   = false
  access_request_sink = false
  data_access_sink    = false
  policy_tags         = false
  evaluator_modules   = ["c12", "c14"]
}

audit_log_retention_days = 400
notification_channels    = []
