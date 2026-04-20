[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd
ignoreip = {{F2B_IGNORE_IPS}}

[sshd]
enabled  = true
port     = 22
filter   = sshd
maxretry = 3
bantime  = 86400
