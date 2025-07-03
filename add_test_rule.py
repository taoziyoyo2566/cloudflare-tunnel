#!/usr/bin/env python3
"""
Add temporary test ingress rule to Cloudflare Tunnel configuration
Only for tunnel testing functionality
"""

import yaml
import sys
import argparse

def add_test_rule(config_file, hostname, port):
    """Add a temporary test rule to the tunnel configuration"""
    try:
        with open(config_file, 'r') as f:
            config = yaml.safe_load(f)
        
        if 'ingress' not in config:
            config['ingress'] = []
        
        # Create test rule
        test_rule = {
            'hostname': hostname,
            'service': f'http://127.0.0.1:{port}'
        }
        
        # Create new ingress list with test rule first
        new_ingress = [test_rule]
        
        # Add existing rules (except catch-all)
        for rule in config['ingress']:
            if 'hostname' in rule or 'path' in rule:
                new_ingress.append(rule)
        
        # Add catch-all rule
        new_ingress.append({'service': 'http_status:404'})
        
        config['ingress'] = new_ingress
        
        # Write back to file
        with open(config_file, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
        return True
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return False

def main():
    parser = argparse.ArgumentParser(description='Add temporary test rule to tunnel config')
    parser.add_argument('config_file', help='Path to tunnel configuration file')
    parser.add_argument('hostname', help='Test hostname')
    parser.add_argument('port', type=int, help='Test port number')
    
    args = parser.parse_args()
    
    if add_test_rule(args.config_file, args.hostname, args.port):
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()