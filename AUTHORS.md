# Authors and credits

This module was originally developed as internal SQL Server HADR tooling and
is published here with the permission of its authors.

## Original author

- **A former colleague** — original module design and implementation (name withheld)
  (planned failover, patching prepare/resume, PagerDuty integration)

## Contributors

- **Renz Bagasbas** — AWS EC2 driver update gate, distributed availability
  group failover fix, Windows Server 2025 / SQL Server 2025 upgrade runbook,
  and this open-source release

## A note on the published version

The public version differs from the internal one in one way only: every
environment-specific identifier has been replaced with a placeholder. No
logic was changed.

Replaced throughout: hostnames and cluster names (`STAGING-NODE2`,
`ag-staging1`), database names (`AppDb`, `AppDb_Data`), the PagerDuty
service id (`PDSERVICE`), IP addresses (RFC 5737 documentation ranges such
as `192.0.2.x`), internal DNS suffixes, email addresses, and issue-tracker
references.

If you are adapting this for your own environment, those are exactly the
values you need to change.
