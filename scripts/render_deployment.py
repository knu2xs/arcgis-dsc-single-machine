#!/usr/bin/env python
"""
Render BaseDeployment configuration from template and path configuration.
This script reads path variables from config/deployment_config.yaml and generates
the actual BaseDeployment-SingleMachine.json file.
"""

import json
import os
import socket
import yaml
from pathlib import Path
from jinja2 import Environment, FileSystemLoader


def infer_base_dir(config_path):
    """Infer repository base directory from config/deployment_config.yaml location."""
    resolved_config = Path(config_path).resolve()
    if resolved_config.parent.name.lower() == 'config':
        return resolved_config.parent.parent

    # Fallback: treat config file parent as base if layout is non-standard.
    return resolved_config.parent

def load_config(config_path):
    """Load YAML configuration file."""
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)

def render_template(template_path, config):
    """Render Jinja2 template with configuration values."""
    # Escape backslashes for JSON compatibility
    config_escaped = {}
    for key, value in config.items():
        if isinstance(value, str):
            config_escaped[key] = value.replace('\\', '\\\\')
        else:
            config_escaped[key] = value
    
    env = Environment(loader=FileSystemLoader(str(Path(template_path).parent)))
    template = env.get_template(Path(template_path).name)
    return template.render(**config_escaped)

def generate_deployment_config(config_yaml_path, template_path, output_path):
    """Generate deployment config from template and YAML configuration."""
    print(f"Loading configuration from: {config_yaml_path}")
    config = load_config(config_yaml_path)

    base_dir = infer_base_dir(config_yaml_path)
    config['BASE_DIR'] = str(base_dir)
    config['MACHINE_NAME'] = os.environ.get('COMPUTERNAME') or socket.gethostname()

    arcgis_version = str(config.get('ARCGIS_VERSION', '')).strip()
    if not arcgis_version:
        raise ValueError('ARCGIS_VERSION is required in config/deployment_config.yaml')
    
    print(f"Using inferred base directory: {base_dir}")
    print(f"Using machine name: {config['MACHINE_NAME']}")
    print(f"Using ArcGIS version: {arcgis_version}")
    print(f"Rendering template: {template_path}")
    rendered = render_template(template_path, config)
    
    # Parse and validate JSON
    json_data = json.loads(rendered)
    
    # Write formatted JSON output
    with open(output_path, 'w') as f:
        json.dump(json_data, f, indent=4)
    
    print(f"✓ Configuration generated: {output_path}")
    return json_data

if __name__ == '__main__':
    import sys
    
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    
    # Default paths (can be overridden via command-line arguments)
    config_file = sys.argv[1] if len(sys.argv) > 1 else str(project_root / 'config' / 'deployment_config.yaml')
    template_file = sys.argv[2] if len(sys.argv) > 2 else str(project_root / 'BaseDeployment-SingleMachine.json.jinja2')
    output_file = sys.argv[3] if len(sys.argv) > 3 else str(project_root / 'BaseDeployment-SingleMachine.json')
    
    try:
        result = generate_deployment_config(config_file, template_file, output_file)
        print("\nConfiguration successfully generated!")
    except Exception as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        sys.exit(1)
