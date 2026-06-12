# `harbor`

This role installs and configures Harbor, the container registry backing
the application catalog. Harbor mirrors and scans the images of the curated
applications with its embedded Trivy scanner, so that every image consumed
by the platform can be served and audited locally.
