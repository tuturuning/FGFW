[Unit]
Description=cloudflared tunnel
After=network.target

[Service]
Type=simple
ExecStart={{CLOUDFLARED_BIN}} tunnel run --token {{ARGO_TOKEN}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

