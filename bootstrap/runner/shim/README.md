# Shim scripts

Location in the runner image: `/opt/dda/shim` (`$DDA_SHIM_DIR`).

The data domain module (`modules/data_domain_shim/{domain,binding}`, owned by the modules draft)
makes its REST calls with `curl` and `jq` from `local-exec` (design §2.3.2). If it needs helper
scripts at a fixed path in the image, they go in this folder as `*.sh` and are copied into the
image at build time. The folder is empty until the module draft asks for one.
