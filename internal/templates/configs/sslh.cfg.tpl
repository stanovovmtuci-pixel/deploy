verbose: false;
foreground: false;
inetd: false;
numeric: false;
transparent: false;
timeout: 5;
user: "sslh";
pidfile: "/run/sslh/sslh.pid";

listen:
(
    { host: "0.0.0.0"; port: "443"; },
    { host: "::";      port: "443"; }
);

protocols:
(
    { name: "tls"; host: "127.0.0.1"; port: "8444"; sni_hostnames: [ "{{NODE_FQDN}}" ]; },
    { name: "tls"; host: "127.0.0.1"; port: "8443"; sni_hostnames: [ "{{SSLH_CAMO_SNI}}", "www.{{SSLH_CAMO_SNI}}" ]; },
    { name: "tls"; host: "127.0.0.1"; port: "8443"; }
);
