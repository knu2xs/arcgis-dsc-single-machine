# ArcGIS Enterprise Single-Machine Deployment

This repository automates ArcGIS Enterprise deployment on a single Windows machine using ArcGIS PowerShell DSC.

It provides:
- version-driven media sync from Esri release shares
- local Python bootstrap for rendering deployment JSON from template
- unattended install orchestration with automatic password encryption

## Quickstart (Three Steps)

1. Configure deployment values in `config/deployment_config.yaml`.
   - Required: `ARCGIS_VERSION`, `ARCGIS_DSC_ZIP_URL`
2. Create plaintext password files.

```powershell
.\scripts\create_password_files.ps1 -Interactive
```

3. Run unattended install.

```powershell
.\scripts\run_unattended_install.ps1
```

## What the Unattended Script Does

1. Syncs required media and authorization files into `resources`
2. Bootstraps local Python environment and renders `BaseDeployment-SingleMachine.json`
3. Installs Web Adaptor prerequisites (unless `-SkipPrerequisites`)
4. Configures IIS SSL certificate (unless `-SkipIisSslConfiguration`)
5. Encrypts plaintext password files
6. Downloads/imports ArcGIS DSC module zip
7. Runs `Invoke-ArcGISConfiguration`

## Password Encryption and Decryption

Use the helper script any time you need to toggle secret file format:

```powershell
.\scripts\protect_secrets.ps1 -Mode Encrypt
.\scripts\protect_secrets.ps1 -Mode Decrypt
```

## Additional Documentation

- `docs/DEPLOYMENT_README.md` - deployment workflow and operational details
- `docs/TEMPLATING_README.md` - template/rendering behavior and variables
- `docs/IMPLEMENTATION_SUMMARY.md` - implementation history and change summary
