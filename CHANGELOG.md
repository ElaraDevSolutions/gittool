# Changelog

All notable changes to this project will be documented in this file.

## [v1.0.4] - 2025-11-09
### Added
- Portable `install.sh` script (manual / curl install).
- Test suite for installer (`test_install.sh`) and unified runner (`run_all.sh`).
- Packaging scripts: `release_checksums.sh`, `build_fpm_packages.sh` (fpm). 
- CI workflow updated to run all tests.

### Changed
- README: new installation instructions and distribution guidance.

### Security
- Recommend pinning install script to a version tag.

## [v1.0.3] - 2025-??-??
- Previous release used for Homebrew (no installer script).

## Earlier tags
- Initial functionality for SSH helper and dispatcher.

---
Format: Keep sections Added / Changed / Removed / Fixed / Security when relevant. New entries append at top.
