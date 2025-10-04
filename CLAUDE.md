# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Bitwarden password manager deployment using Docker containers. The project consists of a simple Docker Compose setup that runs:

- **Vaultwarden**: A lightweight Bitwarden server implementation
- **Caddy**: A reverse proxy server for handling HTTP/HTTPS traffic

## Architecture

The system uses Docker for containerization with Nginx as the reverse proxy:

1. **Vaultwarden Service**: 
   - Runs the core password manager backend
   - Exposed on port 8080 for internal access
   - Uses persistent volume storage at `/mnt/ssd/nas/bitwarden-data/vaultwarden`
   - Has WebSocket support enabled for real-time notifications
   - Protected by admin token authentication

2. **Nginx Reverse Proxy**:
   - Handles SSL termination and routing
   - Proxies requests to Vaultwarden on localhost:8080
   - Configured for bitwarden.shampadsr.com subdomain

## Environment Configuration

The project now keeps environment variables in `env/vaultwarden.env`:
- `ADMIN_TOKEN`: Admin interface access token
- `DOMAIN`: Your Bitwarden domain URL (e.g., https://bitwarden.shampadsr.com)
- `WEBSOCKET_ENABLED`: Enable WebSocket support (true/false)

**Important**: Never commit the `env/` directory to version control as it contains sensitive information.

## Common Commands

### Docker Operations
```bash
# Start the services
docker-compose up -d

# Stop the services  
docker-compose down

# View logs
docker-compose logs -f

# Restart services
docker-compose restart

# Pull latest images
docker-compose pull
```

### System Management
```bash
# Check service status
docker-compose ps

# Access container shell
docker-compose exec vaultwarden sh
docker-compose exec caddy sh
```

## Nginx Configuration

To integrate with your existing Nginx setup:

1. Add `bitwarden.shampadsr.com` to your HTTP redirect server block
2. Add the Bitwarden server block from `nginx-bitwarden-config.txt`
3. Reload Nginx: `sudo nginx -t && sudo systemctl reload nginx`

## Important Notes

- Data is persisted to `/mnt/ssd/nas/bitwarden-data/` on the host system
- Admin interface is protected by token authentication
- Vaultwarden runs on port 8080 (internal access only)
- Nginx handles SSL termination and public access via bitwarden.shampadsr.com
- Service is configured to restart automatically unless explicitly stopped
