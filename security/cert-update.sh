#!/bin/bash
#
# Set up certificate for use.
#
# VERSION       :0.12.1
# DATE          :2016-05-03
# URL           :https://github.com/szepeviktor/debian-server-tools
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+
# DEPENDS       :apt-get install openssl ca-certificates
# LOCATION      :/usr/local/sbin/cert-update.sh

# Usage
#
# See cert-update-manuale-CN.sh

# @TODO Add apache SSLOpenSSLConfCmd for OpenSSL 1.0.2+

Die() {
    local RET="$1"
    shift
    echo -e "$*" 1>&2
    exit "$RET"
}

Readkey() {
    read -r -p "Press any key ..." -n 1 -s
    echo
}

Check_requirements() {
    if [ "$(id --user)" != 0 ]; then
        Die 1 "You need to be root."
    fi
    if [ "$(stat --format=%a .)" != 700 ] \
        #|| [ "$(stat --format=%u .)" != 0 ]; then
        #Die 2 "This directory needs to be private (0700) and owned by root."
        then
        Die 2 "This directory needs to be private (0700)."
    fi
    if ! [ -f "$INT" ] || ! [ -f "$PRIV" ] || ! [ -f "$PUB" ] || ! [ -f "$CABUNDLE" ]; then
        Die 3 "Missing cert or CA bundle."
    fi
    if ! [ -d "$PRIV_DIR" ] || ! [ -d "$PUB_DIR" ]; then
        Die 4 "Missing cert directory."
    fi
    # FIXME Was 0710. Why?
    if [ "$(stat --format=%a "$PRIV_DIR")" != 700 ] \
        || [ "$(stat --format=%u "$PRIV_DIR")" != 0 ]; then
        Die 5 "Private cert directory needs to be private (0700) and owned by root."
    fi
    if ! [ -f /usr/local/sbin/cert-expiry.sh ] || ! [ -f /etc/cron.weekly/cert-expiry1 ]; then
        Die 6 "./install.sh monitoring/cert-expiry.sh"
    fi

    # Check moduli of certificates
    PUB_MOD="$(openssl x509 -noout -modulus -in "$PUB" | openssl sha256)"
    PRIV_MOD="$(openssl rsa -noout -modulus -in "$PRIV" | openssl sha256)"
    if [ "$PUB_MOD" != "$PRIV_MOD" ]; then
        Die 7 "Mismatching certs."
    fi

    # Verify public cert is signed by the intermediate cert if intermediate is present
    if [ -s "$INT" ] && ! openssl verify -purpose sslserver -CAfile "$INT" "$PUB" | grep -qFx "${PUB}: OK"; then
        Die 8 "Mismatching intermediate cert."
    fi
}

Protect_certs() {
    # Are certificates readable?
    chown root:root "$INT" "$PRIV" "$PUB" || Die 10 "certs owner"
    chmod 0600 "$INT" "$PRIV" "$PUB" || Die 11 "certs perms"
}

Courier_mta() {
    [ -z "$COURIER_COMBINED" ] && return 1
    [ -z "$COURIER_DHPARAMS" ] && return 1

    [ -d "$(dirname "$COURIER_COMBINED")" ] || Die 20 "courier ssl dir"

    #cat "$PUB" "$INT" "$PRIV" > "$COURIER_COMBINED" || Die 21 "courier cert creation"
    # From Debian jessie on: private + public + intermediate
    cat "$PRIV" "$PUB" "$INT" > "$COURIER_COMBINED" || Die 21 "courier cert creation"
    chown daemon:root "$COURIER_COMBINED" || Die 22 "courier owner"
    chmod 0600 "$COURIER_COMBINED" || Die 23 "courier perms"

    nice openssl dhparam 2048 > "$COURIER_DHPARAMS" || Die 24 "courier DH params"
    chown daemon:root "$COURIER_DHPARAMS" || Die 25 "courier DH params owner"
    chmod 0600 "$COURIER_DHPARAMS" || Die 26 "courier DH params perms"

    SERVER_NAME="$(head -n 1 /etc/courier/me)"

    # Check config files for SMTP STARTTLS, SMTPS and outgoing SMTP
    # By default don't check client certificate
    #if grep -q "^TLS_CERTFILE=${COURIER_COMBINED}\$" /etc/courier/courierd \
    if grep -q "^TLS_DHPARAMS=${COURIER_DHPARAMS}\$" /etc/courier/courierd \
        && grep -q "^TLS_CERTFILE=${COURIER_COMBINED}\$" /etc/courier/esmtpd \
        && grep -q "^TLS_DHPARAMS=${COURIER_DHPARAMS}\$" /etc/courier/esmtpd \
        && grep -q "^TLS_CERTFILE=${COURIER_COMBINED}\$" /etc/courier/esmtpd-ssl \
        && grep -q "^TLS_DHPARAMS=${COURIER_DHPARAMS}\$" /etc/courier/esmtpd-ssl; then

        service courier-mta restart
        service courier-mta-ssl restart

        # Tests SMTP STARTTLS, SMTPS
        echo QUIT | openssl s_client -CAfile "$CABUNDLE" -crlf \
            -servername "$SERVER_NAME" -connect "${SERVER_NAME}:25" -starttls smtp
        echo "SMTP STARTTLS result=$?"
        Readkey
        echo QUIT | openssl s_client -CAfile "$CABUNDLE" -crlf \
            -servername "$SERVER_NAME" -connect "${SERVER_NAME}:465"
        echo "SMTPS result=$?"
    else
        echo "Add 'TLS_CERTFILE=${COURIER_COMBINED}' to courier configs: esmtpd, esmtpd-ssl" 1>&2
        echo "echo QUIT|openssl s_client -CAfile ${CABUNDLE} -crlf -servername ${SERVER_NAME} -connect ${SERVER_NAME}:25 -starttls smtp" 1>&2
        echo "echo QUIT|openssl s_client -CAfile ${CABUNDLE} -crlf -servername ${SERVER_NAME} -connect ${SERVER_NAME}:465" 1>&2
    fi

    # Check config file for IMAPS
    if grep -q "^TLS_CERTFILE=${COURIER_COMBINED}\$" /etc/courier/imapd-ssl \
        && grep -q "^TLS_DHPARAMS=${COURIER_DHPARAMS}\$" /etc/courier/imapd-ssl; then

        service courier-imap-ssl restart

        # Tests IMAPS
        echo QUIT | openssl s_client -CAfile "$CABUNDLE" -crlf \
            -servername "$SERVER_NAME" -connect "${SERVER_NAME}:993"
        echo "IMAPS result=$?"
    else
        echo "Add 'TLS_CERTFILE=${COURIER_COMBINED}' to courier config imapd-ssl" 1>&2
        echo "echo QUIT|openssl s_client -CAfile ${CABUNDLE} -crlf -servername ${SERVER_NAME} -connect ${SERVER_NAME}:993" 1>&2
    fi

    echo "$(tput setaf 1)WARNING: Update msmtprc on SMTP clients.$(tput sgr0)"
}

Apache2() {
    [ -z "$APACHE_PUB" ] && return 1
    [ -z "$APACHE_PRIV" ] && return 1
    [ -z "$APACHE_VHOST_CONFIG" ] && return 1

    [ -d "$(dirname "$APACHE_PUB")" ] || Die 40 "apache ssl dir"

    {
        cat "$PUB" "$INT"
        #nice openssl dhparam 4096
        nice openssl dhparam 2048
    } > "$APACHE_PUB" || Die 41 "apache cert creation"
    cp "$PRIV" "$APACHE_PRIV" || Die 42 "apache private"
    chown root:root "$APACHE_PUB" "$APACHE_PRIV" || Die 43 "apache owner"
    chmod 0640 "$APACHE_PUB" "$APACHE_PRIV" || Die 44 "apache perms"

    # Check config
    if sed -e "s;\${SITE_DOMAIN};${APACHE_DOMAIN};" "$APACHE_VHOST_CONFIG" \
        | grep -q "^\s*SSLCertificateFile\s\+${APACHE_PUB}$" \
        && sed -e "s;\${SITE_DOMAIN};${APACHE_DOMAIN};" "$APACHE_VHOST_CONFIG" \
        | grep -q "^\s*SSLCertificateKeyFile\s\+${APACHE_PRIV}$"; then
        # @TODO Moved to /etc/apache2/mods-available/ssl.conf
        #&& grep -q "^\s*SSLCACertificatePath\s\+/etc/ssl/certs/$" "$APACHE_VHOST_CONFIG" \
        #&& grep -q "^\s*SSLCACertificateFile\s\+${CABUNDLE}$" "$APACHE_VHOST_CONFIG"; then

        apache2ctl configtest && service apache2 restart

        # Test HTTPS
        # FIXME        sed -n -e
        SERVER_NAME="$(grep -i -o -m1 "ServerName\s\+\S\+" "$APACHE_VHOST_CONFIG" | cut -d " " -f 2)"
        # FIXME "ServerName www.${SITE_DOMAIN}"
        if [ "$SERVER_NAME" == "\${SITE_DOMAIN}" ]; then
            SERVER_NAME="$(sed -ne '0,/^\s\+Define\s\+SITE_DOMAIN\s\+\(\S\+\).*$/s//\1/p' "$APACHE_VHOST_CONFIG")"
        fi
        echo -n | openssl s_client -CAfile "$CABUNDLE" -servername "$SERVER_NAME" -connect "${SERVER_NAME}:443"
        echo "HTTPS result=$?"
    else
        #echo "Edit Apache SSLCertificateFile, SSLCertificateKeyFile, SSLCACertificatePath and SSLCACertificateFile" 1>&2
        echo "Edit Apache SSLCertificateFile, SSLCertificateKeyFile" 1>&2
        echo "echo -n | openssl s_client -CAfile ${CABUNDLE} -servername ${SERVER_NAME} -connect ${SERVER_NAME}:443" 1>&2
    fi
}

Nginx() {
    [ -z "$NGINX_PUB" ] && return 1
    [ -z "$NGINX_DHPARAM" ] && return 1
    [ -z "$NGINX_PRIV" ] && return 1
    [ -z "$NGINX_VHOST_CONFIG" ] && return 1

    [ -d "$(dirname "$NGINX_PUB")" ] || Die 70 "nginx ssl dir"

    cat "$PUB" "$INT" > "$NGINX_PUB" || Die 71 "nginx cert creation"
    nice openssl dhparam 2048 > "$NGINX_DHPARAM" || Die 72 "nginx private"
    cp "$PRIV" "$NGINX_PRIV" || Die 73 "nginx private"
    chown root:root "$NGINX_PUB" "$NGINX_PRIV" || Die 74 "nginx owner"
    chmod 0640 "$NGINX_PUB" "$NGINX_PRIV" || Die 75 "nginx perms"

    # Check config
    if  grep -q "^\s*ssl_certificate\s\+${NGINX_PUB}\$" "$NGINX_VHOST_CONFIG" \
        && grep -q "^\s*ssl_certificate_key\s\+${NGINX_PRIV}\$" "$NGINX_VHOST_CONFIG" \
        && grep -q "^\s*ssl_dhparam\s\+${NGINX_DHPARAM}\$" "$NGINX_VHOST_CONFIG"; then

        nginx -t && service nginx restart

        # Test HTTPS
        SERVER_NAME="$(sed -ne '/^\s*server_name\s\+\(\S\+\);.*$/{s//\1/p;q;}' "$NGINX_VHOST_CONFIG")"
        echo -n | openssl s_client -CAfile "$CABUNDLE" \
            -servername "$SERVER_NAME" -connect "${SERVER_NAME}:443"
        echo "HTTPS result=$?"
    else
        echo "Edit Nginx ssl_certificate and ssl_certificate_key and ssl_dhparam" 1>&2
    fi
}

Proftpd() {
    [ -z "$PROFTPD_PUB" ] && return 1
    [ -z "$PROFTPD_PRIV" ] && return 1
    [ -z "$PROFTPD_INT" ] && return 1

    [ -d "$(dirname "$APACHE_PUB")" ] || Die 30 "proftpd ssl dir"

    cp "$PUB" "$PROFTPD_PUB" || Die 31 "proftpd public"
    cp "$PRIV" "$PROFTPD_PRIV" || Die 32 "proftpd private"
    cp "$INT" "$PROFTPD_INT" || Die 33 "proftpd intermediate"
    chown root:root "$PROFTPD_PUB" "$PROFTPD_PRIV" "$PROFTPD_INT" || Die 34 "proftpd owner"
    chmod 0600 "$PROFTPD_PUB" "$PROFTPD_PRIV" "$PROFTPD_INT" || Die 35 "proftpd perms"

    # Check config
    if  grep -q "^TLSRSACertificateFile\s*${PROFTPD_PUB}\$" /etc/proftpd/tls.conf \
        && grep -q "^TLSRSACertificateKeyFile\s*${PROFTPD_PRIV}\$" /etc/proftpd/tls.conf \
        && grep -q "^TLSCACertificateFile\s*${PROFTPD_INT}\$" /etc/proftpd/tls.conf; then

        service proftpd restart

        # Test FTP
        echo "QUIT" | openssl s_client -crlf -CAfile "$CABUNDLE" \
            -servername "$SERVER_NAME" -connect localhost:21 -starttls ftp
        echo "AUTH TLS result=$?"
    else
        echo "Edit ProFTPd TLSRSACertificateFile, TLSRSACertificateKeyFile and TLSCACertificateFile" 1>&2
    fi
}

Dovecot() {
    [ -z "$DOVECOT_PUB" ] && return 1
    [ -z "$DOVECOT_PRIV" ] && return 1

    [ -d "$(dirname "$DOVECOT_PUB")" ] || Die 50 "dovecot ssl dir"

    # Dovecot: public + intermediate
    cat "$PUB" "$INT" > "$DOVECOT_PUB" || Die 51 "dovecot cert creation"
    cat "$PRIV" > "$DOVECOT_PRIV" || Die 52 "dovecot private cert creation"
    chown root:root "$DOVECOT_PUB" "$DOVECOT_PRIV" || Die 53 "dovecot owner"
    chmod 0600 "$DOVECOT_PUB" "$DOVECOT_PRIV" || Die 54 "dovecot perms"

    # Check config files for ssl_cert, ssl_key
    if grep -q "^ssl_cert\s*=\s*<${DOVECOT_PUB}\$" /etc/dovecot/conf.d/10-ssl.conf \
        && grep -q "^ssl_key\s*=\s*<${DOVECOT_PRIV}\$" /etc/dovecot/conf.d/10-ssl.conf; then

        service dovecot restart

        # Tests POP3, POP3S, IMAP, IMAPS
        echo QUIT|openssl s_client -CAfile "$CABUNDLE" -crlf -connect localhost:110 -starttls pop3
        echo "POP3 STARTTLS result=$?"
        Readkey
        echo QUIT|openssl s_client -CAfile "$CABUNDLE" -crlf -connect localhost:995
        echo "POP3S result=$?"
        Readkey
        echo QUIT|openssl s_client -CAfile "$CABUNDLE" -crlf -connect localhost:143 -starttls imap
        echo "IMAP STARTTLS result=$?"
        Readkey
        echo QUIT|openssl s_client -CAfile "$CABUNDLE" -crlf -connect localhost:993
        echo "IMAPS result=$?"
    else
        echo "Edit Dovecot ssl_cert and ssl_key" 1>&2
    fi
}

Webmin() {
    [ -z "$WEBMIN_COMBINED" ] && return 1
# @FIXME Could be a separate public key: "certfile="
    [ -z "$WEBMIN_INT" ] && return 1

    [ -d "$(dirname "$WEBMIN_COMBINED")" ] || Die 60 "webmin ssl dir"

    # Webmin: private + public
    cat "$PRIV" "$PUB" > "$WEBMIN_COMBINED" || Die 61 "webmin public"
    cp "$INT" "$WEBMIN_INT" || Die 62 "webmin intermediate"
    chown root:root "$WEBMIN_COMBINED" "$WEBMIN_INT" || Die 63 "webmin owner"
    chmod 0600 "$WEBMIN_COMBINED" "$WEBMIN_INT" || Die 64 "webmin perms"

    # Check config
    if  grep -q "^keyfile=${WEBMIN_COMBINED}\$" /etc/webmin/miniserv.conf \
        && grep -q "^extracas=${WEBMIN_INT}\$" /etc/webmin/miniserv.conf; then

        service webmin restart

        # Test HTTPS:10000
        echo -n | timeout 3 openssl s_client -CAfile "$CABUNDLE" -crlf -connect localhost:10000
        echo "HTTPS result=$?"
    else
        echo "Edit Webmin keyfile and extracas" 1>&2
    fi
}

Check_requirements
Protect_certs

Courier_mta && Readkey

Proftpd && Readkey

Apache2 && Readkey

Nginx && Readkey

Dovecot && Readkey

Webmin

echo "OK."
