Include /etc/ssh/sshd_config.d/*.conf

Port 22
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 120
ClientAliveCountMax 3
