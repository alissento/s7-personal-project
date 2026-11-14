# The CloudStack provider talks to EduCloud's API.
#
# Deliberately empty: the provider reads its credentials from environment
# variables, so no key can end up in this repo.
#   CLOUDSTACK_API_URL     https://<educloud-host>/client/api
#   CLOUDSTACK_API_KEY     your API key
#   CLOUDSTACK_SECRET_KEY  your secret key
# They are set by `source ~/.config/educloud/cloudstack.env` (see README.md).
provider "cloudstack" {}
