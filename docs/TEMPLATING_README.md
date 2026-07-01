# Templating and Rendering Reference

## Purpose

`BaseDeployment-SingleMachine.json.jinja2` is the source template for the DSC configuration.
The rendered output is `BaseDeployment-SingleMachine.json`.

Renderer script:

```powershell
.\env\Scripts\python.exe .\scripts\render_deployment.py
```

## Inputs and Inferred Values

YAML input file:
- `config/deployment_config.yaml`

Values injected by renderer:
- `BASE_DIR` (inferred from repository location)
- `MACHINE_NAME` (host machine name)

Required YAML keys used by template:
- `ARCGIS_VERSION`
- `SERVER_DATA_DIR`
- `PORTAL_DATA_DIR`
- `DATASTORE_DATA_DIR`
- `SERVER_INSTALL_DIR`
- `PORTAL_INSTALL_DIR`
- `PORTAL_CONTENT_DIR`
- `DATASTORE_INSTALL_DIR`

## Path Behavior

Template paths are built from `BASE_DIR`, for example:
- `BASE_DIR\\resources\\software`
- `BASE_DIR\\resources\\authorization_files`
- `BASE_DIR\\config\\*password*.txt`

## Validation

After rendering, validate:
- `ConfigData.Version` matches `ARCGIS_VERSION`
- `AllNodes[0].NodeName` matches host machine name
- installer and authorization file paths point under `resources`

## Editing Guidance

1. Update environment-specific values in `config/deployment_config.yaml`.
2. Update structural deployment logic in `BaseDeployment-SingleMachine.json.jinja2`.
3. Re-run render script to regenerate JSON.
