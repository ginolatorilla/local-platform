resource "vault_kv_secret_backend_v2" "apps" {
  mount = vault_mount.apps.path
}

resource "vault_mount" "apps" {
  path        = "apps"
  type        = "kv-v2"
  description = "Contains secrets used by applications"
  options = {
    version = "2"
    type    = "kv-v2"
  }
}

resource "vault_kv_secret_backend_v2" "user" {
  mount = vault_mount.user.path
}

resource "vault_mount" "user" {
  path        = "user"
  type        = "kv-v2"
  description = "Contains secrets that belong to users"
  options = {
    version = "2"
    type    = "kv-v2"
  }
}
