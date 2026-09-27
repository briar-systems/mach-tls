# system CA bundles

`/etc/ssl/certs/ca-certificates.crt` as shipped on 2026-09-27 by the
`debian:stable-slim` image with `ca-certificates` installed (`debian.pem`) and by
the `alpine:latest` image (`alpine.pem`). `tls.cert.bundle`'s tests load both, so
a change in what the loader accepts from a real bundle shows up as a count.
