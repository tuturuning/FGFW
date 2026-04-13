[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart={{XRAY_BIN}} run -c {{XRAY_CONFIG}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

