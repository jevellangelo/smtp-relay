FROM alpine:3.19

RUN apk add --no-cache \
    postfix \
    postfix-pcre \
    openssl \
    cyrus-sasl

COPY config/main.cf /etc/postfix/main.cf
COPY config/master.cf /etc/postfix/master.cf
COPY config/mynetworks /etc/postfix/mynetworks
COPY config/transport /etc/postfix/transport
COPY config/tls_policy /etc/postfix/tls_policy
COPY config/header_checks /etc/postfix/header_checks

# Set mailname — used as the envelope sender domain of last resort
# Replace with your primary domain
RUN echo "yourdomain.com" > /etc/mailname

# Fix file permissions to suppress Postfix security warnings
RUN chmod 640 /etc/postfix/main.cf \
              /etc/postfix/master.cf \
              /etc/postfix/transport \
              /etc/postfix/tls_policy \
              /etc/postfix/mynetworks \
              /etc/postfix/header_checks

# Generate DH params for TLS forward secrecy (takes a few minutes at build time)
RUN openssl dhparam -out /etc/postfix/dh2048.pem 2048

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
