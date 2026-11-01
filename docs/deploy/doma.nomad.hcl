# Nomad job for doma: one task, one host volume for the database, the photos
# and the key files. Register the volume as "doma" on the client; Traefik
# (traefik.yaml) terminates TLS and routes the public hostname here.
job "doma" {
  datacenters = ["dc1"]
  type        = "service"

  group "doma" {
    count = 1

    volume "data" {
      type   = "host"
      source = "doma"
    }

    network {
      port "http" {
        to = 8080
      }
    }

    service {
      name = "doma"
      port = "http"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.doma.rule=Host(`doma.example.com`)",
        "traefik.http.routers.doma.entrypoints=websecure",
        "traefik.http.routers.doma.tls.certresolver=letsencrypt",
      ]
      check {
        type     = "http"
        path     = "/healthz"
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "doma" {
      driver = "docker"

      config {
        image = "ghcr.io/w4jnl/doma:latest"
        ports = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      env {
        DOMA_SERVER_BASE_URL        = "https://doma.example.com"
        DOMA_SERVER_TRUSTED_PROXIES = "10.0.0.0/8"
        DOMA_LOG_FORMAT             = "json"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }
  }
}
