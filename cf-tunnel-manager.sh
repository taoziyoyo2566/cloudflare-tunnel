#!/bin/bash

# Enhanced Cloudflare Tunnel Management Script
# Version: 2.1
# Author: Enhanced by Claude
# Features: Complete tunnel management with DNS routing and multi-tunnel support
# OS Support: Debian/Ubuntu only

set -e

# Configuration variables
CONFIG_DIR="$HOME/.cloudflared"
BACKUP_DIR="$HOME/cloudflared_backups"
LOG_FILE="/var/log/cloudflared_manager.log"

# Global variables for tunnel selection
declare -a tunnel_array
selected_tunnel=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        echo "Please run: sudo $0"
        exit 1
    fi
}

# Install system dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    apt update -qq
    apt install -y wget curl python3 python3-yaml systemd
    log_success "Dependencies installed"
}

# Check network connectivity
check_network() {
    log_info "Checking network connectivity..."
    
    if ! ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        log_error "Network connection failed"
        return 1
    fi
    
    if ! curl -s --connect-timeout 5 https://api.cloudflare.com/client/v4/ &> /dev/null; then
        log_warning "Cannot connect to Cloudflare API"
        return 1
    fi
    
    log_success "Network connection OK"
    return 0
}

# Install/Update cloudflared
install_cloudflared() {
    log_info "Installing/updating cloudflared..."
    
    # Detect architecture
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        *) 
            log_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac
    
    # Download and install
    if wget -O cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"; then
        if dpkg -i cloudflared.deb; then
            rm -f cloudflared.deb
            log_success "cloudflared installed successfully"
            cloudflared version
        else
            log_error "Failed to install cloudflared package"
            rm -f cloudflared.deb
            return 1
        fi
    else
        log_error "Failed to download cloudflared"
        return 1
    fi
}

# Check if cloudflared is installed
check_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        log_warning "cloudflared not found. Install? (y/n)"
        read -r install_choice
        if [[ $install_choice == "y" || $install_choice == "Y" ]]; then
            install_cloudflared
        else
            log_error "cloudflared not installed, exiting"
            exit 1
        fi
    fi
}

# Check Cloudflare authentication
check_auth() {
    if cloudflared tunnel list &> /dev/null; then
        log_success "Cloudflare authentication OK"
        return 0
    else
        log_warning "Cloudflare authentication not found"
        log_info "Please run: cloudflared tunnel login"
        
        read -p "Authenticate now? (y/n): " auth_choice
        if [[ $auth_choice == "y" || $auth_choice == "Y" ]]; then
            cloudflared tunnel login
            if cloudflared tunnel list &> /dev/null; then
                log_success "Authentication successful"
                return 0
            else
                log_error "Authentication failed"
                return 1
            fi
        else
            log_warning "Skipping authentication"
            return 1
        fi
    fi
}

# Get available tunnels list
get_tunnel_list() {
    if ! check_auth; then
        return 1
    fi
    
    # Clear previous array
    tunnel_array=()
    
    # Get tunnels from cloudflared and populate array
    while IFS= read -r tunnel_name; do
        if [[ -n "$tunnel_name" ]]; then
            tunnel_array+=("$tunnel_name")
        fi
    done < <(cloudflared tunnel list 2>/dev/null | grep -v "^ID" | awk '{print $2}' | sort)
    
    if [[ ${#tunnel_array[@]} -eq 0 ]]; then
        log_warning "No tunnels found"
        return 1
    fi
    
    return 0
}

# Select tunnel from list
select_tunnel() {
    local prompt="$1"
    local allow_empty="${2:-false}"
    
    if ! get_tunnel_list; then
        return 1
    fi
    
    echo
    echo -e "${CYAN}Available tunnels:${NC}"
    for i in "${!tunnel_array[@]}"; do
        echo "$((i+1))) ${tunnel_array[i]}"
    done
    
    if [[ "$allow_empty" == "true" ]]; then
        echo "0) Cancel/Skip"
    fi
    
    while true; do
        echo
        read -p "$prompt (1-${#tunnel_array[@]}): " choice
        
        if [[ "$allow_empty" == "true" && "$choice" == "0" ]]; then
            return 2  # Cancel
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#tunnel_array[@]} ]]; then
            selected_tunnel="${tunnel_array[$((choice-1))]}"
            return 0
        fi
        
        log_error "Please enter a number between 1 and ${#tunnel_array[@]}"
        if [[ "$allow_empty" == "true" ]]; then
            echo "Or enter 0 to cancel"
        fi
    done
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    # RFC compliant hostname validation
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Validate service URL
validate_service() {
    local service="$1"
    # Check for valid service formats
    if [[ "$service" =~ ^https?://.+ ]] || \
       [[ "$service" =~ ^tcp://.+ ]] || \
       [[ "$service" =~ ^ssh://.+ ]] || \
       [[ "$service" =~ ^unix:.+ ]] || \
       [[ "$service" == "http_status:"[0-9]+ ]]; then
        return 0
    fi
    return 1
}

# 自动查找 tunnel 配置文件（支持 ~/.cloudflared 与 /etc/cloudflared）
find_tunnel_config() {
    local tunnel_name="$1"
    # 优先级顺序
    local try_paths=(
        "$CONFIG_DIR/config_${tunnel_name}.yml"
        "$CONFIG_DIR/config.yml"
        "/etc/cloudflared/config_${tunnel_name}.yml"
        "/etc/cloudflared/config.yml"
    )
    for file in "${try_paths[@]}"; do
        if [[ -f "$file" ]]; then
            echo "$file"
            return 0
        fi
    done
    return 1
}

# Create new tunnel
create_tunnel() {
    echo
    log_info "=== Create New Tunnel ==="
    
    if ! check_auth; then
        return 1
    fi
    
    local tunnel_name
    while true; do
        read -p "Enter tunnel name: " tunnel_name
        if [[ -z "$tunnel_name" ]]; then
            log_error "Tunnel name cannot be empty"
            continue
        fi
        
        # Validate tunnel name format
        if [[ ! "$tunnel_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "Tunnel name can only contain letters, numbers, hyphens, and underscores"
            continue
        fi
        
        # Check if tunnel already exists
        if cloudflared tunnel list 2>/dev/null | grep -q "^[^[:space:]]*[[:space:]]*${tunnel_name}[[:space:]]*"; then
            log_error "Tunnel '$tunnel_name' already exists"
            continue
        fi
        
        break
    done
    
    log_info "Creating tunnel: $tunnel_name"
    if ! cloudflared tunnel create "$tunnel_name"; then
        log_error "Failed to create tunnel"
        return 1
    fi
    
    # Create directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    
    # Get tunnel ID
    local tunnel_id
    tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}')
    
    if [[ -z "$tunnel_id" ]]; then
        log_error "Failed to get tunnel ID"
        return 1
    fi
    
    log_success "Tunnel created successfully"
    log_info "Tunnel ID: $tunnel_id"
    log_info "Tunnel Name: $tunnel_name"
    
    # Create initial config file
    create_config_file "$tunnel_name" "$tunnel_id"
    
    echo
    log_info "Next steps:"
    echo "1. Add ingress rules (option 4)"
    echo "2. Create DNS routes (option 15)"
    echo "3. Start tunnel service (option 6)"
}

# Create configuration file
create_config_file() {
    local tunnel_name="$1"
    local tunnel_id="$2"

    local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }

    # Validate inputs
    if [[ -z "$tunnel_name" || -z "$tunnel_id" ]]; then
        log_error "Missing tunnel name or ID"
        return 1
    fi
    
    cat > "$config_file" << EOF
# Cloudflare Tunnel Configuration
# Tunnel: $tunnel_name ($tunnel_id)
# Created: $(date)

tunnel: $tunnel_id
credentials-file: $CONFIG_DIR/$tunnel_id.json

# Ingress rules - order matters!
ingress:
  # Default catch-all rule - must be last
  - service: http_status:404

# Optional advanced settings (uncomment to use)
#metrics: localhost:2000
#warp-routing:
#  enabled: false
#retries: 5
#grace-period: 30s
#compression-quality: 0
EOF
    
    chmod 600 "$config_file"
    
    # Validate created configuration file
    if cloudflared tunnel --config "$config_file" ingress validate 2>/dev/null; then
        log_success "Config file created and validated: $config_file"
    else
        log_error "Created config file failed validation"
        return 1
    fi
}

# List all tunnels with status
list_tunnels() {
    echo
    log_info "=== All Tunnels ==="
    if ! check_auth; then
        return 1
    fi
    
    echo
    echo -e "${CYAN}Tunnel List:${NC}"
    echo "----------------------------------------"
    cloudflared tunnel list
    echo "----------------------------------------"
    
    # Show active tunnels
    echo
    echo -e "${CYAN}Active Services:${NC}"
    if systemctl list-units --type=service --state=active 2>/dev/null | grep -q cloudflared; then
        systemctl list-units --type=service --state=active 2>/dev/null | grep cloudflared
    else
        echo "No active cloudflared services"
    fi
    
    # Show available config files
    echo
    echo -e "${CYAN}Available Configurations:${NC}"
    if ls "$CONFIG_DIR"/config_*.yml 2>/dev/null; then
        for config in "$CONFIG_DIR"/config_*.yml; do
            local tunnel_name
            tunnel_name=$(basename "$config" .yml | sed 's/config_//')
            echo "• $tunnel_name: $config"
        done
    else
        echo "No configuration files found"
    fi
}

# Show tunnel details and configuration
show_tunnel_details() {
    echo
    log_info "=== Tunnel Details ==="
    
    if ! select_tunnel "Select tunnel to view details"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
    
    # Get tunnel info
    echo
    echo -e "${CYAN}Tunnel Information for: $tunnel_name${NC}"
    if cloudflared tunnel info "$tunnel_name" 2>/dev/null; then
        echo
        
        # Show DNS routes
        echo -e "${CYAN}DNS Routes:${NC}"
        cloudflared tunnel route dns show "$tunnel_name" 2>/dev/null || echo "No DNS routes configured"
        
        
        local config_file
            config_file=$(find_tunnel_config "$tunnel_name") || {
            log_error "Config file not found for tunnel: $tunnel_name"
            return 1
        }

        if [[ -f "$config_file" ]]; then
            echo
            echo -e "${CYAN}Configuration File ($config_file):${NC}"
            echo "----------------------------------------"
            cat "$config_file"
            echo "----------------------------------------"
            
            # Validate configuration
            echo
            log_info "Validating configuration..."
            if cloudflared tunnel --config "$config_file" ingress validate 2>/dev/null; then
                log_success "Configuration is valid"
            else
                log_error "Configuration validation failed"
            fi
        else
            log_warning "No configuration file found for tunnel: $tunnel_name"
            read -p "Create configuration file for this tunnel? (y/n): " create_config
            if [[ $create_config == "y" || $create_config == "Y" ]]; then
                local tunnel_id
                tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}')
                if [[ -n "$tunnel_id" ]]; then
                    create_config_file "$tunnel_name" "$tunnel_id"
                else
                    log_error "Could not get tunnel ID"
                fi
            fi
        fi
    else
        log_error "Tunnel '$tunnel_name' not found or not accessible"
    fi
}

# Helper function to remove hostname from config
remove_hostname_from_config() {
    local config_file="$1"
    local hostname="$2"
    
    # Validate inputs
    if [[ ! -f "$config_file" || -z "$hostname" ]]; then
        log_error "Invalid config file or hostname"
        return 1
    fi
    
    python3 -c "
import yaml
import sys

try:
    with open('$config_file', 'r') as f:
        config = yaml.safe_load(f)
    
    if 'ingress' not in config:
        print('No ingress rules found')
        sys.exit(1)
    
    new_ingress = []
    for rule in config['ingress']:
        if 'hostname' not in rule or rule['hostname'] != '$hostname':
            new_ingress.append(rule)
    
    config['ingress'] = new_ingress
    
    with open('$config_file', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
}
# Add ingress rule with advanced options
add_ingress_rule() {
    echo
    log_info "=== Add Ingress Rule ==="
    
    # Select tunnel
    if ! select_tunnel "Select tunnel to add ingress rule"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
    local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }   
    # Check if config file exists, create if needed
    if [[ ! -f "$config_file" ]]; then
        log_warning "Config file not found for tunnel: $tunnel_name"
        read -p "Create configuration file? (y/n): " create_config
        if [[ $create_config == "y" || $create_config == "Y" ]]; then
            local tunnel_id
            tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}')
            if [[ -n "$tunnel_id" ]]; then
                create_config_file "$tunnel_name" "$tunnel_id"
            else
                log_error "Could not get tunnel ID for $tunnel_name"
                return 1
            fi
        else
            log_info "Operation cancelled"
            return 1
        fi
    fi
    
    # Input hostname with validation loop
    local hostname
    while true; do
        read -p "Enter hostname (e.g., app.example.com): " hostname
        if [[ -z "$hostname" ]]; then
            log_error "Hostname cannot be empty"
            continue
        fi
        
        if validate_hostname "$hostname"; then
            # Check if hostname already exists
            if grep -q "hostname: $hostname" "$config_file"; then
                log_warning "Hostname '$hostname' already exists in configuration"
                read -p "Replace existing rule? (y/n): " replace
                if [[ $replace == "y" || $replace == "Y" ]]; then
                    # Remove existing rule first
                    remove_hostname_from_config "$config_file" "$hostname"
                    break
                else
                    continue
                fi
            else
                break
            fi
        else
            log_error "Invalid hostname format. Please use format like: app.example.com"
        fi
    done
    
    # Input service with validation loop
    local service
    echo
    echo -e "${CYAN}Service formats:${NC}"
    echo "• HTTP: http://127.0.0.1:8080"
    echo "• HTTPS: https://127.0.0.1:8443"
    echo "• SSH: ssh://127.0.0.1:22"
    echo "• TCP: tcp://127.0.0.1:3389"
    echo "• Status page: http_status:200"
    
    while true; do
        read -p "Enter service address: " service
        if [[ -z "$service" ]]; then
            log_error "Service address cannot be empty"
            continue
        fi
        
        if validate_service "$service"; then
            break
        else
            log_error "Invalid service format. Examples: http://localhost:8080, ssh://127.0.0.1:22"
        fi
    done
    
    # Advanced configuration options
    echo
    read -p "Configure advanced options? (y/n): " advanced
    
    local origin_request=""
    if [[ $advanced == "y" || $advanced == "Y" ]]; then
        echo
        echo -e "${CYAN}Advanced Options:${NC}"
        echo "1) Ignore TLS verification (noTLSVerify: true)"
        echo "2) Custom connect timeout"
        echo "3) Enable HTTP/2 (http2Origin: true)"
        echo "4) Custom HTTP host header"
        echo "5) Skip advanced options"
        
        while true; do
            read -p "Choose option (1-5): " adv_choice
            case $adv_choice in
                1)
                    origin_request="noTLSVerify: true"
                    break
                    ;;
                2)
                    while true; do
                        read -p "Enter timeout in seconds (default 30): " timeout
                        timeout=${timeout:-30}
                        if [[ "$timeout" =~ ^[0-9]+$ ]] && [[ $timeout -gt 0 ]]; then
                            origin_request="connectTimeout: ${timeout}s"
                            break
                        else
                            log_error "Please enter a valid number greater than 0"
                        fi
                    done
                    break
                    ;;
                3)
                    origin_request="http2Origin: true"
                    break
                    ;;
                4)
                    read -p "Enter HTTP host header: " host_header
                    if [[ -n "$host_header" ]]; then
                        origin_request="httpHostHeader: $host_header"
                    fi
                    break
                    ;;
                5|"")
                    break
                    ;;
                *)
                    log_error "Please choose 1-5"
                    ;;
            esac
        done
    fi
    
    # Backup current config
    local backup_file="$BACKUP_DIR/config_${tunnel_name}_$(date +%s).yml"
    cp "$config_file" "$backup_file"
    log_info "Config backed up to: $backup_file"
    
    # Use Python to safely modify YAML configuration
    cat > /tmp/add_ingress.py << 'PYTHON_EOF'
import yaml
import sys

config_file = sys.argv[1]
hostname = sys.argv[2]
service = sys.argv[3]
origin_request = sys.argv[4] if len(sys.argv) > 4 else ""

try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    
    if 'ingress' not in config:
        config['ingress'] = []
    
    # Create new ingress list, preserve non-catch-all rules
    new_ingress = []
    for rule in config['ingress']:
        # Keep rules with hostname or path, skip catch-all rules
        if 'hostname' in rule or 'path' in rule:
            new_ingress.append(rule)
    
    # Create new rule
    new_rule = {
        'hostname': hostname,
        'service': service
    }
    
    # Handle advanced configuration
    if origin_request:
        new_rule['originRequest'] = {}
        if 'noTLSVerify: true' in origin_request:
            new_rule['originRequest']['noTLSVerify'] = True
        elif 'connectTimeout:' in origin_request:
            timeout = origin_request.split('connectTimeout:')[1].strip()
            new_rule['originRequest']['connectTimeout'] = timeout
        elif 'http2Origin: true' in origin_request:
            new_rule['originRequest']['http2Origin'] = True
        elif 'httpHostHeader:' in origin_request:
            header = origin_request.split('httpHostHeader:')[1].strip()
            new_rule['originRequest']['httpHostHeader'] = header
    
    # Add new rule
    new_ingress.append(new_rule)
    
    # Add catch-all rule
    new_ingress.append({'service': 'http_status:404'})
    
    # Update configuration
    config['ingress'] = new_ingress
    
    # Write to file
    with open(config_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
    
    print("SUCCESS")
    
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTHON_EOF
    
    # Execute Python script
    local result
    result=$(python3 /tmp/add_ingress.py "$config_file" "$hostname" "$service" "$origin_request" 2>&1)
    local exit_code=$?
    
    # Clean up temporary file
    rm -f /tmp/add_ingress.py
    
    if [[ $exit_code -eq 0 && "$result" == "SUCCESS" ]]; then
        # Validate configuration
        if cloudflared tunnel --config "$config_file" ingress validate 2>/dev/null; then
            chmod 600 "$config_file"
            log_success "Ingress rule added successfully"
            
            echo
            echo -e "${CYAN}Rule Summary:${NC}"
            echo "• Tunnel: $tunnel_name"
            echo "• Hostname: $hostname"
            echo "• Service: $service"
            if [[ -n "$origin_request" ]]; then
                echo "• Advanced config: Yes"
            fi
            
            echo
            log_info "Next steps:"
            echo "1. Create DNS route: Use option 15 'Manage DNS Routes'"
            echo "2. Restart tunnel service if running"
        else
            mv "$backup_file" "$config_file"
            log_error "Configuration validation failed, restored from backup"
            return 1
        fi
    else
        mv "$backup_file" "$config_file"
        log_error "Failed to add ingress rule: $result"
        log_info "Configuration restored from backup"
        return 1
    fi
}

# Test ingress rules
test_ingress_rules() {
    echo
    log_info "=== Test Ingress Rules ==="
    
    # Select tunnel
    if ! select_tunnel "Select tunnel to test ingress rules"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
        local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Validate config first
    echo
    log_info "Validating configuration..."
    if cloudflared tunnel --config "$config_file" ingress validate; then
        log_success "Configuration is valid"
    else
        log_error "Configuration validation failed"
        return 1
    fi
    
    # Test specific URLs
    echo
    echo -e "${CYAN}Test URLs against ingress rules:${NC}"
    while true; do
        read -p "Enter URL to test (or 'quit' to exit): " test_url
        if [[ "$test_url" == "quit" || "$test_url" == "q" ]]; then
            break
        fi
        
        if [[ -n "$test_url" ]]; then
            echo
            cloudflared tunnel --config "$config_file" ingress rule "$test_url"
            echo
        fi
    done
}

# Manage DNS routes
manage_dns_routes() {
    echo
    log_info "=== Manage DNS Routes ==="
    
    if ! check_auth; then
        return 1
    fi
    
    echo "1) List all DNS routes"
    echo "2) Add DNS route"
    echo "3) Remove DNS route"
    echo "4) Back to main menu"
    
    while true; do
        read -p "Choose option (1-4): " dns_choice
        case $dns_choice in
            1)
                echo
                echo -e "${CYAN}All DNS Routes:${NC}"
                cloudflared tunnel route dns list 2>/dev/null || echo "No DNS routes found"
                break
                ;;
            2)
                echo
                if ! select_tunnel "Select tunnel for DNS route"; then
                    break
                fi
                local tunnel_name="$selected_tunnel"
                
                while true; do
                    read -p "Enter hostname (e.g., app.example.com): " hostname
                    if [[ -z "$hostname" ]]; then
                        log_error "Hostname cannot be empty"
                        continue
                    fi
                    
                    if validate_hostname "$hostname"; then
                        log_info "Creating DNS route..."
                        if cloudflared tunnel route dns "$tunnel_name" "$hostname"; then
                            log_success "DNS route created: $hostname -> $tunnel_name"
                        else
                            log_error "Failed to create DNS route"
                        fi
                        break
                    else
                        log_error "Invalid hostname format"
                    fi
                done
                break
                ;;
            3)
                echo
                echo -e "${CYAN}Current DNS Routes:${NC}"
                if ! cloudflared tunnel route dns list 2>/dev/null; then
                    echo "No DNS routes found"
                    break
                fi
                
                while true; do
                    read -p "Enter hostname to remove: " hostname
                    if [[ -z "$hostname" ]]; then
                        log_error "Hostname cannot be empty"
                        continue
                    fi
                    
                    log_info "Removing DNS route..."
                    if cloudflared tunnel route dns delete "$hostname"; then
                        log_success "DNS route removed: $hostname"
                    else
                        log_error "Failed to remove DNS route"
                    fi
                    break
                done
                break
                ;;
            4)
                break
                ;;
            *)
                log_error "Please choose 1-4"
                ;;
        esac
    done
}

# Remove ingress rule
remove_ingress_rule() {
    echo
    log_info "=== Remove Ingress Rule ==="
    
    # Select tunnel
    if ! select_tunnel "Select tunnel to remove ingress rule from"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
    local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Show current rules
    echo
    echo -e "${CYAN}Current ingress rules for $tunnel_name:${NC}"
    echo "----------------------------------------"
    local rules
    mapfile -t rules < <(grep "hostname:" "$config_file" | awk '{print $2}')
    
    if [[ ${#rules[@]} -eq 0 ]]; then
        log_warning "No hostname rules found in configuration"
        return 1
    fi
    
    for i in "${!rules[@]}"; do
        echo "$((i+1))) ${rules[i]}"
    done
    echo "----------------------------------------"
    
    while true; do
        read -p "Select rule to remove (1-${#rules[@]}) or 0 to cancel: " rule_choice
        
        if [[ "$rule_choice" == "0" ]]; then
            log_info "Operation cancelled"
            return 0
        fi
        
        if [[ "$rule_choice" =~ ^[0-9]+$ ]] && [[ $rule_choice -ge 1 ]] && [[ $rule_choice -le ${#rules[@]} ]]; then
            local hostname_to_remove="${rules[$((rule_choice-1))]}"
            break
        fi
        
        log_error "Please enter a number between 1 and ${#rules[@]}, or 0 to cancel"
    done
    
    echo
    log_warning "About to remove rule: $hostname_to_remove"
    read -p "Are you sure? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        log_info "Operation cancelled"
        return 0
    fi
    
    # Backup config
    local backup_file="$BACKUP_DIR/config_${tunnel_name}_$(date +%s).yml"
    cp "$config_file" "$backup_file"
    log_info "Config backed up to: $backup_file"
    
    # Remove rule using Python
    if remove_hostname_from_config "$config_file" "$hostname_to_remove"; then
        log_success "Ingress rule removed successfully"
        echo
        log_info "Removed rule: $hostname_to_remove from $tunnel_name"
        log_info "Remember to remove the corresponding DNS route if no longer needed"
    else
        log_error "Failed to remove ingress rule"
        mv "$backup_file" "$config_file"
        log_info "Configuration restored from backup"
    fi
}

# Start tunnel service
start_tunnel() {
    echo
    log_info "=== Start Tunnel Service ==="
    
    # Get available config files
    local configs=()
    if ls "$CONFIG_DIR"/config_*.yml 2>/dev/null; then
        for config in "$CONFIG_DIR"/config_*.yml; do
            local tunnel_name
            tunnel_name=$(basename "$config" .yml | sed 's/config_//')
            configs+=("$tunnel_name")
        done
    fi
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        log_error "No configuration files found"
        log_info "Please create a tunnel and add ingress rules first"
        return 1
    fi
    
    echo -e "${CYAN}Available configurations:${NC}"
    for i in "${!configs[@]}"; do
        echo "$((i+1))) ${configs[i]}"
    done
    
    while true; do
        read -p "Select tunnel to start (1-${#configs[@]}) or 0 to cancel: " choice
        
        if [[ "$choice" == "0" ]]; then
            log_info "Operation cancelled"
            return 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#configs[@]} ]]; then
            local tunnel_name="${configs[$((choice-1))]}"
            break
        fi
        
        log_error "Please enter a number between 1 and ${#configs[@]}, or 0 to cancel"
    done
    
    # local config_file="$CONFIG_DIR/config_${tunnel_name}.yml"
    local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }

    # Validate config
    echo
    log_info "Validating configuration..."
    if ! cloudflared tunnel --config "$config_file" ingress validate; then
        log_error "Configuration validation failed"
        return 1
    fi
    
    # Check if service already running
    local service_name="cloudflared"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_warning "Service $service_name is already running"
        read -p "Restart the service? (y/n): " restart_choice
        if [[ $restart_choice == "y" || $restart_choice == "Y" ]]; then
            systemctl restart "$service_name"
            log_success "Service restarted: $service_name"
        fi
        return 0
    fi
    
    # Create systemd service
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=Cloudflare Tunnel ($tunnel_name)
After=network.target

[Service]
Type=notify
User=root
ExecStart=/usr/bin/cloudflared tunnel --config $config_file run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Start service
    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name"
    
    log_success "Tunnel service started: $service_name"
    
    # Show status
    sleep 2
    systemctl status "$service_name" --no-pager
}

# Stop tunnel service
stop_tunnel() {
    echo
    log_info "=== Stop Tunnel Service ==="
    
    # List active services
    local active_services
    mapfile -t active_services < <(systemctl list-units --type=service --state=active 2>/dev/null | grep cloudflared | awk '{print $1}' | sed 's/cloudflared-//' | sed 's/.service//')
    
    if [[ ${#active_services[@]} -eq 0 ]]; then
        log_warning "No active cloudflared services found"
        return 0
    fi
    
    echo -e "${CYAN}Active cloudflared services:${NC}"
    for i in "${!active_services[@]}"; do
        echo "$((i+1))) ${active_services[i]}"
    done
    
    while true; do
        read -p "Select service to stop (1-${#active_services[@]}) or 0 to cancel: " choice
        
        if [[ "$choice" == "0" ]]; then
            log_info "Operation cancelled"
            return 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#active_services[@]} ]]; then
            local tunnel_name="${active_services[$((choice-1))]}"
            break
        fi
        
        log_error "Please enter a number between 1 and ${#active_services[@]}, or 0 to cancel"
    done
    
    local service_name="cloudflared-${tunnel_name}"
    
    log_info "Stopping service: $service_name"
    systemctl stop "$service_name"
    systemctl disable "$service_name"
    log_success "Tunnel service stopped: $service_name"
}

# Restart tunnel service
restart_tunnel() {
    echo
    log_info "=== Restart Tunnel Service ==="
    
    # List active services
    local active_services
    mapfile -t active_services < <(systemctl list-units --type=service --state=active 2>/dev/null | grep cloudflared | awk '{print $1}' | sed 's/cloudflared-//' | sed 's/.service//')
    
    if [[ ${#active_services[@]} -eq 0 ]]; then
        log_warning "No active cloudflared services found"
        return 0
    fi
    
    echo -e "${CYAN}Active cloudflared services:${NC}"
    for i in "${!active_services[@]}"; do
        echo "$((i+1))) ${active_services[i]}"
    done
    
    while true; do
        read -p "Select service to restart (1-${#active_services[@]}) or 0 to cancel: " choice
        
        if [[ "$choice" == "0" ]]; then
            log_info "Operation cancelled"
            return 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#active_services[@]} ]]; then
            local tunnel_name="${active_services[$((choice-1))]}"
            break
        fi
        
        log_error "Please enter a number between 1 and ${#active_services[@]}, or 0 to cancel"
    done
    
    local service_name
    if [[ -z "$tunnel_name" || "$tunnel_name" == "cloudflared" ]]; then
        service_name="cloudflared"
    else
        service_name="cloudflared-${tunnel_name}"
    fi

    log_info "Restarting service: $service_name"

    if systemctl restart "$service_name"; then
        log_success "Tunnel service restarted: $service_name"
        sleep 2
        systemctl status "$service_name" --no-pager
    else
        log_error "Failed to restart service: $service_name"
    fi
}

# Show service status
show_status() {
    echo
    log_info "=== Tunnel Services Status ==="
    
    # Show all cloudflared services
    echo -e "${CYAN}All cloudflared services:${NC}"
    systemctl list-units --type=service 2>/dev/null | grep cloudflared || echo "No cloudflared services found"
    
    echo
    echo -e "${CYAN}Active services details:${NC}"
    local active_found=false
    while IFS= read -r service; do
        if [[ -n "$service" ]]; then
            active_found=true
            echo "----------------------------------------"
            echo "Service: $service"
            systemctl status "$service" --no-pager -l
            echo
            echo "Recent logs:"
            journalctl -u "$service" --no-pager -n 5 --since "5 minutes ago"
            echo "----------------------------------------"
        fi
    done < <(systemctl list-units --type=service --state=active 2>/dev/null | grep cloudflared | awk '{print $1}')
    
    if [[ "$active_found" == false ]]; then
        echo "No active cloudflared services"
    fi
}

# Delete tunnel
delete_tunnel() {
    echo
    log_info "=== Delete Tunnel ==="
    
    if ! check_auth; then
        return 1
    fi
    
    # Select tunnel to delete
    if ! select_tunnel "Select tunnel to delete"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
    
    # Get tunnel ID
    local tunnel_id
    tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}')
    if [[ -z "$tunnel_id" ]]; then
        log_error "Tunnel not found: $tunnel_name"
        return 1
    fi
    
    echo
    echo -e "${RED}WARNING: This will permanently delete the tunnel!${NC}"
    echo
    log_warning "This will:"
    echo "• Stop the tunnel service (if running)"
    echo "• Delete the tunnel from Cloudflare"
    echo "• Remove local configuration files"
    echo "• Remove DNS routes (if any)"
    echo
    echo -e "${YELLOW}Tunnel to delete: $tunnel_name ($tunnel_id)${NC}"
    echo
    
    while true; do
        read -p "Type 'DELETE' in capital letters to confirm deletion: " confirm
        if [[ "$confirm" == "DELETE" ]]; then
            break
        elif [[ -z "$confirm" ]]; then
            log_info "Operation cancelled"
            return 0
        else
            log_error "Please type 'DELETE' exactly to confirm, or press Enter to cancel"
        fi
    done
    
    echo
    log_info "Starting deletion process..."
    
    # Stop service if running
    local service_name="cloudflared-${tunnel_name}"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "Stopping service: $service_name"
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload
        log_success "Service stopped and removed"
    fi
    
    # Remove DNS routes
    log_info "Checking for DNS routes..."
    local routes
    routes=$(cloudflared tunnel route dns list 2>/dev/null | grep "$tunnel_id" | awk '{print $1}' || true)
    if [[ -n "$routes" ]]; then
        log_info "Removing DNS routes..."
        while IFS= read -r route; do
            if [[ -n "$route" ]]; then
                if cloudflared tunnel route dns delete "$route"; then
                    log_success "Removed DNS route: $route"
                else
                    log_warning "Failed to remove: $route"
                fi
            fi
        done <<< "$routes"
    else
        log_info "No DNS routes found"
    fi
    
    # Delete tunnel from Cloudflare
    log_info "Deleting tunnel from Cloudflare..."
    if cloudflared tunnel delete "$tunnel_name"; then
        log_success "Tunnel deleted from Cloudflare"
    else
        log_error "Failed to delete tunnel from Cloudflare"
    fi
    
    # Remove local files
    log_info "Removing local configuration files..."
    rm -f "$CONFIG_DIR/config_${tunnel_name}.yml"
    rm -f "$CONFIG_DIR/${tunnel_id}.json"
    
    # Create final backup of deleted tunnel info
    local delete_backup="$BACKUP_DIR/deleted_${tunnel_name}_$(date +%s).txt"
    cat > "$delete_backup" << EOF
Deleted Tunnel Information
=========================
Tunnel Name: $tunnel_name
Tunnel ID: $tunnel_id
Deleted: $(date)
Service: $service_name

This tunnel has been permanently deleted.
EOF
    
    log_success "Tunnel deletion completed!"
    log_info "Deletion record saved to: $delete_backup"
}

# System setup and environment check
system_setup() {
    echo
    log_info "=== System Setup and Environment Check ==="
    
    # Create directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    
    # Check network
    check_network
    
    # Install dependencies if needed
    if ! command -v wget &> /dev/null || ! command -v python3 &> /dev/null; then
        log_info "Installing missing dependencies..."
        install_dependencies
    fi
    
    # Check/install cloudflared
    check_cloudflared
    
    # Check authentication
    check_auth
    
    log_success "System setup completed successfully"
    
    echo
    log_info "System is ready for tunnel management!"
    echo "Recommended next steps:"
    echo "1. Create a new tunnel (option 1)"
    echo "2. Add ingress rules (option 4)"
    echo "3. Create DNS routes (option 15)"
    echo "4. Start tunnel service (option 6)"
}

# Backup and restore configurations
backup_restore() {
    echo
    log_info "=== Backup & Restore ==="
    
    echo "1) Create backup"
    echo "2) List backups"
    echo "3) Restore from backup"
    echo "4) Back to main menu"
    
    while true; do
        read -p "Choose option (1-4): " backup_choice
        case $backup_choice in
            1)
                local backup_dir="$BACKUP_DIR/full_backup_$(date +%Y%m%d_%H%M%S)"
                mkdir -p "$backup_dir"
                
                # Backup config directory
                if [[ -d "$CONFIG_DIR" ]]; then
                    cp -r "$CONFIG_DIR" "$backup_dir/"
                fi
                
                # Export tunnel list
                if cloudflared tunnel list &> /dev/null; then
                    cloudflared tunnel list > "$backup_dir/tunnel_list.txt"
                    cloudflared tunnel route dns list > "$backup_dir/dns_routes.txt" 2>/dev/null || true
                fi
                
                log_success "Backup created: $backup_dir"
                break
                ;;
            2)
                echo
                echo -e "${CYAN}Available backups:${NC}"
                ls -la "$BACKUP_DIR" 2>/dev/null || echo "No backups found"
                break
                ;;
            3)
                echo
                echo -e "${CYAN}Available backups:${NC}"
                ls "$BACKUP_DIR" 2>/dev/null || echo "No backups found"
                
                read -p "Enter backup directory name to restore: " backup_name
                if [[ -n "$backup_name" && -d "$BACKUP_DIR/$backup_name" ]]; then
                    log_warning "This will overwrite current configurations"
                    read -p "Continue? (y/n): " confirm
                    if [[ $confirm == "y" || $confirm == "Y" ]]; then
                        if [[ -d "$BACKUP_DIR/$backup_name/.cloudflared" ]]; then
                            cp -r "$BACKUP_DIR/$backup_name/.cloudflared/"* "$CONFIG_DIR/"
                            log_success "Configuration restored from: $backup_name"
                        else
                            log_error "Invalid backup directory"
                        fi
                    fi
                else
                    log_error "Backup not found"
                fi
                break
                ;;
            4)
                break
                ;;
            *)
                log_error "Please choose 1-4"
                ;;
        esac
    done
}

# Update cloudflared
update_cloudflared() {
    echo
    log_info "=== Update Cloudflared ==="
    
    if command -v cloudflared &> /dev/null; then
        local current_version
        current_version=$(cloudflared version 2>/dev/null | head -n1 | awk '{print $3}' 2>/dev/null || echo "unknown")
        log_info "Current version: $current_version"
    fi
    
    log_info "Installing latest version..."
    install_cloudflared
    
    local new_version
    new_version=$(cloudflared version 2>/dev/null | head -n1 | awk '{print $3}' 2>/dev/null || echo "unknown")
    log_success "Updated to version: $new_version"
    
    echo
    log_info "Note: Restart tunnel services to use the new version"
}

# Show usage help
show_help() {
    cat << 'EOF'
Cloudflare Tunnel Manager - Complete Guide
==========================================

QUICK START (First Time Users):
1. Run: sudo ./cf-tunnel.sh
2. Choose "0) System Setup" - installs dependencies and authenticates
3. Choose "1) Create New Tunnel" - creates your first tunnel
4. Choose "4) Add Ingress Rule" - maps domain to local service
5. Choose "15) Manage DNS Routes" - creates DNS records automatically
6. Choose "6) Start Tunnel Service" - starts the tunnel

COMMAND LINE OPTIONS:
  --status    Show all tunnel services status
  --logs      Show recent logs from all tunnels
  --help      Show this help

WORKFLOW EXAMPLES:

Basic Web Service:
- Create tunnel: "mytunnel"
- Add ingress: app.example.com -> http://localhost:8080
- Create DNS route: app.example.com -> mytunnel
- Start service

Multiple Services (one tunnel):
- Create tunnel: "main"
- Add ingress: api.example.com -> http://localhost:3000
- Add ingress: web.example.com -> http://localhost:8080
- Create DNS routes for both domains
- Start service

SSH Access:
- Create tunnel: "ssh-tunnel"
- Add ingress: ssh.example.com -> ssh://localhost:22
- Create DNS route
- Start service
- Connect: ssh user@ssh.example.com

IMPORTANT NOTES:
- DNS routes are managed automatically by Cloudflare
- Each tunnel can handle multiple domains/services
- Services are created independently and can run simultaneously
- Configuration files are stored in ~/.cloudflared/
- Backups are automatically created before changes

TROUBLESHOOTING:
- Use option 5 "Test Ingress Rules" to verify configuration
- Check logs with option 9 "Show Service Status"
- Use option 13 "Backup & Restore" if configuration breaks
- Validate config with cloudflared tunnel ingress validate

FILE LOCATIONS:
- Configs: ~/.cloudflared/config_<tunnel>.yml
- Credentials: ~/.cloudflared/<tunnel-id>.json
- Backups: ~/cloudflared_backups/
- Logs: /var/log/cloudflared_manager.log
- Services: /etc/systemd/system/cloudflared-<tunnel>.service

For detailed Cloudflare documentation:
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
EOF
}

# Handle command line arguments
handle_args() {
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --logs)
            echo "Recent logs from all cloudflared services:"
            echo "=========================================="
            local service_found=false
            while IFS= read -r service; do
                if [[ -n "$service" ]]; then
                    service_found=true
                    echo
                    echo "--- $service ---"
                    journalctl -u "$service" --no-pager -n 20 --since "1 hour ago"
                fi
            done < <(systemctl list-units --type=service 2>/dev/null | grep cloudflared | awk '{print $1}')
            
            if [[ "$service_found" == false ]]; then
                echo "No cloudflared services found"
            fi
            exit 0
            ;;
    esac
}


# add testing function 20250703
# Test tunnel with temporary web server
test_tunnel_connectivity() {
    echo
    log_info "=== Test Tunnel Connectivity ==="
    
    # Check if test files exist
    local required_files=("test_server.py" "test_page.html" "add_test_rule.py")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required file missing: $file"
            echo "Please ensure all test files are in the same directory as the script:"
            printf "• %s\n" "${required_files[@]}"
            return 1
        fi
    done
    
    # Select tunnel to test
    if ! select_tunnel "Select tunnel to test connectivity"; then
        return 1
    fi
    
    local tunnel_name="$selected_tunnel"
    local config_file
        config_file=$(find_tunnel_config "$tunnel_name") || {
        log_error "Config file not found for tunnel: $tunnel_name"
        return 1
    }
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Show current ingress rules
    echo
    echo -e "${CYAN}Current ingress rules for $tunnel_name:${NC}"
    echo "----------------------------------------"
    grep -A 10 "ingress:" "$config_file" | grep -E "(hostname|service)" | head -5
    echo "----------------------------------------"
    
    # Choose test method
    echo
    echo "Test options:"
    echo "1) Create temporary test service on port 10101"
    echo "2) Test existing service"
    echo "3) Back to main menu"
    
    while true; do
        read -p "Choose option (1-3): " test_choice
        case $test_choice in
            1)
                create_temp_test_service
                break
                ;;
            2)
                test_existing_service
                break
                ;;
            3)
                return 0
                ;;
            *)
                log_error "Please choose 1-3"
                ;;
        esac
    done
}

# Create temporary test service
create_temp_test_service() {
    local test_port=10101
    local test_hostname
    
    echo
    read -p "Enter test hostname (e.g., test.example.com): " test_hostname
    if [[ -z "$test_hostname" ]]; then
        log_error "Hostname cannot be empty"
        return 1
    fi
    
    if ! validate_hostname "$test_hostname"; then
        log_error "Invalid hostname format"
        return 1
    fi
    
    # Check if port is available
    if netstat -ln 2>/dev/null | grep -q ":$test_port "; then
        log_error "Port $test_port is already in use"
        return 1
    fi
    
    # Start test server
    log_info "Starting test server on port $test_port..."
    python3 test_server.py $test_port &
    local server_pid=$!
    
    sleep 2
    
    # Check if server started successfully
    if ! kill -0 $server_pid 2>/dev/null; then
        log_error "Failed to start test server"
        return 1
    fi
    
    log_success "Test server started on port $test_port (PID: $server_pid)"
    
    # Backup original config
    local backup_file="$BACKUP_DIR/config_${tunnel_name}_test_$(date +%s).yml"
    cp "$config_file" "$backup_file"
    
    # Add temporary ingress rule using external Python script
    log_info "Adding temporary ingress rule..."
    if python3 add_test_rule.py "$config_file" "$test_hostname" "$test_port"; then
        log_success "Test ingress rule added"
    else
        log_error "Failed to add test ingress rule"
        kill $server_pid 2>/dev/null
        return 1
    fi
    
    # Restart tunnel service if running
    local service_name="cloudflared-${tunnel_name}"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "Restarting tunnel service..."
        systemctl restart "$service_name"
        sleep 3
    fi
    
    # Create DNS route
    echo
    log_info "Creating temporary DNS route..."
    if cloudflared tunnel route dns "$tunnel_name" "$test_hostname"; then
        log_success "DNS route created: $test_hostname -> $tunnel_name"
    else
        log_warning "Failed to create DNS route (you may need to add it manually)"
    fi
    
    # Show test instructions
    echo
    echo -e "${GREEN}=== Test Setup Complete ===${NC}"
    echo -e "${CYAN}Test URL: https://$test_hostname${NC}"
    echo
    echo "Instructions:"
    echo "1. Wait 1-2 minutes for DNS propagation"
    echo "2. Open https://$test_hostname in your browser"
    echo "3. You should see the 'Tunnel Test Success!' page"
    echo "4. Press Enter when done testing to cleanup"
    echo
    
    read -p "Press Enter to cleanup test environment..."
    
    # Cleanup
    cleanup_test_environment "$server_pid" "$backup_file" "$config_file" "$test_hostname" "$service_name"
}

# Cleanup test environment
cleanup_test_environment() {
    local server_pid="$1"
    local backup_file="$2"
    local config_file="$3"
    local test_hostname="$4"
    local service_name="$5"
    
    log_info "Cleaning up test environment..."
    
    # Stop test server
    if kill $server_pid 2>/dev/null; then
        log_info "Test server stopped"
    fi
    
    # Restore original config
    if [[ -f "$backup_file" ]]; then
        mv "$backup_file" "$config_file"
        log_info "Original configuration restored"
    fi
    
    # Remove DNS route
    if cloudflared tunnel route dns delete "$test_hostname" 2>/dev/null; then
        log_info "Test DNS route removed"
    fi
    
    # Restart tunnel service
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "Restoring tunnel service..."
        systemctl restart "$service_name"
    fi
    
    log_success "Test environment cleaned up"
}

# Test existing service
test_existing_service() {
    echo
    echo "This will test connectivity to your existing services"
    echo
    
    # Get hostnames from config
    local hostnames
    mapfile -t hostnames < <(grep "hostname:" "$config_file" | sed -E 's/^[[:space:]]*hostname:[[:space:]]*//' | grep -v '^$' | sort)


    if [[ ${#hostnames[@]} -eq 0 ]]; then
        log_warning "No hostnames found in configuration"
        return 1
    fi
    
    echo -e "${CYAN}Available hostnames to test:${NC}"
    for i in "${!hostnames[@]}"; do
        echo "$((i+1))) ${hostnames[i]}"
    done
    
    while true; do
        read -p "Select hostname to test (1-${#hostnames[@]}) or 0 to cancel: " choice
        
        if [[ "$choice" == "0" ]]; then
            return 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#hostnames[@]} ]]; then
            local test_hostname="${hostnames[$((choice-1))]}"
            break
        fi
        
        log_error "Please enter a number between 1 and ${#hostnames[@]}, or 0 to cancel"
    done
    
    echo
    log_info "Testing connectivity to: $test_hostname"
    
    # Test DNS resolution
    echo -n "• DNS resolution: "
    if nslookup "$test_hostname" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        log_warning "DNS resolution failed"
    fi
    
    # Test HTTP response
    echo -n "• HTTP response: "
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$test_hostname" --max-time 10 2>/dev/null)
    
    if [[ "$http_code" =~ ^[2-3][0-9][0-9]$ ]]; then
        echo -e "${GREEN}✓ ($http_code)${NC}"
        log_success "Tunnel is working correctly!"
    elif [[ "$http_code" == "000" ]]; then
        echo -e "${RED}✗ (Connection failed)${NC}"
        log_error "Cannot connect to service"
    else
        echo -e "${YELLOW}! ($http_code)${NC}"
        log_warning "Service responded but may have issues"
    fi
    
    # Test tunnel status
    echo -n "• Tunnel status: "
    if cloudflared tunnel info "$tunnel_name" 2>/dev/null | grep -q "connection"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        log_warning "Tunnel may not be running"
    fi
    
    echo
    read -p "Open $test_hostname in browser for manual testing? (y/n): " open_browser
    if [[ $open_browser == "y" || $open_browser == "Y" ]]; then
        if command -v xdg-open &> /dev/null; then
            xdg-open "https://$test_hostname"
        elif command -v open &> /dev/null; then
            open "https://$test_hostname"
        else
            echo "Please manually open: https://$test_hostname"
        fi
    fi
}

# Main menu
show_menu() {
    echo
    echo "============================================"
    echo "   Cloudflare Tunnel Manager v2.1"
    echo "============================================"
    echo " SETUP & INFO:"
    echo "  0)  System Setup & Environment Check"
    echo "  1)  Create New Tunnel"
    echo "  2)  List All Tunnels"
    echo "  3)  Show Tunnel Details"
    echo
    echo " CONFIGURATION:"
    echo "  4)  Add Ingress Rule"
    echo "  5)  Test Ingress Rules"
    echo "  11) Remove Ingress Rule"
    echo
    echo " SERVICE MANAGEMENT:"
    echo "  6)  Start Tunnel Service"
    echo "  7)  Stop Tunnel Service"
    echo "  8)  Restart Tunnel Service"
    echo "  9)  Show Service Status"
    echo
    echo " DNS & ROUTING:"
    echo "  15) Manage DNS Routes"
    echo "  16) Test Tunnel Connectivity"
    echo
    echo " MAINTENANCE:"
    echo "  10) Delete Tunnel"
    echo "  13) Backup & Restore"
    echo "  14) Update Cloudflared"
    echo
    echo " HELP & EXIT:"
    echo "  h)  Show Complete Help Guide"
    echo "  q)  Exit"
    echo "============================================"
}

# Main function
main() {
    # Handle command line arguments
    handle_args "$1"
    
    # Check root privileges
    check_root
    
    # Create directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    
    # Main loop
    while true; do
        show_menu
        read -p "Choose option: " choice
        
        case $choice in
            0) system_setup ;;
            1) create_tunnel ;;
            2) list_tunnels ;;
            3) show_tunnel_details ;;
            4) add_ingress_rule ;;
            5) test_ingress_rules ;;
            6) start_tunnel ;;
            7) stop_tunnel ;;
            8) restart_tunnel ;;
            9) show_status ;;
            10) delete_tunnel ;;
            11) remove_ingress_rule ;;
            13) backup_restore ;;
            14) update_cloudflared ;;
            15) manage_dns_routes ;;
            16) test_tunnel_connectivity ;;
            h) show_help ;;
            q) 
                log_info "Exiting Cloudflare Tunnel Manager"
                exit 0
                ;;
            *)
                log_error "Invalid option. Please try again."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Execute main function
main "$@"

