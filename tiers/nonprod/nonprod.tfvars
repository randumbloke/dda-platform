# Tier nonprod values. Estate values (organisation, billing, project IDs, flags) are read from
# bootstrap/estate.json in the state bucket, never repeated here (design section 6.13.3).
tier            = "nonprod"
region          = "australia-southeast1"
tf_state_bucket = "tfstate-pltfrm-ngnrng"
