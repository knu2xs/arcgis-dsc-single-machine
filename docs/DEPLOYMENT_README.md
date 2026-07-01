# Deployment Workflow Reference

## Overview

This project deploys ArcGIS Enterprise components (Server, Portal, Data Store, Web Adaptor) using a rendered DSC configuration and a single unattended runner.

Primary entrypoint:

```powershell
.\scripts\run_unattended_install.ps1
```

## Configuration Inputs

Edit `config/deployment_config.yaml` before execution.

Required values:
- `ARCGIS_VERSION`
- `ARCGIS_DSC_ZIP_URL`

Common install/data path values:
- `SERVER_DATA_DIR`
- `PORTAL_DATA_DIR`
- `DATASTORE_DATA_DIR`
- `SERVER_INSTALL_DIR`
- `PORTAL_INSTALL_DIR`
- `DATASTORE_INSTALL_DIR`

## Standard Flow

1. `scripts/sync_install_resources.ps1`
2. `scripts/bootstrap_new_instance.ps1`
3. `scripts/install_webadaptor_prereqs.ps1` (unless skipped)
4. `scripts/configure_iis_ssl_certifactory.ps1` (unless skipped)
5. `scripts/protect_secrets.ps1 -Mode Encrypt`
6. ArcGIS DSC module download/import from zip
7. `Invoke-ArcGISConfiguration`

## Useful Commands

Create password files:

```powershell
.\scripts\create_password_files.ps1 -Interactive
```

Run unattended install:

```powershell
.\scripts\run_unattended_install.ps1
```

Skip prereq or SSL phases when needed:

```powershell
.\scripts\run_unattended_install.ps1 -SkipPrerequisites -SkipIisSslConfiguration
```

## Generated Artifacts

- `BaseDeployment-SingleMachine.json` (rendered output)
- `resources/software/*` (normalized media files)
- `resources/authorization_files/*`
- `resources/dsc_module/*` (extracted module)

Do not manually edit the generated JSON; re-render via `scripts/render_deployment.py`.
