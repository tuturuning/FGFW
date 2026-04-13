[Unit]
Description=sing-box Service
After=network.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
Environment=ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true
ExecStart={{SINGBOX_BIN}} run -c {{SINGBOX_CONFIG}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
