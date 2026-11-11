# Changelog

## 1.0.0 - 2026-11-11

First public release.

- Catalog search for Lenovo (`catalogv2.xml`) and Dell (`DriverPackCatalog.cab`) Windows 11 driver packs
- Model list (`Models.json`): add, rename and remove models
- Download with BITS / `Invoke-WebRequest` fallback, optional proxy, catalog hash verification
- Extraction, `Drivers.zip`, atomic copy to the package share
- Standard ConfigMgr package with configurable name prefix, console folder and DP group
- Build history with `-OnlyNew`, `-PlanOnly`, run lock, log retention
- Scheduled task helper for gMSA or service accounts
- Pester tests with catalog fixtures, PSScriptAnalyzer and GitHub Actions CI
